#!/usr/bin/env bash
# Usage: new-remote-test.sh --svn-url <url> [--n <number>]
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
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Run /tp-setup first." >&2; exit 1
fi

if [[ -z "$N" ]]; then
  MAX_N=0
  for d in "$WORKTREES_DIR"/remote-svn-test-*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ "$name" =~ ^remote-svn-test-([0-9]+)$ ]]; then
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
REMOTE_BRANCH="remote-svn/test-$IDX"
REMOTE_NAME="remote-svn-test-$IDX"
REMOTE_PATH="$WORKTREES_DIR/$REMOTE_NAME"

if git -C "$MAIN_WORKTREE" branch --list "$TEST_BRANCH" | grep -q .; then
  echo "Error: branch '$TEST_BRANCH' already exists." >&2; exit 1
fi
if [[ -e "$REMOTE_PATH" ]]; then
  echo "Error: worktree '$REMOTE_NAME' already exists at: $REMOTE_PATH" >&2; exit 1
fi

# SECURITY (U2 / R1): validate the caller-supplied $SVN_URL falls under the trusted
# repository root BEFORE any git mutation, before any svn sink, and before the ERR
# rollback trap is registered. Trust base = remote-svn-main's repos-root-url. Running this
# before the trap means a rejected URL produces ZERO side effects and does NOT trigger
# rollback. If remote-svn-main is absent / not a working copy, assert_trusted_svn_url fails
# closed (non-zero) and we exit here — still before any branch/worktree is created.
REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-svn-main"
if ! assert_trusted_svn_url "$REMOTE_MAIN_PATH" "$SVN_URL" >/dev/null; then
  echo "Error: refusing to create test environment with untrusted/unverifiable SVN URL." >&2
  exit 1
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
  REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-svn-main"
  MAIN_SVN_URL="$(svn info --show-item url "$REMOTE_MAIN_PATH")"
  echo "SVN path '$SVN_URL' does not exist. Creating from '$MAIN_SVN_URL'..."
  svn copy "$MAIN_SVN_URL" "$SVN_URL" -m "create $TEST_BRANCH branch"
fi

echo "Running: svn checkout --force $SVN_URL $REMOTE_PATH"
# --force: `git worktree add` already created `.git` (pointer file) + init-commit content
# (init.txt) in the worktree path; svn would otherwise mark these as "obstructed/conflict"
# and svn commit would refuse. --force treats existing files as already-versioned.
svn checkout --force "$SVN_URL" "$REMOTE_PATH"

# CRITICAL: untrack `.git` from svn working copy BEFORE setting svn:ignore.
# Without this, `.git` (git pointer file) gets pushed to permanent SVN history and pollutes
# test branches for everyone who checks out (with a `.git` pointing to the original committer's
# local path). `--keep-local` removes it from svn versioning but keeps the file on disk.
if [[ -e "$REMOTE_PATH/.git" ]]; then
  (cd "$REMOTE_PATH" && svn rm --keep-local '.git' 2>/dev/null || true)
fi

REMOTE_MAIN_PATH="$WORKTREES_DIR/remote-svn-main"
IGNORE_TO_APPLY=$'.git\n.gitignore'
if [[ -d "$REMOTE_MAIN_PATH" ]]; then
  INHERITED="$(svn propget svn:ignore "$REMOTE_MAIN_PATH" 2>/dev/null || true)"
  if [[ -n "$INHERITED" ]]; then IGNORE_TO_APPLY="$INHERITED"; fi
fi

# v0.2.7+ F-U16.bridge fix: sync main's current .gitignore into remote-svn-test-N BEFORE
# svn commit. SVN's test-N was svn-copied from main SVN whose .gitignore may be older
# than main git's current .gitignore. Without this sync, test-N and remote-svn/test-N
# diverge on .gitignore content → first tp-push-to-svn 必撞 add/add merge conflict.
if [[ -f "$MAIN_WORKTREE/.gitignore" ]]; then
  cp -f "$MAIN_WORKTREE/.gitignore" "$REMOTE_PATH/.gitignore"
  echo "Synced main's .gitignore into $REMOTE_NAME for first-push consistency."
fi

(
  cd "$REMOTE_PATH"
  svn propset svn:ignore "$IGNORE_TO_APPLY" '.'
  # svn commit picks up both the propset and the .gitignore content sync (if main differs).
  svn commit -m 'svn:ignore: copy from remote-svn-main; sync .gitignore from main'
)

# All SVN steps succeeded; disable the rollback trap.
trap - ERR

echo ""
echo "Test environment $IDX created."
echo "  Branch        : $TEST_BRANCH  (use 'git checkout $TEST_BRANCH' in main worktree)"
echo "  SVN worktree  : $REMOTE_PATH"
echo ""
echo "Next step: run '/tp-pull-from-svn --branch $TEST_BRANCH' to complete the initial SVN sync."
