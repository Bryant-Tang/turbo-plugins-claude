#!/usr/bin/env bash
# request-merge.sh -- the stand-in for a pull request in a repo that has no git remote.
#
# WHY THIS EXISTS
#   turbo-plugin-git-svn serves purely local git <-> SVN projects. There is no git remote,
#   so there is no PR, and therefore no "a human presses Merge" step. That step is not a
#   formality: `ExitWorktree`'s `remove` deletes the branch along with the worktree, and it
#   is only safe to do that once the branch has been merged. Without a PR nothing supplies
#   that guarantee, so on the ordinary success path `remove` is unusable -- refusing without
#   `discard_changes`, and destroying unmerged work with it.
#
#   This script supplies the missing step: it reports what would be merged (read-only, the
#   default), and -- on a separate invocation carrying --merge -- performs the merge in the
#   MAIN worktree. The confirmation in between belongs to the SKILL, not here.
#
# MIRROR OF merge-main-into-branches.sh
#   That script is the downstream direction (main -> branches); this is the upstream one
#   (branch -> main). They deliberately share their shape: locate the main worktree with
#   get_main_worktree so a call from a linked worktree still acts on the main one, refuse a
#   dirty tree before touching anything, and on conflict `merge --abort` rather than leaving
#   a conflicted tree behind.
#
# ROUTING CONTRACT
#   Emits exactly ONE terminal token line prefixed 'TP_TOKEN:'. The SKILL reads ONLY that
#   line and routes on it; it does NOT run git itself. Precedence (a total order):
#
#     ERROR > BRANCH_IS_BASE > BRANCH_NOT_FOUND > BASE_NOT_FOUND
#           > SOURCE_DIRTY > MAIN_DIRTY > MAIN_DETACHED > BASE_ELSEWHERE
#           > NOTHING_TO_MERGE > READY            (report mode)
#           > MERGED | CONFLICT                   (--merge mode)
#
#   --merge re-runs every check above before acting. That is the point of putting both modes
#   in one script rather than two: the gate the user was shown and the gate that admits the
#   merge are the same code, so they cannot drift, and a tree that changed while the user was
#   deciding is caught rather than merged on the strength of a stale report.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

PREFIX='TP_TOKEN:'
BRANCH=''
BASE='main'
DO_MERGE=0
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

# Emit a terminal ERROR token for a POST-validation failure, so such a failure is never a
# tokenless non-zero exit. Pre-validation rejection stays tokenless (anti-forge). Collapse
# newlines and neutralize any embedded TP_TOKEN: so the reason cannot forge a routing line.
_die_token() {
  local reason
  reason="$(printf '%s' "$1" | tr '\r\n' '  ' | sed 's/TP_TOKEN:/TP_TOKEN_/g')"
  echo "${PREFIX}ERROR reason=$reason"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --branch=*)  BRANCH="${1#--branch=}"; shift ;;
    --base)      [[ $# -ge 2 ]] || { echo "Error: --base requires a value" >&2; exit 1; }; BASE="$2"; shift 2 ;;
    --base=*)    BASE="${1#--base=}"; shift ;;
    --merge)     DO_MERGE=1; shift ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --repo-root=*) REPO_ROOT="${1#--repo-root=}"; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$BASE" ]]; then echo "Error: --base requires a non-empty value" >&2; exit 1; fi

# Validate BEFORE emitting any token (anti-forge): a malformed ref name is a hard, tokenless
# error and never earns a routing token. `check-ref-format` is git's own validator, so this
# tracks git's rules rather than a hand-rolled pattern. Note refnames cannot contain ':' at
# all, which is independently why a branch name cannot forge a 'TP_TOKEN:' line.
for _n in "$BRANCH" "$BASE"; do
  if ! git check-ref-format "refs/heads/$_n" >/dev/null 2>&1; then
    echo "Error: '$_n' is not a valid branch name." >&2
    exit 1
  fi
done

# Post-validation: resolution failures route as TP_TOKEN:ERROR.
if ! MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT" 2>&1)"; then _die_token "$MAIN_WORKTREE"; fi

# --- Guards, in precedence order -------------------------------------------------------

if [[ "$BRANCH" == "$BASE" ]]; then
  echo "${PREFIX}BRANCH_IS_BASE branch=$BRANCH"
  exit 0
fi

if ! git -C "$MAIN_WORKTREE" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  echo "${PREFIX}BRANCH_NOT_FOUND branch=$BRANCH"
  exit 0
fi
if ! git -C "$MAIN_WORKTREE" rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null; then
  echo "${PREFIX}BASE_NOT_FOUND base=$BASE"
  exit 0
fi

# Read the worktree list ONCE, with the failure checked. Reading it inside the lookup via a
# process substitution would turn a git failure into "no worktree has this branch", which
# reads exactly like the healthy answer and would make the SOURCE_DIRTY guard below pass
# without ever looking at anything.
if ! WT_LIST="$(git -C "$MAIN_WORKTREE" worktree list --porcelain 2>&1)"; then
  _die_token "git worktree list failed in $MAIN_WORKTREE: $WT_LIST"
fi

# Which worktree, if any, has a given branch checked out. Echoes the normalized absolute
# path, or nothing. The path is normalized before it is ever compared: git reports Windows
# paths as `C:/...` while other sources hand back `/c/...`, and comparing those two spellings
# is false every single time without saying so.
worktree_for_branch() {
  local want="$1" line cur=''
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) cur="${line#worktree }" ;;
      "branch refs/heads/$want")
        [[ -n "$cur" ]] && get_normalized_absolute_path "$cur"
        return 0
        ;;
    esac
  done <<< "$WT_LIST"
  return 0
}

# The work must be fully committed. This is the guard that matters most for the case this
# script exists for: the caller is about to merge and then let `remove` delete the branch and
# its worktree. Anything still uncommitted there is not in the merge and does not survive the
# removal -- and nothing else in the sequence would have said so.
SOURCE_WT="$(worktree_for_branch "$BRANCH")"
if [[ -n "$SOURCE_WT" ]]; then
  if ! SRC_STATUS="$(git -C "$SOURCE_WT" status --porcelain 2>&1)"; then
    _die_token "git status --porcelain failed in $SOURCE_WT: $SRC_STATUS"
  fi
  if [[ -n "$SRC_STATUS" ]]; then
    echo "${PREFIX}SOURCE_DIRTY path=$SOURCE_WT"
    exit 0
  fi
fi

if ! MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain 2>&1)"; then
  _die_token "git status --porcelain failed in $MAIN_WORKTREE: $MAIN_STATUS"
fi
if [[ -n "$MAIN_STATUS" ]]; then
  echo "${PREFIX}MAIN_DIRTY path=$MAIN_WORKTREE"
  exit 0
fi

# A detached main worktree has no branch to come back to. Merging anyway would check out BASE
# and leave it there, quietly moving the user off the commit they had parked on. Refuse and
# say which state it is in, rather than pick a plausible-looking place to leave them.
ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" symbolic-ref -q --short HEAD 2>/dev/null || true)"
if [[ -z "$ORIGINAL_BRANCH" ]]; then
  echo "${PREFIX}MAIN_DETACHED path=$MAIN_WORKTREE"
  exit 0
fi

# The merge happens on BASE in the main worktree, so BASE has to be checkout-able there.
# git forbids the same branch in two worktrees at once, so if BASE lives in some other
# worktree the checkout would fail partway through. Say so up front instead.
BASE_WT="$(worktree_for_branch "$BASE")"
if [[ -n "$BASE_WT" && "$BASE_WT" != "$MAIN_WORKTREE" ]]; then
  echo "${PREFIX}BASE_ELSEWHERE base=$BASE path=$BASE_WT"
  exit 0
fi

# --- The report -------------------------------------------------------------------------

if ! COUNTS="$(git -C "$MAIN_WORKTREE" rev-list --left-right --count "$BASE...$BRANCH" 2>&1)"; then
  _die_token "git rev-list failed for $BASE...$BRANCH: $COUNTS"
fi
BEHIND="$(printf '%s' "$COUNTS" | awk '{print $1}')"
AHEAD="$(printf '%s' "$COUNTS" | awk '{print $2}')"

if [[ "$AHEAD" -eq 0 ]]; then
  echo "${PREFIX}NOTHING_TO_MERGE branch=$BRANCH base=$BASE"
  exit 0
fi

SUBJECTS="$(git -C "$MAIN_WORKTREE" log --no-merges --reverse --format='  %h %s' "$BASE..$BRANCH")"
NON_MERGE_COUNT="$(printf '%s\n' "$SUBJECTS" | grep -c '[^[:space:]]' || true)"
DIFFSTAT="$(git -C "$MAIN_WORKTREE" diff --stat "$BASE...$BRANCH")"

echo '─── Merge request ───────────────────────────────────────────────────'
echo "  branch : $BRANCH"
echo "  base   : $BASE"
echo "  repo   : $MAIN_WORKTREE"
echo "  ahead  : $AHEAD commit(s) not in $BASE"
echo "  behind : $BEHIND commit(s) in $BASE not in $BRANCH"
echo ''
echo "Commits to be merged (oldest first):"
if [[ -n "$SUBJECTS" ]]; then echo "$SUBJECTS"; fi
if [[ "$AHEAD" -gt "$NON_MERGE_COUNT" ]]; then
  echo "  (+ $((AHEAD - NON_MERGE_COUNT)) merge commit(s) not listed)"
fi
echo ''
echo "Changes vs $BASE:"
if [[ -n "$DIFFSTAT" ]]; then echo "$DIFFSTAT"; else echo '  (no file changes)'; fi
echo '─────────────────────────────────────────────────────────────────────'

if [[ "$DO_MERGE" -eq 0 ]]; then
  echo "${PREFIX}READY branch=$BRANCH base=$BASE ahead=$AHEAD main=$MAIN_WORKTREE"
  exit 0
fi

# --- The merge ---------------------------------------------------------------------------

restore_original() {
  # ORIGINAL_BRANCH is known non-empty here: a detached main worktree was refused above.
  if [[ "$ORIGINAL_BRANCH" != "$BASE" ]]; then
    git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
  fi
}

if [[ "$ORIGINAL_BRANCH" != "$BASE" ]]; then
  if ! CO="$(git -C "$MAIN_WORKTREE" checkout "$BASE" 2>&1)"; then
    _die_token "could not check out '$BASE' in $MAIN_WORKTREE: $CO"
  fi
fi

if git -C "$MAIN_WORKTREE" merge --no-ff "$BRANCH" -m "Merge branch '$BRANCH' into $BASE" >/dev/null 2>&1; then
  MERGE_SHA="$(git -C "$MAIN_WORKTREE" rev-parse --short "refs/heads/$BASE")"
  restore_original
  echo ''
  echo "Merged '$BRANCH' into '$BASE' as $MERGE_SHA."
  echo "${PREFIX}MERGED branch=$BRANCH base=$BASE commit=$MERGE_SHA"
  exit 0
fi

git -C "$MAIN_WORKTREE" merge --abort >/dev/null 2>&1 || true
restore_original
echo ''
echo "Merge conflicted; '$BASE' was left exactly as it was (merge aborted)."
echo "${PREFIX}CONFLICT branch=$BRANCH base=$BASE"
exit 1
