#!/usr/bin/env bash
#
# test-codespaces.sh - Validate that repro branches are correctly configured
#                      and their reproduction scripts are downloadable from the Pruva API.
#
# This simulates what happens when a Codespace starts:
#   1. devcontainer.json is read for REPRO_ID
#   2. pruva-verify fetches metadata from the API
#   3. The reproduction script is downloaded
#
# Usage:
#   ./scripts/test-codespaces.sh                    # Test latest 10 branches
#   ./scripts/test-codespaces.sh --latest 20        # Test latest 20 branches
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

API_URL="${PRUVA_API_URL:-https://pruva-api-production.up.railway.app/v1}"
LATEST=10
TEST_ALL=false
SINGLE_BRANCH=""
DOWNLOAD_SCRIPT=true

usage() {
  cat <<EOF
${BOLD}test-codespaces.sh${NC} - Validate Codespace readiness for repro branches

${BOLD}USAGE:${NC}
    ./scripts/test-codespaces.sh [OPTIONS]

${BOLD}OPTIONS:${NC}
    --latest N         Test the N most recent repro branches (default: 10)
    --all              Test ALL repro branches
    --branch NAME      Test a single branch (e.g. repro/REPRO-2026-00105)
    --no-download      Skip downloading the reproduction script (metadata only)
    --api-url URL      Override the Pruva API URL
    -h, --help         Show this help message

${BOLD}WHAT IT VALIDATES:${NC}
    1. Branch has a valid devcontainer.json
    2. devcontainer.json contains a non-empty REPRO_ID
    3. REPRO_ID in devcontainer.json matches the branch name
    4. Pruva API returns metadata for the REPRO_ID
    5. Metadata contains a reproduction_script artifact
    6. The reproduction script is downloadable and non-empty
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest)
      LATEST="$2"
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

  # Step 7: Check metadata has required fields
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

  # Step 8: Find the reproduction script artifact
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

  # Step 9: Download the reproduction script
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
echo -e "  Download scripts: ${DOWNLOAD_SCRIPT}"
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
  # Latest N repro branches
  while IFS= read -r b; do
    BRANCHES+=("$(echo "$b" | xargs)")
  done < <(git branch -r --sort=-committerdate | grep 'origin/repro/' | head -n "$LATEST" | xargs -n1)
fi

if [[ ${#BRANCHES[@]} -eq 0 ]]; then
  log "No repro branches found to test."
  exit 1
fi

log "Testing ${#BRANCHES[@]} branch(es)..."

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
