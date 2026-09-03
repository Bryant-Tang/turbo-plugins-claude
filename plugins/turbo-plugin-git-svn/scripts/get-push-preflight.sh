#!/usr/bin/env bash
# Pre-flight detection for tp-push-to-svn first-push bootstrap.
# Emits exactly ONE terminal routing token prefixed 'TP_TOKEN:'. See the .ps1 sibling
# for the full contract. Precedence:
#   DETACHED_HEAD > BRANCH_MISMATCH_WARNING > BRIDGE_ABSENT > BRIDGE_PRESENT
# BRANCH_MISMATCH_WARNING fires when the requested branch is checked out in NO worktree at all
# (not merely "the main worktree is on something else") -- see the gate itself for why.
# The SKILL reads ONLY the TP_TOKEN: line and routes; it does NOT run git itself.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PREFIX='TP_TOKEN:'
BRANCH=''
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

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
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
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
if ! MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT" 2>&1)"; then _die_token "$MAIN_WORKTREE"; fi
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

# The mismatch heuristic asks "is there any sign the caller means THIS branch". It used to
# answer that with "is the MAIN worktree standing on it" -- which is wrong the moment a linked
# worktree exists, and wrong in the direction that dead-ends the workflow this plugin is built
# around (issue #161):
#
#   - Developing on a branch in its own worktree means git will NOT let the main worktree hold
#     it too. So the answer was always "no", the warning always fired, and the SKILL's advice
#     for it ("check the branch out in the main worktree and re-run") was IMPOSSIBLE to follow.
#   - Because mismatch outranks the bridge check, the first push of a new branch could never
#     reach BRIDGE_ABSENT -- and first push is the one step every branch must go through.
#   - The message was not merely blocking, it was FALSE: standing in the `dev` worktree, the
#     user was told "you are currently on main".
#
# Being checked out ANYWHERE -- main or linked -- is the evidence the gate was reaching for,
# and it costs nothing to ask for the real thing. What the gate protects is unchanged: it is a
# "did you mean this branch" heuristic with no functional dependency behind it. Nothing in the
# push path reads the main worktree's HEAD -- build-svn-commit merges the NAMED branch ref into
# the bridge worktree, and new-remote-bridge bases the bridge branch on refs/heads/remote-svn/main
# (deliberately, see the comment there). The permanent SVN write is guarded by the SKILL's own
# confirmation of the file list and message, which is untouched.
#
# Read the list ONCE with the failure checked: letting a git failure fall through would answer
# "no worktree holds it", which is exactly the healthy answer for the case that must warn.
if ! WT_LIST="$(git -C "$MAIN_WORKTREE" worktree list --porcelain 2>/dev/null)"; then
  _die_token "git worktree list failed in $MAIN_WORKTREE"
fi
if ! RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR" 2>&1)"; then _die_token "$RESOLVED"; fi
REMOTE_PATH="${RESOLVED##*|}"
if [[ -d "$REMOTE_PATH" ]]; then BRIDGE='present'; else BRIDGE='absent'; fi

# The warning carries the bridge state so it is a WARNING and not a dead end.
#
# "Nobody has this branch checked out" is worth saying -- it is the shape a typo'd branch name
# makes. It is not worth REFUSING over, and refusing was doing real damage: the only way past it
# was to check the branch out in the MAIN worktree, and a branch that no worktree holds is
# routinely the normal state for one that is never developed on directly (an integration branch
# that only ever receives merges). Sending the user to move the main checkout is also the one
# thing a background session is asked not to do -- someone else may be using it.
#
# So the SKILL gets everything it needs to continue after the user confirms the name is right,
# instead of having to re-run and land on the identical token. This is what the prepare-side
# backstop has always done (emit the warning, keep going); the two now agree.
if [[ -z "$(worktree_for_branch "$BRANCH" "$WT_LIST")" ]]; then
  echo "${PREFIX}BRANCH_MISMATCH_WARNING current=$CURRENT requested=$BRANCH bridge=$BRIDGE target=$REMOTE_PATH"
  exit 0
fi

if [[ "$BRIDGE" == 'present' ]]; then
  echo "${PREFIX}BRIDGE_PRESENT requested=$BRANCH"
else
  echo "${PREFIX}BRIDGE_ABSENT requested=$BRANCH target=$REMOTE_PATH"
fi
exit 0
