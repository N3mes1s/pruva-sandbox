#!/usr/bin/env bash
#
# Enforce the public/private boundary for pruva-sandbox.
#
# This repository is public and may be cloned into user Codespaces. It must not
# carry operator credentials, private pruva binaries, or patch references that
# require the private pruva repository to run.
#
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

fail() {
  echo -e "${RED}public boundary check failed:${NC} $*" >&2
  exit 1
}

section() {
  echo -e "${BOLD}$*${NC}"
}

cd "$(dirname "$0")/.."

section "Checking tracked files for credential-looking tokens"

# Keep this intentionally narrow to avoid blocking docs that mention env var
# names such as MODAL_TOKEN_ID. The goal is to catch pasted token values.
secret_regex='(ak|as)-[A-Za-z0-9]{12,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}'
if git grep -n -E "$secret_regex" -- .; then
  fail "found token-looking value in tracked files"
fi

section "Checking repro patches for private pruva dependencies"

if git ls-files 'repro-patches/*.patch' | grep -q .; then
  private_patch_regex='github\.com/N3mes1s/pruva($|[/.])|ghcr\.io/n3mes1s/pruva($|[:/@])|/home/[^[:space:]]*/code/pruva($|/)'
  if git grep -n -E "$private_patch_regex" -- 'repro-patches/*.patch'; then
    fail "repro patch references the private pruva repository, image, or local checkout"
  fi
fi

echo -e "${GREEN}public boundary check passed${NC}"
