#!/bin/bash
# Create a new repro branch for a reproduction
# Usage: ./scripts/create-repro-branch.sh REPRO-2026-00001

set -euo pipefail

REPRO_ID="${1:-}"

if [ -z "$REPRO_ID" ]; then
  echo "Usage: $0 REPRO-YYYY-NNNNN"
  exit 1
fi

# Validate format
if [[ ! "$REPRO_ID" =~ ^REPRO-[0-9]{4}-[0-9]+$ ]]; then
  echo "Error: Invalid REPRO ID format. Expected: REPRO-YYYY-NNNNN"
  exit 1
fi

BRANCH="repro/$REPRO_ID"

echo "Creating branch: $BRANCH"

# Ensure we're on main and up to date
git checkout main
git pull origin main

# Check if branch already exists
if git show-ref --verify --quiet "refs/heads/$BRANCH" || git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "Error: Branch $BRANCH already exists"
  exit 1
fi

# Create and push the branch
git checkout -b "$BRANCH"
git push -u origin "$BRANCH"

echo ""
echo "✓ Created branch: $BRANCH"
echo ""
echo "Codespaces URL:"
echo "https://github.com/codespaces/new?ref=$BRANCH&repo=N3mes1s/pruva-sandbox"
