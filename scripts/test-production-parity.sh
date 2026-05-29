#!/usr/bin/env bash
#
# Verify that pruva production execution, Codespaces, and optional Modal smoke
# all use the same pinned pruva-sandbox image contract.
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_PRUVA_REPO="$(cd "$SANDBOX_REPO/.." 2>/dev/null && pwd)/pruva"

PRUVA_REPO="${PRUVA_REPO:-$DEFAULT_PRUVA_REPO}"
PRUVA_REF="${PRUVA_REF:-origin/main}"
API_URL="${PRUVA_API_URL:-https://api.pruva.dev/v1}"
LATEST="${LATEST:-20}"
SANDBOX_IMAGE_OVERRIDE="${PRUVA_SANDBOX_IMAGE:-}"
MODAL_REPRO_IDS="${MODAL_REPRO_IDS:-REPRO-2026-00185}"
RUN_CODESPACES=true
RUN_MODAL=auto
RUN_MANIFEST=true
FETCH_PRUVA=false
PYTHON_BIN="${PYTHON:-python3}"

WORKTREE_DIR=""
CHECK_PRUVA_REPO=""

usage() {
  cat <<EOF
test-production-parity.sh - Verify pruva/pruva-sandbox production parity

USAGE:
    ./scripts/test-production-parity.sh [OPTIONS]

OPTIONS:
    --pruva-repo PATH       Path to the pruva repo (default: ../pruva)
    --pruva-ref REF         pruva ref to check in a temporary worktree (default: origin/main)
    --fetch-pruva           Fetch the pruva repo before checking PRUVA_REF
    --latest N              Latest published reproductions for Codespaces readiness (default: 20)
    --api-url URL           Pruva API base URL (default: https://api.pruva.dev/v1)
    --sandbox-image IMAGE   Override the sandbox image used for Codespaces/Modal checks
    --skip-codespaces       Skip latest-N Codespaces readiness
    --skip-manifest         Skip registry manifest resolution for the pinned image
    --skip-modal            Skip Modal smoke
    --require-modal         Fail if Modal credentials are absent, then run Modal smoke
    --modal-repro-ids IDS   Comma-separated Modal smoke repro IDs (default: REPRO-2026-00185)
    -h, --help              Show this help

ENVIRONMENT:
    MODAL_TOKEN_ID and MODAL_TOKEN_SECRET are required only when Modal runs.
    PRUVA_SANDBOX_IMAGE can also be used instead of --sandbox-image.

WHAT IT VALIDATES:
    1. pruva worker/docker image pinning through make sandbox-image-check
    2. optional GHCR manifest resolution for the pinned sandbox digest
    3. pruva-sandbox latest-N Codespaces readiness against the same digest
    4. optional Modal pruva-verify smoke against the same digest
EOF
}

log() { echo -e "${CYAN}[parity]${NC} $*"; }
pass() { echo -e "${GREEN}  OK${NC} $*"; }
warn() { echo -e "${YELLOW}  WARN${NC} $*"; }
fail() {
  echo -e "${RED}  FAIL${NC} $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$WORKTREE_DIR" && -d "$WORKTREE_DIR" ]]; then
    git -C "$PRUVA_REPO" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pruva-repo)
      PRUVA_REPO="$2"
      shift 2
      ;;
    --pruva-ref)
      PRUVA_REF="$2"
      shift 2
      ;;
    --fetch-pruva)
      FETCH_PRUVA=true
      shift
      ;;
    --latest)
      LATEST="$2"
      shift 2
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --sandbox-image)
      SANDBOX_IMAGE_OVERRIDE="$2"
      shift 2
      ;;
    --skip-codespaces)
      RUN_CODESPACES=false
      shift
      ;;
    --skip-manifest)
      RUN_MANIFEST=false
      shift
      ;;
    --skip-modal)
      RUN_MODAL=skip
      shift
      ;;
    --require-modal)
      RUN_MODAL=require
      shift
      ;;
    --modal-repro-ids)
      MODAL_REPRO_IDS="$2"
      shift 2
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

git -C "$PRUVA_REPO" rev-parse --git-dir >/dev/null 2>&1 || fail "pruva repo not found: $PRUVA_REPO"
[[ "$LATEST" =~ ^[0-9]+$ ]] || fail "--latest must be numeric"

if [[ "$FETCH_PRUVA" == true ]]; then
  log "Fetching pruva repo"
  git -C "$PRUVA_REPO" fetch origin
fi

if [[ -n "$PRUVA_REF" ]]; then
  tmp_parent="${TMPDIR:-/tmp}"
  WORKTREE_DIR="$(mktemp -d "${tmp_parent%/}/pruva-prod-parity.XXXXXX")"
  rmdir "$WORKTREE_DIR"
  log "Checking pruva ref $PRUVA_REF in temporary worktree"
  git -C "$PRUVA_REPO" worktree add --detach "$WORKTREE_DIR" "$PRUVA_REF" >/dev/null
  CHECK_PRUVA_REPO="$WORKTREE_DIR"
else
  log "Checking pruva working tree at $PRUVA_REPO"
  CHECK_PRUVA_REPO="$PRUVA_REPO"
fi

PRUVA_RS="$CHECK_PRUVA_REPO/pruva-rs"
[[ -d "$PRUVA_RS" ]] || fail "missing pruva-rs directory in checked pruva repo"

log "Running pruva sandbox image pinning check"
make -C "$PRUVA_RS" sandbox-image-check
pass "pruva image pinning contract passed"

if [[ "$RUN_MANIFEST" == true ]]; then
  log "Checking pinned sandbox image resolves from registry"
  CHECK_SANDBOX_IMAGE_MANIFEST=1 make -C "$PRUVA_RS" sandbox-image-check
  pass "pinned sandbox image manifest resolves"
fi

SANDBOX_IMAGE="$SANDBOX_IMAGE_OVERRIDE"
if [[ -z "$SANDBOX_IMAGE" ]]; then
  SANDBOX_IMAGE="$(
    sed -nE 's#^ARG PRUVA_SANDBOX_IMAGE=(ghcr\.io/n3mes1s/pruva-sandbox@sha256:[0-9a-f]{64})$#\1#p' \
      "$PRUVA_RS/Dockerfile" | head -n1
  )"
fi
[[ -n "$SANDBOX_IMAGE" ]] || fail "could not resolve pinned sandbox image from pruva Dockerfile"

log "Using sandbox image: $SANDBOX_IMAGE"

if [[ "$RUN_CODESPACES" == true ]]; then
  log "Running pruva-sandbox latest-$LATEST Codespaces readiness"
  PRUVA_API_URL="$API_URL" PRUVA_SANDBOX_IMAGE="$SANDBOX_IMAGE" \
    "$SANDBOX_REPO/scripts/test-codespaces.sh" --latest "$LATEST" --api-url "$API_URL"
  pass "latest-$LATEST Codespaces readiness passed"
else
  warn "Skipped Codespaces readiness"
fi

modal_id_state=missing
modal_secret_state=missing
[[ -n "${MODAL_TOKEN_ID:-}" ]] && modal_id_state=set
[[ -n "${MODAL_TOKEN_SECRET:-}" ]] && modal_secret_state=set
log "Modal credentials: MODAL_TOKEN_ID=$modal_id_state MODAL_TOKEN_SECRET=$modal_secret_state"

if [[ "$RUN_MODAL" == skip ]]; then
  warn "Skipped Modal smoke"
elif [[ "$modal_id_state" != set || "$modal_secret_state" != set ]]; then
  if [[ "$RUN_MODAL" == require ]]; then
    fail "Modal credentials are required but not exported"
  fi
  warn "Modal credentials missing; skipping Modal smoke"
else
  if ! "$PYTHON_BIN" -c 'import modal' >/dev/null 2>&1; then
    fail "Python package 'modal' is not installed for $PYTHON_BIN"
  fi

  log "Running Modal smoke for $MODAL_REPRO_IDS"
  PRUVA_API_URL="$API_URL" PRUVA_SANDBOX_IMAGE="$SANDBOX_IMAGE" \
    "$PYTHON_BIN" "$SANDBOX_REPO/scripts/test_codespaces_modal.py" \
      --repro-ids "$MODAL_REPRO_IDS" \
      --sandbox-image "$SANDBOX_IMAGE"
  pass "Modal smoke passed"
fi

echo
echo -e "${GREEN}${BOLD}Production parity checks completed.${NC}"
