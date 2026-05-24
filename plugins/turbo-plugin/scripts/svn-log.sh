#!/usr/bin/env bash
# Usage: svn-log.sh [--branch <main|test-<n>>] [--limit <n>] [--verbose]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH='main'
LIMIT='50'
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)  [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --limit)   [[ $# -ge 2 ]] || { echo "Error: --limit requires a value" >&2; exit 1; }; LIMIT="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Error: unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --limit must be a positive integer (got '$LIMIT')." >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree)"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH" >&2; exit 1
fi

# Strip " (...)" only from SVN log header lines (r<n> | author | ...) to remove path suffixes.
# Body lines (commit message content) are left unchanged.
strip_header_parens() {
  while IFS= read -r line; do
    if [[ "$line" =~ ^r[0-9]+[[:space:]]*\| ]]; then
      # shellcheck disable=SC2001
      echo "$line" | LANG=C sed 's/ ([^)]*)//g'
    else
      echo "$line"
    fi
  done
}

if [[ "$VERBOSE" == true ]]; then
  svn log -v --limit "$LIMIT" "$REMOTE_PATH" | strip_header_parens
else
  svn log --limit "$LIMIT" "$REMOTE_PATH" | strip_header_parens
fi
