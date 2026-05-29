#!/bin/bash
# Generate a Codespace URL for a reproduction branch.
# Usage: ./scripts/generate-codespace-url.sh REPRO-2026-00001

set -euo pipefail

REPRO_ID="${1:-}"

if [ -z "$REPRO_ID" ]; then
  echo "Usage: $0 REPRO-YYYY-NNNNN"
  exit 1
fi

# Validate format (supports REPRO, GHSA, CVE formats)
if [[ ! "$REPRO_ID" =~ ^(REPRO-[0-9]{4}-[0-9]+|GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}|CVE-[0-9]{4}-[0-9]+)$ ]]; then
  echo "Error: Invalid ID format. Expected: REPRO-YYYY-NNNNN, GHSA-xxxx-xxxx-xxxx, or CVE-YYYY-NNNNN"
  exit 1
fi

echo ""
echo "Codespace URL for $REPRO_ID:"
echo "https://github.com/codespaces/new?hide_repo_select=true&ref=repro/$REPRO_ID&repo=N3mes1s/pruva-sandbox"
echo ""
echo "Markdown badge:"
echo "[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new?hide_repo_select=true&ref=repro/$REPRO_ID&repo=N3mes1s/pruva-sandbox)"
