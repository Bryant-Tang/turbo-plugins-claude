#!/usr/bin/env bash
# Usage: build-svn-commit.sh --branch <branch>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"   # provides svn_status_xml (UTF-8/entity-safe svn status parser)

BRANCH=''
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required (e.g. main or feat/login)" >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_BRANCH="$(printf '%s' "$REMOTE_SPEC" | cut -d'|' -f2)"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH" >&2; exit 1
fi

# F23: detect --branch mismatch — emit a structured token when the requested branch differs
# from the current HEAD so the SKILL can prompt for user confirmation before pushing.
# prefix with TP_TOKEN: to match the pre-flight contract — the SKILL only
# trusts TP_TOKEN:-prefixed lines, so the backstop must use the same prefix or the warning
# is silently dropped on the normal push path.
CURRENT_HEAD_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [[ -n "$CURRENT_HEAD_BRANCH" && "$CURRENT_HEAD_BRANCH" != "$BRANCH" ]]; then
  echo "TP_TOKEN:BRANCH_MISMATCH_WARNING current=$CURRENT_HEAD_BRANCH requested=$BRANCH"
fi

if git -C "$REMOTE_PATH" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
  # Emit a structured token so tp-push-to-svn SKILL can offer abort/continue/cancel options.
  echo "PENDING_MERGE_DETECTED $REMOTE_PATH"
  exit 0
fi

REMOTE_GIT_STATUS="$(git -C "$REMOTE_PATH" status --porcelain)"
if [[ -n "$REMOTE_GIT_STATUS" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' has uncommitted git changes." >&2; exit 1
fi

SVN_URL="$(svn info --show-item url "$REMOTE_PATH")"

# Staleness is measured against the last revision that touched THIS branch path, never against the
# repository HEAD. SVN revision numbers are repository-wide, so in a repository holding several
# projects a colleague's commit to a SIBLING path bumps HEAD without changing anything of ours.
# Comparing to HEAD made that look stale and refused the push -- while pull correctly found nothing
# to replay for this path, reported "already up to date" and returned. Push said "go pull", pull
# said "nothing to do": a deadlock only a manual `svn update` broke.
#
# This is safe because `svn commit` itself only rejects paths that are actually out of date: a
# working copy below HEAD commits fine as long as nothing under our path changed (measured on svn
# 1.14). And last-changed-revision bubbles up from files nested anywhere beneath the path, so a real
# change deep inside the branch is still caught.
LOCAL_REV="$(svn info --show-item revision "$REMOTE_PATH" | tr -d '[:space:]')"
PATH_REV="$(svn info --show-item last-changed-revision "$SVN_URL" | tr -d '[:space:]')"

# Arithmetic comparison, not string: "9" sorts after "10" lexically.
if (( LOCAL_REV < PATH_REV )); then
  echo "Error: remote SVN worktree is not up to date (local r$LOCAL_REV, this path last changed at r$PATH_REV). Run '/tp-pull-from-svn --branch $BRANCH' first." >&2
  exit 1
fi

RANGE="$REMOTE_BRANCH..$BRANCH"

# Empty range (no new commits at all, merges included) → nothing to push (existing short-circuit).
RANGE_COUNT="$(git -C "$MAIN_WORKTREE" rev-list --count "$RANGE")"
if [[ -z "$RANGE_COUNT" || "$RANGE_COUNT" == "0" ]]; then
  echo 'Nothing to push'
  exit 0
fi

# Locked SVN body = every non-merge subject (no commit-type filtering; merges excluded by parent
# count). Persisted to a pin file below so submit-svn-commit.sh combines it with the agent-supplied
# title — the agent cannot alter the body.
SVN_BODY="$(get_svn_push_body "$MAIN_WORKTREE" "$RANGE")"
if [[ -z "$SVN_BODY" ]]; then
  # Range has commits, but ALL are merges → no code-level subjects. Hard-stop BEFORE staging a
  # merge, keeping the SVN body and release-tag rule consistent (no merge commit is produced here).
  echo "Error: only merge commit(s) in range '$RANGE': nothing to record in the SVN body. Add a non-merge commit (or rebase), then retry." >&2
  exit 1
fi

# Bridges created before this pin exists still carry the inherited core.autocrlf, and THIS is
# the step that actually writes CRLF out: the merge checks the changed files out into the
# bridge, and `svn commit` ships whatever landed. Pinning here (idempotent) fixes those too.
ensure_bridge_eol_faithful "$MAIN_WORKTREE" "$REMOTE_PATH"

if ! git -C "$REMOTE_PATH" merge --no-ff --no-commit -m "Merge branch '$BRANCH' into $REMOTE_BRANCH" "$BRANCH" >/dev/null 2>&1; then
  CONFLICTS="$(git -C "$REMOTE_PATH" diff --name-only --diff-filter=U)"
  echo "Error: merge conflict in remote worktree. Resolve the following files in '$REMOTE_NAME', then re-run, or abort with 'git -C $REMOTE_PATH merge --abort':" >&2
  echo "$CONFLICTS" >&2
  exit 1
fi

# Pin the source branch HEAD SHA so push-to-svn-commit can detect new commits added after prepare.
# NOTE: in a linked worktree, .git is a pointer FILE; resolve via `git rev-parse --absolute-git-dir`.
SHA_GITDIR="$(git -C "$REMOTE_PATH" rev-parse --absolute-git-dir)"
BRANCH_HEAD_SHA="$(git -C "$MAIN_WORKTREE" rev-parse "$BRANCH")"
printf '%s' "$BRANCH_HEAD_SHA" > "$SHA_GITDIR/MERGE_HEAD.tp_branch_sha"

# F12: also snapshot svn status so push-to-svn-commit can detect files added/removed
# in the remote worktree after prepare (drift guard in addition to SHA pin).
# Capture before any svn-add/svn-delete — this is the starting state.
# Use --xml-based capture (UTF-8 paths) so the snapshot is encoding-consistent.
svn_status_xml "$REMOTE_PATH" > "$SHA_GITDIR/MERGE_HEAD.tp_svn_status"

# Persist the LOCKED body alongside the other prepare-time pins (read back by submit-svn-commit.sh).
write_utf8_no_bom "$SHA_GITDIR/MERGE_HEAD.tp_svn_body" "$SVN_BODY"

# Emit the locked body (for the SKILL to display) + the file list. Same string as the pin file.
echo 'BODY'
printf '%s\n' "$SVN_BODY"
echo ''
echo 'FILES'
svn_status_xml "$REMOTE_PATH" | while IFS=$'\t' read -r status filepath; do
  [[ -z "$filepath" ]] && continue
  case "$status" in
    '?') diff_status='A' ;;
    '!') diff_status='D' ;;
    'M') diff_status='M' ;;
    *)   continue ;;
  esac
  if git -C "$REMOTE_PATH" check-ignore -q "$filepath" 2>/dev/null; then
    kind='ignored'
  else
    kind='tracked'
  fi
  echo "$diff_status|$kind|$filepath"

  # An unversioned DIRECTORY is one '?' line in svn status but many files on the way to SVN --
  # expand it so the confirmation shows the real scope (issue #24; full rationale on
  # expand_unversioned_dir in lib/common.sh).
  #
  # An ignored directory is NOT expanded: git-ignored trees (node_modules/, bin/) can hold
  # thousands of files, the folder line already says it is ignored, and listing its contents
  # would bury the entries that matter.
  if [[ "$diff_status" == 'A' && "$kind" == 'tracked' && -d "$REMOTE_PATH/$filepath" ]]; then
    expand_unversioned_dir "$REMOTE_PATH" "$filepath"
  fi
done
