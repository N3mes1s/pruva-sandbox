#!/bin/bash
# Sync repro branches with available reproductions from Pruva API
# Run this script to create missing branches for new reproductions

set -e

API_URL="https://pruva-api-production.up.railway.app/v1/reproductions"
REPO_OWNER="N3mes1s"
REPO_NAME="pruva-sandbox"

echo "Fetching reproductions from API..."
REPRO_IDS=$(curl -s "$API_URL" | jq -r '.[].id')

echo "Fetching existing repro branches..."
git fetch origin 'refs/heads/repro/*:refs/remotes/origin/repro/*' 2>/dev/null || true
EXISTING_BRANCHES=$(git branch -r | grep 'origin/repro/' | sed 's|origin/repro/||' | xargs)

# Get the SHA of main branch
MAIN_SHA=$(git rev-parse origin/main)

echo ""
echo "Creating missing repro branches..."
for repro_id in $REPRO_IDS; do
    if echo "$EXISTING_BRANCHES" | grep -qw "$repro_id"; then
        echo "  ✓ repro/$repro_id (exists)"
    else
        echo "  + Creating repro/$repro_id"
        git branch "repro/$repro_id" "$MAIN_SHA" 2>/dev/null || true
        git push origin "repro/$repro_id"
    fi
done

echo ""
echo "Done! All repro branches are synced."
