#!/usr/bin/env bash
# Usage: reset-branch-to-main.sh --branch <name> [--diff-only]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH=''
DIFF_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --diff-only) DIFF_ONLY=true; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree)"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"
REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_BRANCH="$(printf '%s' "$REMOTE_SPEC" | cut -d'|' -f2)"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if ! git -C "$MAIN_WORKTREE" branch --list "$BRANCH" | grep -q .; then
  echo "Error: branch '$BRANCH' does not exist." >&2; exit 1
fi
if ! git -C "$MAIN_WORKTREE" branch --list 'main' | grep -q .; then
  echo "Error: branch 'main' does not exist." >&2; exit 1
fi
if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote-svn worktree not found: $REMOTE_PATH" >&2; exit 1
fi

MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before reset." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

# v0.2.7+ F-U18.svn-state fix: filter out .svn/* paths from git status check.
# .svn/wc.db is SVN's binary metadata (modified by every svn op); treating it as
# user uncommitted change deadlocks user - told to push/pull but those touch wc.db too.
REMOTE_STATUS_RAW="$(git -C "$REMOTE_PATH" status --porcelain)"
REMOTE_STATUS="$(printf '%s' "$REMOTE_STATUS_RAW" | grep -v -E '^\s*[?MADRC!]+\s+\.svn[/\\]' || true)"
if [[ -n "$REMOTE_STATUS" ]]; then
  echo "Error: remote-svn worktree '$REMOTE_PATH' has uncommitted changes. Run /tp-push-to-svn or /tp-pull-from-svn to resolve first." >&2
  echo "$REMOTE_STATUS" >&2
  exit 1
fi

LOSE_RAW="$(git -C "$MAIN_WORKTREE" log --oneline "main..$BRANCH")"
GAIN_RAW="$(git -C "$MAIN_WORKTREE" log --oneline "$BRANCH..main")"

echo 'LOSE'
[[ -n "$LOSE_RAW" ]] && echo "$LOSE_RAW"
echo ''
echo 'GAIN'
[[ -n "$GAIN_RAW" ]] && echo "$GAIN_RAW"

# F25: emit file-impact preview - list files that would be svn-deleted on the next push.
# This lets the SKILL prompt the user before they commit to the reset.
FILES_LOST_RAW="$(git -C "$MAIN_WORKTREE" diff --name-status "main..$REMOTE_BRANCH" 2>/dev/null || true)"
echo ''
echo 'FILES_LOST_AFTER_PUSH'
[[ -n "$FILES_LOST_RAW" ]] && echo "$FILES_LOST_RAW"

if [[ "$DIFF_ONLY" == true ]]; then exit 0; fi

if [[ -z "$LOSE_RAW" && -z "$GAIN_RAW" ]]; then
  echo ''
  echo "$BRANCH already equals main. Nothing to reset."
  exit 0
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"

SWITCHED=false
if [[ "$ORIGINAL_BRANCH" != "$BRANCH" ]]; then
  echo ''
  echo "Switching main worktree from '$ORIGINAL_BRANCH' to '$BRANCH'..."
  git -C "$MAIN_WORKTREE" checkout "$BRANCH"
  SWITCHED=true
fi

if ! git -C "$MAIN_WORKTREE" reset --hard 'main'; then
  [[ "$SWITCHED" == true ]] && git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Error: git reset --hard main failed on $BRANCH" >&2
  exit 1
fi

if [[ "$SWITCHED" == true ]]; then
  git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Switched back to '$ORIGINAL_BRANCH'."
fi

echo ''
echo "Reset $BRANCH to main. Run /tp-push-to-svn --branch $BRANCH to publish."
