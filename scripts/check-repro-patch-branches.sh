#!/usr/bin/env bash
#
# Ensure public repro patches are committed to the repro branches that
# Codespaces actually opens.
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE=origin
FETCH_REFS=true

usage() {
  cat <<EOF
check-repro-patch-branches.sh - verify repro patches exist on repro branches

USAGE:
    ./scripts/check-repro-patch-branches.sh [OPTIONS]

OPTIONS:
    --remote NAME   Git remote to inspect (default: ${REMOTE})
    --no-fetch      Do not fetch repro branch refs before checking
    -h, --help      Show this help.

WHAT IT VALIDATES:
    Every tracked repro-patches/<REPRO_ID>.patch in this checkout exists at the
    same path on ${REMOTE}/repro/<REPRO_ID> and has identical content. A patch
    that exists only on main will not be visible when a user opens the repro
    branch from the Codespaces web UI.
EOF
}

log() { echo -e "${CYAN}[patch-branches]${NC} $*"; }
fail() {
  echo -e "${RED}patch branch check failed:${NC} $*" >&2
  exit 1
}
pass() { echo -e "${GREEN}$*${NC}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE="$2"
      shift 2
      ;;
    --no-fetch)
      FETCH_REFS=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

cd "$REPO_ROOT"

if [[ "$FETCH_REFS" == true ]]; then
  log "Fetching ${REMOTE}/repro/* refs"
  git fetch "$REMOTE" '+refs/heads/repro/*:refs/remotes/'"$REMOTE"'/repro/*' >/dev/null
fi

mapfile -t patch_paths < <(git ls-files 'repro-patches/*.patch' | sort)
if [[ ${#patch_paths[@]} -eq 0 ]]; then
  pass "no repro patches tracked"
  exit 0
fi

checked=0
failed=0

for patch_path in "${patch_paths[@]}"; do
  repro_id="${patch_path#repro-patches/}"
  repro_id="${repro_id%.patch}"
  branch_ref="${REMOTE}/repro/${repro_id}"

  checked=$((checked + 1))

  if ! git show-ref --verify --quiet "refs/remotes/${branch_ref}"; then
    echo "MISSING_BRANCH ${repro_id}: ${branch_ref}"
    failed=$((failed + 1))
    continue
  fi

  if ! git cat-file -e "${branch_ref}:${patch_path}" 2>/dev/null; then
    echo "MISSING_PATCH ${repro_id}: ${patch_path} is absent from ${branch_ref}"
    failed=$((failed + 1))
    continue
  fi

  if ! git diff --quiet "HEAD:${patch_path}" "${branch_ref}:${patch_path}"; then
    echo "DRIFT ${repro_id}: ${patch_path} differs between HEAD and ${branch_ref}"
    failed=$((failed + 1))
    continue
  fi

  echo "MATCH ${repro_id}"
done

if [[ "$failed" -gt 0 ]]; then
  fail "${failed}/${checked} repro patch branch checks failed"
fi

echo -e "${BOLD}${GREEN}repro patch branch check passed (${checked} checked)${NC}"
