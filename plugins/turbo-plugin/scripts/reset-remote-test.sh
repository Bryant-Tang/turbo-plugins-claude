#!/usr/bin/env bash
# Usage: reset-remote-test.sh --n <number> [--diff-only]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

N=''
DIFF_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)         [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N="$2"; shift 2 ;;
    --diff-only) DIFF_ONLY=true; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$N" ]]; then echo "Error: --n is required" >&2; exit 1; fi
if ! [[ "$N" =~ ^[0-9]+$ ]]; then echo "Error: --n must be a positive integer (got '$N')" >&2; exit 1; fi

IDX="$N"
TEST_BRANCH="test-$IDX"

MAIN_WORKTREE="$(get_main_worktree)"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"
REMOTE_PATH="$WORKTREES_DIR/remote-test-$IDX"

if ! git -C "$MAIN_WORKTREE" branch --list "$TEST_BRANCH" | grep -q .; then
  echo "Error: branch '$TEST_BRANCH' does not exist." >&2; exit 1
fi
if ! git -C "$MAIN_WORKTREE" branch --list 'main' | grep -q .; then
  echo "Error: branch 'main' does not exist." >&2; exit 1
fi
if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote test worktree not found: $REMOTE_PATH" >&2; exit 1
fi

MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before reset." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

# v0.2.7+ F-U18.svn-state fix: filter out .svn/* paths from git status check.
# .svn/wc.db is SVN's binary metadata (modified by every svn op); treating it as
# user uncommitted change deadlocks user — told to push/pull but those touch wc.db too.
REMOTE_STATUS_RAW="$(git -C "$REMOTE_PATH" status --porcelain)"
REMOTE_STATUS="$(printf '%s' "$REMOTE_STATUS_RAW" | grep -v -E '^\s*[?MADRC!]+\s+\.svn[/\\]' || true)"
if [[ -n "$REMOTE_STATUS" ]]; then
  echo "Error: remote test worktree '$REMOTE_PATH' has uncommitted changes. Run /tp-push-to-svn or /tp-pull-from-svn to resolve first." >&2
  echo "$REMOTE_STATUS" >&2
  exit 1
fi

LOSE_RAW="$(git -C "$MAIN_WORKTREE" log --oneline "main..$TEST_BRANCH")"
GAIN_RAW="$(git -C "$MAIN_WORKTREE" log --oneline "$TEST_BRANCH..main")"

echo 'LOSE'
[[ -n "$LOSE_RAW" ]] && echo "$LOSE_RAW"
echo ''
echo 'GAIN'
[[ -n "$GAIN_RAW" ]] && echo "$GAIN_RAW"

if [[ "$DIFF_ONLY" == true ]]; then exit 0; fi

if [[ -z "$LOSE_RAW" && -z "$GAIN_RAW" ]]; then
  echo ''
  echo "$TEST_BRANCH already equals main. Nothing to reset."
  exit 0
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"

SWITCHED=false
if [[ "$ORIGINAL_BRANCH" != "$TEST_BRANCH" ]]; then
  echo ''
  echo "Switching main worktree from '$ORIGINAL_BRANCH' to '$TEST_BRANCH'..."
  git -C "$MAIN_WORKTREE" checkout "$TEST_BRANCH"
  SWITCHED=true
fi

if ! git -C "$MAIN_WORKTREE" reset --hard 'main'; then
  [[ "$SWITCHED" == true ]] && git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Error: git reset --hard main failed on $TEST_BRANCH" >&2
  exit 1
fi

if [[ "$SWITCHED" == true ]]; then
  git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Switched back to '$ORIGINAL_BRANCH'."
fi

echo ''
echo "Reset $TEST_BRANCH to main. Run /tp-push-to-svn --branch $TEST_BRANCH to publish."
