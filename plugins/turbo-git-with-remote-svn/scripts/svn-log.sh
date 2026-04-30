#!/usr/bin/env bash
# Usage: svn-log.sh [--branch <main|test-<n>>] [--limit <n>] [--verbose]
set -euo pipefail

BRANCH="${TGS_SVN_LOG_DEFAULT_BRANCH:-main}"
LIMIT="${TGS_SVN_LOG_DEFAULT_LIMIT:-50}"
_TGS_VERBOSE="${TGS_SVN_LOG_DEFAULT_VERBOSE:-}"
case "${_TGS_VERBOSE,,}" in
  1|true) VERBOSE=true ;;
  *) VERBOSE=false ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)  [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --limit)   [[ $# -ge 2 ]] || { echo "Error: --limit requires a value" >&2; exit 1; }; LIMIT="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Error: unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --limit must be a positive integer (got '$LIMIT')." >&2; exit 1
fi

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

if [[ "$BRANCH" == 'main' ]]; then
  REMOTE_WORKTREE_NAME='remote-main'
elif [[ "$BRANCH" =~ ^test-([0-9]+)$ ]]; then
  N="${BASH_REMATCH[1]}"
  REMOTE_WORKTREE_NAME="remote-test-$N"
else
  echo "Error: unsupported branch '$BRANCH'. Only 'main' and 'test-<n>' are supported." >&2; exit 1
fi

REMOTE_WORKTREE_PATH="$WORKTREES_DIR/$REMOTE_WORKTREE_NAME"

if [[ ! -d "$REMOTE_WORKTREE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_WORKTREE_NAME' not found at: $REMOTE_WORKTREE_PATH" >&2; exit 1
fi

if [[ "$VERBOSE" == true ]]; then
  svn log -v --limit "$LIMIT" "$REMOTE_WORKTREE_PATH" | LANG=C sed 's/ ([^)]*)//g'
else
  svn log --limit "$LIMIT" "$REMOTE_WORKTREE_PATH" | LANG=C sed 's/ ([^)]*)//g'
fi
