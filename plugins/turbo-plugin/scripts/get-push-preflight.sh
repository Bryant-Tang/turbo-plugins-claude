#!/usr/bin/env bash
# Pre-flight detection for tp-push-to-svn first-push bootstrap (v0.5.0 U9).
# Emits exactly ONE terminal routing token prefixed 'TP_TOKEN:'. See the .ps1 sibling
# for the full contract. Precedence:
#   DETACHED_HEAD > BRANCH_MISMATCH_WARNING > BRIDGE_ABSENT > BRIDGE_PRESENT
# The SKILL reads ONLY the TP_TOKEN: line and routes; it does NOT run git itself.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PREFIX='TP_TOKEN:'
BRANCH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi

# Reject the literal 'HEAD' up-front (see .ps1 sibling for rationale).
if [[ "$BRANCH" == 'HEAD' ]]; then
  echo "${PREFIX}DETACHED_HEAD requested=HEAD"
  exit 0
fi

# Sanitize the requested branch BEFORE emitting any token (anti-forge). Invalid input
# is a hard error, never a token.
assert_valid_remote_branch_name "$BRANCH" || exit 1

MAIN_WORKTREE="$(get_main_worktree)"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

# Detached-HEAD detection via symbolic-ref (not current == requested).
if CURRENT="$(git -C "$MAIN_WORKTREE" symbolic-ref -q --short HEAD 2>/dev/null)"; then
  :
else
  CURRENT=''
fi
if [[ -z "$CURRENT" ]]; then
  echo "${PREFIX}DETACHED_HEAD requested=$BRANCH"
  exit 0
fi

if [[ "$CURRENT" != "$BRANCH" ]]; then
  echo "${PREFIX}BRANCH_MISMATCH_WARNING current=$CURRENT requested=$BRANCH"
  exit 0
fi

RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")" || exit 1
REMOTE_PATH="${RESOLVED##*|}"
if [[ -d "$REMOTE_PATH" ]]; then
  echo "${PREFIX}BRIDGE_PRESENT requested=$BRANCH"
else
  echo "${PREFIX}BRIDGE_ABSENT requested=$BRANCH target=$REMOTE_PATH"
fi
exit 0
