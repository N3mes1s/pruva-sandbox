#!/usr/bin/env bash
#
# test-codespaces-gh.sh - Create real GitHub Codespaces from repro branches.
#
# This exercises the actual user path:
#   1. create a Codespace from repro/<REPRO_ID>
#   2. wait until GitHub reports it is available
#   3. optionally SSH in, reject recovery containers, and run pruva-verify
#   4. delete the Codespace unless --keep is set
#
set -euo pipefail

REPO="N3mes1s/pruva-sandbox"
API_URL="${PRUVA_API_URL:-https://api.pruva.dev/v1}"
LATEST=0
REPRO_IDS=()
KEEP=false
IDLE_TIMEOUT="10m"
RETENTION_PERIOD="1h"
CREATE_TIMEOUT="45m"
SSH_TIMEOUT="10m"
MACHINE=""
LOCATION=""
MODE="available"

CREATED_CODESPACES=()

usage() {
  cat <<EOF
test-codespaces-gh.sh - Run Codespaces smoke tests for Pruva repro branches

USAGE:
    ./scripts/test-codespaces-gh.sh --repro-id REPRO-2026-00185
    ./scripts/test-codespaces-gh.sh --latest 3

OPTIONS:
    --repro-id ID          Test one reproduction ID. Can be repeated.
    --repro-ids LIST       Comma-separated reproduction IDs.
    --latest N            Test the latest N published reproductions from the API.
    --repo OWNER/REPO      Repository to create Codespaces in (default: ${REPO})
    --api-url URL          Pruva API base URL (default: ${API_URL})
    --machine NAME         Codespaces machine name to request. Defaults to the
                           first machine returned by the Codespaces API.
    --location NAME        Codespaces location to request.
    --idle-timeout VALUE   Codespace idle timeout (default: ${IDLE_TIMEOUT})
    --retention VALUE      Codespace retention period (default: ${RETENTION_PERIOD})
    --create-timeout VALUE Max time for Codespace creation (default: ${CREATE_TIMEOUT})
    --ssh-timeout VALUE    Max time to wait for SSH in verify mode (default: ${SSH_TIMEOUT})
    --mode MODE            Test mode: available or verify (default: ${MODE}).
                           available waits for GitHub API state only, matching
                           the web UI creation path. verify waits for the
                           postCreateCommand pruva-verify result from the real
                           Codespaces startup path.
    --keep                Keep created Codespaces for debugging.
    -h, --help            Show this help message.

REQUIRES:
    gh auth refresh -h github.com -s codespace
    --mode verify also requires an SSH-capable devcontainer.
EOF
}

log() {
  printf '[codespace-test] %s\n' "$*"
}

fail() {
  printf '[codespace-test] ERROR: %s\n' "$*" >&2
}

cleanup() {
  if [[ "$KEEP" == "true" ]]; then
    return
  fi
  for codespace in "${CREATED_CODESPACES[@]}"; do
    [[ -z "$codespace" ]] && continue
    log "Deleting Codespace ${codespace}"
    gh codespace delete --codespace "$codespace" --force >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

delete_codespace() {
  local codespace="$1"
  if [[ "$KEEP" == "true" || -z "$codespace" ]]; then
    return
  fi
  log "Deleting Codespace ${codespace}"
  gh codespace delete --codespace "$codespace" --force >/dev/null 2>&1 || true
  local remaining=()
  local item
  for item in "${CREATED_CODESPACES[@]}"; do
    [[ "$item" != "$codespace" ]] && remaining+=("$item")
  done
  CREATED_CODESPACES=("${remaining[@]}")
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "Missing required command: ${cmd}"
    exit 1
  fi
}

run_with_timeout() {
  local timeout_value="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_value" "$@"
  else
    "$@"
  fi
}

check_codespace_scope() {
  local err
  err=$(mktemp)
  if gh codespace list --repo "$REPO" --limit 1 --json name >/dev/null 2>"$err"; then
    rm -f "$err"
    return
  fi

  if grep -q 'needs the "codespace" scope' "$err"; then
    cat "$err" >&2
    rm -f "$err"
    fail 'GitHub CLI token is missing Codespaces scope. Run: gh auth refresh -h github.com -s codespace'
    exit 1
  fi

  cat "$err" >&2
  rm -f "$err"
  exit 1
}

fetch_latest_repro_ids() {
  local count="$1"
  local tmp http_code
  tmp=$(mktemp)
  http_code=$(curl -sf -w "%{http_code}" -o "$tmp" "${API_URL}/reproductions?status=published&limit=${count}" 2>/dev/null) || http_code="000"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp"
    fail "Failed to fetch latest reproductions from API (HTTP ${http_code})"
    exit 1
  fi
  jq -r '.reproductions[]?.repro_id // empty' "$tmp"
  rm -f "$tmp"
}

default_machine_for_ref() {
  local ref="$1"
  gh api "/repos/${REPO}/codespaces/machines?ref=${ref}" --jq '.machines[0].name // empty'
}

find_codespace_by_display_name() {
  local display_name="$1"
  gh codespace list --repo "$REPO" --limit 100 --json name,displayName \
    | jq -r --arg display_name "$display_name" '.[] | select(.displayName == $display_name) | .name' \
    | head -n 1
}

wait_for_codespace_name() {
  local display_name="$1"
  local deadline=$((SECONDS + 300))
  local name=""
  while [[ $SECONDS -lt $deadline ]]; do
    name=$(find_codespace_by_display_name "$display_name")
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return
    fi
    sleep 5
  done
  return 1
}

wait_for_codespace_available() {
  local codespace="$1"
  local deadline=$((SECONDS + 900))
  local state=""
  while [[ $SECONDS -lt $deadline ]]; do
    state=$(gh codespace view --codespace "$codespace" --json state --jq '.state' 2>/dev/null || true)
    if [[ "$state" == "Available" ]]; then
      return 0
    fi
    log "Codespace ${codespace} state: ${state:-unknown}"
    sleep 10
  done
  fail "Timed out waiting for Codespace ${codespace} to become Available"
  return 1
}

wait_for_codespace_ssh() {
  local codespace="$1"
  local deadline=$((SECONDS + 600))
  if [[ "$SSH_TIMEOUT" =~ ^([0-9]+)m$ ]]; then
    deadline=$((SECONDS + (${BASH_REMATCH[1]} * 60)))
  elif [[ "$SSH_TIMEOUT" =~ ^([0-9]+)s$ ]]; then
    deadline=$((SECONDS + BASH_REMATCH[1]))
  fi

  while [[ $SECONDS -lt $deadline ]]; do
    if gh codespace ssh --codespace "$codespace" -- true >/dev/null 2>&1; then
      return 0
    fi
    log "Waiting for SSH in ${codespace}"
    sleep 10
  done
  fail "Timed out waiting for SSH in Codespace ${codespace}"
  return 1
}

wait_for_codespace_post_create() {
  local codespace="$1"
  local deadline=$((SECONDS + 1800))
  local logs
  logs=$(mktemp)

  while [[ $SECONDS -lt $deadline ]]; do
    if gh codespace logs --codespace "$codespace" >"$logs" 2>/dev/null; then
      if grep -q "Finished configuring codespace" "$logs"; then
        rm -f "$logs"
        return 0
      fi
    fi
    log "Waiting for postCreateCommand in ${codespace}"
    sleep 10
  done

  cat "$logs" >&2 || true
  rm -f "$logs"
  fail "Timed out waiting for postCreateCommand in Codespace ${codespace}"
  return 1
}

check_environment_in_codespace() {
  local codespace="$1"
  local remote_script quoted_script

  remote_script="set -euo pipefail
if [ \"\${CODESPACES_RECOVERY_CONTAINER:-}\" = \"true\" ]; then
  echo 'ERROR: connected to a Codespaces recovery container, not the Pruva devcontainer' >&2
  exit 2
fi
test -f /etc/pruva-sandbox-version
command -v pruva-verify >/dev/null
echo '== sandbox =='
cat /etc/pruva-sandbox-version"
  printf -v quoted_script "%q" "$remote_script"
  gh codespace ssh --codespace "$codespace" "bash -lc ${quoted_script}"
}

verify_post_create_result() {
  local codespace="$1"
  local repro_id="$2"
  local logs
  logs=$(mktemp)

  if ! gh codespace logs --codespace "$codespace" >"$logs"; then
    rm -f "$logs"
    fail "Could not fetch Codespace logs for ${codespace}"
    return 1
  fi

  if ! grep -q "$repro_id" "$logs"; then
    cat "$logs" >&2 || true
    rm -f "$logs"
    fail "postCreateCommand logs did not mention ${repro_id}"
    return 1
  fi

  if grep -q "VERIFICATION SUCCESSFUL" "$logs"; then
    rm -f "$logs"
    return 0
  fi

  if grep -q "VERIFICATION FAILED" "$logs"; then
    cat "$logs" >&2 || true
    rm -f "$logs"
    fail "postCreateCommand pruva-verify failed for ${repro_id}"
    return 1
  fi

  cat "$logs" >&2 || true
  rm -f "$logs"
  fail "postCreateCommand logs did not include a terminal pruva-verify result for ${repro_id}"
  return 1
}

test_one_repro() {
  local repro_id="$1"
  if [[ ! "$repro_id" =~ ^REPRO-[0-9]{4}-[0-9]{5}$ ]]; then
    fail "Invalid REPRO_ID: ${repro_id}"
    return 1
  fi

  local branch="repro/${repro_id}"
  local short_id="${repro_id#REPRO-}"
  local display_name="pruva-smoke-${short_id}-$(date +%m%d%H%M%S)"
  local output_file
  output_file=$(mktemp)
  local machine="$MACHINE"
  if [[ -z "$machine" ]]; then
    machine=$(default_machine_for_ref "$branch")
    if [[ -z "$machine" ]]; then
      fail "Could not resolve a Codespaces machine for ${branch}"
      rm -f "$output_file"
      return 1
    fi
  fi

  log "Creating Codespace for ${branch} on machine ${machine}"
  local args=(
    codespace create
    --repo "$REPO"
    --branch "$branch"
    --display-name "$display_name"
    --idle-timeout "$IDLE_TIMEOUT"
    --retention-period "$RETENTION_PERIOD"
    --default-permissions
    --machine "$machine"
  )
  if [[ -n "$LOCATION" ]]; then
    args+=(--location "$LOCATION")
  fi

  local create_rc=0
  if run_with_timeout "$CREATE_TIMEOUT" gh "${args[@]}" 2>&1 | tee "$output_file"; then
    create_rc=0
  else
    create_rc=$?
  fi

  local codespace_name
  codespace_name=$(wait_for_codespace_name "$display_name" || true)
  if [[ -n "$codespace_name" ]]; then
    CREATED_CODESPACES+=("$codespace_name")
    log "Codespace: ${codespace_name}"
    if ! wait_for_codespace_available "$codespace_name"; then
      delete_codespace "$codespace_name"
      rm -f "$output_file"
      return 1
    fi
    if [[ "$MODE" == "verify" ]]; then
      if ! wait_for_codespace_ssh "$codespace_name"; then
        gh codespace logs --codespace "$codespace_name" || true
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
      if ! wait_for_codespace_post_create "$codespace_name"; then
        gh codespace logs --codespace "$codespace_name" || true
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
      log "Checking Pruva environment in ${codespace_name}"
      if ! check_environment_in_codespace "$codespace_name"; then
        gh codespace logs --codespace "$codespace_name" || true
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
      log "Checking postCreateCommand pruva-verify result in ${codespace_name}"
      if ! verify_post_create_result "$codespace_name" "$repro_id"; then
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
    fi
  else
    fail "Could not find created Codespace with display name ${display_name}"
  fi

  if [[ $create_rc -ne 0 ]]; then
    fail "Codespace create failed for ${repro_id} (exit ${create_rc})"
    delete_codespace "$codespace_name"
    rm -f "$output_file"
    return 1
  fi

  if ! grep -Eq "postCreateCommand|pruva-verify|${repro_id}" "$output_file"; then
    log "Create output did not include postCreate details; relying on ${MODE} mode result."
  fi

  rm -f "$output_file"
  log "PASS ${repro_id}"
  delete_codespace "$codespace_name"
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --latest)
      LATEST="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --machine)
      MACHINE="$2"
      shift 2
      ;;
    --location)
      LOCATION="$2"
      shift 2
      ;;
    --idle-timeout)
      IDLE_TIMEOUT="$2"
      shift 2
      ;;
    --retention)
      RETENTION_PERIOD="$2"
      shift 2
      ;;
    --create-timeout)
      CREATE_TIMEOUT="$2"
      shift 2
      ;;
    --ssh-timeout)
      SSH_TIMEOUT="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --keep)
      KEEP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

require_command gh
require_command jq
require_command curl

case "$MODE" in
  available|verify) ;;
  *)
    fail "Invalid --mode '${MODE}' (expected available or verify)"
    exit 1
    ;;
esac

if [[ "$LATEST" != "0" ]]; then
  while IFS= read -r repro_id; do
    [[ -n "$repro_id" ]] && REPRO_IDS+=("$repro_id")
  done < <(fetch_latest_repro_ids "$LATEST")
fi

if [[ ${#REPRO_IDS[@]} -eq 0 ]]; then
  usage
  exit 1
fi

check_codespace_scope

log "Repo: ${REPO}"
log "API: ${API_URL}"
log "Mode: ${MODE}"
log "Keep Codespaces: ${KEEP}"

passed=0
failed=0
for repro_id in "${REPRO_IDS[@]}"; do
  if test_one_repro "$repro_id"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

log "Summary: ${passed} passed, ${failed} failed"
if [[ $failed -gt 0 ]]; then
  exit 1
fi
