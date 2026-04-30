#!/usr/bin/env bash
# Usage: create-remote-test.sh [--n <number>] [--svn-url <url>]
set -euo pipefail

N_ARG=''
SVN_URL=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)        [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N_ARG="$2"; shift 2 ;;
    --svn-url)  [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"
WORKSPACE_FILE="$ROOT_DIR/$PROJ_NAME.code-workspace"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Are you inside a tgs project?" >&2; exit 1
fi

# Resolve <n>
if [[ -z "$N_ARG" ]]; then
  MAX_N=0
  for d in "$WORKTREES_DIR"/remote-test-*/; do
    [[ -d "$d" ]] || continue
    NAME="$(basename "$d")"
    if [[ "$NAME" =~ ^remote-test-([0-9]+)$ ]]; then
      NUM="${BASH_REMATCH[1]}"
      (( NUM > MAX_N )) && MAX_N=$NUM
    fi
  done
  IDX=$(( MAX_N + 1 ))
else
  if ! [[ "$N_ARG" =~ ^[0-9]+$ ]]; then
    echo "Error: --n must be a positive integer, got '$N_ARG'" >&2; exit 1
  fi
  IDX="$N_ARG"
fi

TEST_BRANCH="test-$IDX"
REMOTE_BRANCH="remote/test-$IDX"
REMOTE_WORKTREE_NAME="remote-test-$IDX"
REMOTE_WORKTREE_PATH="$WORKTREES_DIR/$REMOTE_WORKTREE_NAME"

# Check conflicts
if git -C "$MAIN_WORKTREE" branch --list "$TEST_BRANCH" | grep -q .; then
  echo "Error: branch '$TEST_BRANCH' already exists." >&2; exit 1
fi
if [[ -d "$REMOTE_WORKTREE_PATH" ]]; then
  echo "Error: worktree '$REMOTE_WORKTREE_NAME' already exists at: $REMOTE_WORKTREE_PATH" >&2; exit 1
fi

echo "Creating test environment $IDX..."

# Branch remote/test-N from the init commit (repo root) so the worktree starts with only
# .gitignore; this avoids an SVN obstruction conflict when checking out SVN content that
# overlaps with files already present from remote/main.
INIT_COMMIT="$(git -C "$MAIN_WORKTREE" rev-list --max-parents=0 HEAD)"
git -C "$MAIN_WORKTREE" branch "$REMOTE_BRANCH" "$INIT_COMMIT"
git -C "$MAIN_WORKTREE" branch "$TEST_BRANCH" 'main'
git -C "$MAIN_WORKTREE" worktree add "$REMOTE_WORKTREE_PATH" "$REMOTE_BRANCH"

if [[ -n "$SVN_URL" ]]; then
  # Check if the SVN URL already exists; if not, create it via svn copy from remote-main
  if svn info "$SVN_URL" > /dev/null 2>&1; then
    echo "SVN path exists, will checkout: $SVN_URL"
  else
    REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-main"
    MAIN_SVN_URL="$(svn info --show-item url "$REMOTE_MAIN_PATH")"
    echo "SVN path '$SVN_URL' does not exist. Creating from '$MAIN_SVN_URL'..."
    svn copy "$MAIN_SVN_URL" "$SVN_URL" -m "create $TEST_BRANCH branch"
  fi
  echo "Running: svn checkout $SVN_URL $REMOTE_WORKTREE_PATH"
  svn checkout "$SVN_URL" "$REMOTE_WORKTREE_PATH"

  # Set svn:ignore so git metadata files are never accidentally committed to SVN
  (cd "$REMOTE_WORKTREE_PATH" && \
    printf '.git\n.gitignore\n' | svn propset svn:ignore --file - . && \
    svn commit -m 'svn:ignore git metadata')
fi

CLOSE_LINE="$(grep -n $'^\t\],' "$WORKSPACE_FILE" | cut -d: -f1)"
if [[ -z "$CLOSE_LINE" ]]; then
  echo "Error: could not find folders closing bracket in $WORKSPACE_FILE" >&2; exit 1
fi
PREV_LINE=$(( CLOSE_LINE - 1 ))
TOTAL_LINES="$(wc -l < "$WORKSPACE_FILE")"
{
  head -n "$PREV_LINE" "$WORKSPACE_FILE" | sed '$s/$/,/'
  printf '\t\t{"name": "%s", "path": "%s.worktrees/%s"}\n' "$REMOTE_WORKTREE_NAME" "$PROJ_NAME" "$REMOTE_WORKTREE_NAME"
  tail -n $(( TOTAL_LINES - PREV_LINE )) "$WORKSPACE_FILE"
} > "${WORKSPACE_FILE}.tmp" && mv "${WORKSPACE_FILE}.tmp" "$WORKSPACE_FILE"

echo ""
echo "Test environment $IDX created."
echo "  Branch        : $TEST_BRANCH  (use 'git checkout $TEST_BRANCH' in main worktree)"
echo "  SVN worktree  : $REMOTE_WORKTREE_PATH"

if [[ -z "$SVN_URL" ]]; then
  echo ""
  echo "No SVN URL provided. To link SVN manually:"
  echo "  cd '$REMOTE_WORKTREE_PATH'"
  echo "  svn checkout <url> ."
  echo "Then run '/tgs:pull-from-svn --branch $TEST_BRANCH' to complete the sync."
else
  echo ""
  echo "Next step: run '/tgs:pull-from-svn --branch $TEST_BRANCH' to complete the initial SVN sync."
fi
echo ""
echo "Recommended: open Claude Code in the main worktree and run /tgs:setup to configure"
echo "  tgs environment variable defaults. Main worktree: $MAIN_WORKTREE"
