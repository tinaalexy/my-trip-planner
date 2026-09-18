#!/usr/bin/env bash
# Local pre-push hook — mirrors the CI pipeline.
# Install:  bash scripts/pre-push.sh --install
# Run once: bash scripts/pre-push.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=1
ERRORS_FILE="$(mktemp)"
trap 'rm -f "$ERRORS_FILE"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
step() { echo; echo "▶  $1"; }
ok()   { echo "   ✓  $1"; }
# Write error to temp file so subshells can communicate failures to parent
err()  { echo "   ✗  $1"; echo "$1" >> "$ERRORS_FILE"; }

# ── install mode ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--install" ]]; then
  HOOK="$REPO_ROOT/.git/hooks/pre-push"
  cat > "$HOOK" <<'HOOK_BODY'
#!/usr/bin/env bash
exec "$(git rev-parse --show-toplevel)/scripts/pre-push.sh"
HOOK_BODY
  chmod +x "$HOOK"
  echo "pre-push hook installed at $HOOK"
  exit 0
fi

echo "═══════════════════════════════════════════"
echo "  Pre-push checks"
echo "═══════════════════════════════════════════"

# ── BACKEND TESTS ─────────────────────────────────────────────────────────────
step "Backend — pytest"
(
  cd "$REPO_ROOT/backend"
  export DATABASE_URL="sqlite:///./test.db"
  export JWT_SECRET="test-secret-key-min-32-characters-long"
  export JWT_EXPIRES_DAYS="1"
  export CORS_ORIGINS="http://localhost:5173"
  python -m pytest --tb=short -q 2>&1
) && ok "All backend tests passed" || err "Backend tests failed"

# ── BACKEND SECURITY ──────────────────────────────────────────────────────────
step "Backend — Bandit security scan"
if command -v bandit &>/dev/null; then
  (cd "$REPO_ROOT/backend" && bandit -r app/ -ll --skip B101 -q 2>&1) \
    && ok "Bandit: no medium/high issues" || err "Bandit found security issues"
else
  echo "   ⚠  bandit not installed — skipping (pip install bandit)"
fi

step "Backend — Safety dependency scan"
if command -v safety &>/dev/null; then
  (cd "$REPO_ROOT/backend" && safety scan 2>&1) \
    && ok "Safety: no known vulnerabilities" || err "Safety found vulnerable dependencies"
else
  echo "   ⚠  safety not installed — skipping (pip install safety)"
fi

# ── BACKEND PRIVACY ───────────────────────────────────────────────────────────
step "Backend — Privacy / hardcoded secrets scan"
PATTERNS='(password\s*=\s*["'"'"'][^"'"'"']{6,}|secret\s*=\s*["'"'"'][^"'"'"']{6,}|api_key\s*=\s*["'"'"'][^"'"'"']{4,})'
if grep -rEn "$PATTERNS" "$REPO_ROOT/backend/app/" --include="*.py" 2>/dev/null; then
  err "Possible hardcoded credential in backend source"
else
  ok "No hardcoded secrets detected"
fi

# ── FRONTEND TYPE-CHECK & LINT ────────────────────────────────────────────────
step "Frontend — TypeScript type-check"
(cd "$REPO_ROOT/frontend" && npx tsc --noEmit 2>&1) \
  && ok "TypeScript: no type errors" || err "TypeScript type errors found"

step "Frontend — oxlint"
(cd "$REPO_ROOT/frontend" && npm run lint 2>&1) \
  && ok "oxlint: no lint errors" || err "Lint errors found"

# ── FRONTEND SECURITY ─────────────────────────────────────────────────────────
step "Frontend — npm audit"
(cd "$REPO_ROOT/frontend" && npm audit --audit-level=moderate 2>&1) \
  && ok "npm audit: no moderate+ vulnerabilities" || err "npm audit found vulnerabilities"

step "Frontend — Privacy / hardcoded credentials scan"
PATTERNS='(api_key|apikey|secret|password|token)\s*[:=]\s*["'"'"'][A-Za-z0-9+/\-_]{8,}'
if grep -rEin "$PATTERNS" "$REPO_ROOT/frontend/src/" --include="*.ts" --include="*.tsx" 2>/dev/null; then
  err "Possible hardcoded credential in frontend source"
else
  ok "No hardcoded credentials detected"
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════"
if [[ ! -s "$ERRORS_FILE" ]]; then
  echo "  ALL CHECKS PASSED — safe to push"
  echo "═══════════════════════════════════════════"
  exit $PASS
else
  echo "  FAILED CHECKS:"
  while IFS= read -r line; do
    echo "    • $line"
  done < "$ERRORS_FILE"
  echo "═══════════════════════════════════════════"
  echo "  Fix the issues above before pushing."
  exit $FAIL
fi
