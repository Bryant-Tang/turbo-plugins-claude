#!/usr/bin/env bash
# Usage: push-to-svn-prepare.sh --branch <main|test-<n>>
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

# Check no existing merge state (left over from a previous prepare that wasn't committed/aborted)
if git -C "$REMOTE_WORKTREE_PATH" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
  echo "Error: remote worktree '$REMOTE_WORKTREE_NAME' has a pending merge (.git/MERGE_HEAD exists). Run '/tgs:push-to-svn' to commit it, or 'git -C $REMOTE_WORKTREE_PATH merge --abort' to discard." >&2
  exit 1
fi

# Check remote worktree git status (clean tree expected before staging the merge)
REMOTE_GIT_STATUS="$(git -C "$REMOTE_WORKTREE_PATH" status --porcelain)"
if [[ -n "$REMOTE_GIT_STATUS" ]]; then
  echo "Error: remote worktree '$REMOTE_WORKTREE_NAME' has uncommitted git changes." >&2; exit 1
fi

# Check SVN is up-to-date
SVN_URL="$(svn info --show-item url "$REMOTE_WORKTREE_PATH")"
LOCAL_REV="$(svn info --show-item revision "$REMOTE_WORKTREE_PATH")"
HEAD_REV="$(svn info --show-item revision "$SVN_URL")"

if [[ "$LOCAL_REV" != "$HEAD_REV" ]]; then
  echo "Error: remote SVN worktree is not up to date (local r$LOCAL_REV, head r$HEAD_REV). Run '/tgs:pull-from-svn --branch $BRANCH' first." >&2
  exit 1
fi

# Get pending commits
LOG_OUTPUT="$(git -C "$MAIN_WORKTREE" log "$REMOTE_BRANCH..$BRANCH" --reverse --pretty=format:'%h|%s')"

if [[ -z "$LOG_OUTPUT" ]]; then
  echo 'Nothing to push'
  exit 0
fi

# Stage the merge so svn status reflects the actual file changes that would be pushed.
# --no-ff guarantees a merge commit; --no-commit lets us preview before finalising.
# The commit message is stashed in .git/MERGE_MSG and reused when push-to-svn-commit runs `git commit --no-edit`.
if ! git -C "$REMOTE_WORKTREE_PATH" merge --no-ff --no-commit -m "Merge branch '$BRANCH' into $REMOTE_BRANCH" "$BRANCH" >/dev/null 2>&1; then
  CONFLICTS="$(git -C "$REMOTE_WORKTREE_PATH" diff --name-only --diff-filter=U)"
  echo "Error: merge conflict in remote worktree. Resolve the following files in '$REMOTE_WORKTREE_NAME', then re-run, or abort with 'git -C $REMOTE_WORKTREE_PATH merge --abort':" >&2
  echo "$CONFLICTS" >&2
  exit 1
fi

echo 'COMMITS'
echo "$LOG_OUTPUT"
echo ''
echo 'FILES'
(cd "$REMOTE_WORKTREE_PATH" && svn status) | tr -d '\r' | while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  status="${line:0:1}"
  filepath="${line:8}"
  [[ -z "$filepath" ]] && continue
  case "$status" in
    '?') diff_status='A' ;;
    '!') diff_status='D' ;;
    'M') diff_status='M' ;;
    *)   continue ;;
  esac
  if git -C "$REMOTE_WORKTREE_PATH" check-ignore -q "$filepath" 2>/dev/null; then
    echo "$diff_status|ignored|$filepath"
  else
    echo "$diff_status|tracked|$filepath"
  fi
done
