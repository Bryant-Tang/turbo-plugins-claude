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

# Emit a terminal ERROR token on the SKILL's routing channel (parity with the .ps1 catch),
# for a POST-sanitization failure (e.g. MAX_PATH in resolve) so it is never a tokenless
# non-zero exit. (Pre-sanitization rejection stays tokenless -- anti-forge.) Collapse
# newlines and neutralize any embedded TP_TOKEN: so the reason can't forge a line.
_die_token() {
  local reason
  reason="$(printf '%s' "$1" | tr '\r\n' '  ' | sed 's/TP_TOKEN:/TP_TOKEN_/g')"
  echo "${PREFIX}ERROR reason=$reason"
  exit 1
}

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

# Sanitize the requested branch BEFORE emitting any token (anti-forge): a forged/invalid
# branch is a hard error and stays tokenless, never earning a token. Only POST-sanitization
# failures (e.g. MAX_PATH in resolve below, or worktree resolution) emit TP_TOKEN:ERROR.
assert_valid_remote_branch_name "$BRANCH" || exit 1

# Post-sanitization: worktree resolution failures emit TP_TOKEN:ERROR (parity with the .ps1
# catch, which fires for the same Get-MainWorktree/Get-WorktreesDir throws once sanitized).
if ! MAIN_WORKTREE="$(get_main_worktree 2>&1)"; then _die_token "$MAIN_WORKTREE"; fi
if ! WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE" 2>&1)"; then _die_token "$WORKTREES_DIR"; fi

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

if ! RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR" 2>&1)"; then _die_token "$RESOLVED"; fi
REMOTE_PATH="${RESOLVED##*|}"
if [[ -d "$REMOTE_PATH" ]]; then
  echo "${PREFIX}BRIDGE_PRESENT requested=$BRANCH"
else
  echo "${PREFIX}BRIDGE_ABSENT requested=$BRANCH target=$REMOTE_PATH"
fi
exit 0
