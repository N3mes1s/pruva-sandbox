#!/bin/bash
# Pruva Reproduction Runner
# Automatically runs the reproduction based on the branch name

set -e

# Extract REPRO ID from branch name (format: repro/REPRO-YYYY-NNNNN)
BRANCH=$(git branch --show-current 2>/dev/null || echo "")

if [[ "$BRANCH" == repro/* ]]; then
    REPRO_ID="${BRANCH#repro/}"

    echo ""
    echo "=========================================="
    echo "  Pruva Reproduction: $REPRO_ID"
    echo "=========================================="
    echo ""
    echo "Starting automated reproduction..."
    echo "This will run in a sandboxed environment."
    echo ""

    # Run the reproduction using pruva-verify
    pruva-verify "$REPRO_ID"

    echo ""
    echo "=========================================="
    echo "  Reproduction Complete"
    echo "=========================================="
    echo ""
    echo "Check the output above for results."
    echo "The reproduction script is available at: ./reproduction_steps.sh"
    echo ""
    echo "To re-run manually:"
    echo "  pruva-verify $REPRO_ID"
    echo ""

elif [[ -n "$REPRO_ID" ]]; then
    # Allow passing REPRO_ID via environment variable
    echo "Running reproduction from environment: $REPRO_ID"
    pruva-verify "$REPRO_ID"

else
    echo ""
    echo "=========================================="
    echo "  Pruva Sandbox Environment"
    echo "=========================================="
    echo ""
    echo "Welcome to the Pruva sandbox!"
    echo ""
    echo "This environment has pruva-verify pre-installed."
    echo ""
    echo "To run a reproduction, use:"
    echo "  pruva-verify REPRO-2026-00006"
    echo "  pruva-verify GHSA-655q-fx9r-782v"
    echo "  pruva-verify CVE-2025-1716"
    echo ""
    echo "Browse reproductions at: https://pruva.dev/reproductions"
    echo ""
fi
