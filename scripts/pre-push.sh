#!/usr/bin/env bash
# Local pre-push hook — mirrors the CI pipeline.
# Install:  bash scripts/pre-push.sh --install
# Run once: bash scripts/pre-push.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=1
errors=()

# ── helpers ──────────────────────────────────────────────────────────────────
step() { echo; echo "▶  $1"; }
ok()   { echo "   ✓  $1"; }
err()  { echo "   ✗  $1"; errors+=("$1"); }

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
  if python -m pytest --tb=short -q 2>&1; then
    ok "All backend tests passed"
  else
    err "Backend tests failed"
  fi
)

# ── BACKEND SECURITY ──────────────────────────────────────────────────────────
step "Backend — Bandit security scan"
(
  cd "$REPO_ROOT/backend"
  if command -v bandit &>/dev/null; then
    if bandit -r app/ -ll --skip B101 -q 2>&1; then
      ok "Bandit: no medium/high issues"
    else
      err "Bandit found security issues"
    fi
  else
    echo "   ⚠  bandit not installed — skipping (pip install bandit)"
  fi
)

step "Backend — Safety dependency scan"
(
  cd "$REPO_ROOT/backend"
  if command -v safety &>/dev/null; then
    if safety scan 2>&1; then
      ok "Safety: no known vulnerabilities"
    else
      err "Safety found vulnerable dependencies"
    fi
  else
    echo "   ⚠  safety not installed — skipping (pip install safety)"
  fi
)

# ── BACKEND PRIVACY ───────────────────────────────────────────────────────────
step "Backend — Privacy / hardcoded secrets scan"
(
  cd "$REPO_ROOT/backend"
  PATTERNS='(password\s*=\s*["'"'"'][^"'"'"']{6,}|secret\s*=\s*["'"'"'][^"'"'"']{6,}|api_key\s*=\s*["'"'"'][^"'"'"']{4,})'
  if grep -rEn "$PATTERNS" app/ --include="*.py" 2>/dev/null; then
    err "Possible hardcoded credential in backend source"
  else
    ok "No hardcoded secrets detected"
  fi
)

# ── FRONTEND TYPE-CHECK & LINT ────────────────────────────────────────────────
step "Frontend — TypeScript type-check"
(
  cd "$REPO_ROOT/frontend"
  if npx tsc --noEmit 2>&1; then
    ok "TypeScript: no type errors"
  else
    err "TypeScript type errors found"
  fi
)

step "Frontend — oxlint"
(
  cd "$REPO_ROOT/frontend"
  if npm run lint 2>&1; then
    ok "oxlint: no lint errors"
  else
    err "Lint errors found"
  fi
)

# ── FRONTEND SECURITY ─────────────────────────────────────────────────────────
step "Frontend — npm audit"
(
  cd "$REPO_ROOT/frontend"
  if npm audit --audit-level=moderate 2>&1; then
    ok "npm audit: no moderate+ vulnerabilities"
  else
    err "npm audit found vulnerabilities"
  fi
)

step "Frontend — Privacy / hardcoded credentials scan"
(
  cd "$REPO_ROOT/frontend"
  PATTERNS='(api_key|apikey|secret|password|token)\s*[:=]\s*["'"'"'][A-Za-z0-9+/\-_]{8,}'
  if grep -rEin "$PATTERNS" src/ --include="*.ts" --include="*.tsx" 2>/dev/null; then
    err "Possible hardcoded credential in frontend source"
  else
    ok "No hardcoded credentials detected"
  fi
)

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════"
if [[ ${#errors[@]} -eq 0 ]]; then
  echo "  ALL CHECKS PASSED — safe to push"
  echo "═══════════════════════════════════════════"
  exit $PASS
else
  echo "  FAILED CHECKS:"
  for e in "${errors[@]}"; do
    echo "    • $e"
  done
  echo "═══════════════════════════════════════════"
  echo "  Fix the issues above before pushing."
  exit $FAIL
fi
