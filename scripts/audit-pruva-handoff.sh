#!/usr/bin/env bash
#
# Audit whether a local private pruva checkout is ready to publish reproductions
# into this public pruva-sandbox Codespaces runtime.
#
# This script is intentionally read-only for the private repo. It reports whether
# the operator checkout at ~/code/pruva is clean, up to date with the expected
# ref, and contains the publish/image wiring required by docs/PRODUCTION.md.
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_PRUVA_REPO="$(cd "$SANDBOX_REPO/.." 2>/dev/null && pwd)/pruva"

PRUVA_REPO="${PRUVA_REPO:-$DEFAULT_PRUVA_REPO}"
PRUVA_REF="${PRUVA_REF:-origin/main}"
FETCH=false

failures=0
warnings=0

usage() {
  cat <<EOF
audit-pruva-handoff.sh - Check private pruva -> public pruva-sandbox readiness

USAGE:
    ./scripts/audit-pruva-handoff.sh [OPTIONS]

OPTIONS:
    --pruva-repo PATH   Private pruva checkout path (default: ../pruva)
    --ref REF           Required private pruva ref (default: origin/main)
    --fetch             Fetch the private pruva repo before auditing
    -h, --help          Show this help

WHAT IT CHECKS:
    1. public pruva-sandbox boundary scanner passes
    2. private required ref has the production sandbox image/publish contract
    3. local private checkout is clean and contains the required ref
    4. local private checkout has the same production handoff wiring
EOF
}

log() { echo -e "${BOLD}$*${NC}"; }
pass() { echo -e "${GREEN}  OK${NC} $*"; }
warn() {
  warnings=$((warnings + 1))
  echo -e "${YELLOW}  WARN${NC} $*" >&2
}
fail() {
  failures=$((failures + 1))
  echo -e "${RED}  FAIL${NC} $*" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pruva-repo)
      PRUVA_REPO="$2"
      shift 2
      ;;
    --ref)
      PRUVA_REF="$2"
      shift 2
      ;;
    --fetch)
      FETCH=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_git_repo() {
  local repo="$1"
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    fail "not a git repository: $repo"
    return 1
  fi
}

file_contains() {
  local label="$1"
  local path="$2"
  local regex="$3"
  if [[ ! -f "$path" ]]; then
    fail "$label: missing $path"
    return
  fi
  if grep -Eq "$regex" "$path"; then
    pass "$label"
  else
    fail "$label"
  fi
}

file_not_contains() {
  local label="$1"
  local path="$2"
  local regex="$3"
  if [[ ! -f "$path" ]]; then
    fail "$label: missing $path"
    return
  fi
  if grep -Eq "$regex" "$path"; then
    fail "$label"
  else
    pass "$label"
  fi
}

ref_contains() {
  local label="$1"
  local ref="$2"
  local path="$3"
  local regex="$4"
  local content
  if ! git -C "$PRUVA_REPO" cat-file -e "${ref}:${path}" 2>/dev/null; then
    fail "$label: missing ${ref}:${path}"
    return
  fi
  content="$(git -C "$PRUVA_REPO" show "${ref}:${path}")"
  if grep -Eq "$regex" <<<"$content"; then
    pass "$label"
  else
    fail "$label"
  fi
}

ref_not_contains() {
  local label="$1"
  local ref="$2"
  local path="$3"
  local regex="$4"
  local content
  if ! git -C "$PRUVA_REPO" cat-file -e "${ref}:${path}" 2>/dev/null; then
    fail "$label: missing ${ref}:${path}"
    return
  fi
  content="$(git -C "$PRUVA_REPO" show "${ref}:${path}")"
  if grep -Eq "$regex" <<<"$content"; then
    fail "$label"
  else
    pass "$label"
  fi
}

check_pruva_contract_in_ref() {
  local ref="$1"
  log "Checking private pruva required ref: $ref"
  if ! git -C "$PRUVA_REPO" rev-parse --verify "$ref" >/dev/null 2>&1; then
    fail "cannot resolve required ref: $ref"
    return
  fi

  ref_contains "ref pins public sandbox image by digest" "$ref" \
    "pruva-rs/Dockerfile" \
    '^ARG PRUVA_SANDBOX_IMAGE=ghcr\.io/n3mes1s/pruva-sandbox@sha256:[0-9a-f]{64}$'
  ref_contains "ref has sandbox image pinning make target" "$ref" \
    "pruva-rs/Makefile" \
    '^sandbox-image-check:'
  ref_contains "ref has sandbox image pinning script" "$ref" \
    "pruva-rs/scripts/check-sandbox-image-pinning.sh" \
    'sandbox image pinning check passed'
  ref_contains "ref publish command accepts PRUVA_SANDBOX_IMAGE" "$ref" \
    "pruva-rs/crates/pruva-cli/src/commands/publish.rs" \
    'env = "PRUVA_SANDBOX_IMAGE"'
  ref_contains "ref publish stamps sandbox image into Codespaces branch" "$ref" \
    "pruva-rs/crates/pruva-cli/src/commands/publish.rs" \
    'update_sandbox_devcontainer'
  ref_contains "ref publish passes sandbox image to branch creation" "$ref" \
    "pruva-rs/crates/pruva-cli/src/commands/publish.rs" \
    'args\.sandbox_image\.as_deref\(\)'
  ref_contains "ref process command uses PRUVA_SANDBOX_IMAGE for docker backend" "$ref" \
    "pruva-rs/crates/pruva-cli/src/commands/process.rs" \
    'env = "PRUVA_SANDBOX_IMAGE"'
  ref_not_contains "ref process command does not default to pruva-sandbox:latest" "$ref" \
    "pruva-rs/crates/pruva-cli/src/commands/process.rs" \
    'pruva-sandbox:latest'
}

check_pruva_contract_in_worktree() {
  local root="$1"
  log "Checking local private pruva working tree"
  file_contains "local pins public sandbox image by digest" \
    "$root/pruva-rs/Dockerfile" \
    '^ARG PRUVA_SANDBOX_IMAGE=ghcr\.io/n3mes1s/pruva-sandbox@sha256:[0-9a-f]{64}$'
  file_contains "local has sandbox image pinning make target" \
    "$root/pruva-rs/Makefile" \
    '^sandbox-image-check:'
  file_contains "local has sandbox image pinning script" \
    "$root/pruva-rs/scripts/check-sandbox-image-pinning.sh" \
    'sandbox image pinning check passed'
  file_contains "local publish command accepts PRUVA_SANDBOX_IMAGE" \
    "$root/pruva-rs/crates/pruva-cli/src/commands/publish.rs" \
    'env = "PRUVA_SANDBOX_IMAGE"'
  file_contains "local publish stamps sandbox image into Codespaces branch" \
    "$root/pruva-rs/crates/pruva-cli/src/commands/publish.rs" \
    'update_sandbox_devcontainer'
  file_contains "local publish passes sandbox image to branch creation" \
    "$root/pruva-rs/crates/pruva-cli/src/commands/publish.rs" \
    'args\.sandbox_image\.as_deref\(\)'
  file_contains "local process command uses PRUVA_SANDBOX_IMAGE for docker backend" \
    "$root/pruva-rs/crates/pruva-cli/src/commands/process.rs" \
    'env = "PRUVA_SANDBOX_IMAGE"'
  file_not_contains "local process command does not default to pruva-sandbox:latest" \
    "$root/pruva-rs/crates/pruva-cli/src/commands/process.rs" \
    'pruva-sandbox:latest'
}

log "Checking public pruva-sandbox runtime"
"$SANDBOX_REPO/scripts/check-public-boundary.sh"
pass "public boundary scanner passed"

require_git_repo "$PRUVA_REPO" || true

if [[ "$FETCH" == true ]]; then
  log "Fetching private pruva repo"
  if git -C "$PRUVA_REPO" fetch origin; then
    pass "fetched private pruva repo"
  else
    fail "failed to fetch private pruva repo"
  fi
fi

check_pruva_contract_in_ref "$PRUVA_REF"

log "Checking local private pruva checkout state"
status_line=$(git -C "$PRUVA_REPO" status --short --branch | sed -n '1p')
echo "  $status_line"

if [[ -n "$(git -C "$PRUVA_REPO" status --porcelain)" ]]; then
  fail "local pruva working tree has uncommitted changes; do not use it as a production operator path until reconciled"
else
  pass "local pruva working tree is clean"
fi

if git -C "$PRUVA_REPO" merge-base --is-ancestor "$PRUVA_REF" HEAD; then
  pass "local pruva HEAD contains $PRUVA_REF"
else
  fail "local pruva HEAD does not contain $PRUVA_REF; update/rebase before production use"
fi

check_pruva_contract_in_worktree "$PRUVA_REPO"

echo
if [[ "$failures" -gt 0 ]]; then
  echo -e "${RED}${BOLD}Pruva handoff audit failed:${NC} ${failures} failure(s), ${warnings} warning(s)"
  exit 1
fi

if [[ "$warnings" -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}Pruva handoff audit passed with warnings:${NC} ${warnings} warning(s)"
else
  echo -e "${GREEN}${BOLD}Pruva handoff audit passed.${NC}"
fi
