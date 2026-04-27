#!/usr/bin/env bash
set -euo pipefail

GIT_DIR="$(git rev-parse --absolute-git-dir)"
STATE_FILE="$GIT_DIR/testing-and-proof.applied-stash-ref"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No applied local-test stash state file found. Skipping revert."
  exit 0
fi

STASH_REF="$(cat "$STATE_FILE")"
git stash show -p "$STASH_REF" | git apply -R

STATUS_OUTPUT="$(git status --porcelain)"

if [[ -n "$STATUS_OUTPUT" ]]; then
  echo "Working tree still contains changes after reverting local test stash."
  echo "$STATUS_OUTPUT"
  exit 1
fi

rm -f "$STATE_FILE"
echo "Reverted local test stash: $STASH_REF"
