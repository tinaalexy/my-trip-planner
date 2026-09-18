#!/usr/bin/env bash
# Full AWS infrastructure provisioning for my-trip-advisor.
#
# Creates (in order, idempotent — safe to re-run):
#   1. ECR repository
#   2. S3 bucket (frontend, public access blocked)
#   3. Security groups  (EC2 + RDS)
#   4. RDS PostgreSQL   (db.t3.micro, free-tier)
#   5. ECS cluster + IAM roles + EC2 instance + task definition + service
#   6. CloudFront OAC + distribution
#   7. Update ECS task definition CORS_ORIGINS → CloudFront URL
#   8. Print GitHub Secrets summary + state file
#
# Usage:
#   bash scripts/aws-provision.sh
#
# Prerequisites:
#   - Run bash scripts/aws-free-tier-connect.sh first
#   - Docker installed (for the initial ECR image push)
#
# Required IAM permissions:
#   ecr:*, s3:*, rds:*, ec2:*, ecs:*, iam:*, logs:*, cloudfront:*
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── Load profile from state file (set by aws-free-tier-connect.sh) ───────────
STATE_FILE_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.aws-state.env"
if [[ -f "$STATE_FILE_EARLY" ]]; then
  _SAVED_PROFILE=$(grep "^AWS_PROFILE=" "$STATE_FILE_EARLY" 2>/dev/null | cut -d= -f2-)
  [[ -n "$_SAVED_PROFILE" ]] && export AWS_PROFILE="${AWS_PROFILE:-$_SAVED_PROFILE}"
fi
echo "Using AWS profile: ${AWS_PROFILE:-default}"

# ── Project config ────────────────────────────────────────────────────────────
REGION="${AWS_REGION:-ap-southeast-2}"
PROJECT="my-trip-advisor"
ECR_REPO="${PROJECT}-backend"
S3_BUCKET="${PROJECT}-frontend"
RDS_IDENTIFIER="${PROJECT}-db"
RDS_DB_NAME="tripplanner"
RDS_USER="tripuser"
EC2_SG_NAME="${PROJECT}-ec2-sg"
RDS_SG_NAME="${PROJECT}-rds-sg"
ECS_CLUSTER="${PROJECT}"
ECS_TASK_FAMILY="${PROJECT}-backend"
ECS_SERVICE="${PROJECT}-backend"
ECS_EXEC_ROLE="${PROJECT}-ecs-execution-role"
ECS_INSTANCE_ROLE="${PROJECT}-ecs-instance-role"
EC2_INSTANCE_PROFILE="${PROJECT}-ecs-instance-profile"
LOG_GROUP="/ecs/${ECS_TASK_FAMILY}"
STATE_FILE="$(dirname "${BASH_SOURCE[0]}")/../.aws-state.env"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'; BLD='\033[1m'; RST='\033[0m'
ok()   { printf "   ${GRN}✓${RST}  %s\n" "$1"; }
warn() { printf "   ${YLW}⚠${RST}  %s\n" "$1"; }
err()  { printf "   ${RED}✗${RST}  %s\n" "$1"; }
step() { echo;  printf "${BLD}▶  %s${RST}\n" "$1"; }
hr()   { echo "═══════════════════════════════════════════════════"; }
die()  { err "$1"; echo; exit 1; }

# ── State helpers ─────────────────────────────────────────────────────────────
save_state() { echo "$1=$2" >> "$STATE_FILE"; }
load_state() { grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
touch "$STATE_FILE"

hr
printf "${BLD}  AWS Infrastructure Provisioning — %s${RST}\n" "$PROJECT"
printf "  Region : %s\n" "$REGION"
hr

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 — Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 0 — Prerequisites"
command -v aws &>/dev/null || die "AWS CLI not installed."

IDENTITY=$(aws sts get-caller-identity --output json 2>&1) \
  || die "Not authenticated. Run: bash scripts/aws-free-tier-connect.sh"
ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
ok "Account : $ACCOUNT"
ok "Identity: $ARN"
ECR_REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

step "Phase 0 — Permission check"
PERM_FAIL=false
check_perm() {
  local label=$1 svc=$2; shift 2
  if aws "$svc" "$@" --region "$REGION" &>/dev/null 2>&1; then
    ok "$label"
  else
    err "$label — MISSING"
    PERM_FAIL=true
  fi
}
check_perm "ECR"        ecr        describe-repositories
check_perm "S3"         s3api      list-buckets
check_perm "EC2 / VPC"  ec2        describe-vpcs
check_perm "RDS"        rds        describe-db-instances
check_perm "ECS"        ecs        list-clusters
check_perm "IAM"        iam        list-roles
check_perm "CloudFront" cloudfront list-distributions

if $PERM_FAIL; then
  echo
  warn "Missing permissions — attach these policies to your IAM user:"
  echo "    AmazonEC2ContainerRegistryFullAccess"
  echo "    AmazonS3FullAccess  AmazonRDSFullAccess  AmazonVPCFullAccess"
  echo "    AmazonECS_FullAccess  IAMFullAccess  CloudFrontFullAccess"
  echo "    CloudWatchLogsFullAccess"
  hr; exit 1
fi

if ! command -v docker &>/dev/null; then
  warn "Docker not installed — initial ECR image push will be skipped."
  warn "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
  DOCKER_AVAILABLE=false
else
  ok "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  DOCKER_AVAILABLE=true
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — ECR
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 1 — ECR repository"
ECR_URI=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" --region "$REGION" \
  --query 'repositories[0].repositoryUri' --output text 2>/dev/null)

if [[ -z "$ECR_URI" || "$ECR_URI" == "None" ]]; then
  ECR_URI=$(aws ecr create-repository \
    --repository-name "$ECR_REPO" --region "$REGION" \
    --query 'repository.repositoryUri' --output text)
  ok "Created ECR repository: $ECR_URI"
else
  ok "ECR repository exists: $ECR_URI"
fi
save_state "ECR_URI" "$ECR_URI"

if $DOCKER_AVAILABLE; then
  step "Phase 1b — Push initial Docker image to ECR"
  EXISTING_IMAGE=$(aws ecr describe-images \
    --repository-name "$ECR_REPO" --region "$REGION" \
    --query 'imageDetails[0].imageTags[0]' --output text 2>/dev/null)
  if [[ -z "$EXISTING_IMAGE" || "$EXISTING_IMAGE" == "None" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    docker build -t "$ECR_URI:latest" "$REPO_ROOT/backend"
    docker push "$ECR_URI:latest"
    ok "Initial image pushed: $ECR_URI:latest"
  else
    ok "Image already exists in ECR — skipping build"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — S3
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 2 — S3 bucket"
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
  ok "S3 bucket exists: s3://$S3_BUCKET"
else
  aws s3api create-bucket \
    --bucket "$S3_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  aws s3api put-public-access-block \
    --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  ok "Created S3 bucket: s3://$S3_BUCKET (public access blocked)"
fi
save_state "S3_BUCKET" "$S3_BUCKET"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — VPC + Security groups
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 3 — VPC + Security groups"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].CidrBlock' --output text)
ok "Default VPC: $VPC_ID ($VPC_CIDR)"

SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
# Take just the first subnet for EC2 launch
FIRST_SUBNET=$(echo "$SUBNET_IDS" | cut -d',' -f1)
ok "Subnets: $SUBNET_IDS"
save_state "VPC_ID"     "$VPC_ID"
save_state "SUBNET_IDS" "$SUBNET_IDS"

# EC2 security group — port 80 inbound (API), all outbound (to reach RDS)
EC2_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$EC2_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$EC2_SG_ID" || "$EC2_SG_ID" == "None" ]]; then
  EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name "$EC2_SG_NAME" \
    --description "ECS EC2 instance — port 80 public" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$EC2_SG_ID" --region "$REGION" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
  ok "Created EC2 security group: $EC2_SG_ID (port 80 ← 0.0.0.0/0)"
else
  ok "EC2 SG exists: $EC2_SG_ID"
fi
save_state "EC2_SG_ID" "$EC2_SG_ID"

# RDS security group — port 5432 from EC2 SG only
RDS_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$RDS_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$RDS_SG_ID" || "$RDS_SG_ID" == "None" ]]; then
  RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "$RDS_SG_NAME" \
    --description "RDS PostgreSQL — port 5432 from ECS EC2 only" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG_ID" --region "$REGION" \
    --protocol tcp --port 5432 --source-group "$EC2_SG_ID" > /dev/null
  ok "Created RDS security group: $RDS_SG_ID (port 5432 ← $EC2_SG_ID)"
else
  ok "RDS SG exists: $RDS_SG_ID"
fi
save_state "RDS_SG_ID" "$RDS_SG_ID"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — RDS PostgreSQL  (~8 min)
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 4 — RDS PostgreSQL"

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)

if [[ -z "$RDS_STATUS" || "$RDS_STATUS" == "None" ]]; then
  RDS_PASSWORD=$(python3 -c "import secrets,string; \
    print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(16)))")

  DB_SUBNET_GROUP="${PROJECT}-subnet-group"
  aws rds describe-db-subnet-groups \
    --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$REGION" &>/dev/null \
  || aws rds create-db-subnet-group \
       --db-subnet-group-name "$DB_SUBNET_GROUP" \
       --db-subnet-group-description "Subnet group for $PROJECT RDS" \
       --subnet-ids $(echo "$SUBNET_IDS" | tr ',' ' ') \
       --region "$REGION" > /dev/null

  aws rds create-db-instance \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --db-instance-class db.t3.micro \
    --engine postgres --engine-version "16.3" \
    --master-username "$RDS_USER" \
    --master-user-password "$RDS_PASSWORD" \
    --db-name "$RDS_DB_NAME" \
    --allocated-storage 20 --storage-type gp2 \
    --vpc-security-group-ids "$RDS_SG_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --no-publicly-accessible --no-multi-az --no-deletion-protection \
    --region "$REGION" > /dev/null

  save_state "RDS_PASSWORD" "$RDS_PASSWORD"
  ok "RDS creation started (~8 min)..."
else
  RDS_PASSWORD=$(load_state "RDS_PASSWORD")
  ok "RDS exists — status: $RDS_STATUS"
fi

echo "   Waiting for RDS to reach 'available'..."
for i in $(seq 1 25); do
  RDS_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
  echo "     Attempt $i/25 — $RDS_STATUS"
  [[ "$RDS_STATUS" == "available" ]] && break
  [[ "$RDS_STATUS" == "failed" ]]    && die "RDS creation failed."
  sleep 30
done
[[ "$RDS_STATUS" != "available" ]] && die "RDS timed out."

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
DATABASE_URL="postgresql://${RDS_USER}:${RDS_PASSWORD}@${RDS_ENDPOINT}:5432/${RDS_DB_NAME}"
ok "RDS endpoint: $RDS_ENDPOINT"
save_state "RDS_ENDPOINT" "$RDS_ENDPOINT"
save_state "DATABASE_URL" "$DATABASE_URL"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — ECS cluster + IAM roles + EC2 instance + task + service
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 5a — ECS cluster"
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER" --region "$REGION" \
  --query 'clusters[0].status' --output text 2>/dev/null)
if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
  aws ecs create-cluster --cluster-name "$ECS_CLUSTER" --region "$REGION" > /dev/null
  ok "Created ECS cluster: $ECS_CLUSTER"
else
  ok "ECS cluster exists: $ECS_CLUSTER"
fi

step "Phase 5b — ECS task execution role"
ECS_EXEC_ROLE_ARN=$(aws iam get-role --role-name "$ECS_EXEC_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null)
if [[ -z "$ECS_EXEC_ROLE_ARN" || "$ECS_EXEC_ROLE_ARN" == "None" ]]; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  ECS_EXEC_ROLE_ARN=$(aws iam create-role \
    --role-name "$ECS_EXEC_ROLE" \
    --assume-role-policy-document "$TRUST" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name "$ECS_EXEC_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  ok "Created ECS execution role: $ECS_EXEC_ROLE_ARN"
else
  ok "ECS execution role exists: $ECS_EXEC_ROLE_ARN"
fi
save_state "ECS_EXEC_ROLE_ARN" "$ECS_EXEC_ROLE_ARN"

step "Phase 5c — EC2 instance role + profile"
EC2_ROLE_ARN=$(aws iam get-role --role-name "$ECS_INSTANCE_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null)
if [[ -z "$EC2_ROLE_ARN" || "$EC2_ROLE_ARN" == "None" ]]; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  EC2_ROLE_ARN=$(aws iam create-role \
    --role-name "$ECS_INSTANCE_ROLE" \
    --assume-role-policy-document "$TRUST" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name "$ECS_INSTANCE_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  ok "Created EC2 instance role: $EC2_ROLE_ARN"
else
  ok "EC2 instance role exists: $EC2_ROLE_ARN"
fi

# Instance profile (wraps the role so EC2 can assume it)
aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" &>/dev/null \
|| {
  aws iam create-instance-profile \
    --instance-profile-name "$EC2_INSTANCE_PROFILE" > /dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$EC2_INSTANCE_PROFILE" \
    --role-name "$ECS_INSTANCE_ROLE"
  sleep 10   # IAM propagation
  ok "Created instance profile: $EC2_INSTANCE_PROFILE"
}
ok "Instance profile ready"
save_state "EC2_INSTANCE_PROFILE" "$EC2_INSTANCE_PROFILE"

step "Phase 5d — CloudWatch log group"
aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null \
  && ok "Created log group: $LOG_GROUP" \
  || ok "Log group exists: $LOG_GROUP"

step "Phase 5e — EC2 instance (ECS-optimized t2.micro)"
EC2_INSTANCE_ID=$(load_state "EC2_INSTANCE_ID")

if [[ -z "$EC2_INSTANCE_ID" ]]; then
  # Get latest ECS-optimized Amazon Linux 2 AMI for the region
  ECS_AMI=$(aws ssm get-parameters \
    --names /aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id \
    --region "$REGION" --query 'Parameters[0].Value' --output text)
  ok "ECS-optimized AMI: $ECS_AMI"

  # User data registers the instance with the ECS cluster
  USER_DATA=$(base64 <<EOF
#!/bin/bash
echo ECS_CLUSTER=${ECS_CLUSTER} >> /etc/ecs/ecs.config
EOF
)

  EC2_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$ECS_AMI" \
    --instance-type t2.micro \
    --iam-instance-profile Name="$EC2_INSTANCE_PROFILE" \
    --security-group-ids "$EC2_SG_ID" \
    --subnet-id "$FIRST_SUBNET" \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}-ecs-host}]" \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)

  save_state "EC2_INSTANCE_ID" "$EC2_INSTANCE_ID"
  ok "Launched EC2 instance: $EC2_INSTANCE_ID — waiting for it to be running..."

  aws ec2 wait instance-running --instance-ids "$EC2_INSTANCE_ID" --region "$REGION"
  ok "Instance is running"
else
  ok "EC2 instance exists: $EC2_INSTANCE_ID"
fi

EC2_PUBLIC_DNS=$(aws ec2 describe-instances \
  --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
ok "EC2 public DNS: $EC2_PUBLIC_DNS"
save_state "EC2_PUBLIC_DNS" "$EC2_PUBLIC_DNS"

# Wait for instance to register with the ECS cluster
echo "   Waiting for EC2 to register with ECS cluster..."
for i in $(seq 1 12); do
  COUNT=$(aws ecs list-container-instances \
    --cluster "$ECS_CLUSTER" --region "$REGION" \
    --query 'length(containerInstanceArns)' --output text 2>/dev/null || echo 0)
  echo "     Attempt $i/12 — registered instances: $COUNT"
  [[ "$COUNT" -ge 1 ]] && break
  sleep 15
done

step "Phase 5f — ECS task definition"
JWT_SECRET=$(load_state "JWT_SECRET")
[[ -z "$JWT_SECRET" ]] && JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
save_state "JWT_SECRET" "$JWT_SECRET"

TASK_DEF_ARN=$(aws ecs register-task-definition \
  --family "$ECS_TASK_FAMILY" \
  --requires-compatibilities EC2 \
  --network-mode bridge \
  --execution-role-arn "$ECS_EXEC_ROLE_ARN" \
  --container-definitions "[{
    \"name\": \"backend\",
    \"image\": \"${ECR_URI}:latest\",
    \"essential\": true,
    \"portMappings\": [{
      \"containerPort\": 8000,
      \"hostPort\": 80,
      \"protocol\": \"tcp\"
    }],
    \"environment\": [
      {\"name\": \"DATABASE_URL\",    \"value\": \"${DATABASE_URL}\"},
      {\"name\": \"JWT_SECRET\",      \"value\": \"${JWT_SECRET}\"},
      {\"name\": \"JWT_EXPIRES_DAYS\",\"value\": \"7\"},
      {\"name\": \"PORT\",            \"value\": \"8000\"},
      {\"name\": \"CORS_ORIGINS\",    \"value\": \"*\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"${LOG_GROUP}\",
        \"awslogs-region\": \"${REGION}\",
        \"awslogs-stream-prefix\": \"ecs\"
      }
    }
  }]" \
  --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
ok "Registered task definition: $TASK_DEF_ARN"
save_state "TASK_DEF_ARN" "$TASK_DEF_ARN"

step "Phase 5g — ECS service"
SVC_STATUS=$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$REGION" \
  --query 'services[0].status' --output text 2>/dev/null)

if [[ "$SVC_STATUS" != "ACTIVE" ]]; then
  if ! $DOCKER_AVAILABLE; then
    warn "Docker not available — ECS service NOT created yet."
    warn "Push an image to ECR first, then re-run this script."
  else
    aws ecs create-service \
      --cluster "$ECS_CLUSTER" \
      --service-name "$ECS_SERVICE" \
      --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 \
      --launch-type EC2 \
      --region "$REGION" > /dev/null
    ok "Created ECS service: $ECS_SERVICE"

    echo "   Waiting for service to reach ACTIVE with 1 running task..."
    aws ecs wait services-stable \
      --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$REGION"
    ok "ECS service is stable"
  fi
else
  ok "ECS service exists: $ECS_SERVICE"
fi
save_state "ECS_CLUSTER"     "$ECS_CLUSTER"
save_state "ECS_SERVICE"     "$ECS_SERVICE"
save_state "ECS_TASK_FAMILY" "$ECS_TASK_FAMILY"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — CloudFront OAC + distribution
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 6 — CloudFront distribution"
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'$S3_BUCKET')]].Id" \
  --output text 2>/dev/null)

if [[ -z "$CF_ID" || "$CF_ID" == "None" ]]; then
  OAC_ID=$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "{
      \"Name\": \"${PROJECT}-oac\",
      \"OriginAccessControlOriginType\": \"s3\",
      \"SigningBehavior\": \"always\",
      \"SigningProtocol\": \"sigv4\",
      \"Description\": \"OAC for $S3_BUCKET\"
    }" \
    --query 'OriginAccessControl.Id' --output text)
  ok "Created OAC: $OAC_ID"

  CF_ID=$(aws cloudfront create-distribution \
    --distribution-config "{
      \"CallerReference\": \"$(date +%s)\",
      \"Comment\": \"$PROJECT frontend\",
      \"DefaultRootObject\": \"index.html\",
      \"Origins\": {\"Quantity\": 1, \"Items\": [{
        \"Id\": \"s3-origin\",
        \"DomainName\": \"${S3_BUCKET}.s3.${REGION}.amazonaws.com\",
        \"S3OriginConfig\": {\"OriginAccessIdentity\": \"\"},
        \"OriginAccessControlId\": \"$OAC_ID\"
      }]},
      \"DefaultCacheBehavior\": {
        \"TargetOriginId\": \"s3-origin\",
        \"ViewerProtocolPolicy\": \"redirect-to-https\",
        \"AllowedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\",\"HEAD\"]},
        \"CachedMethods\":  {\"Quantity\": 2, \"Items\": [\"GET\",\"HEAD\"]},
        \"ForwardedValues\": {\"QueryString\": false, \"Cookies\": {\"Forward\": \"none\"}},
        \"MinTTL\": 0
      },
      \"CustomErrorResponses\": {\"Quantity\": 1, \"Items\": [{
        \"ErrorCode\": 403, \"ResponsePagePath\": \"/index.html\",
        \"ResponseCode\": \"200\", \"ErrorCachingMinTTL\": 0
      }]},
      \"Enabled\": true,
      \"PriceClass\": \"PriceClass_100\"
    }" \
    --query 'Distribution.Id' --output text)
  ok "Created CloudFront distribution: $CF_ID"

  aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${S3_BUCKET}/*\",
      \"Condition\": {\"StringEquals\": {
        \"AWS:SourceArn\": \"arn:aws:cloudfront::${ACCOUNT}:distribution/${CF_ID}\"
      }}
    }]
  }"
  ok "S3 bucket policy updated for CloudFront OAC"
else
  ok "CloudFront distribution exists: $CF_ID"
fi
save_state "CF_ID" "$CF_ID"

CF_DOMAIN=$(aws cloudfront get-distribution \
  --id "$CF_ID" --query 'Distribution.DomainName' --output text)
save_state "CF_DOMAIN" "https://$CF_DOMAIN"
ok "CloudFront domain: https://$CF_DOMAIN"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Update ECS task definition CORS_ORIGINS → CloudFront URL
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 7 — Update CORS_ORIGINS in ECS task definition"
NEW_TASK_DEF=$(aws ecs describe-task-definition \
  --task-definition "$ECS_TASK_FAMILY" --region "$REGION" \
  --query 'taskDefinition' --output json \
| python3 -c "
import sys, json
td = json.load(sys.stdin)
for env in td['containerDefinitions'][0]['environment']:
    if env['name'] == 'CORS_ORIGINS':
        env['value'] = 'https://$CF_DOMAIN'
for k in ['taskDefinitionArn','revision','status','requiresAttributes',
          'compatibilities','registeredAt','registeredBy']:
    td.pop(k, None)
print(json.dumps(td))
")

UPDATED_ARN=$(aws ecs register-task-definition \
  --cli-input-json "$NEW_TASK_DEF" --region "$REGION" \
  --query 'taskDefinition.taskDefinitionArn' --output text)

aws ecs update-service \
  --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$UPDATED_ARN" --region "$REGION" > /dev/null
ok "CORS_ORIGINS set to https://$CF_DOMAIN — new task revision: $UPDATED_ARN"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — GitHub Secrets summary
# ─────────────────────────────────────────────────────────────────────────────
echo
hr
printf "${BLD}  Provisioning complete. Add these GitHub Secrets:${RST}\n"
printf "  GitHub → Settings → Secrets and variables → Actions\n"
hr
printf "\n  %-35s  %s\n" "Secret" "Value"
printf "  %-35s  %s\n"   "──────────────────────────────────" "──────────────────────────────────────────"
printf "  %-35s  %s\n"   "AWS_ACCESS_KEY_ID"               "<IAM user key>"
printf "  %-35s  %s\n"   "AWS_SECRET_ACCESS_KEY"           "<IAM user secret>"
printf "  %-35s  %s\n"   "AWS_REGION"                      "$REGION"
printf "  %-35s  %s\n"   "ECR_REGISTRY"                    "$ECR_REGISTRY"
printf "  %-35s  %s\n"   "ECR_REPOSITORY"                  "$ECR_REPO"
printf "  %-35s  %s\n"   "ECS_CLUSTER"                     "$ECS_CLUSTER"
printf "  %-35s  %s\n"   "ECS_SERVICE"                     "$ECS_SERVICE"
printf "  %-35s  %s\n"   "ECS_TASK_FAMILY"                 "$ECS_TASK_FAMILY"
printf "  %-35s  %s\n"   "S3_BUCKET"                       "$S3_BUCKET"
printf "  %-35s  %s\n"   "CLOUDFRONT_DISTRIBUTION_ID"      "${CF_ID:-<not yet created>}"
printf "  %-35s  %s\n"   "VITE_API_BASE_URL"               "http://${EC2_PUBLIC_DNS}/api/v1"
echo
warn "Sensitive values (DB password, JWT secret) saved to .aws-state.env — do NOT commit."
warn "EC2 public DNS changes if the instance is stopped/started — use an Elastic IP to fix it."
hr
