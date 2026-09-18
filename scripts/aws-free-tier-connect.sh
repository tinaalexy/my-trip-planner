#!/usr/bin/env bash
# Set up a dedicated AWS CLI profile for the my-trip-advisor project.
# Uses the profile name "trip-advisor" — sits alongside existing Philips
# profiles without touching them.
#
# Usage:
#   bash scripts/aws-free-tier-connect.sh          — interactive setup
#   bash scripts/aws-free-tier-connect.sh --verify — verify existing profile
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PROFILE="505435644200-aws-free-tier"
REGION="ap-southeast-2"
VERIFY_ONLY=false
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=true

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'; CYN='\033[36m'; BLD='\033[1m'; RST='\033[0m'
ok()   { printf "   ${GRN}✓${RST}  %s\n" "$1"; }
warn() { printf "   ${YLW}⚠${RST}  %s\n" "$1"; }
err()  { printf "   ${RED}✗${RST}  %s\n" "$1"; }
step() { echo;  printf "${BLD}▶  %s${RST}\n" "$1"; }
info() { printf "   ${CYN}→${RST}  %s\n" "$1"; }
hr()   { echo "═══════════════════════════════════════════════════"; }
die()  { err "$1"; echo; exit 1; }

hr
printf "${BLD}  AWS Free Tier — Profile Setup (profile: %s)${RST}\n" "$PROFILE"
hr

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Check AWS CLI
# ─────────────────────────────────────────────────────────────────────────────
step "Step 1 — AWS CLI"
if ! command -v aws &>/dev/null; then
  err "AWS CLI not installed."
  echo
  info "Install it with one of these:"
  echo
  echo "    Windows (PowerShell as admin):"
  echo "      winget install Amazon.AWSCLI"
  echo
  echo "    Or download the installer:"
  echo "      https://awscli.amazonaws.com/AWSCLIV2.msi"
  echo
  echo "  After installing, re-run this script."
  hr
  exit 1
fi
ok "AWS CLI: $(aws --version 2>&1 | awk '{print $1}')"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Check if profile already exists
# ─────────────────────────────────────────────────────────────────────────────
step "Step 2 — Check existing profile"
PROFILE_EXISTS=false
if aws configure list --profile "$PROFILE" 2>/dev/null | grep -q "access_key"; then
  PROFILE_EXISTS=true
  ok "Profile '$PROFILE' is already configured."
  if $VERIFY_ONLY; then
    echo
  fi
else
  warn "Profile '$PROFILE' not found — will create it."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Guide account + IAM user creation (if not verifying)
# ─────────────────────────────────────────────────────────────────────────────
if ! $VERIFY_ONLY && ! $PROFILE_EXISTS; then
  step "Step 3 — Create AWS Free Tier account (if you haven't already)"
  echo
  echo "  If you don't have a personal AWS account:"
  echo
  info "1. Open: https://aws.amazon.com/free"
  info "2. Click 'Create a Free Account'"
  info "3. Fill in email, password, account name"
  info "4. Enter a credit card (required; won't charge within free tier limits)"
  info "5. Verify your phone number"
  info "6. Choose 'Basic support (Free)'"
  info "7. Sign in to the AWS Console"
  echo
  read -rp "   Press Enter once your AWS account is ready..." _

  step "Step 4 — Create an IAM user in the AWS Console"
  echo
  info "1. Go to: AWS Console → search 'IAM' → Users → Create user"
  info "2. Username: trip-advisor-deploy"
  info "3. Click 'Next' (no console access needed)"
  info "4. 'Attach policies directly' → search and attach:"
  echo "        AmazonEC2ContainerRegistryFullAccess"
  echo "        AmazonS3FullAccess"
  echo "        AmazonRDSFullAccess"
  echo "        AmazonVPCFullAccess"
  echo "        IAMFullAccess"
  echo "        AWSAppRunnerFullAccess"
  echo "        CloudFrontFullAccess"
  info "5. Create user → click the user → 'Security credentials' tab"
  info "6. 'Create access key' → Use case: CLI → Create"
  info "7. IMPORTANT: Download the .csv file — the secret is shown only once"
  echo
  read -rp "   Press Enter once you have the Access Key ID and Secret Access Key..." _
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 / 5 — Configure the profile
# ─────────────────────────────────────────────────────────────────────────────
if ! $VERIFY_ONLY && ! $PROFILE_EXISTS; then
  step "Step 5 — Configure profile '$PROFILE'"
  echo
  echo "  Enter the credentials from the IAM user you just created."
  echo "  (Input is hidden for the secret key)"
  echo

  read -rp "   AWS Access Key ID:     " INPUT_KEY_ID
  [[ -z "$INPUT_KEY_ID" ]] && die "Access Key ID cannot be empty."

  read -rsp "   AWS Secret Access Key: " INPUT_SECRET
  echo
  [[ -z "$INPUT_SECRET" ]] && die "Secret Access Key cannot be empty."

  # Validate key ID format  (AKIA... or ASIA...)
  if ! echo "$INPUT_KEY_ID" | grep -qE '^(AKIA|ASIA)[A-Z0-9]{16}$'; then
    warn "Key ID format looks unusual — double-check it, but continuing."
  fi

  aws configure set aws_access_key_id     "$INPUT_KEY_ID" --profile "$PROFILE"
  aws configure set aws_secret_access_key "$INPUT_SECRET" --profile "$PROFILE"
  aws configure set region                "$REGION"       --profile "$PROFILE"
  aws configure set output                "json"          --profile "$PROFILE"

  ok "Profile '$PROFILE' saved to ~/.aws/credentials"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Verify connection
# ─────────────────────────────────────────────────────────────────────────────
step "Step 6 — Verify connection"
IDENTITY=$(AWS_PROFILE="$PROFILE" aws sts get-caller-identity --output json 2>&1)
if [[ $? -ne 0 ]]; then
  err "Authentication failed."
  echo
  echo "$IDENTITY"
  echo
  info "Common fixes:"
  info "  — Check the Access Key ID starts with AKIA (long-term) or ASIA (temp)"
  info "  — Re-run without --verify to re-enter credentials:"
  info "      bash scripts/aws-free-tier-connect.sh"
  hr
  exit 1
fi

ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$IDENTITY"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
USER_ID=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['UserId'])")

ok "Connected!"
ok "Account : $ACCOUNT"
ok "Identity: $ARN"

# Warn if this is a role (assumed-role) rather than an IAM user
if echo "$ARN" | grep -q "assumed-role"; then
  warn "This identity is a role, not an IAM user."
  warn "Long-term credentials won't work — use an IAM user for the CD pipeline."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Permission check
# ─────────────────────────────────────────────────────────────────────────────
step "Step 7 — Required permissions check"
PERM_FAIL=false

check_perm() {
  local label=$1 svc=$2; shift 2
  if AWS_PROFILE="$PROFILE" aws "$svc" "$@" --region "$REGION" &>/dev/null 2>&1; then
    ok "$label"
  else
    err "$label — MISSING"
    PERM_FAIL=true
  fi
}

check_perm "ECR"         ecr          describe-repositories
check_perm "S3"          s3api        list-buckets
check_perm "EC2 / VPC"   ec2          describe-vpcs
check_perm "RDS"         rds          describe-db-instances
check_perm "IAM"         iam          list-roles
check_perm "ECS"         ecs          list-clusters
check_perm "CloudFront"  cloudfront   list-distributions

if $PERM_FAIL; then
  echo
  warn "Some permissions are missing. In the IAM Console:"
  info "  Users → trip-advisor-deploy → Permissions → Add permissions"
  info "  Attach the policies for any failing checks above."
  echo
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Save profile to project state and update provision script env
# ─────────────────────────────────────────────────────────────────────────────
step "Step 8 — Save profile to project"
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.aws-state.env"
touch "$STATE_FILE"

# Write or overwrite the AWS_PROFILE entry
if grep -q "^AWS_PROFILE=" "$STATE_FILE" 2>/dev/null; then
  sed -i "s|^AWS_PROFILE=.*|AWS_PROFILE=$PROFILE|" "$STATE_FILE"
else
  echo "AWS_PROFILE=$PROFILE"   >> "$STATE_FILE"
fi
if grep -q "^AWS_ACCOUNT=" "$STATE_FILE" 2>/dev/null; then
  sed -i "s|^AWS_ACCOUNT=.*|AWS_ACCOUNT=$ACCOUNT|" "$STATE_FILE"
else
  echo "AWS_ACCOUNT=$ACCOUNT"   >> "$STATE_FILE"
fi
ok "Saved to .aws-state.env"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo
hr
if $PERM_FAIL; then
  printf "${YLW}${BLD}  Connected but some permissions need fixing (see above).${RST}\n"
else
  printf "${GRN}${BLD}  All checks passed. Ready to provision infrastructure.${RST}\n"
  echo
  info "Next step — provision all AWS resources:"
  echo
  echo "    AWS_PROFILE=$PROFILE bash scripts/aws-provision.sh"
fi
hr
