# Test Coverage Analysis

## Current State

### What Exists Today

The codebase has **zero unit tests**. All existing test infrastructure is integration/E2E-level:

| File | Type | What It Tests |
|------|------|---------------|
| `scripts/test_codespaces_modal.py` | Integration | Runs `pruva-verify` end-to-end inside Modal sandboxes |
| `scripts/test-codespaces.sh` | Integration | Validates repro branch configuration and API connectivity |
| `scripts/detect-missing-deps.sh` | Utility | Analyzes failure logs (no tests for itself) |
| `scripts/generate-codespace-url.sh` | Utility | Generates URLs (no tests for itself) |
| `.github/workflows/test-codespaces.yml` | CI | Orchestrates Docker-based E2E runs |

There is **no test framework configured** (no pytest, no bats, no shunit2), **no coverage tooling**, and **no unit tests for any individual function or script**.

---

## Coverage Gaps and Proposals

### 1. `pruva-verify` — Core CLI (Critical Priority)

The main 412-line bash script contains multiple independently testable functions and code paths, none of which are unit-tested.

**Functions/logic needing tests:**

| Function/Logic | Lines | Risk | What to Test |
|----------------|-------|------|--------------|
| `resolve_repro_id()` | 85-112 | High | Regex matching for REPRO-/GHSA-/CVE- formats, invalid input rejection |
| `check_deps()` | 115-126 | Medium | Missing dependency detection, correct error messages |
| Input format validation | 88, 91, 99, 107-110 | High | All valid/invalid ID patterns: `REPRO-2026-00006`, `GHSA-655q-fx9r-782v`, `CVE-2025-1716`, garbage input |
| Artifact path normalization | 234-238 | High | `bundle/` prefix stripping, nested paths, edge cases |
| Script artifact selection (jq) | 195-202 | High | `reproduction_script` field present vs absent, `repro/` prefix priority, fallback to largest |
| Path rewriting (`BASE_DIR` substitution) | 310-317 | Medium | Hardcoded path replacement in scripts, edge cases with special characters in paths |
| Patch application logic | 266-305 | Medium | Local patch found, GitHub fallback, already-applied patch, no patch available |
| Results directory selection | 29-38 | Medium | `PRUVA_RESULTS_DIR` override, Codespaces detection, default `$HOME` fallback |
| Cleanup trap behavior | 184-191 | Low | `KEEP_DIR=1` preserves dir, `KEEP_DIR=0` removes it |
| Auto-confirm logic | 328-337 | Low | `CODESPACES=true`, `PRUVA_SANDBOX=true`, interactive TTY |

**Recommended approach:** Use [bats-core](https://github.com/bats-core/bats-core) (Bash Automated Testing System) to test the bash functions in isolation. Refactor `pruva-verify` to source its functions from a library file that can be tested independently.

**Example test cases:**
```bash
@test "resolve_repro_id accepts valid REPRO ID" {
  run resolve_repro_id "REPRO-2026-00006"
  [ "$output" = "REPRO-2026-00006" ]
}

@test "resolve_repro_id rejects invalid input" {
  run resolve_repro_id "INVALID-123"
  [ "$status" -eq 1 ]
}

@test "bundle prefix is stripped from artifact path" {
  local_path="bundle/repro/exploit.sh"
  result="${local_path#bundle/}"
  [ "$result" = "repro/exploit.sh" ]
}
```

---

### 2. `scripts/detect-missing-deps.sh` — Dependency Detection (High Priority)

This 226-line script has rich parsing logic with 40+ command-to-apt mappings and 20+ Python module-to-pip mappings, but **no tests at all**.

**What to test:**

| Logic | What to Test |
|-------|--------------|
| "command not found" parsing | `bash: go: command not found` → detects `go`, suggests `golang` |
| Python module detection | `No module named 'yaml'` → suggests `pyyaml` |
| Node.js module detection | `Cannot find module 'express'` → suggests `express` |
| Shared library detection | `libssl.so.1.1: cannot open shared object file` → detects it |
| `/usr/bin/env` pattern | `/usr/bin/env: 'ruby': No such file or directory` → detects `ruby` |
| JSON output mode | `--json` flag produces valid JSON with correct structure |
| Deduplication | Multiple occurrences of same missing dep → single entry |
| No-deps-found case | Clean log → "No missing dependencies detected" |
| Edge cases | Empty log file, binary garbage, partial lines |

**Recommended approach:** Use bats-core with fixture log files containing known error patterns.

---

### 3. `scripts/generate-codespace-url.sh` — URL Generation (Medium Priority)

Small script but has regex validation and URL formatting that should be verified.

**What to test:**

| Logic | What to Test |
|-------|--------------|
| ID format validation regex | REPRO-YYYY-NNNNN, GHSA-xxxx-xxxx-xxxx, CVE-YYYY-NNNNN all accepted |
| Invalid formats rejected | Random strings, partial matches, SQL injection attempts |
| URL format | Output contains correct Codespaces URL with `ref=repro/<REPRO_ID>` |
| Markdown badge | Output contains valid markdown image link |

---

### 4. `scripts/test_codespaces_modal.py` — Modal Test Runner (Medium Priority)

The Python test runner itself has no tests, and its helper functions have testable pure logic.

**What to test:**

| Function | What to Test |
|----------|--------------|
| `_load_local_patch()` | Returns patch content when file exists, empty string when not |
| Missing deps extraction (lines 207-222) | "command not found" regex, Python module regex, npm module regex, deduplication |
| `fetch_latest_repro_ids()` | Correct URL construction, response parsing (mock the HTTP call) |
| `fetch_repro_ids_from_branches()` | Git branch parsing, REPRO ID extraction from branch names |
| `print_results()` | Correct pass/fail/error counts, output formatting |
| Proxy tunnel socket creation | CONNECT request format, auth header inclusion, error handling |

**Recommended approach:** Use pytest with unittest.mock for HTTP/subprocess calls.

---

### 5. `scripts/sandbox_shell.py` — Interactive Shell (Low Priority)

Mostly interactive I/O, but `run_cmd()` and the proxy tunnel setup could be tested.

---

### 6. GitHub Actions Workflows (Low Priority — test indirectly)

The workflow YAML files contain bash logic in `run:` blocks (matrix building, dependency analysis, issue creation). These are best validated by:
- Shellcheck linting
- Extracting complex bash into standalone scripts that can be tested

---

## Recommended Test Infrastructure

### 1. Add bats-core for Bash Tests

```
tests/
├── test_pruva_verify.bats         # Unit tests for pruva-verify functions
├── test_detect_missing_deps.bats  # Tests for dependency detection
├── test_generate_url.bats         # Tests for URL generation
└── fixtures/
    ├── log_missing_apt.txt        # Fixture: log with missing apt packages
    ├── log_missing_pip.txt        # Fixture: log with missing Python modules
    ├── log_missing_npm.txt        # Fixture: log with missing npm packages
    ├── log_clean.txt              # Fixture: successful run log
    └── metadata_sample.json       # Fixture: sample API response
```

### 2. Add pytest for Python Tests

```
tests/
├── test_modal_runner.py           # Tests for test_codespaces_modal.py helpers
├── test_sandbox_shell.py          # Tests for sandbox_shell.py helpers
└── conftest.py                    # Shared fixtures
```

### 3. Add a CI Job for Unit Tests

Add a new job to the existing workflow or a new workflow:

```yaml
unit-tests:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Install bats
      run: |
        git clone https://github.com/bats-core/bats-core.git /tmp/bats
        /tmp/bats/install.sh /usr/local
    - name: Run bash tests
      run: bats tests/*.bats
    - name: Install Python deps
      run: pip install pytest
    - name: Run Python tests
      run: pytest tests/ -v
```

### 4. Add ShellCheck Linting

All bash scripts should pass ShellCheck. Add to CI:

```yaml
- name: ShellCheck
  run: shellcheck pruva-verify scripts/*.sh
```

---

## Priority Summary

| Priority | Area | Impact | Effort |
|----------|------|--------|--------|
| **P0** | `pruva-verify` input validation & ID resolution | Prevents silent failures on bad input | Low |
| **P0** | `pruva-verify` artifact path normalization | Incorrect paths = broken reproductions | Low |
| **P1** | `detect-missing-deps.sh` parsing logic | Wrong suggestions mislead users | Low |
| **P1** | `pruva-verify` script artifact selection (jq) | Wrong script selected = wrong repro runs | Medium |
| **P1** | `pruva-verify` patch application logic | Patches not applied = known-broken repros fail | Medium |
| **P2** | `test_codespaces_modal.py` helper functions | Test runner itself could have bugs | Medium |
| **P2** | `generate-codespace-url.sh` validation | Bad URLs = broken Codespace links | Low |
| **P2** | ShellCheck linting across all scripts | Catches common bash pitfalls | Low |
| **P3** | `sandbox_shell.py` helpers | Interactive tool, lower blast radius | Low |
| **P3** | CI workflow bash logic extraction | Complex inline bash is fragile | High |
