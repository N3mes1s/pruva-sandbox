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
MAX_PARALLEL=1

CREATED_CODESPACES=()
PARALLEL_PIDS=()
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

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
    --max-parallel N       Run up to N Codespaces at once (default: ${MAX_PARALLEL}).
                           Use a small value such as 3 for latest-20 verification
                           to avoid quota and rate-limit noise.
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
  for pid in "${PARALLEL_PIDS[@]:-}"; do
    [[ -z "$pid" ]] && continue
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done

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

codespace_created_epoch() {
  local codespace="$1"
  local created_at
  created_at=$(gh codespace view --codespace "$codespace" --json createdAt --jq '.createdAt // empty')
  if [[ -z "$created_at" ]]; then
    fail "Could not read Codespace creation timestamp for ${codespace}"
    return 1
  fi
  date -u -d "$created_at" +%s
}

remote_pruva_run_finished() {
  local codespace="$1"
  local repro_id="$2"
  local min_epoch="$3"
  local remote_script quoted_script

  remote_script="set -eu
base=/workspaces/pruva-sandbox/pruva-results/${repro_id}
min_epoch=${min_epoch}
repro_id='${repro_id}'
verify_needle=\"pruva-verify \$repro_id\"
script_needle='reproduction_steps.sh'
test -d \"\$base\" || exit 1
self=\$\$
parent=\$(awk '/^PPid:/ {print \$2}' /proc/\$\$/status 2>/dev/null || echo '')
for proc in /proc/[0-9]*; do
  pid=\${proc##*/}
  [ \"\$pid\" = \"\$self\" ] && continue
  [ -n \"\$parent\" ] && [ \"\$pid\" = \"\$parent\" ] && continue
  cmd=\$(tr '\\0' ' ' <\"\$proc/cmdline\" 2>/dev/null || true)
  case \"\$cmd\" in
    *\"\$verify_needle\"*|*\"\$script_needle\"*) exit 1 ;;
  esac
done
for rel in logs/reproduction_steps.log repro/runtime_manifest.json repro/validation_verdict.json; do
  file=\"\$base/\$rel\"
  test -s \"\$file\" || exit 1
  mtime=\$(stat -c %Y \"\$file\")
  [ \"\$mtime\" -ge \"\$min_epoch\" ] || exit 1
done"
  printf -v quoted_script "%q" "$remote_script"
  gh codespace ssh --codespace "$codespace" "bash -lc ${quoted_script}" >/dev/null 2>&1
}

wait_for_codespace_post_create() {
  local codespace="$1"
  local repro_id="$2"
  local min_epoch="$3"
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
    if remote_pruva_run_finished "$codespace" "$repro_id" "$min_epoch"; then
      rm -f "$logs"
      log "Detected completed Pruva run for ${repro_id}"
      return 0
    fi
    log "Waiting for postCreateCommand in ${codespace}"
    sleep 10
  done

  cat "$logs" >&2 || true
  rm -f "$logs"
  fail "Timed out waiting for postCreateCommand in Codespace ${codespace}"
  return 1
}

check_remote_pruva_file_freshness() {
  local codespace="$1"
  local repro_id="$2"
  local min_epoch="$3"
  local base="/workspaces/pruva-sandbox/pruva-results/${repro_id}"
  local remote_script quoted_script

  remote_script="set -eu
base='${base}'
min_epoch=${min_epoch}
for rel in logs/reproduction_steps.log repro/runtime_manifest.json repro/validation_verdict.json; do
  file=\"\$base/\$rel\"
  if [ ! -s \"\$file\" ]; then
    echo \"missing required fresh result file: \$file\" >&2
    exit 1
  fi
  mtime=\$(stat -c %Y \"\$file\")
  if [ \"\$mtime\" -lt \"\$min_epoch\" ]; then
    echo \"stale result file: \$file mtime=\$mtime min=\$min_epoch\" >&2
    exit 1
  fi
done"
  printf -v quoted_script "%q" "$remote_script"
  gh codespace ssh --codespace "$codespace" "bash -lc ${quoted_script}"
}

verify_remote_pruva_result() {
  local codespace="$1"
  local repro_id="$2"
  local min_epoch="$3"
  local base="/workspaces/pruva-sandbox/pruva-results/${repro_id}"
  local verdict_file manifest_file
  verdict_file=$(mktemp)
  manifest_file=$(mktemp)

  if ! check_remote_pruva_file_freshness "$codespace" "$repro_id" "$min_epoch"; then
    rm -f "$verdict_file" "$manifest_file"
    fail "Missing or stale fresh runtime files for ${repro_id} in ${codespace}"
    gh codespace ssh --codespace "$codespace" -- "if [ -d ${base}/logs ]; then echo '== logs tail ==' >&2; find ${base}/logs -maxdepth 2 -type f | sort | while read -r log_file; do echo \"---- \$log_file ----\" >&2; tail -n 40 \"\$log_file\" >&2 || true; done; fi" || true
    return 1
  fi

  if ! gh codespace ssh --codespace "$codespace" -- "cat ${base}/repro/validation_verdict.json" >"$verdict_file"; then
    rm -f "$verdict_file" "$manifest_file"
    fail "No validation verdict for ${repro_id} in ${codespace}"
    return 1
  fi

  echo "== validation_verdict =="
  cat "$verdict_file"
  echo

  if ! gh codespace ssh --codespace "$codespace" -- "cat ${base}/repro/runtime_manifest.json" >"$manifest_file"; then
    rm -f "$verdict_file" "$manifest_file"
    fail "No runtime manifest for ${repro_id} in ${codespace}"
    return 1
  fi

  echo "== runtime_manifest =="
  cat "$manifest_file"
  echo

  if ! jq -e '
    (.target_path_reached == true)
    and ((.overall? // "" | ascii_downcase) != "failed")
    and ((.status? // "" | ascii_downcase) != "failed")
    and ((.repro_result? // "" | ascii_downcase) != "failed")
    and ((.attempt_results?.overall? // "" | ascii_downcase) != "failed")
    and ((.attempt_results?.status? // "" | ascii_downcase) != "failed")
    and ((.attempt_results?.result? // "" | ascii_downcase) != "failed")
  ' "$manifest_file" >/dev/null; then
    fail "runtime_manifest does not confirm a successful fresh runtime for ${repro_id}"
    rm -f "$verdict_file" "$manifest_file"
    gh codespace ssh --codespace "$codespace" -- "if [ -d ${base}/logs ]; then echo '== logs tail ==' >&2; find ${base}/logs -maxdepth 2 -type f | sort | while read -r log_file; do echo \"---- \$log_file ----\" >&2; tail -n 40 \"\$log_file\" >&2 || true; done; fi" || true
    return 1
  fi

  if jq -e '.repro_result == "confirmed" and .end_to_end_target_reached == true' "$verdict_file" >/dev/null; then
    rm -f "$verdict_file" "$manifest_file"
    return 0
  fi

  rm -f "$verdict_file" "$manifest_file"
  gh codespace ssh --codespace "$codespace" -- "if [ -d ${base}/logs ]; then echo '== logs tail ==' >&2; for log_file in ${base}/logs/*; do [ -f \"\$log_file\" ] || continue; echo \"---- \$log_file ----\" >&2; tail -n 40 \"\$log_file\" >&2 || true; done; fi" || true
  return 1
}

check_docker_runtime_contract_in_codespace() {
  local codespace="$1"
  local remote_script quoted_script

  remote_script='set -euo pipefail
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if [ -n "${DOCKER_API_VERSION:-}" ]; then
  echo "ERROR: DOCKER_API_VERSION must not be pinned; found $DOCKER_API_VERSION" >&2
  exit 2
fi

docker version --format "DOCKER_VERSION client={{.Client.Version}} server={{.Server.Version}} api={{.Server.APIVersion}}"
docker info --format "DOCKER_INFO driver={{.Driver}} root={{.DockerRootDir}}"

iptables_version="$($SUDO iptables -V 2>/dev/null || true)"
case "$iptables_version" in
  *nf_tables*) active_backend="nft"; inactive_cmd="iptables-legacy" ;;
  *legacy*) active_backend="legacy"; inactive_cmd="iptables-nft" ;;
  *)
    echo "ERROR: cannot determine active iptables backend from: ${iptables_version:-missing}" >&2
    exit 2
    ;;
esac
echo "IPTABLES_ACTIVE_BACKEND=$active_backend"
echo "IPTABLES_VERSION=$iptables_version"

has_docker_rules() {
  cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 && $SUDO "$cmd" -S 2>/dev/null | grep -Eq "DOCKER|docker"
}

rules_for_bridge() {
  cmd="$1"
  bridge="$2"
  command -v "$cmd" >/dev/null 2>&1 && $SUDO "$cmd" -S 2>/dev/null | grep -Fq "$bridge"
}

forward_policy() {
  cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 && $SUDO "$cmd" -S FORWARD 2>/dev/null | awk "/^-P FORWARD/ {print \$3; exit}"
}

base=/workspaces/pruva-sandbox/pruva-results/.docker-bind-regression
probe_image="${PRUVA_DIND_PROBE_IMAGE:-python:3.13-alpine}"
docker rm -f pruva-net-server >/dev/null 2>&1 || true
docker network rm pruva-net-probe >/dev/null 2>&1 || true
rm -rf "$base"
mkdir -p "$base/dir" "$base/writeback"
cleanup() {
  docker rm -f pruva-net-server >/dev/null 2>&1 || true
  docker network rm pruva-net-probe >/dev/null 2>&1 || true
  rm -rf "$base"
}
trap cleanup EXIT

printf "pruva-file-bind\n" >"$base/file.txt"
printf "pruva-dir-bind\n" >"$base/dir/nested.txt"

docker run --rm -v "$base/file.txt:/probe/file.txt:ro" alpine:3.20 sh -ceu "
  test -f /probe/file.txt
  grep -qx pruva-file-bind /probe/file.txt
"

docker run --rm -v "$base/dir:/probe/dir:ro" alpine:3.20 sh -ceu "
  test -d /probe/dir
  test -f /probe/dir/nested.txt
  grep -qx pruva-dir-bind /probe/dir/nested.txt
"

docker run --rm -v "$base/writeback:/probe/writeback" alpine:3.20 sh -ceu "
  printf pruva-writeback >/probe/writeback/container-created.txt
"
test -f "$base/writeback/container-created.txt"
grep -qx pruva-writeback "$base/writeback/container-created.txt"

cat >"$base/server.py" <<\PY
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        return


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY

docker network create pruva-net-probe >/dev/null
bridge_name="$(docker network inspect pruva-net-probe -f "{{ index .Options \"com.docker.network.bridge.name\" }}" 2>/dev/null || true)"
if [ -z "$bridge_name" ] || [ "$bridge_name" = "<no value>" ]; then
  bridge_id="$(docker network inspect pruva-net-probe -f "{{ .Id }}" | cut -c1-12)"
  bridge_name="br-$bridge_id"
fi
echo "DIND_PROBE_BRIDGE=$bridge_name"

docker run -d --name pruva-net-server --network pruva-net-probe -v "$base/server.py:/server.py:ro" "$probe_image" python /server.py >/dev/null

if ! has_docker_rules iptables; then
  echo "ERROR: active iptables backend lacks Docker rules" >&2
  $SUDO iptables -S >&2 || true
  exit 2
fi

if ! rules_for_bridge iptables "$bridge_name"; then
  echo "ERROR: active iptables backend lacks rules for probe bridge $bridge_name" >&2
  $SUDO iptables -S >&2 || true
  exit 2
fi

inactive_policy="$(forward_policy "$inactive_cmd" || true)"
if [ "$inactive_policy" = "DROP" ] && ! rules_for_bridge "$inactive_cmd" "$bridge_name"; then
  echo "ERROR: inactive $inactive_cmd backend has stale FORWARD DROP without rules for probe bridge $bridge_name" >&2
  $SUDO "$inactive_cmd" -S FORWARD >&2 || true
  exit 2
fi

net_ok=false
for i in $(seq 1 30); do
  if docker run -i --rm --network pruva-net-probe "$probe_image" python - <<\PY
import socket
import urllib.request

socket.gethostbyname("pruva-net-server")
body = urllib.request.urlopen("http://pruva-net-server:8080/", timeout=3).read().decode()
if body != "ok":
    raise SystemExit(f"unexpected body: {body!r}")
PY
  then
    net_ok=true
    break
  fi
  sleep 1
done
if [ "$net_ok" != "true" ]; then
  echo "ERROR: container-to-container DNS/TCP probe failed" >&2
  exit 1
fi

echo "DIND_IPTABLES_CONTRACT_OK"
echo "DIND_BIND_CONTRACT_OK"
echo "DIND_NET_CONTRACT_OK"'
  printf -v quoted_script "%q" "$remote_script"
  gh codespace ssh --codespace "$codespace" "bash -lc ${quoted_script}"
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
command -v docker >/dev/null
if [ -n \"\${DOCKER_API_VERSION:-}\" ]; then
  echo \"ERROR: DOCKER_API_VERSION must not be pinned; found \$DOCKER_API_VERSION\" >&2
  exit 2
fi
echo '== sandbox =='
cat /etc/pruva-sandbox-version"
  printf -v quoted_script "%q" "$remote_script"
  gh codespace ssh --codespace "$codespace" "bash -lc ${quoted_script}"
}

verify_post_create_result() {
  local codespace="$1"
  local repro_id="$2"
  local min_epoch="$3"
  local logs
  logs=$(mktemp)

  if ! gh codespace logs --codespace "$codespace" >"$logs"; then
    rm -f "$logs"
    log "Could not fetch Codespace logs for ${codespace}; checking Pruva result files"
    verify_remote_pruva_result "$codespace" "$repro_id" "$min_epoch"
    return
  fi

  if ! grep -q "$repro_id" "$logs"; then
    rm -f "$logs"
    log "postCreateCommand logs did not mention ${repro_id}; checking Pruva result files"
    verify_remote_pruva_result "$codespace" "$repro_id" "$min_epoch"
    return
  fi

  if grep -q "VERIFICATION SUCCESSFUL" "$logs"; then
    rm -f "$logs"
    verify_remote_pruva_result "$codespace" "$repro_id" "$min_epoch"
    return
  fi

  if grep -q "VERIFICATION FAILED" "$logs"; then
    cat "$logs" >&2 || true
    rm -f "$logs"
    fail "postCreateCommand pruva-verify failed for ${repro_id}"
    return 1
  fi

  rm -f "$logs"
  log "postCreateCommand logs did not include a terminal pruva-verify result for ${repro_id}; checking Pruva result files"
  verify_remote_pruva_result "$codespace" "$repro_id" "$min_epoch"
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
      local created_epoch
      if ! created_epoch=$(codespace_created_epoch "$codespace_name"); then
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
      if ! wait_for_codespace_ssh "$codespace_name"; then
        gh codespace logs --codespace "$codespace_name" || true
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
      if ! wait_for_codespace_post_create "$codespace_name" "$repro_id" "$created_epoch"; then
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
      log "Checking Docker runtime contract in ${codespace_name}"
      if ! check_docker_runtime_contract_in_codespace "$codespace_name"; then
        gh codespace logs --codespace "$codespace_name" || true
        delete_codespace "$codespace_name"
        rm -f "$output_file"
        return 1
      fi
      log "Checking postCreateCommand pruva-verify result in ${codespace_name}"
      if ! verify_post_create_result "$codespace_name" "$repro_id" "$created_epoch"; then
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

run_parallel_repros() {
  local run_dir
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pruva-codespaces-gh.XXXXXX")
  log "Running ${#REPRO_IDS[@]} repro(s) with max parallel ${MAX_PARALLEL}"
  log "Per-repro logs: ${run_dir}"

  local -A pid_to_repro=()
  local -A pid_to_log=()
  local passed=0
  local failed=0
  local index=0

  start_child() {
    local repro_id="$1"
    local log_file="${run_dir}/${repro_id}.log"
    local cmd=(
      "$SCRIPT_PATH"
      --repro-id "$repro_id"
      --repo "$REPO"
      --api-url "$API_URL"
      --idle-timeout "$IDLE_TIMEOUT"
      --retention "$RETENTION_PERIOD"
      --create-timeout "$CREATE_TIMEOUT"
      --ssh-timeout "$SSH_TIMEOUT"
      --mode "$MODE"
      --max-parallel 1
    )
    [[ -n "$MACHINE" ]] && cmd+=(--machine "$MACHINE")
    [[ -n "$LOCATION" ]] && cmd+=(--location "$LOCATION")
    [[ "$KEEP" == "true" ]] && cmd+=(--keep)

    log "START ${repro_id}"
    "${cmd[@]}" >"$log_file" 2>&1 &
    local pid=$!
    PARALLEL_PIDS+=("$pid")
    pid_to_repro["$pid"]="$repro_id"
    pid_to_log["$pid"]="$log_file"
  }

  finish_child() {
    local finished_pid rc repro_id log_file
    set +e
    wait -n -p finished_pid
    rc=$?
    set -e

    repro_id="${pid_to_repro[$finished_pid]:-unknown}"
    log_file="${pid_to_log[$finished_pid]:-${run_dir}/${repro_id}.log}"
    unset 'pid_to_repro[$finished_pid]'
    unset 'pid_to_log[$finished_pid]'

    local remaining=()
    local pid
    for pid in "${PARALLEL_PIDS[@]}"; do
      [[ "$pid" != "$finished_pid" ]] && remaining+=("$pid")
    done
    PARALLEL_PIDS=("${remaining[@]}")

    if [[ $rc -eq 0 ]]; then
      passed=$((passed + 1))
      log "PASS ${repro_id}"
    else
      failed=$((failed + 1))
      fail "FAIL ${repro_id} (exit ${rc}); log: ${log_file}"
      tail -120 "$log_file" >&2 || true
    fi
  }

  while [[ $index -lt ${#REPRO_IDS[@]} || ${#pid_to_repro[@]} -gt 0 ]]; do
    while [[ $index -lt ${#REPRO_IDS[@]} && ${#pid_to_repro[@]} -lt $MAX_PARALLEL ]]; do
      start_child "${REPRO_IDS[$index]}"
      index=$((index + 1))
    done

    if [[ ${#pid_to_repro[@]} -gt 0 ]]; then
      finish_child
    fi
  done

  log "Summary: ${passed} passed, ${failed} failed"
  if [[ $failed -gt 0 ]]; then
    return 1
  fi
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
    --max-parallel)
      MAX_PARALLEL="$2"
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

if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [[ "$MAX_PARALLEL" -lt 1 ]]; then
  fail "Invalid --max-parallel '${MAX_PARALLEL}' (expected positive integer)"
  exit 1
fi

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
log "Max parallel: ${MAX_PARALLEL}"
log "Keep Codespaces: ${KEEP}"

if [[ "$MAX_PARALLEL" -gt 1 && ${#REPRO_IDS[@]} -gt 1 ]]; then
  run_parallel_repros
  exit $?
fi

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
