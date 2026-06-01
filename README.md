# Pruva Sandbox

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/N3mes1s/pruva-sandbox)

Isolated environment for running [Pruva](https://pruva.dev) vulnerability reproductions via GitHub Codespaces.

## How It Works

1. Open a Codespace from a `repro/<REPRO_ID>` branch
2. The `pruva-verify` CLI fetches the reproduction metadata and script from the Pruva API
3. The script runs automatically inside the sandboxed container
4. Results are reported with pass/fail status, timing, and logs

## Quick Start

Click "Open in Codespaces" on any reproduction at [pruva.dev](https://pruva.dev/reproductions).

Or use a direct URL with any reproduction ID:

```
https://github.com/codespaces/new?hide_repo_select=true&ref=repro/REPRO-2026-00006&repo=N3mes1s/pruva-sandbox
```

## Install `pruva-verify` Locally

### Pre-built binary (recommended)

Download the latest release for your platform:

```bash
# Linux x86_64
curl -fsSL https://github.com/N3mes1s/pruva-sandbox/releases/latest/download/pruva-verify-x86_64-unknown-linux-gnu \
  -o ~/.local/bin/pruva-verify && chmod +x ~/.local/bin/pruva-verify

# Linux aarch64
curl -fsSL https://github.com/N3mes1s/pruva-sandbox/releases/latest/download/pruva-verify-aarch64-unknown-linux-gnu \
  -o ~/.local/bin/pruva-verify && chmod +x ~/.local/bin/pruva-verify
```

### Install script

```bash
curl -fsSL https://pruva.dev/install.sh | sh
```

### Build from source

Requires Rust 1.70+:

```bash
cd pruva-verify-rs
cargo build --release
cp target/release/pruva-verify ~/.local/bin/
```

## Usage

```bash
# By reproduction ID
pruva-verify REPRO-2026-00006

# By GHSA ID
pruva-verify GHSA-655q-fx9r-782v

# By CVE ID
pruva-verify CVE-2025-1716
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PRUVA_API_URL` | `https://api.pruva.dev/v1` | API base URL |
| `PRUVA_KEEP_DIR` | `1` | Set to `0` to delete the work directory after verification |
| `PRUVA_RESULTS_DIR` | `$HOME/pruva-results` | Override the results directory |
| `PRUVA_SANDBOX` | — | Set to `true` to skip interactive confirmation |

## Project Structure

```
.
├── pruva-verify                # Legacy bash CLI (kept as fallback)
├── pruva-verify-rs/            # Rust rewrite of pruva-verify
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs             # CLI entry point and orchestration
│       ├── resolve.rs          # Input ID parsing (REPRO/GHSA/CVE)
│       ├── metadata.rs         # API metadata, script selection, artifact listing
│       ├── artifacts.rs        # Downloading, path normalization, permissions
│       ├── patch.rs            # Local + GitHub patch application
│       ├── rewrite.rs          # BASE_DIR path substitution
│       ├── runner.rs           # Script execution and result reporting
│       ├── display.rs          # Colored terminal output
│       └── env.rs              # Sandbox detection, results dir, confirmation
├── .devcontainer/
│   ├── Dockerfile              # Pre-built sandbox image
│   └── devcontainer.json       # Codespace configuration
├── docs/
│   └── PRODUCTION.md           # Public production contract and gates
├── repro-patches/              # Known-issue patches for specific reproductions
├── scripts/
│   ├── test-codespaces.sh      # Branch validation (devcontainer, API, artifacts)
│   ├── test_codespaces_modal.py# Full E2E tests via Modal sandboxes
│   ├── test-production-parity.sh# pruva/Codespaces/Modal sandbox parity gate
│   ├── detect-missing-deps.sh  # Failure log analysis for missing packages
│   ├── generate-codespace-url.sh
│   └── sandbox_shell.py        # Interactive Modal sandbox shell
└── .github/workflows/
    ├── rust-ci.yml             # Rust tests, fmt, clippy on PRs
    ├── release-binary.yml      # Cross-compile + GitHub Release on tags
    ├── build-devcontainer.yml  # Docker image build and push to GHCR
    ├── test-codespaces.yml     # Branch, optional container, and real Codespaces checks
    └── scan-new-repros.yml     # Discover and test new reproductions
```

## Development

### Running Rust tests

```bash
cd pruva-verify-rs
cargo test
```

The test suite covers input validation, artifact path normalization, script selection logic, patch application, path rewriting, and script execution.

### Running integration tests

```bash
# Validate repro branch configuration against the API
./scripts/test-codespaces.sh --latest 10

# Real GitHub Codespaces smoke test, matching the web UI creation path.
./scripts/test-codespaces-gh.sh --repro-id REPRO-2026-00185

# Full Codespaces execution check through gh's SSH transport.
./scripts/test-codespaces-gh.sh --repro-id REPRO-2026-00185 --mode verify

# Latest-N real Codespaces execution with bounded parallelism.
./scripts/test-codespaces-gh.sh --latest 20 --mode verify --max-parallel 3

# Optional raw-container smoke test in CI. This does not apply devcontainer
# features such as docker-outside-of-docker or sshd.
gh workflow run test-codespaces.yml -f latest_count=20 -f container_smoke=true

# Real Codespaces test in CI. Configure a CODESPACES_PAT repository secret with
# Codespaces scope first.
gh workflow run test-codespaces.yml -f latest_count=20 -f codespaces_mode=verify

# Full E2E test via Modal (requires MODAL_TOKEN_ID/MODAL_TOKEN_SECRET)
uv run python scripts/test_codespaces_modal.py --latest 5

# Development only: test local pruva-verify changes before publishing an image.
# Production checks leave this off and use the binary already in the image.
uv run python scripts/test_codespaces_modal.py --latest 5 --inject-verify

# Reuse expensive setup artifacts for long repro reruns.
# The final vulnerability checks still run fresh every time.
uv run python scripts/test_codespaces_modal.py \
  --repro-ids REPRO-2026-00185,REPRO-2026-00183,REPRO-2026-00172 \
  --cache-volume pruva-repro-cache \
  --max-parallel 2

# Test an immutable production candidate image
PRUVA_SANDBOX_IMAGE='ghcr.io/n3mes1s/pruva-sandbox@sha256:<digest>' \
  uv run python scripts/test_codespaces_modal.py --latest 20

# Production parity gate: checks pruva's pinned worker image contract,
# latest-20 Codespaces readiness, and Modal smoke when credentials are present.
./scripts/test-production-parity.sh

# Production parity gate including real Codespaces startup verification.
./scripts/test-production-parity.sh \
  --real-codespaces \
  --codespaces-mode verify \
  --codespaces-max-parallel 3

# Require Modal for the production gate.
./scripts/test-production-parity.sh --require-modal --modal-repro-ids REPRO-2026-00185

# Require Modal and reuse setup cache for long repro reruns.
./scripts/test-production-parity.sh \
  --require-modal \
  --modal-repro-ids REPRO-2026-00185,REPRO-2026-00183,REPRO-2026-00172 \
  --modal-cache-volume pruva-repro-cache
```

### Releasing a new binary

Tag a version to trigger the release workflow:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This cross-compiles binaries for `x86_64` and `aarch64` Linux and uploads them to the GitHub Release. The devcontainer image builds `pruva-verify` from the same checked-out source commit, so Codespaces and the `pruva-rs` worker image do not depend on a separate release being published first.

## Docker-in-Docker for Special Cases

Some reproductions require specific OS versions, library versions, or network isolation. For these, use Docker-in-Docker:

```bash
SANDBOX_IMAGE="${PRUVA_SANDBOX_IMAGE:-ghcr.io/n3mes1s/pruva-sandbox@sha256:1aca6eb86791c66bb964b421dad5de27d5482953916280ee400fba160f87f374}"

docker run --rm \
  -e PRUVA_SANDBOX=true \
  -e REPRO_ID=REPRO-2026-00006 \
  "$SANDBOX_IMAGE" \
  pruva-verify REPRO-2026-00006
```

**When to use Docker-in-Docker:**
- Kernel vulnerabilities requiring specific kernel versions
- Library vulnerabilities requiring exact vulnerable versions
- Network isolation for simulating attack scenarios
- Reproductions that modify system-level configurations

## Security

- Reproductions run in isolated Codespace containers
- Scripts are fetched from the official Pruva API
- Each reproduction exploits a real vulnerability — review before running locally

## Links

- [Browse Reproductions](https://pruva.dev/reproductions)
- [API Documentation](https://pruva.dev/llms.txt)
- [Pruva Main Repository](https://github.com/N3mes1s/pruva)
