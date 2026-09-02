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
#     ERROR > BRANCH_IS_BASE > BRIDGE_BRANCH > BRANCH_NOT_FOUND > BASE_NOT_FOUND
#           > SOURCE_DIRTY > MAIN_DIRTY > MAIN_DETACHED > BASE_ELSEWHERE
#           > NOTHING_TO_MERGE > BEHIND_BASE > READY  (report mode)
#           > MERGED | CONFLICT                       (--merge mode)
#
# DELETING THE SOURCE BRANCH (--delete-branch, requires --merge)
#   A PR host offers "Delete branch" once the merge lands, and repos can have it done for them.
#   Without that step the branch ref simply stays, looking exactly like the branches still being
#   worked on -- so the cost is not one stale ref, it is that after a while nobody can tell which
#   refs mean anything. `ExitWorktree`'s `remove` does not cover it either: it belongs to the
#   harness rather than this plugin, and the branch may well have no worktree at all (a
#   `git checkout -b` inside an existing one is the common way to make a one-commit branch).
#   Never the default, and never unasked: some branches are merged somewhere and still wanted
#   (integration first, `main` later). The SKILL asks; this flag is the answer being carried out.
#   READY and NOTHING_TO_MERGE therefore carry `worktree=yes|no`, which is what tells the SKILL
#   whether deleting the ref is even the right question -- see the ROUTING CONTRACT above.
#
# THE `behind` GATE
#   BEHIND_BASE is what a PR host means by "this branch is out of date with the base branch".
#   It is a gate rather than a line of prose because the failure it catches is silent: the
#   report has always printed `behind : N`, and a merge went ahead regardless, so the merged
#   work was never once seen alongside the state of BASE it was landing on. Two sides that each
#   build can still fail together, and nothing here would have said so -- the next person to
#   build finds out, with it already on BASE.
#   `--allow-behind` is the deliberate override, and it is what the SKILL passes once the user
#   has been shown the count and said to merge anyway. Refusing outright would be worse: the
#   user is the only judge available in a repo with no CI, and a gate with no way through just
#   teaches people to stop using the tool.
#
#   CONSEQUENCE, and it is not an accident: CONFLICT is now only reachable WITH --allow-behind.
#   A merge can only conflict if BASE moved since the branch forked -- and if BASE moved, the
#   branch is behind, so the gate fires first. That is the right order. The advice on a conflict
#   was always "merge BASE into the branch and resolve it there", which is exactly what the gate
#   sends the user to do, one step earlier and without a failed merge in between.
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
ALLOW_BEHIND=0
DELETE_BRANCH=0
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
    --allow-behind) ALLOW_BEHIND=1; shift ;;
    --delete-branch) DELETE_BRANCH=1; shift ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --repo-root=*) REPO_ROOT="${1#--repo-root=}"; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$BASE" ]]; then echo "Error: --base requires a non-empty value" >&2; exit 1; fi
# Report mode is read-only and stays that way. Refusing the combination outright, rather than
# ignoring the flag, keeps that promise checkable instead of relying on the caller's memory.
if [[ "$DELETE_BRANCH" -eq 1 && "$DO_MERGE" -eq 0 ]]; then
  echo "Error: --delete-branch requires --merge (report mode never writes)." >&2
  exit 1
fi

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

# `remote-svn/*` are the SVN bridge branches, and this script must not touch either end of one:
#   - as BASE, this would merge work INTO the bridge -- exactly what merge-main-into-branches
#     excludes, and it pollutes the tree that gets committed back to SVN.
#   - as BRANCH, merging the bridge into a work branch is a real operation, but it belongs to
#     tp-pull-from-svn, which also maintains the revision bookkeeping. Doing it here would
#     produce the same merge commit with none of that state updated.
# Refused by NAME, before the existence checks: the answer must not depend on whether the
# bridge happens to exist yet.
for _n in "$BRANCH" "$BASE"; do
  if [[ "$_n" == remote-svn/* ]]; then
    echo "${PREFIX}BRIDGE_BRANCH name=$_n"
    exit 0
  fi
done

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
# NOTE on `2>/dev/null` rather than `2>&1` on this and every value-carrying call below. git
# writes warnings to stderr while still exiting 0 -- `detected dubious ownership` is the common
# one, and it appears exactly where this script runs (CI images, agent containers, a repo owned
# by another user). Folding that into the captured value makes `status --porcelain` non-empty on
# a perfectly clean tree, which this script would then report as SOURCE_DIRTY / MAIN_DIRTY and
# refuse a merge it should have offered. Discarding stderr keeps the VALUE trustworthy; the
# exit-code check is what catches a real failure, and the token carries enough context to act on.
if ! WT_LIST="$(git -C "$MAIN_WORKTREE" worktree list --porcelain 2>/dev/null)"; then
  _die_token "git worktree list failed in $MAIN_WORKTREE"
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
  if ! SRC_STATUS="$(git -C "$SOURCE_WT" status --porcelain 2>/dev/null)"; then
    _die_token "git status --porcelain failed in $SOURCE_WT"
  fi
  if [[ -n "$SRC_STATUS" ]]; then
    echo "${PREFIX}SOURCE_DIRTY path=$SOURCE_WT"
    exit 0
  fi
fi

if ! MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain 2>/dev/null)"; then
  _die_token "git status --porcelain failed in $MAIN_WORKTREE"
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

# Reported on READY / NOTHING_TO_MERGE so the SKILL knows which question to ask: a branch with a
# worktree is `ExitWorktree`'s to remove (ref and worktree together), one without is a plain ref
# the user may want deleted here.
HAS_WT='no'
[[ -n "$SOURCE_WT" ]] && HAS_WT='yes'

# Delete the source branch -- only on proof that BASE really contains it. Echoes 'yes' or
# 'no <reason-slug>'.
#
# The proof is `merge-base --is-ancestor` against the base actually merged into, NOT `git branch
# -d`'s own verdict: -d judges "already merged" relative to the CURRENT HEAD, and the main
# worktree is not necessarily parked on BASE. A branch genuinely merged into BASE is routinely
# refused as `not fully merged` when asked from some third branch.
# So the -D below is not "-d said no, force it anyway": -d is tried first as an independent
# second opinion, and -D only ever runs on an ancestry proof that -d had no access to.
try_delete_branch() {
  # git refuses to delete a branch any worktree has checked out -- including the main one, when
  # the run started there. Answered here rather than left to git so the reason survives.
  if [[ -n "$SOURCE_WT" ]]; then echo 'no has-worktree'; return 0; fi
  if ! git -C "$MAIN_WORKTREE" merge-base --is-ancestor "$BRANCH" "$BASE" >/dev/null 2>&1; then
    echo 'no not-ancestor'; return 0
  fi
  if git -C "$MAIN_WORKTREE" branch -d "$BRANCH" >/dev/null 2>&1; then echo 'yes'; return 0; fi
  if git -C "$MAIN_WORKTREE" branch -D "$BRANCH" >/dev/null 2>&1; then echo 'yes'; return 0; fi
  echo 'no delete-failed'
}

# Fields appended to the two tokens that can report a deletion, plus the human-readable line that
# explains a refusal. `reason=` is present only when nothing was deleted, so `deleted=yes` needs
# no second field to be unambiguous.
DELETED='no'
DEL_REASON='not-requested'
DEL_FIELDS=''
run_delete() {
  if [[ "$DELETE_BRANCH" -eq 1 ]]; then
    local res
    res="$(try_delete_branch)"
    DELETED="${res%% *}"
    [[ "$DELETED" == 'no' ]] && DEL_REASON="${res#no }"
  fi
  DEL_FIELDS="deleted=$DELETED"
  [[ "$DELETED" == 'no' ]] && DEL_FIELDS="$DEL_FIELDS reason=$DEL_REASON"

  if [[ "$DELETED" == 'yes' ]]; then
    echo "Deleted branch '$BRANCH' (verified merged into '$BASE')."
  elif [[ "$DELETE_BRANCH" -eq 1 ]]; then
    case "$DEL_REASON" in
      has-worktree)  echo "Branch '$BRANCH' was NOT deleted: it is checked out at $SOURCE_WT." ;;
      not-ancestor)  echo "Branch '$BRANCH' was NOT deleted: '$BASE' does not contain it." ;;
      *)             echo "Branch '$BRANCH' was NOT deleted: git refused to remove the ref." ;;
    esac
  fi
}

# --- The report -------------------------------------------------------------------------

if ! COUNTS="$(git -C "$MAIN_WORKTREE" rev-list --left-right --count "$BASE...$BRANCH" 2>/dev/null)"; then
  _die_token "git rev-list failed for $BASE...$BRANCH"
fi
BEHIND="$(printf '%s' "$COUNTS" | awk '{print $1}')"
AHEAD="$(printf '%s' "$COUNTS" | awk '{print $2}')"

if [[ "$AHEAD" -eq 0 ]]; then
  # Already fully in BASE, so this is the other place a deletion belongs: the branch is exactly
  # as safe to remove as it is after a merge, and telling the user "you can clean this up" while
  # leaving them to do it by hand is the same gap one step over.
  run_delete
  echo "${PREFIX}NOTHING_TO_MERGE branch=$BRANCH base=$BASE worktree=$HAS_WT $DEL_FIELDS"
  exit 0
fi

# Guarded like every other call, for the same reason: under `set -e` an unchecked failure here
# would abort with no token at all, and the SKILL routes on nothing else.
if ! SUBJECTS="$(git -C "$MAIN_WORKTREE" log --no-merges --reverse --format='  %h %s' "$BASE..$BRANCH" 2>/dev/null)"; then
  _die_token "git log failed for $BASE..$BRANCH"
fi
NON_MERGE_COUNT="$(printf '%s\n' "$SUBJECTS" | grep -c '[^[:space:]]' || true)"
if ! DIFFSTAT="$(git -C "$MAIN_WORKTREE" -c core.quotePath=false diff --stat "$BASE...$BRANCH" 2>/dev/null)"; then
  _die_token "git diff --stat failed for $BASE...$BRANCH"
fi

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
if [[ "$BEHIND" -gt 0 ]]; then
  echo ''
  echo "  NOTE: $BASE has $BEHIND commit(s) that $BRANCH does not. This work has never"
  echo "        been built or checked alongside them."
fi
echo '─────────────────────────────────────────────────────────────────────'

# The `behind` gate. Placed AFTER the report on purpose: the counts and the commit list are what
# the user needs in order to answer, so they get printed either way, and only the terminal token
# differs. See the header for why this refuses by default.
if [[ "$BEHIND" -gt 0 && "$ALLOW_BEHIND" -eq 0 ]]; then
  echo "${PREFIX}BEHIND_BASE branch=$BRANCH base=$BASE ahead=$AHEAD behind=$BEHIND main=$MAIN_WORKTREE"
  exit 0
fi

if [[ "$DO_MERGE" -eq 0 ]]; then
  echo "${PREFIX}READY branch=$BRANCH base=$BASE ahead=$AHEAD behind=$BEHIND worktree=$HAS_WT main=$MAIN_WORKTREE"
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
  # Tolerant on purpose, and it is the one place in this script where that is right: the merge
  # has ALREADY been written to $BASE. Aborting here over a failure to pretty-print its sha
  # would report "not merged" about a branch that is merged -- the worst answer available.
  MERGE_SHA="$(git -C "$MAIN_WORKTREE" rev-parse --short "refs/heads/$BASE" 2>/dev/null || true)"
  [[ -n "$MERGE_SHA" ]] || MERGE_SHA='(unknown)'
  restore_original
  echo ''
  echo "Merged '$BRANCH' into '$BASE' as $MERGE_SHA."
  # After restore_original, so the run is standing where it will finish before any ref is
  # removed, and after the merge, so the ancestry proof inside is about the state that now exists.
  run_delete
  echo "${PREFIX}MERGED branch=$BRANCH base=$BASE commit=$MERGE_SHA $DEL_FIELDS"
  exit 0
fi

git -C "$MAIN_WORKTREE" merge --abort >/dev/null 2>&1 || true
restore_original
echo ''
echo "Merge conflicted; '$BASE' was left exactly as it was (merge aborted)."
echo "${PREFIX}CONFLICT branch=$BRANCH base=$BASE"
exit 1
