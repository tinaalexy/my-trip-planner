#!/usr/bin/env bash
# Full AWS infrastructure provisioning for my-trip-advisor.
#
# Creates (in order, idempotent — safe to re-run):
#   1. ECR repository
#   2. S3 bucket (frontend, public access blocked)
#   3. Security groups  (RDS + App Runner)
#   4. RDS PostgreSQL   (db.t3.micro, free-tier)
#   5. App Runner IAM access role
#   6. App Runner VPC connector
#   7. App Runner service
#   8. CloudFront OAC + distribution
#   9. Update App Runner CORS_ORIGINS → CloudFront URL
#  10. Print GitHub Secrets summary + state file
#
# Usage:
#   bash scripts/aws-provision.sh
#
# Prerequisites:
#   - AWS CLI configured with an IAM user/role that has the permissions
#     listed in the REQUIRED PERMISSIONS section below
#   - Docker installed (for the initial ECR image push)
#
# Required IAM permissions:
#   ecr:*, s3:*, rds:*, ec2:Describe*, ec2:CreateSecurityGroup,
#   ec2:AuthorizeSecurityGroupIngress, ec2:AuthorizeSecurityGroupEgress,
#   iam:CreateRole, iam:AttachRolePolicy, iam:GetRole, iam:PassRole,
#   apprunner:*, cloudfront:*
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── Project config ────────────────────────────────────────────────────────────
REGION="${AWS_REGION:-eu-west-1}"
PROJECT="my-trip-advisor"
ECR_REPO="${PROJECT}-backend"
S3_BUCKET="${PROJECT}-frontend"
RDS_IDENTIFIER="${PROJECT}-db"
RDS_DB_NAME="tripplanner"
RDS_USER="tripuser"
AR_SERVICE="${PROJECT}-backend"
AR_ROLE="${PROJECT}-apprunner-ecr-role"
RDS_SG_NAME="${PROJECT}-rds-sg"
AR_SG_NAME="${PROJECT}-apprunner-sg"
VPC_CONNECTOR_NAME="${PROJECT}-vpc-connector"
STATE_FILE="$(dirname "${BASH_SOURCE[0]}")/../.aws-state.env"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'; BLD='\033[1m'; RST='\033[0m'
ok()      { printf "   ${GRN}✓${RST}  %s\n" "$1"; }
warn()    { printf "   ${YLW}⚠${RST}  %s\n" "$1"; }
err()     { printf "   ${RED}✗${RST}  %s\n" "$1"; }
step()    { echo; printf "${BLD}▶  %s${RST}\n" "$1"; }
hr()      { echo "═══════════════════════════════════════════════════"; }
die()     { err "$1"; echo; exit 1; }

# ── State helpers ─────────────────────────────────────────────────────────────
save_state() { echo "$1=$2" >> "$STATE_FILE"; }
load_state() { grep -E "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2-; }

# Ensure state file exists
touch "$STATE_FILE"

hr
printf "${BLD}  AWS Infrastructure Provisioning — %s${RST}\n" "$PROJECT"
printf "  Region : %s\n" "$REGION"
hr

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 — Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 0 — Prerequisites"

# AWS CLI
command -v aws &>/dev/null || die "AWS CLI not installed. https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
ok "AWS CLI: $(aws --version 2>&1 | awk '{print $1}')"

# Credentials
IDENTITY=$(aws sts get-caller-identity --output json 2>&1) \
  || die "Not authenticated. Run: aws configure"
ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
ok "Account : $ACCOUNT"
ok "Identity: $ARN"
ECR_REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# Permission probe — catch limited roles early
step "Phase 0 — Permission check"
PERM_FAIL=false
check_perm() {
  local svc=$1 action=$2
  if ! aws $svc $action --region "$REGION" &>/dev/null 2>&1; then
    err "Missing permission: $svc $action"
    PERM_FAIL=true
  else
    ok "$svc $action"
  fi
}

check_perm ecr    "describe-repositories"
check_perm s3api  "list-buckets"
check_perm ec2    "describe-vpcs"
check_perm rds    "describe-db-instances"
check_perm iam    "list-roles"
check_perm apprunner "list-services"
check_perm cloudfront "list-distributions"

if $PERM_FAIL; then
  echo
  warn "The current AWS identity is missing required permissions."
  warn "This is likely a role-scoped identity (e.g. Bedrock-only)."
  echo
  echo "  Fix options:"
  echo "  A) Create a personal AWS Free Tier account at aws.amazon.com"
  echo "     then run:  aws configure  (with the new account's IAM user keys)"
  echo
  echo "  B) Ask your AWS admin to attach these policies to your current role:"
  echo "       AmazonEC2ContainerRegistryFullAccess"
  echo "       AmazonS3FullAccess"
  echo "       AmazonRDSFullAccess"
  echo "       AmazonVPCFullAccess"
  echo "       IAMFullAccess"
  echo "       AWSAppRunnerFullAccess"
  echo "       CloudFrontFullAccess"
  echo
  echo "  Then re-run:  bash scripts/aws-provision.sh"
  hr
  exit 1
fi

# Docker
if ! command -v docker &>/dev/null; then
  warn "Docker not installed — initial ECR image push will be skipped."
  warn "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
  warn "The CD pipeline will push the first image automatically on the next push to main."
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

# Push placeholder image (so App Runner can start)
if $DOCKER_AVAILABLE; then
  step "Phase 1b — Push initial Docker image to ECR"
  IMAGE_URI="$ECR_URI:latest"
  EXISTING_IMAGE=$(aws ecr describe-images \
    --repository-name "$ECR_REPO" --region "$REGION" \
    --query 'imageDetails[0].imageTags[0]' --output text 2>/dev/null)

  if [[ -z "$EXISTING_IMAGE" || "$EXISTING_IMAGE" == "None" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    docker build -t "$IMAGE_URI" "$REPO_ROOT/backend"
    docker push "$IMAGE_URI"
    ok "Initial image pushed: $IMAGE_URI"
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

# Fetch subnet IDs (at least 2 AZs required by RDS)
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
ok "Subnets: $SUBNET_IDS"
save_state "VPC_ID"     "$VPC_ID"
save_state "SUBNET_IDS" "$SUBNET_IDS"

# App Runner security group
AR_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$AR_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$AR_SG_ID" || "$AR_SG_ID" == "None" ]]; then
  AR_SG_ID=$(aws ec2 create-security-group \
    --group-name "$AR_SG_NAME" \
    --description "App Runner VPC connector outbound" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query 'GroupId' --output text)
  ok "Created App Runner security group: $AR_SG_ID"
else
  ok "App Runner SG exists: $AR_SG_ID"
fi
save_state "AR_SG_ID" "$AR_SG_ID"

# RDS security group — allow port 5432 from App Runner SG
RDS_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$RDS_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
if [[ -z "$RDS_SG_ID" || "$RDS_SG_ID" == "None" ]]; then
  RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "$RDS_SG_NAME" \
    --description "RDS PostgreSQL access from App Runner" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG_ID" --region "$REGION" \
    --protocol tcp --port 5432 --source-group "$AR_SG_ID" > /dev/null
  ok "Created RDS security group: $RDS_SG_ID (port 5432 ← $AR_SG_ID)"
else
  ok "RDS SG exists: $RDS_SG_ID"
fi
save_state "RDS_SG_ID" "$RDS_SG_ID"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — RDS PostgreSQL  (longest step — ~8 min)
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 4 — RDS PostgreSQL"

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)

if [[ -z "$RDS_STATUS" || "$RDS_STATUS" == "None" ]]; then
  # Generate a random DB password (16 chars, alphanumeric only — no special chars
  # that would need URL-encoding in DATABASE_URL)
  RDS_PASSWORD=$(python3 -c "import secrets,string; \
    print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(16)))")

  # Build subnet group (required; must span ≥2 AZs)
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
    --engine postgres \
    --engine-version "16.3" \
    --master-username "$RDS_USER" \
    --master-user-password "$RDS_PASSWORD" \
    --db-name "$RDS_DB_NAME" \
    --allocated-storage 20 \
    --storage-type gp2 \
    --vpc-security-group-ids "$RDS_SG_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --no-publicly-accessible \
    --no-multi-az \
    --no-deletion-protection \
    --region "$REGION" > /dev/null

  save_state "RDS_PASSWORD" "$RDS_PASSWORD"
  ok "RDS instance creation started (this takes ~8 minutes)..."
  ok "Credentials saved to .aws-state.env"
else
  RDS_PASSWORD=$(load_state "RDS_PASSWORD")
  ok "RDS instance exists — status: $RDS_STATUS"
fi

# Wait for RDS to become available
echo "   Waiting for RDS to reach 'available' state (polling every 30s)..."
for i in $(seq 1 25); do
  RDS_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
  echo "     Attempt $i/25 — status: $RDS_STATUS"
  [[ "$RDS_STATUS" == "available" ]] && break
  [[ "$RDS_STATUS" == "failed" ]]    && die "RDS creation failed."
  sleep 30
done
[[ "$RDS_STATUS" != "available" ]] && die "RDS timed out after ~12 min."

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" --region "$REGION" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
DATABASE_URL="postgresql://${RDS_USER}:${RDS_PASSWORD}@${RDS_ENDPOINT}:5432/${RDS_DB_NAME}"
ok "RDS endpoint: $RDS_ENDPOINT"
save_state "RDS_ENDPOINT" "$RDS_ENDPOINT"
save_state "DATABASE_URL" "$DATABASE_URL"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — App Runner IAM role + VPC connector + service
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 5 — App Runner IAM access role"

AR_ROLE_ARN=$(aws iam get-role --role-name "$AR_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null)
if [[ -z "$AR_ROLE_ARN" || "$AR_ROLE_ARN" == "None" ]]; then
  TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"build.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  AR_ROLE_ARN=$(aws iam create-role \
    --role-name "$AR_ROLE" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy \
    --role-name "$AR_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
  ok "Created IAM role: $AR_ROLE_ARN"
else
  ok "IAM role exists: $AR_ROLE_ARN"
fi
save_state "AR_ROLE_ARN" "$AR_ROLE_ARN"

step "Phase 5b — App Runner VPC connector"
VPC_CONNECTOR_ARN=$(aws apprunner list-vpc-connectors --region "$REGION" \
  --query "VpcConnectors[?VpcConnectorName=='$VPC_CONNECTOR_NAME' && Status=='ACTIVE'].VpcConnectorArn" \
  --output text 2>/dev/null)
if [[ -z "$VPC_CONNECTOR_ARN" ]]; then
  VPC_CONNECTOR_ARN=$(aws apprunner create-vpc-connector \
    --vpc-connector-name "$VPC_CONNECTOR_NAME" \
    --subnets $(echo "$SUBNET_IDS" | tr ',' ' ') \
    --security-groups "$AR_SG_ID" \
    --region "$REGION" \
    --query 'VpcConnector.VpcConnectorArn' --output text)
  ok "Created VPC connector: $VPC_CONNECTOR_ARN"
else
  ok "VPC connector exists: $VPC_CONNECTOR_ARN"
fi
save_state "VPC_CONNECTOR_ARN" "$VPC_CONNECTOR_ARN"

step "Phase 5c — App Runner service"
AR_SERVICE_ARN=$(aws apprunner list-services --region "$REGION" \
  --query "ServiceSummaryList[?ServiceName=='$AR_SERVICE'].ServiceArn" \
  --output text 2>/dev/null)

JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")

if [[ -z "$AR_SERVICE_ARN" ]]; then
  if ! $DOCKER_AVAILABLE; then
    warn "Docker not available — App Runner service NOT created."
    warn "Push an image to ECR first ($ECR_URI:latest), then re-run this script."
    save_state "JWT_SECRET" "$JWT_SECRET"
  else
    AR_SERVICE_ARN=$(aws apprunner create-service \
      --service-name "$AR_SERVICE" \
      --region "$REGION" \
      --source-configuration "{
        \"AuthenticationConfiguration\": {
          \"AccessRoleArn\": \"$AR_ROLE_ARN\"
        },
        \"AutoDeploymentsEnabled\": false,
        \"ImageRepository\": {
          \"ImageIdentifier\": \"$ECR_URI:latest\",
          \"ImageRepositoryType\": \"ECR\",
          \"ImageConfiguration\": {
            \"Port\": \"8000\",
            \"RuntimeEnvironmentVariables\": {
              \"DATABASE_URL\": \"$DATABASE_URL\",
              \"JWT_SECRET\": \"$JWT_SECRET\",
              \"JWT_EXPIRES_DAYS\": \"7\",
              \"PORT\": \"8000\",
              \"CORS_ORIGINS\": \"*\"
            }
          }
        }
      }" \
      --instance-configuration '{"Cpu":"0.25 vCPU","Memory":"0.5 GB"}' \
      --network-configuration "{
        \"EgressConfiguration\": {
          \"EgressType\": \"VPC\",
          \"VpcConnectorArn\": \"$VPC_CONNECTOR_ARN\"
        }
      }" \
      --query 'Service.ServiceArn' --output text)
    save_state "JWT_SECRET" "$JWT_SECRET"
    ok "Created App Runner service: $AR_SERVICE_ARN"
    ok "Waiting for App Runner service to reach RUNNING..."
    for i in $(seq 1 30); do
      AR_STATUS=$(aws apprunner describe-service \
        --service-arn "$AR_SERVICE_ARN" --region "$REGION" \
        --query 'Service.Status' --output text)
      echo "     Attempt $i/30 — status: $AR_STATUS"
      [[ "$AR_STATUS" == "RUNNING" ]] && break
      [[ "$AR_STATUS" == "CREATE_FAILED" ]] && die "App Runner creation failed."
      sleep 20
    done
  fi
else
  ok "App Runner service exists: $AR_SERVICE_ARN"
  JWT_SECRET=$(load_state "JWT_SECRET")
fi
save_state "AR_SERVICE_ARN" "$AR_SERVICE_ARN"

AR_URL=$(aws apprunner describe-service \
  --service-arn "$AR_SERVICE_ARN" --region "$REGION" \
  --query 'Service.ServiceUrl' --output text 2>/dev/null || echo "")
save_state "AR_URL" "https://$AR_URL"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — CloudFront OAC + distribution
# ─────────────────────────────────────────────────────────────────────────────
step "Phase 6 — CloudFront distribution"
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'$S3_BUCKET')]].Id" \
  --output text 2>/dev/null)

if [[ -z "$CF_ID" || "$CF_ID" == "None" ]]; then
  # Create Origin Access Control
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

  S3_ORIGIN_DOMAIN="${S3_BUCKET}.s3.${REGION}.amazonaws.com"
  CALLER_REF="$(date +%s)"

  CF_ID=$(aws cloudfront create-distribution \
    --distribution-config "{
      \"CallerReference\": \"$CALLER_REF\",
      \"Comment\": \"$PROJECT frontend\",
      \"DefaultRootObject\": \"index.html\",
      \"Origins\": {
        \"Quantity\": 1,
        \"Items\": [{
          \"Id\": \"s3-origin\",
          \"DomainName\": \"$S3_ORIGIN_DOMAIN\",
          \"S3OriginConfig\": {\"OriginAccessIdentity\": \"\"},
          \"OriginAccessControlId\": \"$OAC_ID\"
        }]
      },
      \"DefaultCacheBehavior\": {
        \"TargetOriginId\": \"s3-origin\",
        \"ViewerProtocolPolicy\": \"redirect-to-https\",
        \"AllowedMethods\": {\"Quantity\": 2, \"Items\": [\"GET\",\"HEAD\"]},
        \"CachedMethods\":  {\"Quantity\": 2, \"Items\": [\"GET\",\"HEAD\"]},
        \"ForwardedValues\": {
          \"QueryString\": false,
          \"Cookies\": {\"Forward\": \"none\"}
        },
        \"MinTTL\": 0
      },
      \"CustomErrorResponses\": {
        \"Quantity\": 1,
        \"Items\": [{
          \"ErrorCode\": 403,
          \"ResponsePagePath\": \"/index.html\",
          \"ResponseCode\": \"200\",
          \"ErrorCachingMinTTL\": 0
        }]
      },
      \"Enabled\": true,
      \"PriceClass\": \"PriceClass_100\"
    }" \
    --query 'Distribution.Id' --output text)
  ok "Created CloudFront distribution: $CF_ID"

  # Attach bucket policy for OAC
  aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"AllowCloudFrontOAC\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::$S3_BUCKET/*\",
      \"Condition\": {
        \"StringEquals\": {
          \"AWS:SourceArn\": \"arn:aws:cloudfront::$ACCOUNT:distribution/$CF_ID\"
        }
      }
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
# PHASE 7 — Update App Runner CORS_ORIGINS → CloudFront URL
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$AR_SERVICE_ARN" ]]; then
  step "Phase 7 — Update App Runner CORS_ORIGINS"
  aws apprunner update-service \
    --service-arn "$AR_SERVICE_ARN" --region "$REGION" \
    --source-configuration "{
      \"ImageRepository\": {
        \"ImageIdentifier\": \"$ECR_URI:latest\",
        \"ImageRepositoryType\": \"ECR\",
        \"ImageConfiguration\": {
          \"Port\": \"8000\",
          \"RuntimeEnvironmentVariables\": {
            \"DATABASE_URL\": \"$DATABASE_URL\",
            \"JWT_SECRET\": \"$JWT_SECRET\",
            \"JWT_EXPIRES_DAYS\": \"7\",
            \"PORT\": \"8000\",
            \"CORS_ORIGINS\": \"https://$CF_DOMAIN\"
          }
        }
      }
    }" > /dev/null
  ok "CORS_ORIGINS updated to https://$CF_DOMAIN"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — GitHub Secrets summary
# ─────────────────────────────────────────────────────────────────────────────
echo
hr
printf "${BLD}  Provisioning complete. Add these GitHub Secrets:${RST}\n"
printf "  GitHub → Settings → Secrets and variables → Actions\n"
hr
printf "\n  %-35s  %s\n" "Secret" "Value"
printf "  %-35s  %s\n"   "──────────────────────────────────" "─────────────────────────────────────────"
printf "  %-35s  %s\n"   "AWS_ACCESS_KEY_ID"               "<IAM user key — not role credentials>"
printf "  %-35s  %s\n"   "AWS_SECRET_ACCESS_KEY"           "<IAM user secret>"
printf "  %-35s  %s\n"   "AWS_REGION"                      "$REGION"
printf "  %-35s  %s\n"   "ECR_REGISTRY"                    "$ECR_REGISTRY"
printf "  %-35s  %s\n"   "ECR_REPOSITORY"                  "$ECR_REPO"
printf "  %-35s  %s\n"   "APP_RUNNER_SERVICE_ARN"          "${AR_SERVICE_ARN:-<not yet created>}"
printf "  %-35s  %s\n"   "S3_BUCKET"                       "$S3_BUCKET"
printf "  %-35s  %s\n"   "CLOUDFRONT_DISTRIBUTION_ID"      "${CF_ID:-<not yet created>}"
printf "  %-35s  %s\n"   "VITE_API_BASE_URL"               "https://${AR_URL:-<App Runner URL>}/api/v1"
echo
warn "Sensitive values saved locally to .aws-state.env — do NOT commit that file."
hr
