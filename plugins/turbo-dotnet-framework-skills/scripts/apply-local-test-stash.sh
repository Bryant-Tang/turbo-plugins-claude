#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

GIT_DIR="$(git rev-parse --git-path . | xargs -I{} realpath "{}" 2>/dev/null || git rev-parse --absolute-git-dir)"
STATE_FILE="$GIT_DIR/testing-and-proof.applied-stash-ref"
STASH_SHA="${TEST_LOCAL_STASH_SHA:-}"

if [[ -f "$STATE_FILE" ]]; then
  echo "Found previous applied-stash state file: $STATE_FILE"
  echo "Run revert-local-test-stash.sh before applying again."
  exit 1
fi

STATUS_OUTPUT="$(git status --porcelain)"

if [[ -n "$STATUS_OUTPUT" ]]; then
  echo "Working tree is not clean. Refusing to apply local test stash."
  echo "$STATUS_OUTPUT"
  exit 1
fi

if [[ -z "$STASH_SHA" ]]; then
  echo "TEST_LOCAL_STASH_SHA is not configured. Skipping local test stash apply."
  exit 0
fi

if ! git rev-parse --verify "${STASH_SHA}^{commit}" >/dev/null 2>&1; then
  echo "Configured stash SHA not found: $STASH_SHA"
  git stash list --format='%H %gd %gs'
  exit 1
fi

if ! git stash show -p --include-untracked "$STASH_SHA" >/dev/null 2>&1; then
  echo "Configured stash SHA is not a valid stash entry: $STASH_SHA"
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"
echo "$STASH_SHA" > "$STATE_FILE"
git stash apply "$STASH_SHA"
echo "Applied local test stash: $STASH_SHA"
