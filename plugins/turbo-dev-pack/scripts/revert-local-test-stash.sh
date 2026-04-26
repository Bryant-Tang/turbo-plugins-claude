#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

GIT_DIR="$(git rev-parse --git-path . | xargs -I{} realpath "{}" 2>/dev/null || git rev-parse --absolute-git-dir)"
STATE_FILE="$GIT_DIR/testing-and-proof.applied-stash-ref"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No applied local-test stash state file found. Skipping revert."
  exit 0
fi

STASH_REF="$(cat "$STATE_FILE")"
git stash show -p --include-untracked "$STASH_REF" | git apply -R

rm -f "$STATE_FILE"

STATUS_OUTPUT="$(git status --porcelain)"

if [[ -n "$STATUS_OUTPUT" ]]; then
  echo "Working tree still contains changes after reverting local test stash."
  echo "$STATUS_OUTPUT"
  exit 1
fi

echo "Reverted local test stash: $STASH_REF"
