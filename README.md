# Pruva Sandbox

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/N3mes1s/pruva-sandbox)

Isolated environment for running [Pruva](https://pruva.dev) vulnerability reproductions via GitHub Codespaces.

## How It Works

1. Open a Codespace with a `REPRO_ID` environment variable
2. The `pruva-verify` CLI fetches the reproduction metadata and script from the Pruva API
3. The script runs automatically inside the sandboxed container
4. Results are reported with pass/fail status, timing, and logs

## Quick Start

Click "Open in Codespaces" on any reproduction at [pruva.dev](https://pruva.dev/reproductions).

Or use a direct URL with any reproduction ID:

```
https://codespaces.new/N3mes1s/pruva-sandbox?env[REPRO_ID]=REPRO-2026-00006
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
| `PRUVA_API_URL` | `https://pruva-api-production.up.railway.app/v1` | API base URL |
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
├── repro-patches/              # Known-issue patches for specific reproductions
├── scripts/
│   ├── test-codespaces.sh      # Branch validation (devcontainer, API, artifacts)
│   ├── test_codespaces_modal.py# Full E2E tests via Modal sandboxes
│   ├── detect-missing-deps.sh  # Failure log analysis for missing packages
│   ├── generate-codespace-url.sh
│   └── sandbox_shell.py        # Interactive Modal sandbox shell
└── .github/workflows/
    ├── rust-ci.yml             # Rust tests, fmt, clippy on PRs
    ├── release-binary.yml      # Cross-compile + GitHub Release on tags
    ├── build-devcontainer.yml  # Docker image build and push to GHCR
    ├── test-codespaces.yml     # E2E reproduction testing in containers
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

# Full E2E test via Modal (requires MODAL_TOKEN_ID/MODAL_TOKEN_SECRET)
python3 scripts/test_codespaces_modal.py --latest 5
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
SANDBOX_IMAGE="${PRUVA_SANDBOX_IMAGE:-ghcr.io/n3mes1s/pruva-sandbox:latest}"

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
