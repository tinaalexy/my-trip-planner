#!/usr/bin/env bash
# Script 1 of 2 — AWS IAM Identity Center (SSO) profile setup.
#
# Creates a named AWS CLI profile that uses short-lived session tokens
# issued by AWS IAM Identity Center. No long-term access keys are ever
# stored on disk — credentials expire automatically and are refreshed
# via a browser login (no key rotation required).
#
# Usage:
#   bash scripts/aws-sso-setup.sh           — guided first-time setup
#   bash scripts/aws-sso-setup.sh --login   — refresh expired session
#   bash scripts/aws-sso-setup.sh --verify  — check connection + permissions
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PROFILE="trip-advisor"
REGION="ap-southeast-2"
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.aws-state.env"

# ── Colour helpers ────────────────────────────────────────────────────────────
GRN='\033[32m'; YLW='\033[33m'; RED='\033[31m'; CYN='\033[36m'; BLD='\033[1m'; RST='\033[0m'
ok()   { printf "   ${GRN}✓${RST}  %s\n" "$1"; }
warn() { printf "   ${YLW}⚠${RST}  %s\n" "$1"; }
err()  { printf "   ${RED}✗${RST}  %s\n" "$1"; }
step() { echo;  printf "${BLD}▶  %s${RST}\n" "$1"; }
info() { printf "   ${CYN}→${RST}  %s\n" "$1"; }
hr()   { echo "═══════════════════════════════════════════════════"; }
die()  { err "$1"; echo; exit 1; }

MODE="setup"
[[ "${1:-}" == "--login"  ]] && MODE="login"
[[ "${1:-}" == "--verify" ]] && MODE="verify"

hr
printf "${BLD}  AWS SSO Profile Setup (profile: %s)${RST}\n" "$PROFILE"
printf "  No long-term keys — session tokens only\n"
hr

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — AWS CLI version check (SSO requires v2)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 1 — AWS CLI"
command -v aws &>/dev/null || die "AWS CLI not installed. Run: winget install Amazon.AWSCLI"

CLI_VERSION=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[0-9]+' | head -1)
if [[ "$CLI_VERSION" -lt 2 ]]; then
  die "AWS CLI v2 required for SSO. Installed: $(aws --version 2>&1 | awk '{print $1}'). Update with: winget upgrade Amazon.AWSCLI"
fi
ok "AWS CLI v2: $(aws --version 2>&1 | awk '{print $1}')"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Refresh or verify an existing session
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "login" ]]; then
  step "Refreshing SSO session"
  aws sso login --profile "$PROFILE" \
    && ok "Session refreshed. Run: bash scripts/aws-provision.sh" \
    || die "Login failed. Check your SSO start URL with: aws configure list --profile $PROFILE"
  exit 0
fi

if [[ "$MODE" == "verify" ]]; then
  step "Verifying session"
  IDENTITY=$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>&1) \
    || { err "Session expired or profile not found."; echo; info "Refresh: bash scripts/aws-sso-setup.sh --login"; exit 1; }
  ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
  ok "Account : $ACCOUNT"
  ok "Identity: $ARN"
  # Fall through to permission check below
  goto_perms=true
else
  goto_perms=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — First-time setup: guide through IAM Identity Center
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "setup" ]]; then

  # Check whether profile already exists and session is valid
  IDENTITY=$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>/dev/null)
  if [[ -n "$IDENTITY" ]]; then
    ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
    ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
    ok "Profile '$PROFILE' exists and session is active."
    ok "Account : $ACCOUNT"
    ok "Identity: $ARN"
    goto_perms=true
  else
    goto_perms=false

    step "Step 3 — Enable AWS IAM Identity Center (one-time, ~5 min)"
    echo
    echo "  IAM Identity Center gives you short-lived credentials via browser"
    echo "  login — no access keys to create or rotate."
    echo
    info "1. Sign in to the AWS Console as the root user of account 103714493047"
    info "2. Search 'IAM Identity Center' → Enable"
    info "3. Under 'Users' → Add user → enter your email → set a password"
    info "4. Under 'Permission sets' → Create permission set → AdministratorAccess"
    info "5. Under 'AWS accounts' → select your account → Assign users"
    info "   → select your user → select AdministratorAccess → Submit"
    info "6. Note the 'AWS access portal URL' shown on the Identity Center dashboard"
    info "   It looks like: https://d-xxxxxxxxxx.awsapps.com/start"
    echo
    read -rp "   Press Enter once Identity Center is enabled and you have the access portal URL..." _

    step "Step 4 — Configure the '$PROFILE' profile"
    echo
    echo "  Enter the values from the IAM Identity Center console."
    echo

    read -rp "   SSO Start URL (e.g. https://d-xxxxxxxxxx.awsapps.com/start): " SSO_START_URL
    [[ -z "$SSO_START_URL" ]] && die "SSO start URL cannot be empty."
    [[ "$SSO_START_URL" != https://* ]] && die "SSO start URL must start with https://"

    read -rp "   Permission set name [AdministratorAccess]: " ROLE_NAME
    ROLE_NAME="${ROLE_NAME:-AdministratorAccess}"

    ACCOUNT_ID="103714493047"
    read -rp "   AWS Account ID [$ACCOUNT_ID]: " INPUT_ACCOUNT
    [[ -n "$INPUT_ACCOUNT" ]] && ACCOUNT_ID="$INPUT_ACCOUNT"

    # Write SSO config using aws configure set (no interactive prompts)
    aws configure set sso_start_url  "$SSO_START_URL" --profile "$PROFILE"
    aws configure set sso_region     "$REGION"        --profile "$PROFILE"
    aws configure set sso_account_id "$ACCOUNT_ID"    --profile "$PROFILE"
    aws configure set sso_role_name  "$ROLE_NAME"     --profile "$PROFILE"
    aws configure set region         "$REGION"        --profile "$PROFILE"
    aws configure set output         "json"            --profile "$PROFILE"
    ok "Profile '$PROFILE' written to ~/.aws/config"

    step "Step 5 — Browser login"
    echo
    warn "The next step opens a browser for authentication."
    warn "If running in a headless/remote terminal, use --no-browser to get a manual URL."
    echo
    info "Running: aws sso login --profile $PROFILE"
    echo

    if aws sso login --profile "$PROFILE"; then
      ok "Login successful"
    else
      echo
      err "Browser login failed or was cancelled."
      info "Retry manually:  aws sso login --profile $PROFILE"
      info "Or use:          aws sso login --profile $PROFILE --no-browser"
      exit 1
    fi

    # Fetch identity after login
    IDENTITY=$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>&1) \
      || die "Authentication failed after login. Check profile config with: aws configure list --profile $PROFILE"
    ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
    ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
    ok "Account : $ACCOUNT"
    ok "Identity: $ARN"
    goto_perms=true
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Permission check
# ─────────────────────────────────────────────────────────────────────────────
if $goto_perms; then
  step "Step 6 — Required permissions"
  PERM_FAIL=false

  check_perm() {
    local label=$1 svc=$2; shift 2
    if aws "$svc" "$@" --profile "$PROFILE" --region "$REGION" &>/dev/null 2>&1; then
      ok "$label"
    else
      err "$label — MISSING"
      PERM_FAIL=true
    fi
  }

  check_perm "ECR"         ecr        describe-repositories
  check_perm "S3"          s3api      list-buckets
  check_perm "EC2 / VPC"   ec2        describe-vpcs
  check_perm "RDS"         rds        describe-db-instances
  check_perm "ECS"         ecs        list-clusters
  check_perm "IAM"         iam        list-roles
  check_perm "CloudFront"  cloudfront list-distributions
  check_perm "Secrets Mgr" secretsmanager list-secrets
  check_perm "CloudWatch"  logs       describe-log-groups
  check_perm "CloudFormation" cloudformation list-stacks

  if $PERM_FAIL; then
    echo
    warn "Some permissions are missing. Ensure the permission set assigned"
    warn "in IAM Identity Center includes AdministratorAccess."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Save profile to project state
# ─────────────────────────────────────────────────────────────────────────────
step "Step 7 — Save to project"
touch "$STATE_FILE"

update_state() {
  local key=$1 val=$2
  if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$STATE_FILE"
  else
    echo "${key}=${val}" >> "$STATE_FILE"
  fi
}

update_state "AWS_PROFILE" "$PROFILE"
update_state "AWS_REGION"  "$REGION"
ok "Saved profile '$PROFILE' to .aws-state.env"

echo
hr
if ! ${PERM_FAIL:-false}; then
  printf "${GRN}${BLD}  Profile ready. Next step — provision infrastructure:${RST}\n"
  echo
  echo "    bash scripts/aws-provision.sh"
  echo
  printf "  Session expires in ~8 hours. Refresh with:\n"
  echo
  echo "    bash scripts/aws-sso-setup.sh --login"
else
  printf "${YLW}${BLD}  Profile saved but permissions need fixing (see above).${RST}\n"
fi
hr
