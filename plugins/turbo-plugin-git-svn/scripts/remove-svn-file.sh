#!/usr/bin/env bash
# Usage: remove-svn-file.sh --branch <branch> --path <bridge-relative path>
#
# Remove a single path from the SVN side of a bridge, for tp-suggest-ignore's "un-track from SVN"
# paths. ONE script serves both cases, chosen by a PRE-FLIGHT classification (before any svn delete):
#
#   * git-TRACKED on the bridge (Un-track Option A) -> svn delete leaves the bridge git tree dirty,
#     so RECONCILE: `git add -A` + `sync: svn r<rev>` commit + `--no-ff` merge into <branch>. The
#     commit + merge formats MIRROR sync-from-svn.sh exactly, so remote-svn/<branch> only ever
#     carries `sync:` and merge commits (indistinguishable from /tp-pull-from-svn).
#   * git-UNTRACKED / git-IGNORED (Inconsistency Option B) -> svn delete leaves the bridge git tree
#     clean, so NO reconcile; we verify it stayed clean and stop.
#
# We do NOT delegate to /tp-push-to-svn (its main-clean gate + check-ignore filter make neither
# Un-track ordering drivable through push); a direct svn delete sidesteps both.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH='main'
REL_PATH=''   # NOT `PATH` — that is the shell's executable search path.
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --path)      [[ $# -ge 2 ]] || { echo "Error: --path requires a value" >&2; exit 1; }; REL_PATH="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then BRANCH='main'; fi
if [[ -z "$REL_PATH" ]]; then echo "Error: --path is required (bridge-relative path)" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_BRANCH="$(printf '%s' "$REMOTE_SPEC" | cut -d'|' -f2)"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH. Run /tp-setup to bootstrap the bridge." >&2; exit 1
fi

# ---- pre-flight (ALL checks + classification BEFORE any svn delete) ----

# The bridge must be clean: a dirty bridge means uncommitted state a later `git add -A` (reconcile
# path) would wrongly package into the sync commit.
BRIDGE_STATUS="$(git -C "$REMOTE_PATH" status --porcelain)"
if [[ -n "$BRIDGE_STATUS" ]]; then
  echo "Error: remote worktree '$REMOTE_PATH' has uncommitted changes; resolve before removing a path." >&2
  echo "$BRIDGE_STATUS" >&2
  exit 1
fi

# The target must exist on disk in the bridge.
if [[ ! -e "$REMOTE_PATH/$REL_PATH" ]]; then
  echo "Error: path not found in bridge worktree: '$REL_PATH' (looked under $REMOTE_PATH)." >&2; exit 1
fi

# Classify git-tracked vs not, on the bridge — decides reconcile vs no-reconcile.
if git -C "$REMOTE_PATH" ls-files --error-unmatch -- "$REL_PATH" >/dev/null 2>&1; then
  GIT_TRACKED=true
else
  GIT_TRACKED=false
fi

# Reconcile-path pre-flight (still BEFORE any svn delete). The reconcile branch commits a `sync:`
# on remote-svn/<branch> and merges it into <branch>; verify these up front, because svn delete +
# svn commit are irreversible and a failure after them would leave the SVN copy gone plus an
# orphaned sync commit on the bridge.
if [[ "$GIT_TRACKED" == true ]]; then
  # main worktree must be clean for the merge (mirror sync-from-svn.sh:36-41).
  MAIN_STATUS_PRE="$(git -C "$MAIN_WORKTREE" status --porcelain)"
  if [[ -n "$MAIN_STATUS_PRE" ]]; then
    echo "Error: main worktree has uncommitted changes; cannot merge the SVN removal into '$BRANCH'. Commit or stash first (nothing has been changed)." >&2
    echo "$MAIN_STATUS_PRE" >&2
    exit 1
  fi
  # remote-svn/<branch> must not carry an ORPHANED sync commit -- a `sync: svn r<N>` (non-merge)
  # left ahead of <branch> by an interrupted pull/removal, which the reconcile merge would drag in.
  # `--no-merges` is load-bearing: a normal push leaves a benign `Merge branch '<branch>' into
  # remote-svn/<branch>` MERGE commit ahead of <branch> (its content is already in <branch>), and
  # that steady state must NOT trip this guard. Only a non-merge sync is a genuine orphan.
  # (mirror sync-from-svn.sh.)
  UNMERGED="$(git -C "$MAIN_WORKTREE" log --oneline --no-merges "${BRANCH}..${REMOTE_BRANCH}" 2>/dev/null || true)"
  if [[ -n "$UNMERGED" ]]; then
    echo "Error: remote-svn/${BRANCH} has unmerged sync commit(s) ahead of '${BRANCH}'; resolve first (run /tp-pull-from-svn, or 'git -C $MAIN_WORKTREE merge $REMOTE_BRANCH'), then retry. Nothing has been changed." >&2
    echo "$UNMERGED" >&2
    exit 1
  fi
  # Data-safety: the caller (Un-track A) must have `git rm --cached` the path on <branch> FIRST so
  # the file stays on disk. If <branch> still tracks it, the reconcile merge would DELETE the local
  # copy — refuse rather than lose the file the user asked to keep.
  if git -C "$MAIN_WORKTREE" ls-files --error-unmatch -- "$REL_PATH" >/dev/null 2>&1; then
    echo "Error: path '$REL_PATH' is still git-tracked in the main worktree on '$BRANCH'. Run 'git rm --cached -- $REL_PATH' + commit first (keeps the local file); refusing so the reconcile merge does not delete it." >&2
    exit 1
  fi
fi

# svn-tracked check + local-modification (M) detection. `svn status <path>` prints nothing for a
# clean tracked file, `?` for unversioned, `M` when locally modified.
SVN_STAT="$(cd "$REMOTE_PATH" && svn status -- "$REL_PATH")" || { echo "Error: svn status failed for '$REL_PATH'." >&2; exit 1; }
SVN_FIRST=''
while IFS= read -r _line; do
  [[ -n "${_line// /}" ]] || continue
  SVN_FIRST="${_line:0:1}"
  break
done <<< "$SVN_STAT"
if [[ "$SVN_FIRST" == '?' ]]; then
  echo "Error: path '$REL_PATH' is not tracked by SVN (svn status '?'); nothing to delete from SVN. Use tp-suggest-ignore's git-only option instead." >&2
  exit 1
fi

# ---- svn delete (+ --force when locally modified) then commit via a UTF-8 no-BOM message file ----
MSG_FILE="$(mktemp)"
trap 'rm -f "$MSG_FILE"' EXIT
write_utf8_no_bom "$MSG_FILE" "remove $REL_PATH from svn (turbo-plugin)"

# On delete/commit failure, `svn revert` so the bridge WC is left CLEAN — a dangling scheduled
# deletion would otherwise wedge the next /tp-pull-from-svn and re-runs of this script.
svn_remove_failed() {
  svn revert -- "$REL_PATH" >/dev/null 2>&1 || true
  popd >/dev/null 2>&1 || true
  echo "Error: svn delete/commit failed for '$REL_PATH'; the deletion was reverted (bridge left clean)." >&2
  exit 1
}
pushd "$REMOTE_PATH" >/dev/null
if [[ "$SVN_FIRST" == 'M' ]]; then
  svn delete --force -- "$REL_PATH" || svn_remove_failed
else
  svn delete -- "$REL_PATH" || svn_remove_failed
fi
svn commit --file "$MSG_FILE" --encoding UTF-8 -- "$REL_PATH" || svn_remove_failed
svn update >/dev/null || echo 'Warning: svn update after commit failed. Remote worktree may be stale; run /tp-pull-from-svn to resync.' >&2
SVN_REV="$(svn info --show-item revision)"
popd >/dev/null

if [[ "$GIT_TRACKED" == true ]]; then
  # ---- reconcile (Un-track A): record the deletion on remote-svn/<branch>, then merge into
  # <branch>. Commit + merge formats MIRROR sync-from-svn.sh exactly (user invariant). ----
  git -C "$REMOTE_PATH" add -A
  git -C "$REMOTE_PATH" commit -m "sync: svn r$SVN_REV"

  # (main-clean / unmerged-sync / main-untracks-path were all verified in pre-flight, before the
  # irreversible svn delete, so the merge below is known-safe here.)
  ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"
  SWITCHED=false
  if [[ "$ORIGINAL_BRANCH" != "$BRANCH" ]]; then
    git -C "$MAIN_WORKTREE" checkout "$BRANCH"
    SWITCHED=true
  fi

  if ! git -C "$MAIN_WORKTREE" merge "$REMOTE_BRANCH" --no-ff -m "Merge branch '$REMOTE_BRANCH' into $BRANCH"; then
    CONFLICTS="$(git -C "$MAIN_WORKTREE" diff --name-only --diff-filter=U)"
    if git -C "$MAIN_WORKTREE" merge --abort 2>/dev/null; then abort_status=0; else abort_status=$?; fi
    checkout_status=0
    if [[ "$SWITCHED" == true ]]; then
      if git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH" 2>/dev/null; then checkout_status=0; else checkout_status=$?; fi
    fi
    if [[ $abort_status -ne 0 || $checkout_status -ne 0 ]]; then
      echo "Merge conflict; automatic rollback failed (abort exit=$abort_status, checkout exit=$checkout_status). Working tree is in an inconsistent state. Resolve manually before re-running." >&2
      exit 1
    fi
    echo "Error: merge conflict merging '$REMOTE_BRANCH' into '$BRANCH' (unexpected for a deletion). The merge has been aborted and '$ORIGINAL_BRANCH' restored. Conflicting files:" >&2
    echo "$CONFLICTS" >&2
    exit 1
  fi

  if [[ "$SWITCHED" == true ]]; then
    git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  fi

  echo "Removed '$REL_PATH' from SVN (r$SVN_REV) and reconciled the bridge into '$BRANCH'."
else
  # ---- no-reconcile (Inconsistency B: file was git-ignored): the bridge git tree is unchanged. ----
  POST_STATUS="$(git -C "$REMOTE_PATH" status --porcelain)"
  if [[ -n "$POST_STATUS" ]]; then
    echo "Error: unexpected bridge changes after removing a git-ignored path ('$REL_PATH'); the path may actually be git-tracked. Investigate before proceeding." >&2
    echo "$POST_STATUS" >&2
    exit 1
  fi
  echo "Removed git-ignored '$REL_PATH' from SVN (r$SVN_REV); bridge git tree unchanged."
fi
