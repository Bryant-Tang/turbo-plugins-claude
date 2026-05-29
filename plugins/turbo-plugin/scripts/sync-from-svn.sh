#!/usr/bin/env bash
# Usage: sync-from-svn.sh --branch <main|test-<n>>
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
  echo "Error: --branch is required (main or test-<n>)" >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree)"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_BRANCH="$(printf '%s' "$REMOTE_SPEC" | cut -d'|' -f2)"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH" >&2; exit 1
fi

MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before pulling from SVN." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"

# F-U(synth #24): dirty-check remote worktree, filter out .svn/* paths.
# .svn/wc.db is modified by every svn op; treating it as uncommitted change deadlocks
# the user. Manual edits in the remote worktree would be silently packaged into the
# sync commit without this check.
REMOTE_DIRTY_RAW="$(git -C "$REMOTE_PATH" status --porcelain)"
REMOTE_DIRTY_FILTERED="$(printf '%s' "$REMOTE_DIRTY_RAW" | grep -vE '^[?MADRC! ]+ \.svn[/\\]' || true)"
if [[ -n "$REMOTE_DIRTY_FILTERED" ]]; then
  echo "Error: Remote worktree '$REMOTE_PATH' has uncommitted changes — these would be packaged into the sync commit. Resolve before pulling." >&2
  echo "$REMOTE_DIRTY_FILTERED" >&2
  exit 1
fi

# F-U(synth #11): detect previously-orphaned remote sync commit (svn update + git commit
# succeeded last time but the subsequent merge into $BRANCH was aborted). Refuse until the
# user resolves it (manual merge or rerun /tp-pull-from-svn after committing conflict resolution).
UNMERGED_REMOTE="$(git -C "$MAIN_WORKTREE" log --oneline "${BRANCH}..${REMOTE_BRANCH}" 2>/dev/null || true)"
if [[ -n "$UNMERGED_REMOTE" ]]; then
  UNMERGED_COUNT="$(printf '%s\n' "$UNMERGED_REMOTE" | wc -l | tr -d '[:space:]')"
  echo "Error: remote/${REMOTE_BRANCH} has $UNMERGED_COUNT unmerged sync commit(s) ahead of '${BRANCH}':" >&2
  printf '%s\n' "$UNMERGED_REMOTE" >&2
  echo "" >&2
  echo "Resolve via manual merge or rerun /tp-pull-from-svn after the conflict is committed." >&2
  exit 1
fi

echo "Running svn update in $REMOTE_NAME..."
pushd "$REMOTE_PATH" >/dev/null
svn update
SVN_REV="$(svn info --show-item revision)"
popd >/dev/null

REMOTE_STATUS="$(git -C "$REMOTE_PATH" status --porcelain)"
if [[ -z "$REMOTE_STATUS" ]]; then
  echo "Already up to date at SVN r$SVN_REV"
  exit 0
fi

git -C "$REMOTE_PATH" add -A
git -C "$REMOTE_PATH" commit -m "sync: svn r$SVN_REV"

SWITCHED=false
if [[ "$ORIGINAL_BRANCH" != "$BRANCH" ]]; then
  echo "Switching main worktree from '$ORIGINAL_BRANCH' to '$BRANCH'..."
  git -C "$MAIN_WORKTREE" checkout "$BRANCH"
  SWITCHED=true
fi

if ! git -C "$MAIN_WORKTREE" merge "$REMOTE_BRANCH" --no-ff -m "Merge branch '$REMOTE_BRANCH' into $BRANCH"; then
  CONFLICTS="$(git -C "$MAIN_WORKTREE" diff --name-only --diff-filter=U)"
  # Rollback: abort the merge and return to original branch so the worktree is clean.
  # Capture each rollback op's exit code separately so we can detect rollback failure
  # and emit a distinct error (working tree may be in an inconsistent state).
  if git -C "$MAIN_WORKTREE" merge --abort 2>/dev/null; then
    abort_status=0
  else
    abort_status=$?
  fi
  checkout_status=0
  if [[ "$SWITCHED" == true ]]; then
    if git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH" 2>/dev/null; then
      checkout_status=0
    else
      checkout_status=$?
    fi
  fi
  if [[ $abort_status -ne 0 || $checkout_status -ne 0 ]]; then
    echo "Merge conflict detected; automatic rollback failed (abort exit=$abort_status, checkout exit=$checkout_status). Working tree is in an inconsistent state. Resolve manually before re-running." >&2
    exit 1
  fi
  echo "Error: merge conflict detected. The merge has been aborted and main worktree restored to '$ORIGINAL_BRANCH'. Conflicting files:" >&2
  echo "$CONFLICTS" >&2
  echo "" >&2
  echo "Resolve conflicts manually, commit, then rerun '/tp-pull-from-svn'." >&2
  exit 1
fi

if [[ "$SWITCHED" == true ]]; then
  git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Switched back to '$ORIGINAL_BRANCH'."
fi

echo "Pulled SVN r$SVN_REV into $BRANCH"
