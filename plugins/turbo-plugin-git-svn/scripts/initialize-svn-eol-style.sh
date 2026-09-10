#!/usr/bin/env bash
# Usage: initialize-svn-eol-style.sh [--branch <branch>] [--repo-root <path>] [--preview]
#                                    [--batch-size <n>] [--cleanup-locks]
#
# One-time migration: put svn:eol-style=native on every text file already in SVN, so the repository
# stores LF and each working copy gets its own platform's line endings -- the arrangement git
# already has with GitHub. Until this runs, files that predate the change carry no property and SVN
# stores whatever bytes it was handed, which is how a repository ends up holding both LF and CRLF
# versions of the same kind of file (issues #164, #167).
#
# The push path sets the property on whatever it commits, so an unmigrated repository converges
# file by file on its own. This command is for the rest of the tree -- the files nobody has touched.
#
# --preview reports what would change and exits without writing anything. Use it first: the mixed
# line-ending list it prints is the part that needs a human, since those files are excluded
# permanently and the reason is invisible afterwards.
#
# The SVN commits it makes have no git counterpart. That is safe because they are PROPERTY-ONLY:
# the pull path's replay marks a revision whose tree matches its parent and makes no git commit
# (svn_replay_commit's SKIP:empty), and tp:last-aligned-rev tracks branch-to-trunk alignment, not
# git-to-SVN commit pairing. Content must never ride along here -- that is what would reach SVN and
# never come back into git.
#
# It commits in BATCHES (--batch-size, default 1000) rather than one transaction over the whole
# tree. The file count is the size of the repository by design, and a transaction that large times
# out on the server during `Committing transaction` -- after the data has transmitted, which is the
# worst place for it: a timeout means "no answer", not "no commit" (issue #177). Smaller
# transactions finish quickly, a failure costs only the batch it happened in, and the batches
# already committed stay committed -- rerunning does what is left.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH='main'
REPO_ROOT=''
PREVIEW=0
# How many files go into each SVN commit. The whole point of this command is one pass over every
# text file in the tree, so on a big repository the transaction is enormous and the server times
# out in `Committing transaction` -- AFTER the data has transmitted, which is the worst place for
# it because a timeout means "no answer", not "no commit" (issue #177). Smaller transactions finish
# quickly, and the window in which nobody knows what happened shrinks with them.
BATCH_SIZE=1000
# Clear stale working-copy locks left behind by an interrupted commit. Off by default: it is a
# local-only repair, but it is still a change the user did not ask for, so the SKILL asks first.
CLEANUP_LOCKS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)     [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --repo-root)  [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --preview)    PREVIEW=1; shift ;;
    --batch-size) [[ $# -ge 2 ]] || { echo "Error: --batch-size requires a value" >&2; exit 1; }; BATCH_SIZE="$2"; shift 2 ;;
    --cleanup-locks) CLEANUP_LOCKS=1; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

case "$BATCH_SIZE" in
  ''|*[!0-9]*) echo "Error: --batch-size must be a positive integer, got '$BATCH_SIZE'" >&2; exit 1 ;;
esac
if [[ "$BATCH_SIZE" -lt 1 ]]; then echo 'Error: --batch-size must be at least 1' >&2; exit 1; fi

probe_git_version

if [[ -z "$BRANCH" ]]; then BRANCH='main'; fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH. Run /tp-setup to bootstrap the bridge." >&2
  exit 1
fi

# ---- pre-flight -------------------------------------------------------------
# Put the bridge in the EOL mode the tree actually calls for BEFORE asking whether it is clean.
# "Is this bridge dirty?" has no answer until the mode is right: git reading platform endings while
# pinned to LF reports every marked file as modified, and that is indistinguishable here from real
# pending work. Versions up to 0.8.0 left exactly that state behind -- see the closing refresh at
# the end of this script -- and the guard below then refused to run, so the command that creates
# the state could not be used to clear it either.
ensure_bridge_eol_mode_once "$REMOTE_PATH" || true

# The bridge must be clean on BOTH sides. This commit is meant to contain property changes and
# nothing else; pending work here would be swept into it, and a property-only revision is exactly
# the kind the pull path skips -- so anything that rode along would reach SVN and never come back
# into git.
GIT_DIRTY="$(git -C "$REMOTE_PATH" status --porcelain 2>/dev/null || true)"
if [[ -n "$GIT_DIRTY" ]]; then
  echo "Error: the bridge worktree has uncommitted git changes; resolve them first:" >&2
  printf '%s\n' "$GIT_DIRTY" >&2
  exit 1
fi
SVN_RAW_STATUS="$(cd "$REMOTE_PATH" && svn status || true)"

# Locks first, and reported as their own thing. An interrupted commit leaves the working copy
# locked -- column 3 of `svn status` is `L`, and a big interrupted commit leaves THOUSANDS of them
# (1373 directories in the report behind issue #177). Every later svn operation is refused until
# `svn cleanup` clears them. Folding that into "the bridge has pending SVN changes" is what made
# this undiagnosable: the message named the wrong problem and the fix it implied does not work.
SVN_LOCKED="$(printf '%s\n' "$SVN_RAW_STATUS" | awk 'substr($0, 3, 1) == "L"' || true)"
if [[ -n "$SVN_LOCKED" ]]; then
  SVN_LOCK_COUNT="$(printf '%s\n' "$SVN_LOCKED" | grep -c . || true)"
  if [[ "$CLEANUP_LOCKS" == 1 ]]; then
    echo "Clearing $SVN_LOCK_COUNT stale working-copy lock(s) left by an interrupted commit..."
    ( cd "$REMOTE_PATH" && svn cleanup ) \
      || { echo 'Error: svn cleanup failed. Run `svn cleanup` in the bridge worktree by hand.' >&2; exit 1; }
    SVN_RAW_STATUS="$(cd "$REMOTE_PATH" && svn status || true)"
  else
    {
      echo "Error: the bridge worktree holds $SVN_LOCK_COUNT stale working-copy lock(s)."
      echo '       An interrupted svn commit leaves these behind, and every svn operation is'
      echo '       refused until they are cleared. This is a LOCAL repair -- it does not touch SVN:'
      echo "         svn cleanup   (run in $REMOTE_PATH)"
      echo '       Or rerun this command with --cleanup-locks to have it done for you.'
    } >&2
    exit 1
  fi
fi

SVN_DIRTY="$(printf '%s\n' "$SVN_RAW_STATUS" | grep -v '^?' | grep -v '^[[:space:]]*$' || true)"
if [[ -n "$SVN_DIRTY" ]]; then
  echo "Error: the bridge worktree has pending SVN changes; resolve them first:" >&2
  printf '%s\n' "$SVN_DIRTY" >&2
  exit 1
fi

echo "Updating the bridge to the latest SVN revision..."
( cd "$REMOTE_PATH" && svn update --quiet ) || { echo 'Error: svn update failed.' >&2; exit 1; }

# ---- classify ---------------------------------------------------------------
CLASSIFIED="$(mktemp)"
CANDIDATES="$(mktemp)"
TARGETS=''
trap 'rm -f "$CLASSIFIED" "$CANDIDATES" "${TARGETS:-}"' EXIT

classify_svn_eol_paths "$REMOTE_PATH" > "$CLASSIFIED"

awk -F'\t' '$1 == "candidate" { sub(/^[^\t]*\t/, ""); print }' "$CLASSIFIED" | tr '\\' '/' | LC_ALL=C sort -u > "$CANDIDATES"
BINARY_COUNT="$(awk -F'\t' '$1 == "binary"' "$CLASSIFIED" | grep -c . || true)"
MIXED_LIST="$(awk -F'\t' '$1 == "mixed" { sub(/^[^\t]*\t/, ""); print }' "$CLASSIFIED")"
MIXED_COUNT="$(printf '%s' "$MIXED_LIST" | grep -c . || true)"

CAND_COUNT="$(grep -c . "$CANDIDATES" || true)"

# How many will actually CHANGE is answered by doing it and asking svn, not by comparing our path
# list against `svn propget -R`. That comparison looked obvious and is a trap: propget prints
# ABSOLUTE paths (even when given `.`) while git prints repo-relative ones, the drive letter's case
# differs between the two, and on Windows one side can hand back an 8.3 short name -- `melwu~1`
# against `Mel Wu` -- so the prefix strip silently matches nothing and every file reads as
# "not yet marked". Setting a property to the value it already holds is a no-op to svn, so the
# honest way to count is to set them all and let svn say which ones moved.
if [[ "$CAND_COUNT" -gt 0 ]]; then
  TARGETS="$(mktemp)"
  trap 'rm -f "$CLASSIFIED" "$CANDIDATES" "${TARGETS:-}"' EXIT
  TARGET_LIST=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    TARGET_LIST+=("$(svn_target "$p")")
  done < "$CANDIDATES"
  write_svn_targets_file "$TARGETS" "${TARGET_LIST[@]}" || { echo 'Error: could not write the svn targets file.' >&2; exit 1; }
  # `svn propset --targets` stops at the first file it cannot mark and leaves every file BEFORE it
  # staged -- on a large tree that is tens of thousands of pending property changes. Saying only
  # "nothing was committed" is true of SVN and quite wrong about the working copy: the bridge is
  # left dirty, the pre-flight above then refuses to run again, and the reason is not discoverable
  # from anything the user can see.
  #
  # Reverting is safe here for exactly the reason it is safe on the preview path below: the
  # pre-flight refused to start on a bridge carrying any pending SVN change, so the only thing
  # there is to revert is what this script staged seconds ago. Unlike a failed COMMIT, there is
  # nothing here worth keeping for a retry -- the propset is cheap to redo and the commit never
  # happened.
  if ! ( cd "$REMOTE_PATH" && svn propset svn:eol-style native --quiet --targets "$TARGETS" ); then
    echo 'Error: svn propset failed; nothing was committed.' >&2
    echo 'Reverting the property changes this run had already staged...' >&2
    if ( cd "$REMOTE_PATH" && svn revert -R --quiet '.' ); then
      echo 'The bridge worktree is back to the state it was in before this run.' >&2
    else
      echo 'Warning: the revert failed as well. The bridge worktree still holds staged property' >&2
      echo '         changes; clear them with `svn revert -R .` there before rerunning.' >&2
    fi
    exit 1
  fi
fi

# Column 2 of `svn status` is the property status; count the entries svn now considers changed.
# Counting characters rather than parsing paths keeps this immune to the console codepage.
SET_COUNT="$(cd "$REMOTE_PATH" && svn status | awk 'substr($0, 2, 1) == "M"' | grep -c . || true)"

echo
echo "Branch:            $BRANCH  ($REMOTE_PATH)"
echo "Text files:        $CAND_COUNT"
echo "  already marked:  $((CAND_COUNT - SET_COUNT))"
echo "  to mark:         $SET_COUNT"
echo "Skipped, binary:   $BINARY_COUNT"
echo "Skipped, mixed:    $MIXED_COUNT"
if [[ "$MIXED_COUNT" -gt 0 ]]; then
  echo
  echo "These files have BOTH LF and CRLF line endings. svn refuses to commit such a file once"
  echo "svn:eol-style is set, so they are excluded and will keep whatever endings they have."
  echo "To cover them: pick one ending for each in the MAIN worktree, commit, push with"
  echo "/tp-push-to-svn, then run this command again. The change is a real one there -- these files"
  echo "reached git through the bridge, which stores SVN's bytes as they are, so the mixed endings"
  echo "are in the committed blob and not just in the working copy."
  printf '%s\n' "$MIXED_LIST" | sed 's/^/  /'
fi

# The property changes are already staged in the working copy at this point -- that is how the
# count above was obtained. Preview therefore has to put the tree back exactly as it found it.
# `svn revert -R` is safe here and only here: the pre-flight refused to run on a bridge with any
# pending SVN change, so the only thing there is to revert is what this script just staged.
if [[ "$PREVIEW" == 1 ]]; then
  ( cd "$REMOTE_PATH" && svn revert -R --quiet '.' ) \
    || { echo 'Error: could not revert the staged property changes. Run `svn revert -R .` in the bridge worktree.' >&2; exit 1; }
  echo
  echo "Preview only -- the staged property changes were reverted, nothing was changed."
  exit 0
fi

if [[ "$SET_COUNT" -eq 0 ]]; then
  echo
  echo "Every text file already carries svn:eol-style=native. Nothing to do."
  exit 0
fi

# ---- apply ------------------------------------------------------------------
MSG_FILE="$(mktemp)"
CHUNK_FILE="$(mktemp)"
trap 'rm -f "$CLASSIFIED" "$CANDIDATES" "${TARGETS:-}" "$MSG_FILE" "$CHUNK_FILE"' EXIT

SVN_HTTP_TIMEOUT=3600
BATCH_INDEX=0
TOTAL_BATCHES=$(( (CAND_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))
# Set once svn:auto-props is known: the declaring revision is a commit too, and the count a user
# sees has to match the number of revisions that actually appear.
TOTAL_COMMITS="$TOTAL_BATCHES"

# What to say when a commit does not answer. Everything here is downstream of one fact: a timeout
# means "no reply", not "no commit" -- and the server can finish the transaction LONG after it gave
# up talking. Reported in the wild: the script said the commit failed, an immediate check of the
# path showed nothing had changed, and two hours later that same path carried this script's own
# commit message. The commit had succeeded all along.
#
# So the guidance is deliberately NOT "here is how to check" -- it is "do not check yet".
report_commit_failure() {
  local batch="$1" url
  url="$( ( cd "$REMOTE_PATH" && svn info --show-item url 2>/dev/null ) || true )"
  {
    echo "Error: svn commit failed on batch $batch of $TOTAL_COMMITS."
    echo
    if [[ "$BATCH_INDEX" -gt 1 ]]; then
      echo "Batches 1 to $((batch - 1)) are already committed and are not affected. Only this one"
      echo 'is in doubt, and rerunning this command will redo just what is left.'
      echo
    fi
    echo 'THIS IS AN UNDETERMINED STATE. The commit may have succeeded or failed, and you cannot'
    echo 'tell right now -- that is what a timeout [E175012] means. A large transaction can finish'
    echo 'on the server minutes after it stopped answering, so anything you check at this moment'
    echo 'only describes this moment.'
    echo
    echo 'Do this instead:'
    echo '  1. WAIT a few minutes. Do not conclude anything yet.'
    echo '  2. Then look at the newest log entry for THIS BRANCH PATH -- not at the repository.'
    echo '     Revision numbers are shared repository-wide, so an unrelated commit by someone else'
    echo '     moves the HEAD without your commit having landed:'
    if [[ -n "$url" ]]; then
      echo "       svn log --limit 1 \"$url\""
    else
      echo '       svn log --limit 1 <the branch URL>'
    fi
    echo '     If its message starts with "Set svn:eol-style=native", it is this command and the'
    echo '     commit landed. That message is the identifier -- nothing else writes it.'
    echo '  3. Landed  -> run `svn update` in the bridge and rerun this command for the rest.'
    echo '     Did not -> rerun this command; the staged property changes are still there and the'
    echo '                propset step does NOT have to be repeated.'
    echo
    echo 'Do NOT `svn revert` before you know which of the two it was: that throws away a pending'
    echo 'set you may still need, and redoing it means propsetting every file again.'
    echo
    echo 'An interrupted commit also leaves working-copy locks behind, and every later svn'
    echo 'operation is refused until they are cleared. That repair is local only and does not touch'
    echo 'SVN: `svn cleanup` in the bridge, or rerun this command with --cleanup-locks.'
  } >&2
}

# Commit one batch of paths. The message's first line is a fixed, recognisable string on purpose:
# after a timeout it is the only thing that tells a user whether the revision on the server is
# theirs.
commit_batch() {
  local label="$1"; shift
  local -a targets=("$@")
  write_svn_targets_file "$CHUNK_FILE" "${targets[@]}" \
    || { echo 'Error: could not write the svn targets file.' >&2; return 1; }
  # ASCII on purpose, like every other property and commit message this plugin writes: the message
  # travels through svn's console codepage on the way back out.
  write_utf8_no_bom "$MSG_FILE" "Set svn:eol-style=native on $label

Line endings are now normalised by SVN on commit, so the repository stores LF
and each working copy gets its own platform's endings."
  # --depth empty keeps the root target from recursing; explicit file targets still commit.
  ( cd "$REMOTE_PATH" && svn commit --file "$MSG_FILE" --encoding UTF-8 --depth empty \
      --targets "$CHUNK_FILE" --config-option "servers:global:http-timeout=$SVN_HTTP_TIMEOUT" )
}

# svn:auto-props on this tree's root so files added later by ANY client -- not just through this
# plugin -- get the property too. It is SVN's counterpart to committing a .gitattributes: shared,
# versioned, and applied at `svn add` time. Derived from the extensions actually present, because
# SVN matches auto-props by filename pattern and has no content heuristic to fall back on.
AUTOPROPS="$(derive_svn_auto_props < "$CANDIDATES")"
if [[ -n "$AUTOPROPS" ]]; then TOTAL_COMMITS=$((TOTAL_BATCHES + 1)); fi
#
# It goes out FIRST, in its own revision, before a single file batch. That ordering is load-bearing
# once the run can be interrupted between batches: svn:auto-props on the root IS the signal the
# bridge reads to decide whether to pin git to LF, so
#   - declared first  -> the bridge follows the platform from the start, which is consistent with
#     the files already marked and harmless for the ones not marked yet. It is exactly the
#     "declared, converging file by file" state the push path is built for.
#   - declared last   -> an interrupted run leaves thousands of files carrying svn:eol-style while
#     the bridge is still pinned to LF. The next `svn update` writes platform endings for those
#     files and git reads every one of them as modified.
# The second state is created by the interruption itself, which is the thing batching makes
# possible, so the ordering is part of the batching change and not a separate tidy-up.
if [[ -n "$AUTOPROPS" ]]; then
  ( cd "$REMOTE_PATH" && svn propset svn:auto-props "$AUTOPROPS" --quiet '.' ) \
    || { echo 'Error: could not set svn:auto-props on the branch root.' >&2; exit 1; }
  echo "Declaring the tree: svn:auto-props on the branch root, so new files inherit the property."
  BATCH_INDEX=1
  if ! commit_batch 'the branch root [declaring the tree]' '.'; then
    report_commit_failure 1
    exit 1
  fi
fi

echo "Committing the property changes in batches of $BATCH_SIZE..."
CHUNK_PATHS=()
flush_chunk() {
  [[ "${#CHUNK_PATHS[@]}" -gt 0 ]] || return 0
  BATCH_INDEX=$((BATCH_INDEX + 1))
  local -a targets=()
  local p
  for p in "${CHUNK_PATHS[@]}"; do targets+=("$(svn_target "$p")"); done
  CHUNK_PATHS=()
  echo "  batch $BATCH_INDEX of $TOTAL_COMMITS: ${#targets[@]} file(s)"
  if ! commit_batch "${#targets[@]} text file(s) [batch $BATCH_INDEX of $TOTAL_COMMITS]" "${targets[@]}"; then
    report_commit_failure "$BATCH_INDEX"
    exit 1
  fi
}
while IFS= read -r cand_path; do
  [[ -n "$cand_path" ]] || continue
  CHUNK_PATHS+=("$cand_path")
  if [[ "${#CHUNK_PATHS[@]}" -ge "$BATCH_SIZE" ]]; then flush_chunk; fi
done < "$CANDIDATES"
flush_chunk

# More than one commit leaves a MIXED-REVISION working copy: `svn commit` only bumps what it
# committed, so the root sits at the declaring revision while the files sit at later ones. Anything
# that then asks "what revision is this working copy at?" gets the root's answer -- the pull path
# does exactly that, and it would position the whole copy back at that older revision, undoing the
# property changes in the working copy and leaving every file reading as modified.
#
# One `svn update` makes the copy uniform. This was not needed while the migration was a single
# commit, and it is the same mixed-revision trap that bit the first-push bootstrap before it.
( cd "$REMOTE_PATH" && svn update --quiet ) \
  || { echo 'Warning: svn update after the migration failed; run it in the bridge worktree so the working copy is at a single revision.' >&2; }

# The tree now DECLARES svn:eol-style, which is the one thing that flips the bridge's EOL mode --
# and this is the only command that can flip it. The update above just wrote platform endings
# (CRLF on Windows) for every file it marked, while the bridge is still pinned to LF, so git reads
# the whole tree as modified. Every guard that asks "is this bridge clean?" then fires at once:
# measured on 0.8.0, a successful migration left `/tp-pull-from-svn`, `/tp-push-to-svn` AND a rerun
# of this command all refusing, each naming changes the user never made.
#
# It has to be re-read here rather than left to the next command, for the same reason the bootstrap
# re-reads it after declaring: the mode is a fact about the tree, and this script is what changed
# the tree. Leaving the bridge in a state whose only exit is a git command nobody mentions is not a
# successful migration, whatever the exit code says.
ensure_bridge_eol_mode "$MAIN_WORKTREE" "$REMOTE_PATH" \
  || echo 'Warning: could not re-read the bridge line-ending mode. Run /tp-pull-from-svn to have it done.' >&2

echo
echo "Done. $SET_COUNT file(s) now carry svn:eol-style=native."
if [[ "$MIXED_COUNT" -gt 0 ]]; then
  echo "$MIXED_COUNT file(s) were left out because their line endings are mixed (listed above)."
fi
