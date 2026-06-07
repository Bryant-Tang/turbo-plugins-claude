#!/usr/bin/env bash
# Usage: build-svn-commit.sh --branch <branch>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)  [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required (e.g. main or feat/login)" >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree)"
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
# v0.5.0 U9 (R3-1): prefix with TP_TOKEN: to match the pre-flight contract — the SKILL only
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
LOCAL_REV="$(svn info --show-item revision "$REMOTE_PATH")"
HEAD_REV="$(svn info --show-item revision "$SVN_URL")"

if [[ "$LOCAL_REV" != "$HEAD_REV" ]]; then
  echo "Error: remote SVN worktree is not up to date (local r$LOCAL_REV, head r$HEAD_REV). Run '/tp-pull-from-svn --branch $BRANCH' first." >&2
  exit 1
fi

LOG_OUTPUT="$(git -C "$MAIN_WORKTREE" log "$REMOTE_BRANCH..$BRANCH" --reverse --pretty=format:'%h|%s')"
if [[ -z "$LOG_OUTPUT" ]]; then
  echo 'Nothing to push'
  exit 0
fi

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
svn status "$REMOTE_PATH" > "$SHA_GITDIR/MERGE_HEAD.tp_svn_status"

echo 'COMMITS'
echo "$LOG_OUTPUT"
echo ''
echo 'FILES'
(cd "$REMOTE_PATH" && svn status) | tr -d '\r' | while IFS= read -r line; do
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
  if git -C "$REMOTE_PATH" check-ignore -q "$filepath" 2>/dev/null; then
    echo "$diff_status|ignored|$filepath"
  else
    echo "$diff_status|tracked|$filepath"
  fi
done
