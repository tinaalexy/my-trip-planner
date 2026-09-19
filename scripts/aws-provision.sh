#!/usr/bin/env bash
# Provision all AWS infrastructure for my-trip-advisor.
#
# What this script does:
#   1. Checks your AWS credentials are working
#   2. Finds your default VPC and subnets (required by CloudFormation)
#   3. Generates a database password and JWT secret (once, then reuses them)
#   4. Deploys infrastructure/stack.yml via AWS CloudFormation
#      CloudFormation creates every AWS resource in the right order:
#      ECR, S3, CloudFront, RDS, ECS, EC2, Secrets Manager, IAM roles, etc.
#   5. Prints the GitHub Secrets you need to add after provisioning
#
# Usage:
#   bash scripts/aws-provision.sh             -- create or update all infrastructure
#   bash scripts/aws-provision.sh --delete    -- tear down all infrastructure
#   bash scripts/aws-provision.sh --outputs   -- show what was created (URLs, IDs)
#
# Before running:
#   aws configure --profile aws-free-tier
#   (enter your IAM user Access Key ID and Secret Access Key when prompted)
# -----------------------------------------------------------------------------
set -uo pipefail

# -- Configuration ------------------------------------------------------------
PROFILE="aws-free-tier"          # AWS CLI profile (set up with: aws configure --profile aws-free-tier)
REGION="ap-southeast-2"          # AWS region to deploy into
STACK_NAME="my-trip-advisor"     # CloudFormation stack name
# OIDC removed: org SCP blocks iam:CreateOpenIDConnectProvider; GitHub Secrets use long-term access keys

# Paths (relative to the repo root — works from any directory)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_ROOT/infrastructure/stack.yml"   # CloudFormation template
# On Git Bash (Windows), convert /c/path → /c:/path so that file://$TEMPLATE_WIN
# produces the valid three-slash URI file:///c:/path.  Guard on MSYSTEM so the
# sed never runs on Linux/macOS where single-letter top-level dirs are legitimate.
TEMPLATE_WIN="$TEMPLATE"
# On Git Bash (Windows) only: convert /c/path → c:/path for the AWS CLI file:// prefix.
# botocore on Windows correctly handles file://c:/path (2-slash form).
# Guard on MSYSTEM so this never runs on Linux/macOS where /a/... is a real path.
if [[ "${MSYSTEM:-}" == MINGW* || "${MSYSTEM:-}" == MSYS* || "${MSYSTEM:-}" == UCRT* ]]; then
  TEMPLATE_WIN="$(echo "$TEMPLATE" | sed 's|^/\([a-zA-Z]\)/|\1:/|')"
fi
STATE_FILE="$REPO_ROOT/.aws-state.env"           # Saves generated secrets between runs

# -- Colour output ------------------------------------------------------------
GRN='\033[32m'; YLW='\033[33m'; RED='\033[31m'; BLD='\033[1m'; RST='\033[0m'
ok()   { printf "   ${GRN}✓${RST}  %s\n" "$1"; }   # green tick
warn() { printf "   ${YLW}!${RST}  %s\n" "$1"; }   # yellow warning
err()  { printf "   ${RED}✗${RST}  %s\n" "$1"; }   # red cross
step() { echo;  printf "${BLD}► %s${RST}\n" "$1"; } # bold section header
hr()   { echo "────────────────────────────────────────────────────"; }
die()  { err "$1"; echo; exit 1; }                  # print error and quit

# -- Helpers to save/load values between runs ---------------------------------
# Generated secrets (DB password, JWT key) are saved to .aws-state.env so
# they stay the same if you re-run this script. The file is gitignored.
load_state() { grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
save_state() {
  touch "$STATE_FILE"
  if grep -q "^$1=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"   # update existing entry
  else
    echo "$1=$2" >> "$STATE_FILE"             # add new entry
  fi
}

# -- Read the mode flag (--delete or --outputs) -------------------------------
MODE="deploy"
[[ "${1:-}" == "--delete"  ]] && MODE="delete"
[[ "${1:-}" == "--outputs" ]] && MODE="outputs"

# =============================================================================
hr
printf "${BLD}  my-trip-advisor — AWS Provisioning${RST}\n"
printf "  Profile : $PROFILE  |  Region : $REGION\n"
hr

# =============================================================================
# STEP 1 — Check AWS credentials
# Makes sure the aws-free-tier profile is configured and working.
# =============================================================================
step "Step 1 — Checking AWS credentials"

export AWS_PROFILE="$PROFILE"
export AWS_DEFAULT_REGION="$REGION"

IDENTITY=$(aws sts get-caller-identity --output json 2>&1) \
  || die "Credentials not working. Run: aws configure --profile aws-free-tier"

ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ARN=$(echo     "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")

ok "Connected to AWS account: $ACCOUNT"
ok "Logged in as: $ARN"

# -- Delete mode: remove all infrastructure -----------------------------------
if [[ "$MODE" == "delete" ]]; then
  step "Deleting all infrastructure"
  warn "This will delete all resources EXCEPT:"
  warn "  ECR repository, S3 bucket, RDS database snapshot, CloudWatch logs"
  warn "  (these are kept so you don't lose data accidentally)"
  echo
  read -rp "   Type the stack name '$STACK_NAME' to confirm: " CONFIRM
  [[ "$CONFIRM" != "$STACK_NAME" ]] && die "Cancelled — nothing was deleted."

  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  echo "   Waiting for deletion to finish (this may take a few minutes)..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
  ok "All infrastructure deleted."
  hr; exit 0
fi

# -- Outputs mode: show what was already created ------------------------------
if [[ "$MODE" == "outputs" ]]; then
  step "Showing what was created"
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].Outputs' --output table 2>/dev/null \
    || die "Stack '$STACK_NAME' not found. Run without --outputs to create it first."
  hr; exit 0
fi

# =============================================================================
# STEP 2 — Find your default VPC and subnets
# CloudFormation needs to know which network to put the database and server in.
# This step auto-discovers the default VPC that AWS creates for every account.
# =============================================================================
step "Step 2 — Finding default VPC and subnets"

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
[[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && die "No default VPC found in $REGION."
ok "VPC: $VPC_ID"

# Subnets must span at least 2 availability zones (required by RDS)
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
[[ -z "$SUBNET_IDS" ]] && die "No default subnets found in $REGION."
ok "Subnets: $SUBNET_IDS"

# =============================================================================
# STEP 3 — Generate secrets
# A random database password and JWT signing key are created once and saved
# to .aws-state.env so they stay the same if you re-run this script.
# These are passed to CloudFormation and stored in AWS Secrets Manager —
# they are never written into your code or visible in plain text on AWS.
# =============================================================================
step "Step 3 — Generating secrets (once only — reused on re-runs)"

DB_PASSWORD=$(load_state "DB_PASSWORD")
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD=$(python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits
print(''.join(secrets.choice(chars) for _ in range(16)))
")
  save_state "DB_PASSWORD" "$DB_PASSWORD"
  ok "New database password generated and saved to .aws-state.env"
else
  ok "Using existing database password from .aws-state.env"
fi

JWT_SECRET=$(load_state "JWT_SECRET")
if [[ -z "$JWT_SECRET" ]]; then
  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  save_state "JWT_SECRET" "$JWT_SECRET"
  ok "New JWT secret generated and saved to .aws-state.env"
else
  ok "Using existing JWT secret from .aws-state.env"
fi

warn ".aws-state.env holds sensitive values — never commit this file to git."

# =============================================================================
# STEP 4 — Deploy CloudFormation stack
# CloudFormation reads infrastructure/stack.yml and creates every AWS resource
# described in it. On first run this takes 15–20 minutes (mostly waiting for
# RDS to start). On re-runs it only updates resources that changed.
# =============================================================================
step "Step 4 — Deploying CloudFormation stack (first run: ~15-20 min)"

[[ -f "$TEMPLATE" ]] || die "Template not found at: $TEMPLATE"

# Use create-stack or update-stack directly (not 'deploy') to avoid the
# changeset-based EarlyValidation hook, which is blocked by the org SCP.
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

# If a stack operation is already in flight (e.g. this script was re-run mid-deploy),
# poll until it reaches a terminal state. We poll rather than using 'wait' because
# 'wait stack-create-complete' blocks indefinitely with no output.
if [[ "$STACK_STATUS" == *"_IN_PROGRESS"* ]]; then
  warn "Stack operation in progress ($STACK_STATUS) — polling until it settles..."
  while [[ "$STACK_STATUS" == *"_IN_PROGRESS"* ]]; do
    sleep 15
    STACK_STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")
    echo "   ... $STACK_STATUS"
  done
  ok "Stack settled: $STACK_STATUS"
fi

# If a previous run failed and rolled back, clean up the shell and any retained
# orphan resources (ECR repo, S3 bucket, CloudWatch log group survive rollback
# via DeletionPolicy:Retain and block a fresh create-stack by name).
if [[ "$STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
  warn "Previous run failed and rolled back (ROLLBACK_COMPLETE). Cleaning up before retrying..."

  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION" \
    || die "Failed to delete ROLLBACK_COMPLETE stack shell. Check the AWS Console and clean up manually."
  echo "   Waiting for stack shell deletion..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" \
    || die "Stack shell deletion failed or timed out (DELETE_FAILED?). Check the AWS Console."
  ok "Stack shell deleted."

  # ECR repository (DeletionPolicy: Retain)
  ECR_REPO="my-trip-advisor-backend"
  if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" &>/dev/null; then
    aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" --force \
      || die "Failed to delete orphan ECR repository: $ECR_REPO"
    ok "Removed orphan ECR repository: $ECR_REPO"
  fi

  # S3 bucket (DeletionPolicy: Retain) — name includes account ID for global uniqueness
  S3_ORPHAN="my-trip-advisor-frontend-$ACCOUNT"
  if aws s3api head-bucket --bucket "$S3_ORPHAN" 2>/dev/null; then
    aws s3 rb "s3://$S3_ORPHAN" --force --region "$REGION" \
      || die "Failed to delete orphan S3 bucket: $S3_ORPHAN"
    ok "Removed orphan S3 bucket: $S3_ORPHAN"
  fi

  # CloudWatch log group (DeletionPolicy: Retain)
  # MSYS_NO_PATHCONV=1 prevents Git Bash from mangling the leading slash into a Windows path
  LOG_GROUP="/ecs/my-trip-advisor-backend"
  if MSYS_NO_PATHCONV=1 aws logs describe-log-groups \
       --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
       --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
    MSYS_NO_PATHCONV=1 aws logs delete-log-group \
      --log-group-name "$LOG_GROUP" --region "$REGION" \
      || die "Failed to delete orphan CloudWatch log group: $LOG_GROUP"
    ok "Removed orphan CloudWatch log group: $LOG_GROUP"
  fi

  STACK_STATUS="DOES_NOT_EXIST"
fi

# Commas in SubnetIds must be escaped as \, for the AWS CLI --parameters flag
ESCAPED_SUBNETS="${SUBNET_IDS//,/\\,}"
PARAMS=(
  "ParameterKey=VpcId,ParameterValue=$VPC_ID"
  "ParameterKey=SubnetIds,ParameterValue=$ESCAPED_SUBNETS"
  "ParameterKey=DBPassword,ParameterValue=$DB_PASSWORD"
  "ParameterKey=JWTSecret,ParameterValue=$JWT_SECRET"
)

if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
  ok "Stack does not exist — creating..."
  aws cloudformation create-stack \
    --stack-name      "$STACK_NAME" \
    --template-body   "file://$TEMPLATE_WIN" \
    --region          "$REGION" \
    --capabilities    CAPABILITY_NAMED_IAM \
    --parameters      "${PARAMS[@]}" \
    || die "create-stack failed"
  echo "   Waiting for stack creation to complete (first run: ~15-20 min)..."
  aws cloudformation wait stack-create-complete \
    --stack-name "$STACK_NAME" --region "$REGION" \
    || die "Stack creation failed. Run: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION"
elif [[ "$STACK_STATUS" == "CREATE_COMPLETE" || "$STACK_STATUS" == "UPDATE_COMPLETE" || "$STACK_STATUS" == "UPDATE_ROLLBACK_COMPLETE" ]]; then
  ok "Stack exists ($STACK_STATUS) — updating..."
  UPDATE_OUT=$(aws cloudformation update-stack \
    --stack-name      "$STACK_NAME" \
    --template-body   "file://$TEMPLATE_WIN" \
    --region          "$REGION" \
    --capabilities    CAPABILITY_NAMED_IAM \
    --parameters      "${PARAMS[@]}" 2>&1)
  UPDATE_EXIT=$?
  if [[ $UPDATE_EXIT -eq 0 ]]; then
    echo "   Waiting for stack update to complete..."
    aws cloudformation wait stack-update-complete \
      --stack-name "$STACK_NAME" --region "$REGION" \
      || die "Stack update was accepted but failed mid-apply (UPDATE_ROLLBACK_COMPLETE). Run: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION"
  else
    # 'No updates are to be performed' is not an error
    echo "$UPDATE_OUT" | grep -q "No updates" \
      && ok "Stack is already up to date." \
      || die "update-stack API call failed: $UPDATE_OUT"
  fi
else
  die "Stack is in unexpected state: $STACK_STATUS. Clean it up before re-running."
fi

ok "Deployment complete."

# =============================================================================
# STEP 5 — Read outputs and print GitHub Secrets
# CloudFormation outputs the URLs and IDs you need to configure GitHub.
# Copy each value into GitHub → Settings → Secrets and variables → Actions.
# =============================================================================
step "Step 5 — Reading deployment outputs"

# Helper to read a single output value from the CloudFormation stack
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

ok "ECR (Docker images) : $ECR_URI"
ok "S3 (frontend files) : s3://$S3_BUCKET"
ok "Frontend URL        : $CF_DOMAIN"
ok "Backend URL         : $BACKEND_URL"
ok "ECS Cluster         : $ECS_CLUSTER"

# Save outputs to .aws-state.env for reference
save_state "ECR_URI"     "$ECR_URI"
save_state "S3_BUCKET"   "$S3_BUCKET"
save_state "CF_DIST_ID"  "$CF_DIST_ID"
save_state "CF_DOMAIN"   "$CF_DOMAIN"
save_state "BACKEND_URL" "$BACKEND_URL"
save_state "ECS_CLUSTER" "$ECS_CLUSTER"
save_state "ECS_SERVICE" "$ECS_SERVICE"

# -- Print GitHub Secrets table -----------------------------------------------
echo
hr
printf "${BLD}  Add these to GitHub Secrets${RST}\n"
printf "  Go to: GitHub repo → Settings → Secrets and variables → Actions\n"
hr
echo
printf "  %-40s  %s\n" "Secret name" "Value to paste"
printf "  %-40s  %s\n" "──────────────────────────────────────" "──────────────────────────────────────────"
printf "  %-40s  %s\n" "AWS_REGION"                      "$REGION"
printf "  %-40s  %s\n" "AWS_ACCESS_KEY_ID"               "(your IAM user access key)"
printf "  %-40s  %s\n" "AWS_SECRET_ACCESS_KEY"           "(your IAM user secret key)"
printf "  %-40s  %s\n" "ECR_REPOSITORY"                  "my-trip-advisor-backend"
printf "  %-40s  %s\n" "ECS_CLUSTER"                     "$ECS_CLUSTER"
printf "  %-40s  %s\n" "ECS_SERVICE"                     "$ECS_SERVICE"
printf "  %-40s  %s\n" "ECS_TASK_FAMILY"                 "my-trip-advisor-backend"
printf "  %-40s  %s\n" "S3_BUCKET"                       "$S3_BUCKET"
printf "  %-40s  %s\n" "CLOUDFRONT_DISTRIBUTION_ID"      "$CF_DIST_ID"
printf "  %-40s  %s\n" "VITE_API_BASE_URL"               "$BACKEND_URL"
echo
printf "  ${YLW}Note:${RST} OIDC is disabled (org SCP blocks iam:CreateOpenIDConnectProvider).\n"
printf "  Use the IAM user access keys above in GitHub Secrets instead.\n"
hr
