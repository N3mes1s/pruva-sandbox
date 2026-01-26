# Pruva Sandbox

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/N3mes1s/pruva-sandbox)

Isolated environment for running Pruva vulnerability reproductions via GitHub Codespaces.

## How It Works

1. Open a Codespace with a `REPRO_ID` environment variable
2. The reproduction runs automatically on startup
3. The `pruva-verify` CLI handles downloading and executing the script

## Quick Start

Click "Open in Codespaces" on any reproduction at [pruva.dev](https://pruva.dev/reproductions).

Or use a direct URL with any reproduction ID:

```
https://codespaces.new/N3mes1s/pruva-sandbox?env[REPRO_ID]=REPRO-2026-00006
```

## Install pruva-verify Locally

```bash
curl -fsSL https://pruva.dev/install.sh | sh
```

Or download directly:

```bash
curl -fsSL https://raw.githubusercontent.com/N3mes1s/pruva-sandbox/main/pruva-verify -o ~/.local/bin/pruva-verify
chmod +x ~/.local/bin/pruva-verify
```

## Usage

```bash
pruva-verify REPRO-2026-00006
pruva-verify GHSA-655q-fx9r-782v
pruva-verify CVE-2025-1716
```

## Advanced: Docker-in-Docker for Special Cases

Some reproductions require specific OS versions, library versions, or network isolation that the standard sandbox doesn't provide. For these cases, use Docker-in-Docker:

```bash
#!/bin/bash
# Use a specific sandbox version for reproducibility
SANDBOX_IMAGE="${PRUVA_SANDBOX_IMAGE:-ghcr.io/n3mes1s/pruva-sandbox:2025.01.26}"

docker run --rm -v "$PWD:/work" -w /work "$SANDBOX_IMAGE" bash -c '
  pip install vulnerable-lib==1.2.3
  python exploit.py
'
```

**When to use Docker-in-Docker:**
- Kernel vulnerabilities requiring specific kernel versions
- Library vulnerabilities requiring exact vulnerable versions
- Network isolation for simulating attack scenarios
- Reproductions that modify system-level configurations

**Note:** The standard sandbox (Codespaces or local) is preferred for most cases. Only use Docker-in-Docker when the reproduction explicitly requires environment isolation.

## Security

- Reproductions run in isolated Codespace containers
- Scripts are fetched from the official Pruva API
- Each reproduction exploits a real vulnerability - review before running

## Links

- [Browse Reproductions](https://pruva.dev/reproductions)
- [API Documentation](https://pruva.dev/llms.txt)
- [Pruva Main Repository](https://github.com/N3mes1s/pruva)
