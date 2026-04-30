#!/usr/bin/env bash
# Usage: push-to-svn-commit.sh --branch <main|test-<n>> --message "commit message"
set -euo pipefail

BRANCH=''
MESSAGE=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --message)  [[ $# -ge 2 ]] || { echo "Error: --message requires a value" >&2; exit 1; }; MESSAGE="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$MESSAGE" ]]; then echo "Error: --message is required" >&2; exit 1; fi

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
  echo "Error: unsupported branch '$BRANCH'." >&2; exit 1
fi

REMOTE_WORKTREE_PATH="$WORKTREES_DIR/$REMOTE_WORKTREE_NAME"

if [[ ! -d "$REMOTE_WORKTREE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_WORKTREE_NAME' not found at: $REMOTE_WORKTREE_PATH" >&2; exit 1
fi

# Re-validate SVN (guard against race condition)
SVN_URL="$(svn info --show-item url "$REMOTE_WORKTREE_PATH")"
LOCAL_REV="$(svn info --show-item revision "$REMOTE_WORKTREE_PATH")"
HEAD_REV="$(svn info --show-item revision "$SVN_URL")"
if [[ "$LOCAL_REV" != "$HEAD_REV" ]]; then
  echo "Error: SVN HEAD changed since prepare (local r$LOCAL_REV, head r$HEAD_REV). Run pull-from-svn first." >&2; exit 1
fi

# Re-validate remote git status
REMOTE_GIT_STATUS="$(git -C "$REMOTE_WORKTREE_PATH" status --porcelain)"
if [[ -n "$REMOTE_GIT_STATUS" ]]; then
  echo "Error: remote worktree '$REMOTE_WORKTREE_NAME' has uncommitted changes." >&2; exit 1
fi

# Merge working branch into remote branch
echo "Merging '$BRANCH' into '$REMOTE_BRANCH'..."
if ! git -C "$REMOTE_WORKTREE_PATH" merge "$BRANCH" --no-ff -m "Merge branch '$BRANCH' into $REMOTE_BRANCH"; then
  CONFLICTS="$(git -C "$REMOTE_WORKTREE_PATH" diff --name-only --diff-filter=U)"
  echo "Error: merge conflict in remote worktree. Resolve the following files in '$REMOTE_WORKTREE_NAME', then retry:" >&2
  echo "$CONFLICTS" >&2
  exit 1
fi

# Handle SVN untracked and missing files, then commit
(
  cd "$REMOTE_WORKTREE_PATH"

  TO_ADD=()
  TO_DEL=()
  while IFS= read -r line; do
    status="${line:0:1}"
    filepath="${line:8}"
    if [[ "$status" == '?' ]]; then TO_ADD+=("$filepath")
    elif [[ "$status" == '!' ]]; then TO_DEL+=("$filepath")
    fi
  done < <(svn status | tr -d '\r')

  if [[ ${#TO_ADD[@]} -gt 0 ]]; then
    echo "SVN adding ${#TO_ADD[@]} new file(s)..."
    svn add --parents "${TO_ADD[@]}"
  fi

  if [[ ${#TO_DEL[@]} -gt 0 ]]; then
    echo "SVN deleting ${#TO_DEL[@]} removed file(s)..."
    svn delete "${TO_DEL[@]}"
  fi

  echo "Committing to SVN..."
  COMMIT_OUT="$(svn commit -m "$MESSAGE")"
  printf '%s\n' "$COMMIT_OUT"
  NEW_REV="$(printf '%s\n' "$COMMIT_OUT" | sed -n 's/Committed revision \([0-9]*\)\./\1/p' | tail -1)"
  [ -z "$NEW_REV" ] && NEW_REV='?'
  # Update working copy revision so subsequent prepare checks see the correct local revision
  svn update > /dev/null
  echo "Pushed to SVN r$NEW_REV"
)
