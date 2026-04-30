#!/usr/bin/env bash
# Usage: pull-from-svn.sh --branch <main|test-<n>>
set -euo pipefail

BRANCH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)  [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required (main or test-<n>)" >&2; exit 1
fi

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

# Resolve remote worktree
if [[ "$BRANCH" == 'main' ]]; then
  REMOTE_WORKTREE_NAME='remote-main'
  REMOTE_BRANCH='remote/main'
elif [[ "$BRANCH" =~ ^test-([0-9]+)$ ]]; then
  N="${BASH_REMATCH[1]}"
  REMOTE_WORKTREE_NAME="remote-test-$N"
  REMOTE_BRANCH="remote/test-$N"
else
  echo "Error: unsupported branch '$BRANCH'. Only 'main' and 'test-<n>' are supported." >&2; exit 1
fi

REMOTE_WORKTREE_PATH="$WORKTREES_DIR/$REMOTE_WORKTREE_NAME"

if [[ ! -d "$REMOTE_WORKTREE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_WORKTREE_NAME' not found at: $REMOTE_WORKTREE_PATH" >&2; exit 1
fi

# Check main worktree is clean
MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before pulling from SVN." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"

# SVN update
echo "Running svn update in $REMOTE_WORKTREE_NAME..."
(cd "$REMOTE_WORKTREE_PATH" && svn update)
SVN_REV="$(svn info --show-item revision "$REMOTE_WORKTREE_PATH")"

# Check if git sees any changes
REMOTE_STATUS="$(git -C "$REMOTE_WORKTREE_PATH" status --porcelain)"
if [[ -z "$REMOTE_STATUS" ]]; then
  echo "Already up to date at SVN r$SVN_REV"
  exit 0
fi

# Commit SVN changes to remote/* branch
git -C "$REMOTE_WORKTREE_PATH" add -A
git -C "$REMOTE_WORKTREE_PATH" commit -m "sync: svn r$SVN_REV"

# Switch to target branch in main worktree if needed
SWITCHED=false
if [[ "$ORIGINAL_BRANCH" != "$BRANCH" ]]; then
  echo "Switching main worktree from '$ORIGINAL_BRANCH' to '$BRANCH'..."
  git -C "$MAIN_WORKTREE" checkout "$BRANCH"
  SWITCHED=true
fi

# Merge remote branch into working branch
if ! git -C "$MAIN_WORKTREE" merge "$REMOTE_BRANCH" --no-ff -m "Merge branch '$REMOTE_BRANCH' into $BRANCH"; then
  CONFLICTS="$(git -C "$MAIN_WORKTREE" diff --name-only --diff-filter=U)"
  echo "Error: merge conflict detected. Resolve the following files in the main worktree, then run 'git merge --continue':" >&2
  echo "$CONFLICTS" >&2
  echo "" >&2
  echo "Note: main worktree is now on branch '$BRANCH'. Switch back to '$ORIGINAL_BRANCH' manually when done." >&2
  exit 1
fi

# Switch back if we switched
if [[ "$SWITCHED" == true ]]; then
  git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Switched back to '$ORIGINAL_BRANCH'."
fi

echo "Pulled SVN r$SVN_REV into $BRANCH"
