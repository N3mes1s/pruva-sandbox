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
MODAL_CACHE_VOLUME="${PRUVA_MODAL_CACHE_VOLUME:-}"
RUN_CODESPACES=true
RUN_REAL_CODESPACES=false
CODESPACES_MODE="${CODESPACES_MODE:-verify}"
CODESPACES_MAX_PARALLEL="${CODESPACES_MAX_PARALLEL:-3}"
CODESPACES_READINESS_MAX_PARALLEL_EXPLICIT=false
[[ -n "${CODESPACES_READINESS_MAX_PARALLEL:-}" ]] && CODESPACES_READINESS_MAX_PARALLEL_EXPLICIT=true
CODESPACES_READINESS_MAX_PARALLEL="${CODESPACES_READINESS_MAX_PARALLEL:-$CODESPACES_MAX_PARALLEL}"
RUN_MODAL=auto
RUN_MANIFEST=true
RUN_ROLLOUT_PROOF=true
ROLLOUT_PROOF_MIN_MATCHING="${PRUVA_ROLLOUT_PROOF_MIN_MATCHING:-1}"
ROLLOUT_PROOF_MAX_PARALLEL="${PRUVA_ROLLOUT_PROOF_MAX_PARALLEL:-8}"
ROLLOUT_PROOF_REPRO_IDS="${PRUVA_ROLLOUT_PROOF_REPRO_IDS:-}"
FETCH_PRUVA=false
PYTHON_CMD=()

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
    --real-codespaces       Also create real Codespaces and check the startup path
    --codespaces-mode MODE  Real Codespaces mode: available or verify (default: ${CODESPACES_MODE})
    --codespaces-max-parallel N
                           Max concurrent real Codespaces (default: ${CODESPACES_MAX_PARALLEL})
    --readiness-max-parallel N
                           Max concurrent structural Codespaces readiness checks
                           (default: ${CODESPACES_READINESS_MAX_PARALLEL})
    --skip-manifest         Skip registry manifest resolution for the pinned image
    --skip-rollout-proof    Skip production API environment.sandbox_image proof
    --rollout-proof-repro-ids IDS
                           Comma-separated post-deploy repro IDs to inspect for
                           environment.sandbox_image. Defaults to latest-N.
    --rollout-proof-min-matching N
                           Required matching production API records (default: ${ROLLOUT_PROOF_MIN_MATCHING})
    --rollout-proof-max-parallel N
                           Max concurrent production API detail checks
                           (default: ${ROLLOUT_PROOF_MAX_PARALLEL})
    --skip-modal            Skip Modal smoke
    --require-modal         Fail if Modal credentials are absent, then run Modal smoke
    --modal-repro-ids IDS   Comma-separated Modal smoke repro IDs (default: REPRO-2026-00185)
    --modal-cache-volume NAME
                           Modal Volume name for per-repro setup caches
    -h, --help              Show this help

ENVIRONMENT:
    MODAL_TOKEN_ID and MODAL_TOKEN_SECRET are required only when Modal runs.
    PRUVA_SANDBOX_IMAGE can also be used instead of --sandbox-image.
    PRUVA_ROLLOUT_PROOF_REPRO_IDS can provide post-deploy repro IDs.
    PRUVA_ROLLOUT_PROOF_MIN_MATCHING can configure required API proof count.
    PRUVA_API_TOKEN can provide admin access for active worker sandbox-image
    proof through /v1/workers when reproduction records have not rolled yet.
    CODESPACES_MODE, CODESPACES_MAX_PARALLEL, and
    CODESPACES_READINESS_MAX_PARALLEL can configure Codespaces defaults.
    PRUVA_ROLLOUT_PROOF_MAX_PARALLEL can configure rollout proof concurrency.
    PRUVA_MODAL_CACHE_VOLUME can also be used instead of --modal-cache-volume.
    PYTHON can override the Python interpreter used for Modal. By default the
    script prefers .venv/bin/python, then uv run python, then python3.

WHAT IT VALIDATES:
    1. public/private repository boundary for tracked sandbox files
    2. pruva worker/docker image pinning through make sandbox-image-check
    3. optional GHCR manifest resolution for the pinned sandbox digest
    4. production API rollout proof for environment.sandbox_image
    5. pruva-sandbox latest-N Codespaces readiness against the same digest
    6. optional real Codespaces startup verification for latest-N repros
    7. optional Modal pruva-verify smoke against the same digest using the image binary
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
    --real-codespaces)
      RUN_REAL_CODESPACES=true
      shift
      ;;
    --codespaces-mode)
      CODESPACES_MODE="$2"
      shift 2
      ;;
    --codespaces-max-parallel)
      CODESPACES_MAX_PARALLEL="$2"
      shift 2
      ;;
    --readiness-max-parallel)
      CODESPACES_READINESS_MAX_PARALLEL="$2"
      CODESPACES_READINESS_MAX_PARALLEL_EXPLICIT=true
      shift 2
      ;;
    --skip-manifest)
      RUN_MANIFEST=false
      shift
      ;;
    --skip-rollout-proof)
      RUN_ROLLOUT_PROOF=false
      shift
      ;;
    --rollout-proof-repro-ids)
      ROLLOUT_PROOF_REPRO_IDS="$2"
      shift 2
      ;;
    --rollout-proof-min-matching)
      ROLLOUT_PROOF_MIN_MATCHING="$2"
      shift 2
      ;;
    --rollout-proof-max-parallel)
      ROLLOUT_PROOF_MAX_PARALLEL="$2"
      shift 2
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
    --modal-cache-volume)
      MODAL_CACHE_VOLUME="$2"
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
if [[ "$CODESPACES_READINESS_MAX_PARALLEL_EXPLICIT" != true ]]; then
  CODESPACES_READINESS_MAX_PARALLEL="$CODESPACES_MAX_PARALLEL"
fi
[[ "$LATEST" =~ ^[0-9]+$ ]] || fail "--latest must be numeric"
[[ "$ROLLOUT_PROOF_MIN_MATCHING" =~ ^[0-9]+$ && "$ROLLOUT_PROOF_MIN_MATCHING" -ge 1 ]] || fail "--rollout-proof-min-matching must be a positive integer"
[[ "$ROLLOUT_PROOF_MAX_PARALLEL" =~ ^[0-9]+$ && "$ROLLOUT_PROOF_MAX_PARALLEL" -ge 1 ]] || fail "--rollout-proof-max-parallel must be a positive integer"
case "$CODESPACES_MODE" in
  available|verify) ;;
  *) fail "--codespaces-mode must be 'available' or 'verify'" ;;
esac
[[ "$CODESPACES_MAX_PARALLEL" =~ ^[0-9]+$ && "$CODESPACES_MAX_PARALLEL" -ge 1 ]] || fail "--codespaces-max-parallel must be a positive integer"
[[ "$CODESPACES_READINESS_MAX_PARALLEL" =~ ^[0-9]+$ && "$CODESPACES_READINESS_MAX_PARALLEL" -ge 1 ]] || fail "--readiness-max-parallel must be a positive integer"

if [[ -n "${PYTHON:-}" ]]; then
  PYTHON_CMD=("$PYTHON")
elif [[ -x "$SANDBOX_REPO/.venv/bin/python" ]]; then
  PYTHON_CMD=("$SANDBOX_REPO/.venv/bin/python")
elif command -v uv >/dev/null 2>&1; then
  PYTHON_CMD=(uv run python)
else
  PYTHON_CMD=(python3)
fi

if [[ "$FETCH_PRUVA" == true ]]; then
  log "Fetching pruva repo"
  git -C "$PRUVA_REPO" fetch origin
fi

log "Checking public sandbox boundary"
"$SANDBOX_REPO/scripts/check-public-boundary.sh"
pass "public sandbox boundary passed"

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

if [[ "$RUN_ROLLOUT_PROOF" == true ]]; then
  log "Checking production API rollout proof"
  rollout_args=(
    --api-url "$API_URL"
    --sandbox-image "$SANDBOX_IMAGE"
    --latest "$LATEST"
    --min-matching "$ROLLOUT_PROOF_MIN_MATCHING"
    --max-parallel "$ROLLOUT_PROOF_MAX_PARALLEL"
  )
  if [[ -n "$ROLLOUT_PROOF_REPRO_IDS" ]]; then
    rollout_args+=(--repro-ids "$ROLLOUT_PROOF_REPRO_IDS")
  fi
  "$SANDBOX_REPO/scripts/check-production-rollout-proof.sh" "${rollout_args[@]}"
  pass "production API rollout proof passed"
else
  warn "Skipped production API rollout proof"
fi

if [[ "$RUN_CODESPACES" == true ]]; then
  log "Running pruva-sandbox latest-$LATEST Codespaces readiness"
  PRUVA_API_URL="$API_URL" PRUVA_SANDBOX_IMAGE="$SANDBOX_IMAGE" \
    "$SANDBOX_REPO/scripts/test-codespaces.sh" \
      --latest "$LATEST" \
      --api-url "$API_URL" \
      --max-parallel "$CODESPACES_READINESS_MAX_PARALLEL"
  pass "latest-$LATEST Codespaces readiness passed"
else
  warn "Skipped Codespaces readiness"
fi

if [[ "$RUN_REAL_CODESPACES" == true ]]; then
  log "Running real Codespaces latest-$LATEST mode=$CODESPACES_MODE max_parallel=$CODESPACES_MAX_PARALLEL"
  PRUVA_API_URL="$API_URL" \
    "$SANDBOX_REPO/scripts/test-codespaces-gh.sh" \
      --latest "$LATEST" \
      --api-url "$API_URL" \
      --mode "$CODESPACES_MODE" \
      --max-parallel "$CODESPACES_MAX_PARALLEL"
  pass "latest-$LATEST real Codespaces check passed"
else
  warn "Skipped real Codespaces startup verification"
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
  if ! "${PYTHON_CMD[@]}" -c 'import modal' >/dev/null 2>&1; then
    fail "Python package 'modal' is not installed for ${PYTHON_CMD[*]}"
  fi

  log "Running Modal smoke for $MODAL_REPRO_IDS"
  log "Using Python for Modal: ${PYTHON_CMD[*]}"
  modal_args=(--repro-ids "$MODAL_REPRO_IDS" --sandbox-image "$SANDBOX_IMAGE")
  if [[ -n "$MODAL_CACHE_VOLUME" ]]; then
    log "Using Modal cache volume: $MODAL_CACHE_VOLUME"
    modal_args+=(--cache-volume "$MODAL_CACHE_VOLUME")
  fi
  PRUVA_API_URL="$API_URL" PRUVA_SANDBOX_IMAGE="$SANDBOX_IMAGE" \
    "${PYTHON_CMD[@]}" "$SANDBOX_REPO/scripts/test_codespaces_modal.py" \
      "${modal_args[@]}"
  pass "Modal smoke passed"
fi

echo
echo -e "${GREEN}${BOLD}Production parity checks completed.${NC}"
