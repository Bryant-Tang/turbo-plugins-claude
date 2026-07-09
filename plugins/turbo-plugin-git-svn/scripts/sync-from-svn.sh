#!/usr/bin/env bash
# Usage: sync-from-svn.sh --branch <branch>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH=''
GRANULARITY=''
RANGE=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)      [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --granularity) [[ $# -ge 2 ]] || { echo "Error: --granularity requires a value" >&2; exit 1; }; GRANULARITY="$2"; shift 2 ;;
    --range)       [[ $# -ge 2 ]] || { echo "Error: --range requires a value" >&2; exit 1; }; RANGE="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

# Replay one SVN revision (U3): svn update -r R in the bridge worktree, assert the WC is uniformly
# at R (KTD4 sparse guard -- an empty delta must mean "identical tree", never a partial update),
# then hand off to U1's svn_replay_commit (empty-delta + idempotent skips live there).
replay_one_revision() {
  local remote_path="$1" rev="$2" author="$3" date="$4" message="$5" wc
  ( cd "$remote_path" && svn update -r "$rev" ) || { echo "Error: svn update -r $rev failed" >&2; exit 1; }
  wc="$(svn info --show-item revision "$remote_path" | tr -d '[:space:]')"
  if [[ "$wc" != "$rev" ]]; then
    echo "Error: remote worktree not uniformly at r$rev (got r$wc); refusing per-revision replay." >&2
    exit 1
  fi
  svn_replay_commit "$remote_path" "$rev" "$author" "$date" "$message" >/dev/null
}

# Squash the current WC HEAD-of-range into ONE boundary commit on the bridge worktree's HEAD.
# Subject stays `sync: svn r<rev>` (steady-state shape) but a second -m appends the
# `svn-revision: <rev>` trailer so floor-lookup (U5) treats the squashed range as a single boundary.
# Skips when `git add -A` leaves the index unchanged (empty delta).
boundary_commit() {
  local remote_path="$1" rev="$2"
  git -C "$remote_path" add -A
  if git -C "$remote_path" diff --cached --quiet; then
    return 0
  fi
  git -C "$remote_path" -c commit.gpgsign=false commit -m "sync: svn r$rev" -m "svn-revision: $rev"
}

probe_git_version

if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required (e.g. main or feat/login)" >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree)"
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
# U3 REFINEMENT (trailer-aware): the per-revision model's own replay commits carry an
# `svn-revision:` trailer and ARE the resumable state -- an interrupted per-revision pull re-runs
# and continues them, so those must NOT be treated as orphans. Only a non-merge commit ahead that
# carries NO svn-revision trailer (a legacy `sync:` lump, or a genuinely orphaned aborted merge)
# is a real orphan. This single refinement lets "resume" and "orphan still fires" coexist.
# (`%(trailers:valueonly)` appends a trailing blank line for trailer-bearing commits; the awk
# `$1 !~ 40-hex` filter drops those, so the ahead-count and orphan-scan both stay accurate.)
AHEAD_RAW="$(git -C "$MAIN_WORKTREE" log --no-merges --format='%H%x09%(trailers:key=svn-revision,valueonly)' "${BRANCH}..${REMOTE_BRANCH}" 2>/dev/null || true)"
AHEAD_COUNT="$(printf '%s\n' "$AHEAD_RAW" | awk -F'\t' '$1 ~ /^[0-9a-f]{40}$/ {c++} END{print c+0}')"
ORPHAN_SHAS="$(printf '%s\n' "$AHEAD_RAW" | awk -F'\t' '$1 !~ /^[0-9a-f]{40}$/ {next} {tr=$2; gsub(/[[:space:]]/,"",tr); if (tr=="") print $1}')"
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
HEAD_REV="$(svn info --show-item revision "$SVN_URL" | tr -d '[:space:]')"
WC_REV_START="$(svn info --show-item revision "$REMOTE_PATH" | tr -d '[:space:]')"

# KTD4 sparse guard: a full (infinite-depth) checkout is required so `svn update -r R` yields a
# uniform per-revision tree; assert once before the loop.
DEPTH="$(svn info --show-item depth "$REMOTE_PATH" | tr -d '[:space:]')"
if [[ "$DEPTH" != "infinity" ]]; then
  echo "Error: remote worktree depth is '$DEPTH', not 'infinity'; per-revision replay needs a full checkout." >&2
  exit 1
fi

# cur (resume point) = greatest already-replayed svn-revision trailer on the bridge branch, floored
# by the WC's own revision (the legacy-lump / transition floor: a clean bridge WC guarantees its
# content == git HEAD tree, so WC_REV_START is a valid "already in git" floor even when the baseline
# lump commit carries no trailer). Forward-only; collapses to trailer-only intent once U7 lands.
CUR="$WC_REV_START"
TRAILER_VALS="$(git -C "$MAIN_WORKTREE" log "$REMOTE_BRANCH" --format='%(trailers:key=svn-revision,valueonly)' 2>/dev/null | grep -E '^[0-9]+$' || true)"
if [[ -n "$TRAILER_VALS" ]]; then
  MAX_TRAILER="$(printf '%s\n' "$TRAILER_VALS" | sort -n | tail -n1)"
  if (( MAX_TRAILER > CUR )); then CUR="$MAX_TRAILER"; fi
fi

# Enumerate r(cur+1)..headRev via U1. Guard the reversed/empty range so svn 1.14.x never sees lo>hi
# (it errors "No such revision"). Records land in parallel arrays REC_REV/AUTHOR/DATE/MSG.
REC_REV=(); REC_AUTHOR=(); REC_DATE=(); REC_MSG=()
if (( CUR < HEAD_REV )); then
  LOG_XML="$(svn log --xml -r "$((CUR + 1)):$HEAD_REV" "$REMOTE_PATH")"
  while IFS=$'\037' read -r -d '' _rev _author _date _msg; do
    REC_REV+=("$_rev"); REC_AUTHOR+=("$_author"); REC_DATE+=("$_date"); REC_MSG+=("$_msg")
  done < <(printf '%s' "$LOG_XML" | svn_enumerate_revisions)
fi
COUNT="${#REC_REV[@]}"

# Nothing new to replay and nothing resumable ahead -> up to date.
if (( COUNT == 0 && AHEAD_COUNT == 0 )); then
  echo "Already up to date at SVN r$CUR"
  exit 0
fi

# Granularity gate (KTD7 / R2-R4). <=5 new revisions replay per-revision silently. >5 with no
# explicit choice -> emit a structured signal and exit 0 (NO commits, residue-free) so the SKILL can
# prompt; distinct from the merge-conflict path which exits 1.
MODE='per-revision'
if (( COUNT > 5 )); then
  if [[ -z "$GRANULARITY" ]]; then
    printf 'TP_TOKEN:GRANULARITY_REQUIRED count=%s range=r%s:r%s\n' "$COUNT" "$((CUR + 1))" "$HEAD_REV"
    exit 0
  fi
  MODE="$GRANULARITY"
fi

if [[ "$MODE" == "per-revision" ]]; then
  echo "Replaying $COUNT SVN revision(s) r$((CUR + 1))..r$HEAD_REV into $REMOTE_NAME..."
  for i in "${!REC_REV[@]}"; do
    replay_one_revision "$REMOTE_PATH" "${REC_REV[$i]}" "${REC_AUTHOR[$i]}" "${REC_DATE[$i]}" "${REC_MSG[$i]}"
  done
elif [[ "$MODE" == "squash" ]]; then
  echo "Squashing SVN r$((CUR + 1))..r$HEAD_REV into one commit in $REMOTE_NAME..."
  ( cd "$REMOTE_PATH" && svn update ) || { echo "Error: svn update failed" >&2; exit 1; }
  boundary_commit "$REMOTE_PATH" "$HEAD_REV"
elif [[ "$MODE" == "range" ]]; then
  if [[ ! "$RANGE" =~ ^[0-9]+:[0-9]+$ ]]; then
    echo "Error: granularity 'range' requires --range <lo>:<hi> (got '$RANGE')" >&2; exit 1
  fi
  LO="${RANGE%%:*}"; HI="${RANGE##*:}"
  if (( LO < CUR + 1 )); then LO=$((CUR + 1)); fi
  if (( HI > HEAD_REV )); then HI=$HEAD_REV; fi
  if (( LO > HI )); then
    echo "Error: granularity range does not overlap the pending r$((CUR + 1)):r$HEAD_REV." >&2; exit 1
  fi
  echo "Replaying r$LO..r$HI per-revision, squashing the rest, into $REMOTE_NAME..."
  # Leading squash: r(cur+1)..r(lo-1) -> one boundary commit at r(lo-1). Skipped when lo==cur+1.
  if (( LO - 1 >= CUR + 1 )); then
    ( cd "$REMOTE_PATH" && svn update -r "$((LO - 1))" ) || { echo "Error: svn update -r $((LO - 1)) failed" >&2; exit 1; }
    boundary_commit "$REMOTE_PATH" "$((LO - 1))"
  fi
  # Per-revision inside [lo,hi].
  for i in "${!REC_REV[@]}"; do
    r="${REC_REV[$i]}"
    if (( r >= LO && r <= HI )); then
      replay_one_revision "$REMOTE_PATH" "$r" "${REC_AUTHOR[$i]}" "${REC_DATE[$i]}" "${REC_MSG[$i]}"
    fi
  done
  # Trailing squash: r(hi+1)..rHEAD -> one boundary commit at rHEAD. Skipped when hi>=headRev.
  if (( HI < HEAD_REV )); then
    ( cd "$REMOTE_PATH" && svn update ) || { echo "Error: svn update failed" >&2; exit 1; }
    boundary_commit "$REMOTE_PATH" "$HEAD_REV"
  fi
else
  echo "Error: unknown granularity '$GRANULARITY' (expected per-revision | squash | range)" >&2; exit 1
fi

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
