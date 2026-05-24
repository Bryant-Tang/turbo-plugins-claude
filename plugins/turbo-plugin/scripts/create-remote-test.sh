#!/usr/bin/env bash
# Usage: create-remote-test.sh --svn-url <url> [--n <number>]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

SVN_URL=''
N=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svn-url) [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    --n)       [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree)"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Run /tp-setup first." >&2; exit 1
fi

if [[ -z "$N" ]]; then
  MAX_N=0
  for d in "$WORKTREES_DIR"/remote-test-*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ "$name" =~ ^remote-test-([0-9]+)$ ]]; then
      num="${BASH_REMATCH[1]}"
      (( num > MAX_N )) && MAX_N="$num"
    fi
  done
  IDX=$((MAX_N + 1))
else
  if ! [[ "$N" =~ ^[0-9]+$ ]]; then echo "Error: --n must be a positive integer (got '$N')" >&2; exit 1; fi
  IDX="$N"
fi

TEST_BRANCH="test-$IDX"
REMOTE_BRANCH="remote/test-$IDX"
REMOTE_NAME="remote-test-$IDX"
REMOTE_PATH="$WORKTREES_DIR/$REMOTE_NAME"

if git -C "$MAIN_WORKTREE" branch --list "$TEST_BRANCH" | grep -q .; then
  echo "Error: branch '$TEST_BRANCH' already exists." >&2; exit 1
fi
if [[ -e "$REMOTE_PATH" ]]; then
  echo "Error: worktree '$REMOTE_NAME' already exists at: $REMOTE_PATH" >&2; exit 1
fi

echo "Creating test environment $IDX..."

INIT_COMMIT="$(git -C "$MAIN_WORKTREE" rev-list --max-parents=0 HEAD)"

# Roll back partial git state if any subsequent step fails. Mirrors create-remote-test.ps1 try/catch.
# Registered BEFORE the first git mutation so even early branch-creation failures roll back cleanly.
# Each cleanup step's exit code is captured independently so a PARTIAL_ROLLBACK token can
# emit concrete manual-recovery hints when any step fails.
_rollback_create_remote_test() {
    local exit_code=$?
    local wt_status=0 rb_status=0 tb_status=0
    echo "SVN setup failed; rolling back git state..." >&2
    git -C "$MAIN_WORKTREE" worktree remove --force "$REMOTE_PATH" 2>/dev/null || wt_status=$?
    git -C "$MAIN_WORKTREE" branch -D "$REMOTE_BRANCH" 2>/dev/null || rb_status=$?
    git -C "$MAIN_WORKTREE" branch -D "$TEST_BRANCH" 2>/dev/null || tb_status=$?
    if [[ $wt_status -ne 0 || $rb_status -ne 0 || $tb_status -ne 0 ]]; then
        echo "PARTIAL_ROLLBACK: worktree-remove=$wt_status branch-D-remote=$rb_status branch-D-test=$tb_status" >&2
        echo "Some cleanup steps failed. Manual recovery hints:" >&2
        [[ $wt_status -ne 0 ]] && echo "  - git worktree prune  (or: git -C $MAIN_WORKTREE worktree remove --force $REMOTE_PATH)" >&2
        [[ $rb_status -ne 0 ]] && echo "  - git -C $MAIN_WORKTREE branch -D $REMOTE_BRANCH" >&2
        [[ $tb_status -ne 0 ]] && echo "  - git -C $MAIN_WORKTREE branch -D $TEST_BRANCH" >&2
    fi
    exit "$exit_code"
}
trap _rollback_create_remote_test ERR

git -C "$MAIN_WORKTREE" branch "$REMOTE_BRANCH" "$INIT_COMMIT"
git -C "$MAIN_WORKTREE" branch "$TEST_BRANCH" 'main'
git -C "$MAIN_WORKTREE" worktree add "$REMOTE_PATH" "$REMOTE_BRANCH"

if svn info "$SVN_URL" >/dev/null 2>&1; then
  echo "SVN path exists, will checkout: $SVN_URL"
else
  REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-main"
  MAIN_SVN_URL="$(svn info --show-item url "$REMOTE_MAIN_PATH")"
  echo "SVN path '$SVN_URL' does not exist. Creating from '$MAIN_SVN_URL'..."
  svn copy "$MAIN_SVN_URL" "$SVN_URL" -m "create $TEST_BRANCH branch"
fi

echo "Running: svn checkout $SVN_URL $REMOTE_PATH"
svn checkout "$SVN_URL" "$REMOTE_PATH"

REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-main"
IGNORE_TO_APPLY=$'.git\n.gitignore'
if [[ -d "$REMOTE_MAIN_PATH" ]]; then
  INHERITED="$(svn propget svn:ignore "$REMOTE_MAIN_PATH" 2>/dev/null || true)"
  if [[ -n "$INHERITED" ]]; then IGNORE_TO_APPLY="$INHERITED"; fi
fi

(
  cd "$REMOTE_PATH"
  svn propset svn:ignore "$IGNORE_TO_APPLY" '.'
  svn commit -m 'svn:ignore: copy from remote-main'
)

# All SVN steps succeeded; disable the rollback trap.
trap - ERR

echo ""
echo "Test environment $IDX created."
echo "  Branch        : $TEST_BRANCH  (use 'git checkout $TEST_BRANCH' in main worktree)"
echo "  SVN worktree  : $REMOTE_PATH"
echo ""
echo "Next step: run '/tp-pull-from-svn --branch $TEST_BRANCH' to complete the initial SVN sync."
