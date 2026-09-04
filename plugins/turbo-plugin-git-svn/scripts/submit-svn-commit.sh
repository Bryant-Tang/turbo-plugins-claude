#!/usr/bin/env bash
# Usage: submit-svn-commit.sh --branch <branch> --title "one-line title"
# The body is read from the locked pin (MERGE_HEAD.tp_svn_body) written by build-svn-commit.sh
# and combined with the title here; the agent supplies ONLY the title (U9).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"   # provides svn_status_xml (UTF-8/entity-safe svn status parser)

BRANCH=''
# U9: the agent supplies ONLY the title. The body is read from the pin file written by
# build-svn-commit.sh (body-from-file) and combined here — the agent cannot pass a free message.
TITLE=''
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --title)     [[ $# -ge 2 ]] || { echo "Error: --title requires a value" >&2; exit 1; }; TITLE="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$TITLE" ]]; then echo "Error: --title is required" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH" >&2; exit 1
fi

if ! git -C "$REMOTE_PATH" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
  echo "Error: no pending merge in remote worktree '$REMOTE_NAME'. Run /tp-push-to-svn (which calls push-to-svn-prepare first) instead of invoking this script directly." >&2
  exit 1
fi

# Staleness is measured against the last revision that touched THIS branch path, never against the
# repository HEAD -- the same rule build-svn-commit.sh states at length and follows. This end had
# the older repository-HEAD version, so only half the fix was ever applied, and it showed: in a
# repository holding several projects, `setup` commits under sibling paths bumped HEAD and this
# guard refused the push with "SVN HEAD changed since prepare (local r85, head r87)" while r86/r87
# had not touched a single byte of ours. It then sent the user to /tp-pull-from-svn, which
# correctly found nothing to replay for this path and answered "Already up to date at SVN r85" --
# the two commands contradicting each other with no way forward but a manual `svn update`.
#
# Arithmetic `<`, not string `!=`: the working copy legitimately sits ABOVE the path's
# last-changed-revision (a sibling path moved HEAD on), and "9" sorts after "10" as a string.
SVN_URL="$(svn info --show-item url "$REMOTE_PATH")"
LOCAL_REV="$(svn info --show-item revision "$REMOTE_PATH" | tr -d '[:space:]')"
PATH_REV="$(svn info --show-item last-changed-revision "$SVN_URL" | tr -d '[:space:]')"
if (( LOCAL_REV < PATH_REV )); then
  echo "Error: this SVN path changed since prepare (local r$LOCAL_REV, this path last changed at r$PATH_REV). Abort the merge with 'git -C $REMOTE_PATH merge --abort', then run '/tp-pull-from-svn --branch $BRANCH'." >&2; exit 1
fi

# Verify no new commits were added to the branch since prepare (SHA pinning check).
# NOTE: in a linked worktree, .git is a pointer FILE; resolve via `git rev-parse --absolute-git-dir`.
SHA_GITDIR="$(git -C "$REMOTE_PATH" rev-parse --absolute-git-dir)"
SHA_FILE="$SHA_GITDIR/MERGE_HEAD.tp_branch_sha"
if [[ ! -f "$SHA_FILE" ]]; then
  # F-U(synth #18): fail-closed when MERGE_HEAD exists but the SHA pin file is missing.
  # That state means prepare didn't stage with current locking (older logic, manual MERGE_HEAD,
  # or hand-edit). Refuse to commit silently against the latest HEAD — require re-staging.
  echo "Error: SHA pin file missing while merge state exists. Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to (re-)stage the merge with current locking." >&2
  exit 1
fi
PINNED_SHA="$(tr -d '[:space:]' < "$SHA_FILE")"
CURRENT_SHA="$(git -C "$MAIN_WORKTREE" rev-parse "$BRANCH")"
if [[ "$PINNED_SHA" != "$CURRENT_SHA" ]]; then
  PIN_SHORT="${PINNED_SHA:0:8}"
  CUR_SHORT="${CURRENT_SHA:0:8}"
  echo "Error: Branch '$BRANCH' has new commits since prepare (pinned: $PIN_SHORT, current: $CUR_SHORT). Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to include new commits." >&2
  exit 1
fi

# F12: verify svn status drift — remote worktree must not have gained new files since prepare.
SVN_STATUS_FILE="$SHA_GITDIR/MERGE_HEAD.tp_svn_status"
if [[ ! -f "$SVN_STATUS_FILE" ]]; then
  # Fail-closed: if the svn status pin is missing while MERGE_HEAD exists, the prepare
  # step was not run with drift detection (older logic). Require re-staging.
  echo "Error: svn-status pin file missing while merge state exists. Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to (re-)stage." >&2
  exit 1
fi
# Compare snapshot vs current: detect files that appeared after prepare.
# Both sides come from `svn status --xml` (UTF-8, "<sc>\t<path>" lines, written by
# build-svn-commit.sh) so the comparison is encoding-clean and free of the previous
# CRLF/column-offset fragility.
# Capture-first so an svn failure propagates (svn_status_xml returns non-zero on `svn status`
# failure); feeding svn_status_drift_paths straight from a process substitution would otherwise
# swallow that exit code.
CURRENT_XML="$(svn_status_xml "$REMOTE_PATH")" || { echo "Error: svn status failed (drift check). Re-run /tp-push-to-svn." >&2; exit 1; }
# One awk pass per side (see svn_status_drift_paths): the former per-path `grep -qxF` over a
# piped snapshot mis-read every early hit as a miss on any repo whose snapshot outgrew the pipe
# buffer, so large pushes were blocked by a drift report listing files that had not moved (#170).
DRIFTED_FILES="$(printf '%s\n' "$CURRENT_XML" | svn_status_drift_paths "$SVN_STATUS_FILE")"
if [[ -n "$DRIFTED_FILES" ]]; then
  echo "Error: Remote worktree changed since prepare — file(s) appeared: ${DRIFTED_FILES//$'\n'/ }. Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to recompute." >&2
  exit 1
fi

# U9: assemble the final SVN message = agent title + LOCKED body-from-file. Read the body pin
# written by build-svn-commit.sh; fail closed if missing (same posture as the SHA / svn-status
# pins). The body comes from a FILE (not argv), so non-ASCII subjects re-pass cleanly.
BODY_FILE="$SHA_GITDIR/MERGE_HEAD.tp_svn_body"
if [[ ! -f "$BODY_FILE" ]]; then
  echo "Error: SVN body pin file missing while merge state exists. Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to (re-)stage." >&2
  exit 1
fi
SVN_BODY="$(cat "$BODY_FILE")"
# Collapse the title to a single line so the agent cannot smuggle extra body content via embedded
# newlines (a '\n' in the title would otherwise bypass the body lock).
TITLE_LINE="$(printf '%s' "$TITLE" | tr '\r\n' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$TITLE_LINE" ]]; then echo "Error: title is empty after removing line breaks." >&2; exit 1; fi
FULL_MESSAGE="$(printf '%s\n%s' "$TITLE_LINE" "$SVN_BODY")"

# U4/KTD5: decide whether this push ADVANCES tp:last-aligned-rev. It advances only when the branch
# being pushed newly reaches a higher `svn-revision:` trailer than its stored alignment -- i.e. a
# merge of `main` into the branch brought in newer trunk revisions. TP_NEW_ALIGNED = the highest
# svn-revision trailer REACHABLE FROM THE BRANCH (NOT main's tip: a branch that merged an older main
# must never over-advance, or U5 checkout mis-routes). Requiring a pre-existing tp:last-aligned-rev
# (`-n "$TP_CUR_ALIGNED"`) keeps a `main`/trunk push (whose bridge has no tp props) and any pre-U4
# bridge from being written -- initialization is New-RemoteBridge's job, not this advance. The write
# is folded into the SAME content commit below (never a separate property commit) and is idempotent
# (no-op when unchanged). `|| true` on the grep pipeline so an empty match under `set -e` is benign.
TP_CUR_ALIGNED="$(get_tp_branch_prop last-aligned-rev "$REMOTE_PATH")"
# Greatest marked trunk revision reachable from the branch (refs/tp/svn/<N>). Because a `main` push
# now marks the revision it created, a branch that merged main sees that revision here -- which is
# what the trailer-based scan could not do (trailers only ever existed for PULLED revisions, so a
# repo that pushed trunk itself never advanced its branches' alignment). Echoes 0 when the branch
# reaches no marker; the -gt guard below then keeps TP_ADVANCE=0.
TP_NEW_ALIGNED="$(svn_max_rev_reachable "$MAIN_WORKTREE" "$BRANCH")"
TP_ADVANCE=0
if [[ -n "$TP_CUR_ALIGNED" && -n "$TP_NEW_ALIGNED" && "$TP_NEW_ALIGNED" -gt "$TP_CUR_ALIGNED" ]]; then
  TP_ADVANCE=1
fi

echo "Finalising merge commit..."
if ! git -C "$REMOTE_PATH" commit --no-edit; then
  echo "Error: git commit failed when finalising the prepared merge." >&2
  exit 1
fi

MSG_FILE="$(mktemp)"
# --targets files for the add / delete / commit steps (issue #35). Created OUT here, not inside the
# subshell below: an EXIT trap set inside a subshell replaces the inherited one, so registering them
# together keeps a single cleanup that covers every exit path.
TARGETS_ADD="$(mktemp)"
TARGETS_DEL="$(mktemp)"
TARGETS_COMMIT="$(mktemp)"
# Cleanup the temp files unconditionally; SHA_FILE only on success
# (a failed commit retains the pin for retry — pin staleness is rechecked at top).
trap 'rm -f "$MSG_FILE" "$TARGETS_ADD" "$TARGETS_DEL" "$TARGETS_COMMIT"' EXIT
write_utf8_no_bom "$MSG_FILE" "$FULL_MESSAGE"

# Run the commit work in a subshell so a failure inside doesn't kill our cleanup logic.
# Capture its exit status so we can gate the SHA pin removal on success.
set +e
(
  cd "$REMOTE_PATH"

  TO_ADD=()
  TO_DEL=()
  MODIFIED_TO_COMMIT=()
  # issue #79: our own copy of "what is being committed", as `<status>\t<UTF-8 path>` entries.
  # It is collected from the SAME --xml passes that feed svn, so it is UTF-8 no matter what the
  # console codepage is. See the print site after `svn commit` for why svn's own listing cannot be
  # used for this.
  COMMIT_DISPLAY=()

  # Capture via `svn status --xml` (UTF-8 paths) so non-ASCII filenames re-pass cleanly.
  # Capture-first (under `set +e`) so an svn failure aborts the push instead of silently looking
  # like "no changes" — which would clean the pins and leave git ahead of an un-pushed SVN.
  XML_PASS1="$(svn_status_xml "$REMOTE_PATH")" || { echo "Error: svn status failed; aborting (pins retained for retry)." >&2; exit 1; }
  while IFS=$'\t' read -r status filepath; do
    [[ -z "$filepath" ]] && continue

    if git -C "$REMOTE_PATH" check-ignore -q "$filepath" 2>/dev/null; then
      echo "Skipping git-ignored ($status): $filepath"
      continue
    fi

    # svn_target: append the peg-revision escape. A filename containing '@' is legal in SVN and
    # checks out fine, but passing it as a TARGET makes svn read everything after the last '@' as a
    # revision (issue #34). Escaped here at collection time so every downstream svn call gets it.
    case "$status" in
      '?') TO_ADD+=("$(svn_target "$filepath")") ;;
      '!') TO_DEL+=("$(svn_target "$filepath")") ;;
      'M') MODIFIED_TO_COMMIT+=("$(svn_target "$filepath")")
           COMMIT_DISPLAY+=("M	$filepath") ;;
    esac
  done <<< "$XML_PASS1"

  # --targets, not argv: a push large enough (a first import of an existing project is typically
  # thousands of files) overflows the command-line length limit and dies with
  # "Argument list too long" before svn even starts (issue #35). The file carries the same escaped
  # paths -- a targets file is peg-parsed line by line exactly like argv.
  if [[ ${#TO_ADD[@]} -gt 0 ]]; then
    echo "SVN adding ${#TO_ADD[@]} new file(s)..."
    write_svn_targets_file "$TARGETS_ADD" "${TO_ADD[@]}" || exit 1
    # --quiet: svn echoes one "A <path>" line per file here, in the console codepage -- the same
    # mojibake as the commit listing (issue #79). The count is already announced above and every
    # path is listed as UTF-8 after the commit, so this output is redundant as well as unreadable.
    # Errors still reach stderr.
    svn add --quiet --parents --targets "$TARGETS_ADD" || exit 1
  fi
  if [[ ${#TO_DEL[@]} -gt 0 ]]; then
    echo "SVN deleting ${#TO_DEL[@]} removed file(s)..."
    write_svn_targets_file "$TARGETS_DEL" "${TO_DEL[@]}" || exit 1
    svn delete --quiet --targets "$TARGETS_DEL" || exit 1
  fi

  COMMIT_TARGETS=()
  # Second pass after add/delete: collect scheduled A/D entries (UTF-8 paths via --xml).
  XML_PASS2="$(svn_status_xml "$REMOTE_PATH")" || { echo "Error: svn status (second pass) failed; aborting." >&2; exit 1; }
  while IFS=$'\t' read -r status filepath; do
    [[ -z "$filepath" ]] && continue
    if [[ "$status" == 'A' || "$status" == 'D' ]]; then
      COMMIT_TARGETS+=("$(svn_target "$filepath")")
      COMMIT_DISPLAY+=("$status	$filepath")
    fi
  done <<< "$XML_PASS2"
  if [[ ${#MODIFIED_TO_COMMIT[@]} -gt 0 ]]; then
    COMMIT_TARGETS+=("${MODIFIED_TO_COMMIT[@]}")
  fi

  if [[ ${#COMMIT_TARGETS[@]} -eq 0 ]]; then
    echo "No changes to commit to SVN (all pending changes are git-ignored)"
    svn update > /dev/null || echo 'Warning: svn update on no-commit path failed. Remote worktree may be stale.' >&2
    exit 0
  fi

  # U4/KTD5: fold the tp:last-aligned-rev advance into THIS content commit. Set the property on the
  # branch root and add '.' as a --depth empty target so ONLY its property rides along (no recursion
  # into descendants, no separate property revision). Explicit file targets still commit regardless
  # of --depth (proven by the svn:ignore=.git + '.git' precedent in new-remote-bridge.sh). An
  # ordinary feature push (TP_ADVANCE=0) leaves the commit byte-identical to before -- no '.', no
  # --depth -- so it adds no property change.
  DEPTH_ARGS=()
  DOT_TARGET=()
  if [[ "$TP_ADVANCE" == 1 ]]; then
    svn propset tp:last-aligned-rev "$TP_NEW_ALIGNED" '.' || exit 1
    # '.' stays on the COMMAND LINE rather than going into the targets file: it is svn's
    # "this directory" token, not a collected path, so it must not pick up the peg escape that
    # every real path gets. Verified working alongside --targets + --depth empty.
    DOT_TARGET=('.')
    DEPTH_ARGS=(--depth empty)
  fi

  echo "Committing to SVN..."
  write_svn_targets_file "$TARGETS_COMMIT" "${COMMIT_TARGETS[@]}" || exit 1
  COMMIT_OUT="$(svn commit ${DEPTH_ARGS[@]+"${DEPTH_ARGS[@]}"} --file "$MSG_FILE" --encoding UTF-8 --targets "$TARGETS_COMMIT" ${DOT_TARGET[@]+"${DOT_TARGET[@]}"})" || exit 1
  # issue #79: print OUR OWN path list rather than svn's. svn renders its per-path progress lines in
  # the console codepage, so on a zh-TW host a non-ASCII filename arrives as '?' -- and this listing
  # is the one place the user sees WHAT was just written permanently, at the moment it became
  # permanent. The same paths are already in hand as UTF-8 (they came out of `svn status --xml`),
  # so print those and drop svn's mangled duplicates.
  #
  # ONLY the per-path action lines are dropped. Everything else svn says -- `Committed revision`,
  # warnings, anything a future svn version adds -- still passes through untouched, so this cannot
  # silently swallow a message we did not anticipate. Worst case (a localised svn whose verbs do not
  # match) is that both listings show, which is redundant but not wrong.
  #
  # Status letters, not svn's verbs: `A` / `D` / `M` is the same vocabulary tp-svn-log --verbose
  # already prints, so one format covers both directions.
  if [[ ${#COMMIT_DISPLAY[@]} -gt 0 ]]; then
    printf '%s\n' "${COMMIT_DISPLAY[@]}" | LC_ALL=C sort | while IFS=$'\t' read -r dstatus dpath; do
      printf '%s  %s\n' "$dstatus" "$dpath"
    done
  fi
  printf '%s\n' "$COMMIT_OUT" | grep -vE '^(Adding|Deleting|Sending|Replacing)( +\(bin\))?[[:space:]]' || true
  NEW_REV="$(printf '%s\n' "$COMMIT_OUT" | sed -n 's/Committed revision \([0-9]*\)\./\1/p' | tail -1)"
  [ -z "$NEW_REV" ] && NEW_REV='?'
  # R14 marker for a TRUNK push: this push CREATED revision $NEW_REV, and the commit whose tree is
  # that revision is the branch tip we just pushed. Recording it here is what makes a locally
  # PUSHED revision resolvable at all -- pulls mark the revisions they replay, pushes mark the ones
  # they create, and the floor lookup / alignment advance no longer care which direction it came
  # from. Only the trunk branch is marked: refs/tp/svn/* maps TRUNK revisions, and a feature push
  # creates a revision on the branch path, not on trunk.
  if [[ "$BRANCH" == "main" && "$NEW_REV" =~ ^[0-9]+$ ]]; then
    svn_rev_mark_set "$MAIN_WORKTREE" "$NEW_REV" "$(git -C "$MAIN_WORKTREE" rev-parse "$BRANCH")"
  fi
  svn update > /dev/null || echo 'Warning: svn update after commit failed. Remote worktree may be stale.' >&2
  echo "Pushed to SVN r$NEW_REV"
)
svn_commit_status=$?
set -e

if [[ $svn_commit_status -eq 0 ]]; then
  # SHA pin + svn-status pin + body pin cleanup runs only on success — a failed commit retains the pins for retry.
  rm -f "$SHA_FILE" 2>/dev/null || true
  rm -f "$SVN_STATUS_FILE" 2>/dev/null || true
  rm -f "$BODY_FILE" 2>/dev/null || true
else
  # A failed svn commit leaves a half-finished state that nothing else reports: the merge commit was
  # already made above, the adds/deletes are still SCHEDULED in the bridge working copy, and the pins
  # are deliberately kept so a retry need not redo the merge. Previously the script said none of this
  # and the user was left to reverse-engineer it (issue #34).
  #
  # No automatic rollback: whether to retry or unwind depends on WHY svn refused, and the script
  # cannot tell. A transient failure (network, lock, credentials) should be retried -- unwinding it
  # would throw away a correct merge. A rejected commit needs unwinding -- retrying just fails again.
  # So state the position plainly and give both exits.
  MERGE_SHA="$(git -C "$REMOTE_PATH" rev-parse --verify -q HEAD 2>/dev/null || true)"
  {
    echo ''
    echo 'TP_TOKEN:SVN_COMMIT_FAILED_HALF_DONE'
    echo 'The SVN commit failed. Nothing reached SVN (an svn commit is atomic), but locally:'
    echo '  - the merge commit has already been made on the bridge branch'
    echo '  - the add/delete are still scheduled in the bridge working copy'
    echo '  - the prepare pins are kept, so a retry does not have to redo the merge'
    echo ''
    echo 'RETRY (transient cause -- network, lock, credentials): fix the cause, re-run /tp-push-to-svn.'
    echo 'UNWIND (the commit was rejected and would be rejected again):'
    echo "  1. svn revert -R \"$REMOTE_PATH\""
    echo "  2. git -C \"$REMOTE_PATH\" reset --hard ${MERGE_SHA:-<merge-sha>}^1"
    echo "  3. rm -f \"$SHA_FILE\" \"$SVN_STATUS_FILE\" \"$BODY_FILE\""
    echo '  ORDER MATTERS: revert BEFORE reset. The other way round deletes the files from disk while'
    echo '  svn still has them scheduled, which is harder to clean up than the state you are in now.'
  } >&2
  exit $svn_commit_status
fi
