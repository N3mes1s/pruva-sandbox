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
API_TOKEN="${PRUVA_API_TOKEN:-}"
API_TOKEN_HEADER="${PRUVA_API_TOKEN_HEADER:-auto}"
LATEST=20
MIN_MATCHING=1
MAX_PARALLEL="${PRUVA_ROLLOUT_PROOF_MAX_PARALLEL:-8}"
REQUIRE_ALL=false
REQUIRE_WORKER_PROOF=false
REPRO_IDS=()

usage() {
  cat <<EOF
check-production-rollout-proof.sh - Verify production API sandbox image evidence

USAGE:
    ./scripts/check-production-rollout-proof.sh --sandbox-image IMAGE [OPTIONS]

OPTIONS:
    --sandbox-image IMAGE   Required immutable pruva-sandbox image digest.
    --api-url URL           Pruva API base URL (default: ${API_URL})
    --api-token TOKEN       Optional admin API token. When supplied, active
                             /v1/workers records are also inspected for
                             capabilities.sandbox_image.
    --api-token-header MODE Header for --api-token: auto, x-api-key, or
                             authorization (default: ${API_TOKEN_HEADER})
    --latest N              Inspect latest N published reproductions when no
                             explicit repro IDs are supplied (default: ${LATEST})
    --repro-id ID           Inspect one reproduction ID. Can be repeated.
    --repro-ids LIST        Comma-separated reproduction IDs.
    --min-matching N        Required records with matching environment.sandbox_image
                             (default: ${MIN_MATCHING})
    --max-parallel N        Inspect up to N reproduction detail records concurrently
                             (default: ${MAX_PARALLEL})
    --require-all           Require every inspected record to expose the exact image.
    --require-worker-proof  Require at least one active worker to expose the
                             exact image in capabilities.sandbox_image.
    -h, --help              Show this help.

WHAT IT VALIDATES:
    The production API exposes reproduction detail environment.sandbox_image for
    at least one post-deploy record, or active worker capabilities.sandbox_image
    when an admin token is supplied, and that value matches the promoted digest.
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

curl_auth_args() {
  case "$API_TOKEN_HEADER" in
    auto)
      if [[ "$API_TOKEN" == pak_* ]]; then
        printf '%s\n' -H "X-API-Key: ${API_TOKEN}"
      else
        printf '%s\n' -H "Authorization: Bearer ${API_TOKEN}"
      fi
      ;;
    x-api-key)
      printf '%s\n' -H "X-API-Key: ${API_TOKEN}"
      ;;
    authorization)
      printf '%s\n' -H "Authorization: Bearer ${API_TOKEN}"
      ;;
  esac
}

fetch_workers() {
  local tmp http_code
  local -a auth_args
  tmp=$(mktemp)
  mapfile -t auth_args < <(curl_auth_args)
  http_code=$(curl -sf -w "%{http_code}" -o "$tmp" "${auth_args[@]}" "${API_URL}/workers?status=active&limit=100" 2>/dev/null) || http_code="000"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp"
    printf 'ERROR:HTTP_%s\n' "$http_code"
    return
  fi
  jq -r '
    .workers[]? |
    [
      (.worker_id // "unknown"),
      (.capabilities.sandbox_image // .capabilities.sandbox_environment.sandbox_image // "")
    ] | @tsv
  ' "$tmp"
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
    --api-token)
      API_TOKEN="$2"
      shift 2
      ;;
    --api-token-header)
      API_TOKEN_HEADER="$2"
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
    --max-parallel)
      MAX_PARALLEL="$2"
      shift 2
      ;;
    --require-all)
      REQUIRE_ALL=true
      shift
      ;;
    --require-worker-proof)
      REQUIRE_WORKER_PROOF=true
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
[[ "$MAX_PARALLEL" =~ ^[0-9]+$ && "$MAX_PARALLEL" -ge 1 ]] || fail "--max-parallel must be a positive integer"
case "$API_TOKEN_HEADER" in
  auto|x-api-key|authorization) ;;
  *) fail "--api-token-header must be auto, x-api-key, or authorization" ;;
esac
if [[ "$REQUIRE_WORKER_PROOF" == true && -z "$API_TOKEN" ]]; then
  fail "--require-worker-proof needs --api-token or PRUVA_API_TOKEN"
fi

if [[ ${#REPRO_IDS[@]} -eq 0 ]]; then
  while IFS= read -r repro_id; do
    [[ -n "$repro_id" ]] && REPRO_IDS+=("$repro_id")
  done < <(fetch_latest_repro_ids "$LATEST")
fi
[[ ${#REPRO_IDS[@]} -gt 0 ]] || fail "no reproduction IDs to inspect"

log "API: $API_URL"
log "Expected sandbox image: $SANDBOX_IMAGE"
log "Inspecting ${#REPRO_IDS[@]} reproduction(s)"
log "Max parallel: $MAX_PARALLEL"

matching=0
missing=0
mismatched=0
fetch_failed=0
worker_matching=0
worker_missing=0
worker_mismatched=0
worker_fetch_failed=0

inspect_repro() {
  local repro_id="$1"
  local result_file="$2"
  local image

  image=$(fetch_repro_environment_image "$repro_id")
  if [[ "$image" == ERROR:* ]]; then
    printf 'fetch_failed\t%s\tmetadata fetch failed (%s)\n' "$repro_id" "${image#ERROR:}" >"$result_file"
  elif [[ -z "$image" ]]; then
    printf 'missing\t%s\thas no environment.sandbox_image\n' "$repro_id" >"$result_file"
  elif [[ "$image" == "$SANDBOX_IMAGE" ]]; then
    printf 'matching\t%s\tenvironment.sandbox_image matches\n' "$repro_id" >"$result_file"
  else
    printf 'mismatched\t%s\tuses different sandbox image: %s\n' "$repro_id" "$image" >"$result_file"
  fi
}

run_parallel_inspections() {
  local run_dir
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pruva-rollout-proof.XXXXXX")

  local -A pid_to_result=()
  local -A pid_to_repro=()
  local index=0

  start_child() {
    local repro_id="$1"
    local result_file="${run_dir}/${repro_id}.result"
    inspect_repro "$repro_id" "$result_file" &
    local pid=$!
    pid_to_result["$pid"]="$result_file"
    pid_to_repro["$pid"]="$repro_id"
  }

  finish_child() {
    local finished_pid rc result_file kind repro_id detail
    set +e
    wait -n -p finished_pid
    rc=$?
    set -e

    result_file="${pid_to_result[$finished_pid]:-}"
    repro_id="${pid_to_repro[$finished_pid]:-unknown}"
    unset 'pid_to_result[$finished_pid]'
    unset 'pid_to_repro[$finished_pid]'

    if [[ $rc -ne 0 || -z "$result_file" || ! -f "$result_file" ]]; then
      warn "$repro_id metadata fetch failed (worker_exit_${rc})"
      fetch_failed=$((fetch_failed + 1))
      return
    fi

    IFS=$'\t' read -r kind repro_id detail <"$result_file"
    case "$kind" in
      matching)
        pass "$repro_id $detail"
        matching=$((matching + 1))
        ;;
      missing)
        warn "$repro_id $detail"
        missing=$((missing + 1))
        ;;
      mismatched)
        warn "$repro_id $detail"
        mismatched=$((mismatched + 1))
        ;;
      fetch_failed)
        warn "$repro_id $detail"
        fetch_failed=$((fetch_failed + 1))
        ;;
      *)
        warn "$repro_id metadata fetch failed (unknown_result)"
        fetch_failed=$((fetch_failed + 1))
        ;;
    esac
  }

  while [[ $index -lt ${#REPRO_IDS[@]} || ${#pid_to_result[@]} -gt 0 ]]; do
    while [[ $index -lt ${#REPRO_IDS[@]} && ${#pid_to_result[@]} -lt $MAX_PARALLEL ]]; do
      start_child "${REPRO_IDS[$index]}"
      index=$((index + 1))
    done

    if [[ ${#pid_to_result[@]} -gt 0 ]]; then
      finish_child
    fi
  done
}

run_parallel_inspections

if [[ -n "$API_TOKEN" ]]; then
  log "Inspecting active worker sandbox proof"
  worker_rows=$(fetch_workers)
  if [[ "$worker_rows" == ERROR:* ]]; then
    warn "worker metadata fetch failed (${worker_rows#ERROR:})"
    worker_fetch_failed=$((worker_fetch_failed + 1))
  elif [[ -z "$worker_rows" ]]; then
    warn "no active workers returned from /workers"
    worker_missing=$((worker_missing + 1))
  else
    while IFS=$'\t' read -r worker_id image; do
      [[ -n "$worker_id" ]] || continue
      if [[ -z "$image" ]]; then
        warn "$worker_id has no capabilities.sandbox_image"
        worker_missing=$((worker_missing + 1))
      elif [[ "$image" == "$SANDBOX_IMAGE" ]]; then
        pass "$worker_id capabilities.sandbox_image matches"
        worker_matching=$((worker_matching + 1))
      else
        warn "$worker_id uses different sandbox image: $image"
        worker_mismatched=$((worker_mismatched + 1))
      fi
    done <<< "$worker_rows"
  fi
else
  warn "No PRUVA_API_TOKEN supplied; skipping active worker sandbox proof"
fi

log "Reproduction summary: ${matching} matching, ${missing} missing, ${mismatched} different, ${fetch_failed} fetch failed"
log "Worker summary: ${worker_matching} matching, ${worker_missing} missing, ${worker_mismatched} different, ${worker_fetch_failed} fetch failed"

proof_matching=$((matching + worker_matching))

if [[ "$REQUIRE_WORKER_PROOF" == true && "$worker_matching" -lt 1 ]]; then
  fail "--require-worker-proof set but no active worker exposes the promoted image"
fi

if [[ "$proof_matching" -lt "$MIN_MATCHING" ]]; then
  fail "Need at least ${MIN_MATCHING} production proof record(s) with matching sandbox image"
fi

if [[ "$REQUIRE_ALL" == true && "$matching" -ne "${#REPRO_IDS[@]}" ]]; then
  fail "--require-all set but not every inspected record exposes the promoted image"
fi

pass "production API rollout proof passed"
