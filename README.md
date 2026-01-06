# Pruva Sandbox

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/N3mes1s/pruva-sandbox)

Isolated environment for running Pruva vulnerability reproductions via GitHub Codespaces.

## How It Works

1. Each reproduction has a branch named `repro/REPRO-YYYY-NNNNN`
2. Opening a Codespace on that branch automatically runs the reproduction
3. The `pruva-verify` CLI handles downloading and executing the script

## Quick Start

Click "Open in Codespaces" on any reproduction at [pruva.dev](https://pruva.dev/reproductions).

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

## Security

- Reproductions run in isolated Codespace containers
- Scripts are fetched from the official Pruva API
- Each reproduction exploits a real vulnerability - review before running

## Links

- [Browse Reproductions](https://pruva.dev/reproductions)
- [API Documentation](https://pruva.dev/llms.txt)
- [Pruva Main Repository](https://github.com/N3mes1s/pruva)
