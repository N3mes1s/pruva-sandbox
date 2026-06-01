#!/usr/bin/env bash
#
# Check that production API metadata proves at least one post-deploy
# reproduction was created with the promoted immutable pruva-sandbox image.
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

API_URL="${PRUVA_API_URL:-https://api.pruva.dev/v1}"
SANDBOX_IMAGE="${PRUVA_SANDBOX_IMAGE:-}"
LATEST=20
MIN_MATCHING=1
REQUIRE_ALL=false
REPRO_IDS=()

usage() {
  cat <<EOF
check-production-rollout-proof.sh - Verify production API sandbox image evidence

USAGE:
    ./scripts/check-production-rollout-proof.sh --sandbox-image IMAGE [OPTIONS]

OPTIONS:
    --sandbox-image IMAGE   Required immutable pruva-sandbox image digest.
    --api-url URL           Pruva API base URL (default: ${API_URL})
    --latest N              Inspect latest N published reproductions when no
                             explicit repro IDs are supplied (default: ${LATEST})
    --repro-id ID           Inspect one reproduction ID. Can be repeated.
    --repro-ids LIST        Comma-separated reproduction IDs.
    --min-matching N        Required records with matching environment.sandbox_image
                             (default: ${MIN_MATCHING})
    --require-all           Require every inspected record to expose the exact image.
    -h, --help              Show this help.

WHAT IT VALIDATES:
    The production API exposes reproduction detail environment.sandbox_image for
    at least one post-deploy record, and that value matches the promoted digest.
EOF
}

log() { echo -e "${CYAN}[rollout-proof]${NC} $*"; }
pass() { echo -e "${GREEN}  OK${NC} $*"; }
warn() { echo -e "${YELLOW}  WARN${NC} $*"; }
fail() {
  echo -e "${RED}  FAIL${NC} $*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

fetch_latest_repro_ids() {
  local count="$1"
  local tmp http_code
  tmp=$(mktemp)
  http_code=$(curl -sf -w "%{http_code}" -o "$tmp" "${API_URL}/reproductions?status=published&limit=${count}" 2>/dev/null) || http_code="000"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp"
    fail "Failed to fetch latest reproductions from API (HTTP ${http_code})"
  fi
  jq -r '.reproductions[]?.repro_id // empty' "$tmp"
  rm -f "$tmp"
}

fetch_repro_environment_image() {
  local repro_id="$1"
  local tmp http_code
  tmp=$(mktemp)
  http_code=$(curl -sf -w "%{http_code}" -o "$tmp" "${API_URL}/reproductions/${repro_id}" 2>/dev/null) || http_code="000"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp"
    printf 'ERROR:HTTP_%s\n' "$http_code"
    return
  fi
  jq -r '.environment.sandbox_image // empty' "$tmp"
  rm -f "$tmp"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox-image)
      SANDBOX_IMAGE="$2"
      shift 2
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --latest)
      LATEST="$2"
      shift 2
      ;;
    --repro-id)
      REPRO_IDS+=("$2")
      shift 2
      ;;
    --repro-ids)
      IFS=',' read -r -a parsed_ids <<< "$2"
      for id in "${parsed_ids[@]}"; do
        [[ -n "$id" ]] && REPRO_IDS+=("$id")
      done
      shift 2
      ;;
    --min-matching)
      MIN_MATCHING="$2"
      shift 2
      ;;
    --require-all)
      REQUIRE_ALL=true
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

require_command curl
require_command jq

[[ -n "$SANDBOX_IMAGE" ]] || fail "--sandbox-image is required"
[[ "$SANDBOX_IMAGE" =~ ^ghcr\.io/n3mes1s/pruva-sandbox@sha256:[0-9a-f]{64}$ ]] \
  || fail "--sandbox-image must be an immutable pruva-sandbox digest"
[[ "$LATEST" =~ ^[0-9]+$ && "$LATEST" -ge 1 ]] || fail "--latest must be a positive integer"
[[ "$MIN_MATCHING" =~ ^[0-9]+$ && "$MIN_MATCHING" -ge 1 ]] || fail "--min-matching must be a positive integer"

if [[ ${#REPRO_IDS[@]} -eq 0 ]]; then
  while IFS= read -r repro_id; do
    [[ -n "$repro_id" ]] && REPRO_IDS+=("$repro_id")
  done < <(fetch_latest_repro_ids "$LATEST")
fi
[[ ${#REPRO_IDS[@]} -gt 0 ]] || fail "no reproduction IDs to inspect"

log "API: $API_URL"
log "Expected sandbox image: $SANDBOX_IMAGE"
log "Inspecting ${#REPRO_IDS[@]} reproduction(s)"

matching=0
missing=0
mismatched=0
fetch_failed=0

for repro_id in "${REPRO_IDS[@]}"; do
  image=$(fetch_repro_environment_image "$repro_id")
  if [[ "$image" == ERROR:* ]]; then
    warn "$repro_id metadata fetch failed (${image#ERROR:})"
    fetch_failed=$((fetch_failed + 1))
  elif [[ -z "$image" ]]; then
    warn "$repro_id has no environment.sandbox_image"
    missing=$((missing + 1))
  elif [[ "$image" == "$SANDBOX_IMAGE" ]]; then
    pass "$repro_id environment.sandbox_image matches"
    matching=$((matching + 1))
  else
    warn "$repro_id uses different sandbox image: $image"
    mismatched=$((mismatched + 1))
  fi
done

log "Summary: ${matching} matching, ${missing} missing, ${mismatched} different, ${fetch_failed} fetch failed"

if [[ "$matching" -lt "$MIN_MATCHING" ]]; then
  fail "Need at least ${MIN_MATCHING} production reproduction(s) with matching environment.sandbox_image"
fi

if [[ "$REQUIRE_ALL" == true && "$matching" -ne "${#REPRO_IDS[@]}" ]]; then
  fail "--require-all set but not every inspected record exposes the promoted image"
fi

pass "production API rollout proof passed"
