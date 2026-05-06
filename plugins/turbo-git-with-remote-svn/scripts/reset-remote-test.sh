#!/usr/bin/env bash
# Usage: reset-remote-test.sh --n <number> [--diff-only]
set -euo pipefail

N_ARG=''
DIFF_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)         [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N_ARG="$2"; shift 2 ;;
    --diff-only) DIFF_ONLY=1; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$N_ARG" ]]; then
  echo "Error: --n is required" >&2; exit 1
fi
if ! [[ "$N_ARG" =~ ^[0-9]+$ ]]; then
  echo "Error: --n must be a positive integer, got '$N_ARG'" >&2; exit 1
fi
IDX="$N_ARG"
TEST_BRANCH="test-$IDX"

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"
REMOTE_WORKTREE_PATH="$WORKTREES_DIR/remote-test-$IDX"

# Pre-flight: branches & worktrees exist
if ! git -C "$MAIN_WORKTREE" branch --list "$TEST_BRANCH" | grep -q .; then
  echo "Error: branch '$TEST_BRANCH' does not exist." >&2; exit 1
fi
if ! git -C "$MAIN_WORKTREE" branch --list 'main' | grep -q .; then
  echo "Error: branch 'main' does not exist." >&2; exit 1
fi
if [[ ! -d "$REMOTE_WORKTREE_PATH" ]]; then
  echo "Error: remote test worktree not found: $REMOTE_WORKTREE_PATH" >&2; exit 1
fi

# Pre-flight: main worktree clean
MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before reset." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

# Pre-flight: remote-test-<n> worktree clean
REMOTE_STATUS="$(git -C "$REMOTE_WORKTREE_PATH" status --porcelain)"
if [[ -n "$REMOTE_STATUS" ]]; then
  echo "Error: remote test worktree has uncommitted changes. Run /tgs:push-to-svn or /tgs:pull-from-svn to resolve first." >&2
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

if [[ "$DIFF_ONLY" -eq 1 ]]; then
  exit 0
fi

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
  if [[ "$SWITCHED" == true ]]; then
    git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH" || true
  fi
  echo "Error: git reset --hard main failed on $TEST_BRANCH" >&2
  exit 1
fi

if [[ "$SWITCHED" == true ]]; then
  git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Switched back to '$ORIGINAL_BRANCH'."
fi

echo ''
echo "Reset $TEST_BRANCH to main. Run /tgs:push-to-svn --branch $TEST_BRANCH to publish."
