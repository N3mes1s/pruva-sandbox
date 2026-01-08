#!/bin/bash
# Codespace startup script - extracts REPRO_ID from branch name or env var

# First check if REPRO_ID is already set via environment
if [ -n "$REPRO_ID" ]; then
    echo "Running reproduction from REPRO_ID env var: $REPRO_ID"
    pruva-verify "$REPRO_ID"
    exit 0
fi

# Try to extract REPRO_ID from branch name
# Supports formats:
#   repro/REPRO-2026-00045
#   repro/CVE-2025-1234
#   repro/GHSA-xxxx-xxxx-xxxx
BRANCH=$(git branch --show-current 2>/dev/null)

if [[ "$BRANCH" =~ ^repro/(.+)$ ]]; then
    REPRO_ID="${BASH_REMATCH[1]}"
    echo "Running reproduction from branch: $REPRO_ID"
    pruva-verify "$REPRO_ID"
    exit 0
fi

# No REPRO_ID found - show welcome message
echo 'Welcome to Pruva Sandbox! Run: pruva-verify <REPRO-ID>'
