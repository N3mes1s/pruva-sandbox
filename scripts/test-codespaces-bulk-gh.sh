#!/usr/bin/env bash
#
# test-codespaces-bulk-gh.sh - Run many pruva-verify executions inside one
# warmed GitHub Codespace.
#
# This complements test-codespaces-gh.sh:
#   - test-codespaces-gh.sh proves branch-specific web UI startup.
#   - this script amortizes Codespaces startup for bulk runtime verification.
#
set -euo pipefail

REPO="N3mes1s/pruva-sandbox"
API_URL="${PRUVA_API_URL:-https://api.pruva.dev/v1}"
BRANCH="main"
LATEST=0
REPRO_IDS=()
KEEP=false
IDLE_TIMEOUT="10m"
RETENTION_PERIOD="1h"
CREATE_TIMEOUT="45m"
SSH_TIMEOUT="10m"
MACHINE=""
LOCATION=""
CODESPACE=""
CREATED_CODESPACE=""
PER_REPRO_TIMEOUT="0"
RUN_LABEL="bulk-$(date +%Y%m%d%H%M%S)"

usage() {
  cat <<EOF
test-codespaces-bulk-gh.sh - Run multiple repros in one warmed Codespace

USAGE:
    ./scripts/test-codespaces-bulk-gh.sh --latest 5
    ./scripts/test-codespaces-bulk-gh.sh --repro-ids REPRO-2026-00153,REPRO-2026-00105

OPTIONS:
    --repro-id ID          Run one reproduction ID. Can be repeated.
    --repro-ids LIST       Comma-separated reproduction IDs.
    --latest N             Run the latest N published reproductions from the API.
    --repo OWNER/REPO      Repository for the Codespace (default: ${REPO})
    --branch NAME          Branch for the warmed Codespace (default: ${BRANCH})
    --api-url URL          Pruva API base URL (default: ${API_URL})
    --codespace NAME       Reuse an existing Codespace instead of creating one.
    --machine NAME         Codespaces machine name. Defaults to first available.
    --location NAME        Codespaces location to request.
    --idle-timeout VALUE   Codespace idle timeout (default: ${IDLE_TIMEOUT})
    --retention VALUE      Codespace retention period (default: ${RETENTION_PERIOD})
    --create-timeout VALUE Max time for Codespace creation (default: ${CREATE_TIMEOUT})
    --ssh-timeout VALUE    Max time to wait for SSH (default: ${SSH_TIMEOUT})
    --per-repro-timeout T  Optional remote timeout per pruva-verify run.
                           Use timeout(1) syntax such as 30m or 2h. Default: none.
    --run-label LABEL      Remote result directory name.
    --keep                 Keep a created Codespace for debugging.
    -h, --help             Show this help message.

WHAT IT VALIDATES:
    1. One public Codespace can start from the requested branch.
    2. The devcontainer is the Pruva sandbox, not a recovery container.
    3. The checked-out public repo has pruva-verify and repro-patches.
    4. Each requested repro runs through pruva-verify with per-ID logs.

This is not a replacement for branch-specific startup testing. Use
test-codespaces-gh.sh when you need to prove the web UI opens a specific
repro/<REPRO_ID> branch and runs its postCreateCommand.
EOF
}

log() {
  printf '[codespace-bulk] %s\n' "$*"
}

fail() {
  printf '[codespace-bulk] ERROR: %s\n' "$*" >&2
}

cleanup() {
  if [[ "$KEEP" == "true" || -z "$CREATED_CODESPACE" ]]; then
    return
  fi
  log "Deleting Codespace ${CREATED_CODESPACE}"
  gh codespace delete --codespace "$CREATED_CODESPACE" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

create_codespace() {
  local display_name="pruva-bulk-${BRANCH//\//-}-$(date +%m%d%H%M%S)"
  local machine="$MACHINE"
  if [[ -z "$machine" ]]; then
    machine=$(default_machine_for_ref "$BRANCH")
    if [[ -z "$machine" ]]; then
      fail "Could not resolve a Codespaces machine for ${BRANCH}"
      return 1
    fi
  fi

  log "Creating Codespace for ${REPO}:${BRANCH} on machine ${machine}"
  local args=(
    codespace create
    --repo "$REPO"
    --branch "$BRANCH"
    --display-name "$display_name"
    --idle-timeout "$IDLE_TIMEOUT"
    --retention-period "$RETENTION_PERIOD"
    --default-permissions
    --machine "$machine"
  )
  if [[ -n "$LOCATION" ]]; then
    args+=(--location "$LOCATION")
  fi

  run_with_timeout "$CREATE_TIMEOUT" gh "${args[@]}"
  CODESPACE=$(wait_for_codespace_name "$display_name") || {
    fail "Could not find created Codespace with display name ${display_name}"
    return 1
  }
  CREATED_CODESPACE="$CODESPACE"
  log "Codespace: ${CODESPACE}"
}

run_remote_bulk() {
  local ids_text remote_script quoted_script
  ids_text=$(printf '%s\n' "${REPRO_IDS[@]}")
  remote_script=$(cat <<EOF
set -euo pipefail
if [ "\${CODESPACES_RECOVERY_CONTAINER:-}" = "true" ]; then
  echo "ERROR: connected to a Codespaces recovery container, not the Pruva devcontainer" >&2
  exit 2
fi
cd /workspaces/pruva-sandbox
test -f /etc/pruva-sandbox-version
command -v pruva-verify >/dev/null
run_dir="pruva-results/bulk-codespaces/${RUN_LABEL}"
mkdir -p "\$run_dir"
cat > "\$run_dir/repro_ids.txt" <<'BULK_IDS'
${ids_text}
BULK_IDS
echo "[bulk] Codespace: ${CODESPACE}"
echo "[bulk] Branch: \$(git rev-parse --abbrev-ref HEAD)"
echo "[bulk] Commit: \$(git rev-parse --short HEAD)"
echo "[bulk] Run dir: \$run_dir"
cat /etc/pruva-sandbox-version
passed=0
failed=0
while IFS= read -r repro_id; do
  [ -n "\$repro_id" ] || continue
  log_file="\$run_dir/\${repro_id}.log"
  echo "[bulk] START \$repro_id"
  set +e
  if [ "${PER_REPRO_TIMEOUT}" = "0" ]; then
    PRUVA_KEEP_DIR=1 pruva-verify "\$repro_id" >"\$log_file" 2>&1
  else
    PRUVA_KEEP_DIR=1 timeout "${PER_REPRO_TIMEOUT}" pruva-verify "\$repro_id" >"\$log_file" 2>&1
  fi
  rc=\$?
  set -e
  if [ "\$rc" -eq 0 ]; then
    passed=\$((passed + 1))
    printf 'PASS\t%s\t%s\n' "\$repro_id" "\$log_file" | tee -a "\$run_dir/summary.tsv"
  else
    failed=\$((failed + 1))
    printf 'FAIL\t%s\t%s\texit=%s\n' "\$repro_id" "\$log_file" "\$rc" | tee -a "\$run_dir/summary.tsv"
    echo "[bulk] Tail for \$repro_id"
    tail -80 "\$log_file" || true
  fi
done < "\$run_dir/repro_ids.txt"
echo "[bulk] Summary: \$passed passed, \$failed failed"
cat "\$run_dir/summary.tsv"
[ "\$failed" -eq 0 ]
EOF
)
  printf -v quoted_script "%q" "$remote_script"
  gh codespace ssh --codespace "$CODESPACE" "bash -lc ${quoted_script}"
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
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --codespace)
      CODESPACE="$2"
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
    --per-repro-timeout)
      PER_REPRO_TIMEOUT="$2"
      shift 2
      ;;
    --run-label)
      RUN_LABEL="$2"
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

[[ "$LATEST" =~ ^[0-9]+$ ]] || {
  fail "--latest must be numeric"
  exit 1
}

if [[ "$LATEST" != "0" ]]; then
  while IFS= read -r repro_id; do
    [[ -n "$repro_id" ]] && REPRO_IDS+=("$repro_id")
  done < <(fetch_latest_repro_ids "$LATEST")
fi

if [[ ${#REPRO_IDS[@]} -eq 0 ]]; then
  usage
  exit 1
fi

for repro_id in "${REPRO_IDS[@]}"; do
  if [[ ! "$repro_id" =~ ^REPRO-[0-9]{4}-[0-9]{5}$ ]]; then
    fail "Invalid REPRO_ID: ${repro_id}"
    exit 1
  fi
done

check_codespace_scope

log "Repo: ${REPO}"
log "Branch: ${BRANCH}"
log "API: ${API_URL}"
log "Repros: ${#REPRO_IDS[@]}"
log "Per-repro timeout: ${PER_REPRO_TIMEOUT}"

if [[ -z "$CODESPACE" ]]; then
  create_codespace
else
  log "Using existing Codespace: ${CODESPACE}"
fi

wait_for_codespace_available "$CODESPACE"
wait_for_codespace_ssh "$CODESPACE"
run_remote_bulk
