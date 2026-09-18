#!/usr/bin/env bash
# Script 2 of 2 — Deploy / update all AWS infrastructure using CloudFormation.
#
# The infrastructure is declared in infrastructure/stack.yml (the IaC).
# This script only handles environment-specific discovery (VPC, subnets)
# and secret generation — CloudFormation owns the resource lifecycle.
#
# Usage:
#   bash scripts/aws-provision.sh              — deploy or update stack
#   bash scripts/aws-provision.sh --delete     — delete stack (destroys all resources)
#   bash scripts/aws-provision.sh --outputs    — print stack outputs only
#
# Prerequisites:
#   bash scripts/aws-sso-setup.sh must have run successfully first.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

STACK_NAME="my-trip-advisor"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infrastructure/stack.yml"
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.aws-state.env"
GITHUB_REPO="tinaalexy/my-trip-planner"

# ── Colour helpers ────────────────────────────────────────────────────────────
GRN='\033[32m'; YLW='\033[33m'; RED='\033[31m'; BLD='\033[1m'; RST='\033[0m'
ok()   { printf "   ${GRN}✓${RST}  %s\n" "$1"; }
warn() { printf "   ${YLW}⚠${RST}  %s\n" "$1"; }
err()  { printf "   ${RED}✗${RST}  %s\n" "$1"; }
step() { echo;  printf "${BLD}▶  %s${RST}\n" "$1"; }
hr()   { echo "═══════════════════════════════════════════════════"; }
die()  { err "$1"; echo; exit 1; }

# ── State helpers ─────────────────────────────────────────────────────────────
load_state() { grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
save_state() {
  touch "$STATE_FILE"
  if grep -q "^$1=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"
  else
    echo "$1=$2" >> "$STATE_FILE"
  fi
}

MODE="deploy"
[[ "${1:-}" == "--delete"  ]] && MODE="delete"
[[ "${1:-}" == "--outputs" ]] && MODE="outputs"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Load profile and verify connection
# ─────────────────────────────────────────────────────────────────────────────
hr
printf "${BLD}  CloudFormation IaC Deploy — %s${RST}\n" "$STACK_NAME"
hr

step "Step 1 — AWS connection"

PROFILE=$(load_state "AWS_PROFILE")
REGION=$(load_state "AWS_REGION")
[[ -z "$PROFILE" ]] && die "No AWS profile found. Run: bash scripts/aws-sso-setup.sh"
[[ -z "$REGION"  ]] && REGION="ap-southeast-2"
export AWS_PROFILE="$PROFILE"
export AWS_DEFAULT_REGION="$REGION"

IDENTITY=$(aws sts get-caller-identity --output json 2>&1) \
  || { err "Session expired."; echo; die "Refresh: bash scripts/aws-sso-setup.sh --login"; }

ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
ok "Profile : $PROFILE"
ok "Account : $ACCOUNT"
ok "Identity: $ARN"
ok "Region  : $REGION"

# ─────────────────────────────────────────────────────────────────────────────
# Delete mode
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "delete" ]]; then
  step "Deleting stack '$STACK_NAME'"
  warn "This destroys all resources EXCEPT those with DeletionPolicy: Retain"
  warn "  (ECR repository, S3 bucket, RDS snapshot, CloudWatch logs)"
  echo
  read -rp "   Type the stack name to confirm deletion: " CONFIRM
  [[ "$CONFIRM" != "$STACK_NAME" ]] && die "Cancelled."

  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  echo "   Waiting for deletion to complete..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
  ok "Stack deleted."
  hr; exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Outputs-only mode
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "outputs" ]]; then
  step "Stack outputs"
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].Outputs' --output table 2>/dev/null \
    || die "Stack '$STACK_NAME' not found."
  hr; exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Discover VPC and subnets (environment-specific, not in the template)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 2 — Discover default VPC and subnets"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
[[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && die "No default VPC found in $REGION."
ok "VPC: $VPC_ID"

# Collect all default subnets (comma-separated for CloudFormation List parameter)
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
[[ -z "$SUBNET_IDS" ]] && die "No default subnets found."
ok "Subnets: $SUBNET_IDS"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Load or generate secrets (generated once, reused on re-runs)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 3 — Secrets"

DB_PASSWORD=$(load_state "DB_PASSWORD")
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD=$(python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits
print(''.join(secrets.choice(chars) for _ in range(16)))
")
  save_state "DB_PASSWORD" "$DB_PASSWORD"
  ok "Generated new DB password (saved to .aws-state.env)"
else
  ok "Loaded existing DB password"
fi

JWT_SECRET=$(load_state "JWT_SECRET")
if [[ -z "$JWT_SECRET" ]]; then
  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  save_state "JWT_SECRET" "$JWT_SECRET"
  ok "Generated new JWT secret (saved to .aws-state.env)"
else
  ok "Loaded existing JWT secret"
fi

warn ".aws-state.env contains sensitive values — it is gitignored, never commit it."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Deploy CloudFormation stack
# ─────────────────────────────────────────────────────────────────────────────
step "Step 4 — Deploy stack (this may take 15–20 min on first run due to RDS)"

[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"

# cloudformation deploy:
#   - Creates the stack if it doesn't exist
#   - Updates it if it does (only changed resources)
#   - Exits 0 with no-op message if nothing changed (--no-fail-on-empty-changeset)
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    SubnetIds="$SUBNET_IDS" \
    DBPassword="$DB_PASSWORD" \
    JWTSecret="$JWT_SECRET" \
    GitHubRepo="$GITHUB_REPO"

ok "Stack deploy complete."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Extract outputs and print GitHub Secrets
# ─────────────────────────────────────────────────────────────────────────────
step "Step 5 — Stack outputs"

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null
}

ECR_URI=$(get_output "ECRRepositoryUri")
S3_BUCKET=$(get_output "S3BucketName")
CF_DIST_ID=$(get_output "CloudFrontDistributionId")
CF_DOMAIN=$(get_output "CloudFrontDomain")
BACKEND_URL=$(get_output "BackendUrl")
ECS_CLUSTER=$(get_output "ECSClusterName")
ECS_SERVICE=$(get_output "ECSServiceName")
GH_ROLE_ARN=$(get_output "GitHubActionsRoleArn")

ok "ECR URI       : $ECR_URI"
ok "S3 Bucket     : $S3_BUCKET"
ok "CloudFront    : $CF_DOMAIN"
ok "Backend URL   : $BACKEND_URL"
ok "ECS Cluster   : $ECS_CLUSTER"

# Save outputs for reference
save_state "ECR_URI"    "$ECR_URI"
save_state "S3_BUCKET"  "$S3_BUCKET"
save_state "CF_DIST_ID" "$CF_DIST_ID"
save_state "CF_DOMAIN"  "$CF_DOMAIN"
save_state "BACKEND_URL" "$BACKEND_URL"
save_state "ECS_CLUSTER" "$ECS_CLUSTER"
save_state "ECS_SERVICE" "$ECS_SERVICE"

echo
hr
printf "${BLD}  GitHub Secrets${RST}\n"
printf "  GitHub → Settings → Secrets and variables → Actions\n"
hr
echo

if [[ -n "$GH_ROLE_ARN" ]]; then
  printf "${GRN}${BLD}  GitHub OIDC is enabled — NO access keys needed in GitHub Secrets.${RST}\n"
  printf "  Update cd.yml to use role-to-assume (see note below).\n\n"
  printf "  %-40s  %s\n" "Secret" "Value"
  printf "  %-40s  %s\n" "────────────────────────────────────────" "────────────────────────────────────────────"
  printf "  %-40s  %s\n" "AWS_REGION"                      "$REGION"
  printf "  %-40s  %s\n" "AWS_GITHUB_ACTIONS_ROLE_ARN"     "$GH_ROLE_ARN"
  printf "  %-40s  %s\n" "ECR_REPOSITORY"                  "my-trip-advisor-backend"
  printf "  %-40s  %s\n" "ECS_CLUSTER"                     "$ECS_CLUSTER"
  printf "  %-40s  %s\n" "ECS_SERVICE"                     "$ECS_SERVICE"
  printf "  %-40s  %s\n" "ECS_TASK_FAMILY"                 "my-trip-advisor-backend"
  printf "  %-40s  %s\n" "S3_BUCKET"                       "$S3_BUCKET"
  printf "  %-40s  %s\n" "CLOUDFRONT_DISTRIBUTION_ID"      "$CF_DIST_ID"
  printf "  %-40s  %s\n" "VITE_API_BASE_URL"               "$BACKEND_URL"
  echo
  printf "  ${YLW}cd.yml change needed — replace:${RST}\n"
  printf "    aws-access-key-id / aws-secret-access-key\n"
  printf "  ${YLW}with:${RST}\n"
  printf "    role-to-assume: \${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}\n"
else
  printf "  ${YLW}GitHub OIDC not configured (GitHubRepo param was empty).${RST}\n"
  printf "  Access keys are required. Create an IAM user and add:\n\n"
  printf "  %-40s  %s\n" "Secret" "Value"
  printf "  %-40s  %s\n" "────────────────────────────────────────" "──────────────────────────────────────────────"
  printf "  %-40s  %s\n" "AWS_ACCESS_KEY_ID"               "<IAM user key>"
  printf "  %-40s  %s\n" "AWS_SECRET_ACCESS_KEY"           "<IAM user secret>"
  printf "  %-40s  %s\n" "AWS_REGION"                      "$REGION"
  printf "  %-40s  %s\n" "ECR_REPOSITORY"                  "my-trip-advisor-backend"
  printf "  %-40s  %s\n" "ECS_CLUSTER"                     "$ECS_CLUSTER"
  printf "  %-40s  %s\n" "ECS_SERVICE"                     "$ECS_SERVICE"
  printf "  %-40s  %s\n" "ECS_TASK_FAMILY"                 "my-trip-advisor-backend"
  printf "  %-40s  %s\n" "S3_BUCKET"                       "$S3_BUCKET"
  printf "  %-40s  %s\n" "CLOUDFRONT_DISTRIBUTION_ID"      "$CF_DIST_ID"
  printf "  %-40s  %s\n" "VITE_API_BASE_URL"               "$BACKEND_URL"
fi

echo
hr
