#!/usr/bin/env bash
#
# test-codespaces.sh - Validate that repro branches are correctly configured
#                      and their reproduction scripts are downloadable from the Pruva API.
#
# This simulates what happens when a Codespace starts:
#   1. devcontainer.json is read for REPRO_ID
#   2. devcontainer image is checked against API sandbox metadata, when present
#   3. pruva-verify fetches metadata from the API
#   4. The reproduction script is downloaded
#
# Usage:
#   ./scripts/test-codespaces.sh                    # Test latest 10 published API reproductions
#   ./scripts/test-codespaces.sh --latest 20        # Test latest 20 published API reproductions
#   ./scripts/test-codespaces.sh --all              # Test ALL repro branches
#   ./scripts/test-codespaces.sh --branch repro/REPRO-2026-00105  # Test one branch
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

API_URL="${PRUVA_API_URL:-https://api.pruva.dev/v1}"
DEFAULT_SANDBOX_IMAGE="${PRUVA_SANDBOX_IMAGE:-ghcr.io/n3mes1s/pruva-sandbox@sha256:1aca6eb86791c66bb964b421dad5de27d5482953916280ee400fba160f87f374}"
LATEST=10
LATEST_SOURCE="api"
TEST_ALL=false
SINGLE_BRANCH=""
DOWNLOAD_SCRIPT=true
MAX_PARALLEL="${CODESPACES_READINESS_MAX_PARALLEL:-4}"

usage() {
  cat <<EOF
${BOLD}test-codespaces.sh${NC} - Validate Codespace readiness for repro branches

${BOLD}USAGE:${NC}
    ./scripts/test-codespaces.sh [OPTIONS]

${BOLD}OPTIONS:${NC}
    --latest N         Test the N latest published reproductions from the API (default: 10)
    --branch-latest N  Test the N most recent repro branches by git committer date
    --all              Test ALL repro branches
    --branch NAME      Test a single branch (e.g. repro/REPRO-2026-00105)
    --no-download      Skip downloading the reproduction script (metadata only)
    --api-url URL      Override the Pruva API URL
    --max-parallel N   Validate up to N branches concurrently (default: ${MAX_PARALLEL})
    -h, --help         Show this help message

${BOLD}WHAT IT VALIDATES:${NC}
    1. Branch has a valid devcontainer.json
    2. devcontainer.json contains a non-empty REPRO_ID
    3. REPRO_ID in devcontainer.json matches the branch name
    4. devcontainer image matches metadata.environment.sandbox_image, or the pinned default when metadata is absent
    5. Pruva API returns metadata for the REPRO_ID
    6. Metadata contains a reproduction_script artifact
    7. The reproduction script is downloadable and non-empty
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest)
      LATEST="$2"
      LATEST_SOURCE="api"
      shift 2
      ;;
    --branch-latest)
      LATEST="$2"
      LATEST_SOURCE="branches"
      shift 2
      ;;
    --all)
      TEST_ALL=true
      shift
      ;;
    --branch)
      SINGLE_BRANCH="$2"
      shift 2
      ;;
    --no-download)
      DOWNLOAD_SCRIPT=false
      shift
      ;;
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --max-parallel)
      MAX_PARALLEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [[ "$MAX_PARALLEL" -lt 1 ]]; then
  echo "Invalid --max-parallel '${MAX_PARALLEL}' (expected positive integer)" >&2
  exit 1
fi

# Counters
TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

# Results array for summary
declare -a RESULTS=()

log()     { echo -e "${CYAN}[test]${NC} $*"; }
pass()    { echo -e "${GREEN}  ✓${NC} $*"; }
fail()    { echo -e "${RED}  ✗${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
section() { echo -e "\n${BOLD}$*${NC}"; }

fetch_latest_api_repro_ids() {
  local count="$1"
  local tmp_meta http_code
  tmp_meta=$(mktemp)
  http_code=$(curl -sf -w "%{http_code}" -o "$tmp_meta" "${API_URL}/reproductions?status=published&limit=${count}" 2>/dev/null) || http_code="000"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp_meta"
    echo "Failed to fetch latest reproductions from API (HTTP ${http_code})" >&2
    return 1
  fi
  jq -r '.reproductions[]?.repro_id // empty' "$tmp_meta"
  rm -f "$tmp_meta"
}

# Test a single branch
test_branch() {
  local branch="$1"
  local branch_name="${branch#origin/}"
  local errors=0
  local warnings=0

  section "Testing: ${branch_name}"

  # Step 1: Read devcontainer.json from the branch
  local devcontainer
  devcontainer=$(git show "${branch}:.devcontainer/devcontainer.json" 2>/dev/null) || {
    fail "Cannot read .devcontainer/devcontainer.json from ${branch_name}"
    RESULTS+=("FAIL ${branch_name}: missing devcontainer.json")
    return 1
  }
  pass "devcontainer.json exists"

  # Step 2: Validate JSON
  if ! echo "$devcontainer" | jq empty 2>/dev/null; then
    fail "devcontainer.json is not valid JSON"
    RESULTS+=("FAIL ${branch_name}: invalid JSON in devcontainer.json")
    return 1
  fi
  pass "devcontainer.json is valid JSON"

  # Step 3: Extract REPRO_ID
  local repro_id
  repro_id=$(echo "$devcontainer" | jq -r '.containerEnv.REPRO_ID // empty')
  if [[ -z "$repro_id" ]]; then
    fail "REPRO_ID is empty or missing in containerEnv"
    RESULTS+=("FAIL ${branch_name}: REPRO_ID empty")
    return 1
  fi
  pass "REPRO_ID is set: ${repro_id}"

  # Step 4: Check REPRO_ID matches branch name
  local expected_id="${branch_name#repro/}"
  if [[ "$repro_id" != "$expected_id" ]]; then
    fail "REPRO_ID mismatch: branch says ${expected_id}, devcontainer says ${repro_id}"
    errors=$((errors + 1))
  else
    pass "REPRO_ID matches branch name"
  fi

  # Step 5: Check postCreateCommand references pruva-verify
  local post_create
  post_create=$(echo "$devcontainer" | jq -r '.postCreateCommand // empty')
  if [[ -z "$post_create" ]]; then
    fail "postCreateCommand is missing"
    errors=$((errors + 1))
  elif [[ "$post_create" != *"pruva-verify"* ]]; then
    warn "postCreateCommand does not reference pruva-verify"
    warnings=$((warnings + 1))
  else
    pass "postCreateCommand invokes pruva-verify"
  fi

  # Step 6: Fetch metadata from Pruva API
  local metadata http_code
  local tmp_meta
  tmp_meta=$(mktemp)
  http_code=$(curl -sf -w "%{http_code}" -o "$tmp_meta" "${API_URL}/reproductions/${repro_id}" 2>/dev/null) || http_code="000"
  metadata=$(cat "$tmp_meta" 2>/dev/null || echo "")
  rm -f "$tmp_meta"

  if [[ "$http_code" != "200" ]]; then
    fail "API returned HTTP ${http_code} for ${repro_id}"
    RESULTS+=("FAIL ${branch_name}: API returned ${http_code}")
    return 1
  fi
  pass "API metadata fetched (HTTP 200)"

  # Step 7: Check Codespaces image pinning and parity with reproduction metadata when available
  local devcontainer_api_url devcontainer_image devcontainer_env_image expected_image metadata_image sandbox_version docker_moby docker_compose_mode sshd_version
  devcontainer_api_url=$(echo "$devcontainer" | jq -r '.containerEnv.PRUVA_API_URL // empty')
  devcontainer_image=$(echo "$devcontainer" | jq -r '.image // empty')
  devcontainer_env_image=$(echo "$devcontainer" | jq -r '.containerEnv.PRUVA_SANDBOX_IMAGE // empty')
  metadata_image=$(echo "$metadata" | jq -r '.environment.sandbox_image // empty')
  expected_image="${metadata_image:-$DEFAULT_SANDBOX_IMAGE}"
  sandbox_version=$(echo "$metadata" | jq -r '.environment.sandbox_version // empty')
  docker_moby=$(echo "$devcontainer" | jq -r 'if .features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"].moby == false then "false" elif .features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"].moby == true then "true" else "unset" end')
  docker_compose_mode=$(echo "$devcontainer" | jq -r '.features["ghcr.io/devcontainers/features/docker-outside-of-docker:1"].dockerDashComposeVersion // "unset"')
  sshd_version=$(echo "$devcontainer" | jq -r '.features["ghcr.io/devcontainers/features/sshd:1"].version // empty')

  if [[ "$devcontainer_api_url" != "$API_URL" ]]; then
    fail "PRUVA_API_URL mismatch: devcontainer has '${devcontainer_api_url:-empty}', expected '${API_URL}'"
    errors=$((errors + 1))
  else
    pass "PRUVA_API_URL matches test API"
  fi

  if [[ -z "$devcontainer_image" ]]; then
    fail "Codespaces image is missing"
    errors=$((errors + 1))
  elif [[ "$devcontainer_image" == *":latest" ]]; then
    fail "Codespaces image must be immutable; found '${devcontainer_image}'"
    errors=$((errors + 1))
  elif [[ "$devcontainer_image" != "$expected_image" ]]; then
    fail "Codespaces image mismatch: devcontainer has '${devcontainer_image}', expected '${expected_image}'"
    errors=$((errors + 1))
  else
    if [[ -n "$metadata_image" ]]; then
      pass "Codespaces image matches metadata sandbox_image"
    else
      pass "Codespaces image uses pinned default sandbox image"
    fi
  fi

  if [[ "$devcontainer_env_image" != "$devcontainer_image" ]]; then
    fail "PRUVA_SANDBOX_IMAGE env mismatch: env has '${devcontainer_env_image:-empty}', image has '${devcontainer_image:-empty}'"
    errors=$((errors + 1))
  else
    pass "PRUVA_SANDBOX_IMAGE matches devcontainer image"
  fi

  if [[ "$docker_moby" != "false" ]]; then
    fail "docker-outside-of-docker feature must set moby=false for Codespaces compatibility; found '${docker_moby}'"
    errors=$((errors + 1))
  else
    pass "docker-outside-of-docker moby=false"
  fi

  if [[ "$docker_compose_mode" != "none" ]]; then
    fail "docker-outside-of-docker must not install the docker-compose shim; found dockerDashComposeVersion='${docker_compose_mode}'"
    errors=$((errors + 1))
  else
    pass "docker-outside-of-docker docker-compose shim disabled"
  fi

  if [[ "$sshd_version" != "latest" ]]; then
    fail "sshd feature version must be latest; found '${sshd_version:-missing}'"
    errors=$((errors + 1))
  else
    pass "sshd feature enabled"
  fi

  if [[ -z "$metadata_image" && -n "$sandbox_version" ]]; then
    warn "Metadata has sandbox_version=${sandbox_version} but no sandbox_image; using pinned default for this branch"
    warnings=$((warnings + 1))
  fi

  # Step 8: Check metadata has required fields
  local title status
  title=$(echo "$metadata" | jq -r '.title // empty')
  status=$(echo "$metadata" | jq -r '.status // empty')

  if [[ -z "$title" ]]; then
    fail "Metadata missing title"
    errors=$((errors + 1))
  else
    pass "Title: ${title}"
  fi

  if [[ "$status" != "published" ]]; then
    warn "Reproduction status is '${status}' (expected 'published')"
    warnings=$((warnings + 1))
  else
    pass "Status: published"
  fi

  # Step 9: Find the reproduction script artifact
  local script_path
  script_path=$(echo "$metadata" | jq -r '
    if .reproduction_script then
      .reproduction_script
    else
      ([.artifacts[] | select(.category == "reproduction_script" and (.path | startswith("repro/")))] | first | .path) //
      ([.artifacts[] | select(.category == "reproduction_script")] | sort_by(.size) | last | .path)
    end // empty
  ')

  if [[ -z "$script_path" ]]; then
    fail "No reproduction_script artifact found in metadata"
    RESULTS+=("FAIL ${branch_name}: no reproduction script")
    return 1
  fi
  pass "Reproduction script: ${script_path}"

  # Step 10: Download the reproduction script
  if [[ "$DOWNLOAD_SCRIPT" == "true" ]]; then
    local script_url="${API_URL}/reproductions/${repro_id}/artifacts/${script_path}"
    local tmp_script
    tmp_script=$(mktemp)
    local dl_code
    dl_code=$(curl -sf -w "%{http_code}" -o "$tmp_script" "$script_url" 2>/dev/null) || dl_code="000"
    local script_size
    script_size=$(wc -c < "$tmp_script" 2>/dev/null || echo "0")
    rm -f "$tmp_script"

    if [[ "$dl_code" != "200" ]]; then
      fail "Script download failed (HTTP ${dl_code})"
      errors=$((errors + 1))
    elif [[ "$script_size" -lt 10 ]]; then
      fail "Downloaded script is empty or too small (${script_size} bytes)"
      errors=$((errors + 1))
    else
      pass "Script downloaded successfully (${script_size} bytes)"
    fi
  fi

  # Final verdict
  if [[ $errors -gt 0 ]]; then
    RESULTS+=("FAIL ${branch_name}: ${errors} error(s)")
    return 1
  elif [[ $warnings -gt 0 ]]; then
    RESULTS+=("WARN ${branch_name}: ${warnings} warning(s)")
    return 2
  else
    RESULTS+=("PASS ${branch_name}")
    return 0
  fi
}

# Main
echo ""
echo -e "${BOLD}=========================================${NC}"
echo -e "${BOLD}  Codespace Readiness Test${NC}"
echo -e "${BOLD}=========================================${NC}"
echo -e "  API: ${API_URL}"
echo -e "  Default sandbox image: ${DEFAULT_SANDBOX_IMAGE}"
echo -e "  Download scripts: ${DOWNLOAD_SCRIPT}"
echo -e "  Max parallel: ${MAX_PARALLEL}"
if [[ -z "$SINGLE_BRANCH" && "$TEST_ALL" != "true" ]]; then
  echo -e "  Latest source: ${LATEST_SOURCE}"
fi
echo ""

# Collect branches to test
declare -a BRANCHES=()

if [[ -n "$SINGLE_BRANCH" ]]; then
  # Single branch mode
  if [[ "$SINGLE_BRANCH" != origin/* ]]; then
    SINGLE_BRANCH="origin/${SINGLE_BRANCH}"
  fi
  BRANCHES=("$SINGLE_BRANCH")
elif [[ "$TEST_ALL" == "true" ]]; then
  # All repro branches
  while IFS= read -r b; do
    BRANCHES+=("$(echo "$b" | xargs)")
  done < <(git branch -r --sort=-committerdate | grep 'origin/repro/' | xargs -n1)
else
  if [[ "$LATEST_SOURCE" == "api" ]]; then
    while IFS= read -r repro_id; do
      [[ -n "$repro_id" ]] && BRANCHES+=("origin/repro/${repro_id}")
    done < <(fetch_latest_api_repro_ids "$LATEST")
  else
    # Latest N repro branches by branch commit date.
    while IFS= read -r b; do
      BRANCHES+=("$(echo "$b" | xargs)")
    done < <(git branch -r --sort=-committerdate | grep 'origin/repro/' | head -n "$LATEST" | xargs -n1)
  fi
fi

if [[ ${#BRANCHES[@]} -eq 0 ]]; then
  log "No repro branches found to test."
  exit 1
fi

log "Testing ${#BRANCHES[@]} branch(es)..."

run_branches_parallel() {
  local run_dir
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/pruva-codespaces-readiness.XXXXXX")
  log "Running branch checks with max parallel ${MAX_PARALLEL}"
  log "Per-branch logs: ${run_dir}"

  local -A pid_to_branch=()
  local -A pid_to_log=()
  local -A pid_to_result=()
  local -a parallel_pids=()
  local index=0

  start_child() {
    local branch="$1"
    local branch_name="${branch#origin/}"
    local safe_name="${branch_name//\//_}"
    local log_file="${run_dir}/${safe_name}.log"
    local result_file="${run_dir}/${safe_name}.result"

    log "START ${branch_name}"
    (
      set +e
      RESULTS=()
      test_branch "$branch"
      rc=$?
      if [[ ${#RESULTS[@]} -gt 0 ]]; then
        printf '%s\n' "${RESULTS[$((${#RESULTS[@]} - 1))]}" >"$result_file"
      else
        case "$rc" in
          0) printf 'PASS %s\n' "$branch_name" >"$result_file" ;;
          2) printf 'WARN %s\n' "$branch_name" >"$result_file" ;;
          *) printf 'FAIL %s: exit %s\n' "$branch_name" "$rc" >"$result_file" ;;
        esac
      fi
      exit "$rc"
    ) >"$log_file" 2>&1 &

    local pid=$!
    parallel_pids+=("$pid")
    pid_to_branch["$pid"]="$branch_name"
    pid_to_log["$pid"]="$log_file"
    pid_to_result["$pid"]="$result_file"
  }

  finish_child() {
    local finished_pid rc branch_name log_file result_file result
    set +e
    wait -n -p finished_pid
    rc=$?
    set -e

    branch_name="${pid_to_branch[$finished_pid]:-unknown}"
    log_file="${pid_to_log[$finished_pid]:-${run_dir}/${branch_name}.log}"
    result_file="${pid_to_result[$finished_pid]:-${run_dir}/${branch_name}.result}"

    local remaining=()
    local pid
    for pid in "${parallel_pids[@]}"; do
      [[ "$pid" != "$finished_pid" ]] && remaining+=("$pid")
    done
    parallel_pids=("${remaining[@]}")
    unset 'pid_to_branch[$finished_pid]'
    unset 'pid_to_log[$finished_pid]'
    unset 'pid_to_result[$finished_pid]'

    if [[ -f "$result_file" ]]; then
      result="$(cat "$result_file")"
    else
      result="FAIL ${branch_name}: exit ${rc}"
    fi
    RESULTS+=("$result")
    TOTAL=$((TOTAL + 1))

    case "$rc" in
      0)
        PASSED=$((PASSED + 1))
        log "PASS ${branch_name}"
        ;;
      2)
        WARNINGS=$((WARNINGS + 1))
        PASSED=$((PASSED + 1))
        log "WARN ${branch_name}; log: ${log_file}"
        ;;
      *)
        FAILED=$((FAILED + 1))
        fail "FAIL ${branch_name} (exit ${rc}); log: ${log_file}"
        tail -120 "$log_file" >&2 || true
        ;;
    esac
  }

  while [[ $index -lt ${#BRANCHES[@]} || ${#pid_to_branch[@]} -gt 0 ]]; do
    while [[ $index -lt ${#BRANCHES[@]} && ${#pid_to_branch[@]} -lt $MAX_PARALLEL ]]; do
      start_child "${BRANCHES[$index]}"
      index=$((index + 1))
    done

    if [[ ${#pid_to_branch[@]} -gt 0 ]]; then
      finish_child
    fi
  done
}

if [[ "$MAX_PARALLEL" -gt 1 && ${#BRANCHES[@]} -gt 1 ]]; then
  run_branches_parallel
else
  for branch in "${BRANCHES[@]}"; do
  TOTAL=$((TOTAL + 1))
  if test_branch "$branch"; then
    PASSED=$((PASSED + 1))
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      WARNINGS=$((WARNINGS + 1))
      PASSED=$((PASSED + 1))  # warnings still count as passed
    else
      FAILED=$((FAILED + 1))
    fi
  fi
  done
fi

# Summary
echo ""
echo -e "${BOLD}=========================================${NC}"
echo -e "${BOLD}  RESULTS SUMMARY${NC}"
echo -e "${BOLD}=========================================${NC}"
echo ""

for result in "${RESULTS[@]}"; do
  case "$result" in
    PASS*) echo -e "  ${GREEN}✓${NC} ${result#PASS }" ;;
    WARN*) echo -e "  ${YELLOW}⚠${NC} ${result#WARN }" ;;
    FAIL*) echo -e "  ${RED}✗${NC} ${result#FAIL }" ;;
  esac
done

echo ""
echo -e "  ${BOLD}Total:${NC}    ${TOTAL}"
echo -e "  ${GREEN}Passed:${NC}  ${PASSED}"
echo -e "  ${YELLOW}Warnings:${NC} ${WARNINGS}"
echo -e "  ${RED}Failed:${NC}  ${FAILED}"
echo ""

if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}${BOLD}Some branches failed validation.${NC}"
  exit 1
else
  echo -e "${GREEN}${BOLD}All branches passed validation.${NC}"
  exit 0
fi
