#!/usr/bin/env bash
# Verify AWS connectivity and check project resource status.
# Usage:
#   bash scripts/aws-setup.sh            — check status of all resources
#   bash scripts/aws-setup.sh --create   — create missing resources
set -uo pipefail

# ── Config (edit these to match your deployment) ─────────────────────────────
REGION="${AWS_REGION:-ap-southeast-2}"
ECR_REPO="my-trip-advisor-backend"
S3_BUCKET="my-trip-advisor-frontend"
ECS_CLUSTER="my-trip-advisor"
ECS_SERVICE="my-trip-advisor-backend"
RDS_IDENTIFIER="my-trip-advisor-db"
CREATE_MODE=false
[[ "${1:-}" == "--create" ]] && CREATE_MODE=true

# ── Helpers ───────────────────────────────────────────────────────────────────
MISSING_FILE="$(mktemp)"
trap 'rm -f "$MISSING_FILE"' EXIT

ok()      { printf "   \033[32m✓\033[0m  %s\n" "$1"; }
warn()    { printf "   \033[33m⚠\033[0m  %s\n" "$1"; }
missing() { printf "   \033[31m✗\033[0m  %s\n" "$1"; echo "$1" >> "$MISSING_FILE"; }
step()    { echo; printf "\033[1m▶  %s\033[0m\n" "$1"; }
hr()      { echo "═══════════════════════════════════════════════════"; }

hr
echo "  AWS Connection & Resource Check"
echo "  Project : my-trip-advisor"
echo "  Region  : $REGION"
hr

# ── 1. AWS CLI ────────────────────────────────────────────────────────────────
step "AWS CLI"
if ! command -v aws &>/dev/null; then
  missing "AWS CLI not installed — https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  echo
  hr
  echo "  Install AWS CLI first, then re-run this script."
  hr
  exit 1
fi
ok "AWS CLI $(aws --version 2>&1 | awk '{print $1}')"

# ── 2. Credentials & identity ─────────────────────────────────────────────────
step "Credentials"
IDENTITY=$(aws sts get-caller-identity --output json 2>&1)
if [[ $? -ne 0 ]]; then
  missing "Not authenticated — run: aws configure"
  echo
  echo "  You will need:"
  echo "    AWS Access Key ID"
  echo "    AWS Secret Access Key"
  echo "    Default region: $REGION"
  echo "    Default output: json"
  hr
  exit 1
fi

ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
ok "Account : $ACCOUNT"
ok "Identity: $ARN"

# ── 3. ECR repository ─────────────────────────────────────────────────────────
step "ECR — container registry ($ECR_REPO)"
ECR_URI=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query 'repositories[0].repositoryUri' \
  --output text 2>/dev/null)

if [[ -z "$ECR_URI" || "$ECR_URI" == "None" ]]; then
  if $CREATE_MODE; then
    ECR_URI=$(aws ecr create-repository \
      --repository-name "$ECR_REPO" \
      --region "$REGION" \
      --query 'repository.repositoryUri' \
      --output text)
    ok "Created ECR repository: $ECR_URI"
  else
    missing "ECR repository '$ECR_REPO' not found — run with --create to create it"
  fi
else
  ok "ECR repository: $ECR_URI"
fi

# ── 4. RDS instance ───────────────────────────────────────────────────────────
step "RDS — PostgreSQL ($RDS_IDENTIFIER)"
RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --region "$REGION" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null)

if [[ -z "$RDS_STATUS" || "$RDS_STATUS" == "None" ]]; then
  missing "RDS instance '$RDS_IDENTIFIER' not found"
  if $CREATE_MODE; then
    warn "RDS requires a VPC and security group — create it manually in the AWS Console."
    warn "Follow Section 3 Step 1 in docs/deployment-plan.md"
  fi
else
  ok "RDS status: $RDS_STATUS"
  RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --region "$REGION" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text 2>/dev/null)
  ok "RDS endpoint: $RDS_ENDPOINT"
fi

# ── 5. ECS service ────────────────────────────────────────────────────────────
step "ECS — cluster and service ($ECS_CLUSTER / $ECS_SERVICE)"
ECS_STATUS=$(aws ecs describe-clusters --clusters "$ECS_CLUSTER" --region "$REGION" \
  --query 'clusters[0].status' --output text 2>/dev/null)

if [[ -z "$ECS_STATUS" || "$ECS_STATUS" == "None" || "$ECS_STATUS" == "INACTIVE" ]]; then
  missing "ECS cluster '$ECS_CLUSTER' not found — run: bash scripts/aws-provision.sh"
else
  ok "ECS cluster status: $ECS_STATUS"
  SVC_STATUS=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$REGION" \
    --query 'services[0].status' --output text 2>/dev/null)
  if [[ -z "$SVC_STATUS" || "$SVC_STATUS" != "ACTIVE" ]]; then
    missing "ECS service '$ECS_SERVICE' not found"
  else
    RUNNING=$(aws ecs describe-services \
      --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$REGION" \
      --query 'services[0].runningCount' --output text 2>/dev/null)
    ok "ECS service status: $SVC_STATUS ($RUNNING running task(s))"
    # Resolve EC2 public DNS
    TASK_ARN=$(aws ecs list-tasks --cluster "$ECS_CLUSTER" \
      --service-name "$ECS_SERVICE" --region "$REGION" \
      --query 'taskArns[0]' --output text 2>/dev/null)
    if [[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]]; then
      CI_ARN=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" \
        --region "$REGION" --query 'tasks[0].containerInstanceArn' --output text)
      EC2_ID=$(aws ecs describe-container-instances --cluster "$ECS_CLUSTER" \
        --container-instances "$CI_ARN" --region "$REGION" \
        --query 'containerInstances[0].ec2InstanceId' --output text)
      EC2_DNS=$(aws ec2 describe-instances --instance-ids "$EC2_ID" --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
      ok "Backend URL: http://$EC2_DNS"
    fi
  fi
fi

# ── 6. S3 bucket ──────────────────────────────────────────────────────────────
step "S3 — frontend bucket ($S3_BUCKET)"
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
  ok "S3 bucket exists: s3://$S3_BUCKET"
else
  if $CREATE_MODE; then
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
    # Block all public access (CloudFront uses OAC)
    aws s3api put-public-access-block \
      --bucket "$S3_BUCKET" \
      --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    ok "Created S3 bucket: s3://$S3_BUCKET (public access blocked)"
  else
    missing "S3 bucket '$S3_BUCKET' not found — run with --create to create it"
  fi
fi

# ── 7. CloudFront distribution ────────────────────────────────────────────────
step "CloudFront — distribution"
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?contains(DomainName,'$S3_BUCKET')]].Id" \
  --output text 2>/dev/null)

if [[ -z "$CF_ID" || "$CF_ID" == "None" ]]; then
  missing "CloudFront distribution for '$S3_BUCKET' not found"
  if $CREATE_MODE; then
    warn "CloudFront OAC setup requires manual steps — create it in the AWS Console."
    warn "Follow Section 3 Step 6 in docs/deployment-plan.md"
  fi
else
  CF_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --query 'Distribution.DomainName' \
    --output text 2>/dev/null)
  ok "CloudFront distribution: $CF_ID"
  ok "CloudFront domain: https://$CF_DOMAIN"
fi

# ── 8. GitHub Secrets reminder ────────────────────────────────────────────────
step "GitHub Secrets"
echo "   Add these to GitHub → Settings → Secrets and variables → Actions:"
echo
printf "   %-35s %s\n" "Secret" "Value"
printf "   %-35s %s\n" "------" "-----"
printf "   %-35s %s\n" "AWS_ACCOUNT_ID"             "$ACCOUNT"
printf "   %-35s %s\n" "AWS_REGION"                 "$REGION"
printf "   %-35s %s\n" "ECR_REGISTRY"               "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
printf "   %-35s %s\n" "ECR_REPOSITORY"             "$ECR_REPO"
printf "   %-35s %s\n" "ECS_CLUSTER"                "$ECS_CLUSTER"
printf "   %-35s %s\n" "ECS_SERVICE"                "$ECS_SERVICE"
printf "   %-35s %s\n" "ECS_TASK_FAMILY"            "${ECS_SERVICE}"
printf "   %-35s %s\n" "S3_BUCKET"                  "$S3_BUCKET"
printf "   %-35s %s\n" "CLOUDFRONT_DISTRIBUTION_ID" "${CF_ID:-<get from CloudFront console>}"
printf "   %-35s %s\n" "AWS_ACCESS_KEY_ID"          "<from IAM user credentials>"
printf "   %-35s %s\n" "AWS_SECRET_ACCESS_KEY"      "<from IAM user credentials>"
printf "   %-35s %s\n" "VITE_API_BASE_URL"          "http://<EC2 public DNS>/api/v1"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
hr
MISSING_COUNT=$(wc -l < "$MISSING_FILE" | tr -d ' ')
if [[ "$MISSING_COUNT" -eq 0 ]]; then
  printf "\033[32m  ALL RESOURCES READY — CD pipeline can deploy.\033[0m\n"
else
  printf "\033[33m  %s resource(s) missing.\033[0m\n" "$MISSING_COUNT"
  echo  "  Run with --create to auto-create what can be scripted:"
  echo  "    bash scripts/aws-setup.sh --create"
  echo
  echo  "  Run the full provisioning script to create everything:"
  echo  "    bash scripts/aws-provision.sh"
fi
hr
