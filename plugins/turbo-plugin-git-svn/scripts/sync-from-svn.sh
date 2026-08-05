#!/usr/bin/env bash
# Usage: sync-from-svn.sh --branch <branch>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH=''
GRANULARITY=''
RANGE=''
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)      [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --granularity) [[ $# -ge 2 ]] || { echo "Error: --granularity requires a value" >&2; exit 1; }; GRANULARITY="$2"; shift 2 ;;
    --range)       [[ $# -ge 2 ]] || { echo "Error: --range requires a value" >&2; exit 1; }; RANGE="$2"; shift 2 ;;
    --repo-root)   [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

# U3/U7: the per-revision replay loop (svn update -r R -> replay-commit, squash boundary commits,
# granularity dispatch) now lives in lib/common.sh (svn_replay_one_revision / svn_boundary_commit /
# svn_replay_dispatch), shared verbatim with the first-import bootstrap (Initialize-GitSvnBridge).
# This script keeps only the resume-point (`cur`) derivation + the granularity GATE, then delegates.

probe_git_version

if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required (e.g. main or feat/login)" >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

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

# Dirty-check the remote worktree. `.svn/` is now in the bridge's .gitignore
# (synced from main by new-remote-bridge), so git ignores SVN's binary metadata and the
# manual `.svn/*` filter is gone; genuine manual edits are still caught and would otherwise
# be packaged into the sync commit.
REMOTE_DIRTY="$(git -C "$REMOTE_PATH" status --porcelain)"
if [[ -n "$REMOTE_DIRTY" ]]; then
  echo "Error: Remote worktree '$REMOTE_PATH' has uncommitted changes — these would be packaged into the sync commit. Resolve before pulling." >&2
  echo "$REMOTE_DIRTY" >&2
  exit 1
fi

# F-U(synth #11) + U3: detect a previously-orphaned remote sync commit (a prior pull committed on
# remote-svn/<branch> but the merge into $BRANCH was aborted). Refuse until resolved.
# `--no-merges` is load-bearing: a normal push leaves a benign `Merge branch '<branch>' into
# remote-svn/<branch>` MERGE commit ahead of $BRANCH (content already in $BRANCH); that steady
# state must NOT trip this guard.
# U3 REFINEMENT (marker-aware): the per-revision model's own replay commits are MARKED by a
# refs/tp/svn/<N> ref and ARE the resumable state -- an interrupted per-revision pull re-runs and
# continues them, so those must NOT be treated as orphans. Only an UNMARKED non-merge commit ahead
# (a legacy lump, or a genuinely orphaned aborted merge) is a real orphan.
MARKED_SHAS="$(svn_rev_marks "$MAIN_WORKTREE" | awk '{print $2}')"
AHEAD_RAW="$(git -C "$MAIN_WORKTREE" log --no-merges --format='%H' "${BRANCH}..${REMOTE_BRANCH}" 2>/dev/null || true)"
AHEAD_COUNT="$(printf '%s\n' "$AHEAD_RAW" | awk '$1 ~ /^[0-9a-f]{40}$/ {c++} END{print c+0}')"
ORPHAN_SHAS="$(printf '%s\n' "$AHEAD_RAW" | awk -v marked="$MARKED_SHAS" '
  BEGIN { n = split(marked, m, /[[:space:]]+/); for (i = 1; i <= n; i++) if (m[i] != "") seen[m[i]] = 1 }
  $1 ~ /^[0-9a-f]{40}$/ && !($1 in seen) { print $1 }')"
if [[ -n "$ORPHAN_SHAS" ]]; then
  ORPHAN_COUNT="$(printf '%s\n' "$ORPHAN_SHAS" | grep -c . | tr -d '[:space:]')"
  echo "Error: remote/${REMOTE_BRANCH} has $ORPHAN_COUNT unmerged sync commit(s) ahead of '${BRANCH}':" >&2
  printf '%s\n' "$ORPHAN_SHAS" >&2
  echo "" >&2
  echo "Resolve via manual merge or rerun /tp-pull-from-svn after the conflict is committed." >&2
  exit 1
fi

# ── U3: per-revision replay loop with granularity control ─────────────────────
# Resolve the branch URL + repo HEAD (URL side, not the WC -- the WC reports only its checked-out
# revision, not what SVN has). WC_REV_START is the WC baseline captured BEFORE the loop mutates it.
SVN_URL="$(svn info --show-item url "$REMOTE_PATH" | tr -d '\r\n')"
# A bridge whose SVN path (or any parent folder) was renamed AFTER the bridge was built points at a
# path that no longer exists, and svn's own error names that old path -- which the user never typed
# and will not recognise. There is no way to discover the new name from here: svn follows copy
# history backwards from an existing path, not forwards from a deleted one (issue #32). So the only
# honest thing to do is say precisely that.
if ! HEAD_REV="$(svn info --show-item revision "$SVN_URL" 2>/dev/null | tr -d '[:space:]')" || [[ -z "$HEAD_REV" ]]; then
  echo "Error: cannot read SVN at the path this bridge is attached to:" >&2
  echo "  $SVN_URL" >&2
  echo "  Either SVN is unreachable, or that path (or one of its parent folders) was renamed or removed on SVN." >&2
  echo "  If it was renamed, re-run /tp-setup against the current URL -- a bridge cannot find its own new name." >&2
  exit 1
fi
WC_REV_START="$(svn info --show-item revision "$REMOTE_PATH" | tr -d '[:space:]')"

# cur (resume point) = greatest MARKED revision reachable from the bridge branch, floored by the
# WC's own revision (a clean bridge WC guarantees its content == git HEAD tree, so WC_REV_START is a
# valid "already in git" floor even for a baseline commit that predates any marker). Forward-only.
CUR="$WC_REV_START"
MAX_MARK="$(svn_max_rev_reachable "$MAIN_WORKTREE" "$REMOTE_BRANCH")"
if (( MAX_MARK > CUR )); then CUR="$MAX_MARK"; fi

# Count pending revisions r(cur+1)..headRev for the granularity GATE. svn_replay_dispatch itself
# re-enumerates the full records; here we only need the COUNT (one NUL per record from U1's
# enumerator). Guard the reversed/empty range so svn 1.14.x never sees lo>hi ("No such revision").
COUNT=0
if (( CUR < HEAD_REV )); then
  # Pegged URL, not the WC: same reason as svn_replay_dispatch's enumeration (issue #32) -- a WC
  # sitting at an older revision is bound to the path name of that revision.
  COUNT="$(svn log --xml -r "$((CUR + 1)):$HEAD_REV" "${SVN_URL}@${HEAD_REV}" | svn_enumerate_revisions | tr -cd '\000' | wc -c | tr -d '[:space:]')"
fi

# Nothing new to replay and nothing resumable ahead -> up to date.
if (( COUNT == 0 && AHEAD_COUNT == 0 )); then
  # The working copy legitimately sits below the repository HEAD in a repository shared with other
  # projects: a sibling path's commit bumps the global revision without touching ours. Catch it up
  # anyway. It costs one no-op update, and a working copy left permanently behind makes every later
  # pull re-enumerate an ever-growing range of revisions that were never ours. Failure is not fatal
  # here -- we are already reporting "up to date".
  if (( WC_REV_START < HEAD_REV )); then
    svn update "$REMOTE_PATH" >/dev/null 2>&1 || true
  fi
  echo "Already up to date at SVN r$CUR"
  exit 0
fi

# Granularity gate (KTD7 / R2-R4). <=5 new revisions replay per-revision silently. >5 with no
# explicit choice -> emit a structured signal and exit 0 (NO commits, residue-free) so the SKILL can
# prompt; distinct from the merge-conflict path which exits 1.
# The threshold decides whether to ASK, never whether to HONOUR the answer: an explicitly passed
# --granularity is used at any count. (Same fix as the bootstrap side; previously a caller's
# explicit choice was silently discarded whenever the count sat at or below the threshold.)
MODE='per-revision'
if [[ -n "$GRANULARITY" ]]; then
  MODE="$GRANULARITY"
elif (( COUNT > TP_GRANULARITY_THRESHOLD )); then
  printf 'TP_TOKEN:GRANULARITY_REQUIRED count=%s range=r%s:r%s\n' "$COUNT" "$((CUR + 1))" "$HEAD_REV"
  exit 0
fi

# Materialise the chosen granularity via the shared enumerate+replay dispatch (lib/common.sh),
# the same body the first-import bootstrap (Initialize-GitSvnBridge) uses.
svn_replay_dispatch "$REMOTE_PATH" "$REMOTE_NAME" "$CUR" "$HEAD_REV" "$MODE" "$RANGE" "$SVN_URL"

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

echo "Pulled SVN r$((CUR + 1))..r$HEAD_REV into $BRANCH ($COUNT revision(s), $MODE)"
