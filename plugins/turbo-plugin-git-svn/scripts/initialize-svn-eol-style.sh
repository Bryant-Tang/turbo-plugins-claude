#!/usr/bin/env bash
# Usage: initialize-svn-eol-style.sh [--branch <branch>] [--repo-root <path>] [--preview]
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
# This makes ONE SVN commit that has no git counterpart. That is safe: the pull path's replay marks
# a revision whose tree matches its parent and makes no git commit (svn_replay_commit's SKIP:empty),
# and tp:last-aligned-rev tracks branch-to-trunk alignment, not git-to-SVN commit pairing.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH='main'
REPO_ROOT=''
PREVIEW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --preview)   PREVIEW=1; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

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
SVN_DIRTY="$(cd "$REMOTE_PATH" && svn status | grep -v '^?' || true)"
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
  ( cd "$REMOTE_PATH" && svn propset svn:eol-style native --quiet --targets "$TARGETS" ) \
    || { echo 'Error: svn propset failed; nothing was committed.' >&2; exit 1; }
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
  echo "Normalise them in git first if you want them covered:"
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
trap 'rm -f "$CLASSIFIED" "$CANDIDATES" "${TARGETS:-}" "$MSG_FILE"' EXIT

# svn:auto-props on this tree's root so files added later by ANY client -- not just through this
# plugin -- get the property too. It is SVN's counterpart to committing a .gitattributes: shared,
# versioned, and applied at `svn add` time. Derived from the extensions actually present, because
# SVN matches auto-props by filename pattern and has no content heuristic to fall back on.
AUTOPROPS="$(awk -F'/' '{ print $NF }' "$CANDIDATES" \
  | awk -F'.' 'NF > 1 { print "*." tolower($NF) }' \
  | LC_ALL=C sort -u \
  | sed 's/$/ = svn:eol-style=native/')"
if [[ -n "$AUTOPROPS" ]]; then
  ( cd "$REMOTE_PATH" && svn propset svn:auto-props "$AUTOPROPS" --quiet '.' ) \
    || { echo 'Error: could not set svn:auto-props on the branch root.' >&2; exit 1; }
  echo "Set svn:auto-props on the branch root so new files inherit the property."
fi

# ASCII on purpose, like every other property and commit message this plugin writes: the message
# travels through svn's console codepage on the way back out.
write_utf8_no_bom "$MSG_FILE" "Set svn:eol-style=native on $SET_COUNT text file(s)

Line endings are now normalised by SVN on commit, so the repository stores LF
and each working copy gets its own platform's endings."

echo "Committing the property change to SVN..."
( cd "$REMOTE_PATH" && svn commit --file "$MSG_FILE" --encoding UTF-8 ) \
  || { echo 'Error: svn commit failed. The property changes are still pending in the bridge worktree.' >&2; exit 1; }

echo
echo "Done. $SET_COUNT file(s) now carry svn:eol-style=native."
if [[ "$MIXED_COUNT" -gt 0 ]]; then
  echo "$MIXED_COUNT file(s) were left out because their line endings are mixed (listed above)."
fi
