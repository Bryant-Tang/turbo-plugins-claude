#!/usr/bin/env bash
# Usage: submit-svn-commit.sh --branch <branch> --title "one-line title"
# The body is read from the locked pin (MERGE_HEAD.tp_svn_body) written by build-svn-commit.sh
# and combined with the title here; the agent supplies ONLY the title (U9).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"   # provides svn_status_xml (UTF-8/entity-safe svn status parser)
                                     # and svn_status_drift_paths (snapshot-vs-current set difference)

BRANCH=''
# U9: the agent supplies ONLY the title. The body is read from the pin file written by
# build-svn-commit.sh (body-from-file) and combined here — the agent cannot pass a free message.
TITLE=''
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''
# Drop svn:mime-type from the files SVN decided were binary but git calls text. Off by default and
# deliberately not inferable: it changes how SVN will treat those files from here on, so it is the
# user's call. The SKILL shows the list at confirmation time and only passes this after a yes.
CLEAR_BINARY_MIME=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --title)     [[ $# -ge 2 ]] || { echo "Error: --title requires a value" >&2; exit 1; }; TITLE="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --clear-binary-mime) CLEAR_BINARY_MIME=1; shift ;;
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

# The prepared merge is committed on the git side only AFTER svn has accepted the changeset (issue
# #187). It used to be committed first, so any svn step failing afterwards -- `svn add`, the binary
# guard, eol-style, the commit itself -- left MERGE_HEAD gone and SVN unchanged. A re-run then saw
# no pending merge and an empty range and answered "Nothing to push", which reads as success.
# Committing last keeps MERGE_HEAD until SVN has the change, so a failure lands back on the existing
# PENDING_MERGE_DETECTED path, and a retry still reuses the merge (what #34 wanted to keep).
finalise_git_merge() {
  echo "Finalising merge commit..."
  git -C "$REMOTE_PATH" commit --no-edit
}
# Exit codes the commit subshell below uses to say the git commit failed in a state where the
# half-done retry/unwind guidance would be WRONG. Anything else non-zero is the half-done state.
readonly EXIT_GIT_FAILED_AFTER_SVN=3   # SVN has the change; only the git commit is missing
readonly EXIT_GIT_FAILED_NOTHING_SENT=4  # nothing needed sending to SVN; only the git commit is missing
# issue #219: exit codes for "someone else committed to this SVN path while this push was running".
readonly EXIT_PATH_CHANGED_BEFORE_COMMIT=5  # caught just before `svn commit`; nothing reached SVN
readonly EXIT_REVISIONS_MISSING_IN_GIT=6    # caught after `svn commit`; SVN has ours AND theirs

# issue #219: the staleness check at the top runs once, and the add / delete / property steps
# between it and `svn commit` can take minutes on a large push. A teammate committing to the same
# path in that window is NOT refused by svn when none of their files are in our changeset -- the
# commit is out-of-date only per file -- so this asks the question again, from the URL, right
# before the commit. It narrows the window to the commit itself; it cannot close it, which is why
# list_foreign_revisions runs after the commit as well.
# Echoes the path's last-changed-revision; non-zero if svn cannot be asked.
current_path_rev() {
  local rev
  rev="$(svn info --show-item last-changed-revision "$SVN_URL" | tr -d '[:space:]')" || return 1
  [[ "$rev" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$rev"
}

# issue #219: list the revisions that changed THIS path strictly between the working copy's
# revision (what the push was built on) and the revision the push created. The staleness checks
# guarantee none of them were in the working copy, so every one is someone else's -- and since
# `svn commit` accepted ours anyway, the revision we created contains their changes too. One line
# per revision: "r<N> <author>: <first line of message>". Empty when there is no gap. Non-zero if
# svn cannot be asked. Args: <local_rev> <new_rev>
list_foreign_revisions() {
  local lo=$(( $1 + 1 )) hi=$(( $2 - 1 )) log_xml rev author _date msg
  (( lo <= hi )) || return 0
  # Pegged at the revision we created: the path exists there by construction.
  log_xml="$(svn log --xml -r "$lo:$hi" "${SVN_URL}@$2")" || return 1
  while IFS=$'\037' read -r -d '' rev author _date msg; do
    [[ -n "$rev" ]] || continue
    printf 'r%s %s: %s\n' "$rev" "${author:-(no author)}" "${msg%%$'\n'*}"
  done < <(printf '%s' "$log_xml" | svn_enumerate_revisions)
}

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
  # The same '?' paths without the peg escape, for the binary prediction below (issue #186).
  TO_ADD_RAW=()
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
      '?') TO_ADD+=("$(svn_target "$filepath")")
           TO_ADD_RAW+=("$filepath") ;;
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
    # --quiet: svn echoes one "A <path>" line per file here, in the console codepage -- the same
    # mojibake as the commit listing (issue #79). The count is already announced above and every
    # path is listed as UTF-8 after the commit, so this output is redundant as well as unreadable.
    # Errors still reach stderr.
    #
    # Files svn will stamp binary go in FIRST and without auto-props (issue #186): on a tree whose
    # svn:auto-props sets svn:eol-style for their extension, a plain add dies with E200009 and never
    # reaches the binary guard below. The main add then needs --force, because --parents has
    # already versioned any new directory those files live in; --force makes it recurse into that
    # directory and add the rest instead of refusing it as already versioned. Only in that case --
    # an ordinary push runs the exact same add as before. The same treatment covers a file git
    # itself calls binary whose name an eol-style rule matches (issue #212) -- see
    # list_new_svn_binary_files.
    ADD_FORCE=()
    NO_AUTOPROPS_FILES=()
    while IFS= read -r nb_path; do
      [[ -n "$nb_path" ]] && NO_AUTOPROPS_FILES+=("$(svn_target "$nb_path")")
    done < <(list_new_svn_binary_files "$REMOTE_PATH" "${TO_ADD_RAW[@]}")
    if [[ ${#NO_AUTOPROPS_FILES[@]} -gt 0 ]]; then
      write_svn_targets_file "$TARGETS_ADD" "${NO_AUTOPROPS_FILES[@]}" || exit 1
      svn add --quiet --parents --no-auto-props --targets "$TARGETS_ADD" || exit 1
      ADD_FORCE=(--force)
    fi
    write_svn_targets_file "$TARGETS_ADD" "${TO_ADD[@]}" || exit 1
    svn add --quiet --parents ${ADD_FORCE[@]+"${ADD_FORCE[@]}"} --targets "$TARGETS_ADD" || exit 1
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
    finalise_git_merge || exit "$EXIT_GIT_FAILED_NOTHING_SENT"
    # issue #219: nothing of ours was sent, so a revision someone else committed to this path since
    # the top check would arrive through this update as uncommitted edits, and /tp-pull-from-svn
    # could never replay it afterwards (the working copy would already be past it). Leave the
    # working copy where it is instead, so the pull still sees that revision as new.
    if NOW_REV="$(current_path_rev)" && (( LOCAL_REV < NOW_REV )); then
      echo "Note: this SVN path changed to r$NOW_REV while the push was running; skipped the closing svn update. Run /tp-pull-from-svn --branch $BRANCH to bring that revision into git." >&2
    else
      svn update > /dev/null || echo 'Warning: svn update on no-commit path failed. Remote worktree may be stale.' >&2
    fi
    exit 0
  fi

  # SVN's own content heuristic can decide a plain-text file is binary -- it reads the first 1024
  # bytes and counts every byte of UTF-8 CJK against the file, so prose with few ASCII markers
  # crosses the line -- and it stamps svn:mime-type=application/octet-stream at `svn add` time.
  # svn:eol-style CANNOT be set on a file carrying a binary mime type, so those files stop the push
  # one step below, and until now they did it with no warning at any earlier point (issue #175).
  #
  # This asks svn what it actually stored rather than re-deriving it: by now the adds have been
  # scheduled, so the property is real and no longer a prediction. The prediction belongs to
  # build-svn-commit.sh, which runs before anything is written and is what the confirmation shows.
  BLOCKERS_TSV="$(printf '%s\n' ${COMMIT_DISPLAY[@]+"${COMMIT_DISPLAY[@]}"} | list_svn_eol_blockers "$REMOTE_PATH")"
  if [[ -n "$BLOCKERS_TSV" ]]; then
    BLOCKED_PATHS=()
    while IFS=$'\t' read -r _why blocked_path; do
      [[ -n "$blocked_path" ]] && BLOCKED_PATHS+=("$blocked_path")
    done <<< "$BLOCKERS_TSV"
    if [[ "$CLEAR_BINARY_MIME" == 1 ]]; then
      if ! clear_svn_binary_mime "$REMOTE_PATH" "${BLOCKED_PATHS[@]}"; then
        echo 'Error: could not remove svn:mime-type from the files SVN marked binary; aborting (pins retained for retry).' >&2
        exit 1
      fi
      echo "Removed svn:mime-type from ${#BLOCKED_PATHS[@]} file(s) SVN had marked binary."
    else
      {
        echo 'Error: SVN treats these files as binary, so svn:eol-style cannot be set on them and'
        echo '       this push cannot go through (pins retained for retry):'
        printf '  %s\n' "${BLOCKED_PATHS[@]}"
        echo
        echo 'git considers them text. SVN decides from the first 1024 bytes and counts every byte'
        echo 'of UTF-8 CJK against the file, so a prose document with few ASCII markers ends up on'
        echo 'the wrong side. Rerun with --clear-binary-mime to drop svn:mime-type from them.'
      } >&2
      exit 1
    fi
  fi

  # Every text file in this changeset must carry svn:eol-style before the commit, because that
  # property is the only reason SVN normalises line endings on the way in. Without it svn stores
  # the working copy's bytes verbatim -- and this bridge deliberately follows the platform, so on
  # Windows those bytes are CRLF. Setting it here is what lets the bridge stop being pinned to LF
  # while SVN still ends up holding LF, the same division of labour git has with GitHub.
  #
  # Deletions are excluded: there is no working file left to translate.
  EOL_SCOPE=()
  for entry in ${COMMIT_DISPLAY[@]+"${COMMIT_DISPLAY[@]}"}; do
    entry_status="${entry%%$'\t'*}"
    entry_path="${entry#*$'\t'}"
    [[ "$entry_status" == 'D' ]] && continue
    [[ -n "$entry_path" ]] && EOL_SCOPE+=("$entry_path")
  done
  if [[ ${#EOL_SCOPE[@]} -gt 0 ]]; then
    # Aborts the push rather than committing anyway: pushing CRLF into a repository that stores
    # LF is precisely the silent corruption this whole mechanism exists to prevent, and it is not
    # visible afterwards in either tool.
    if ! EOL_MARKED="$(apply_svn_eol_style "$REMOTE_PATH" "${EOL_SCOPE[@]}")"; then
      echo 'Error: could not set svn:eol-style on the files being committed; aborting (pins retained for retry).' >&2
      exit 1
    fi
    if [[ "$EOL_MARKED" != '0' ]]; then
      echo "Marked $EOL_MARKED file(s) with svn:eol-style=native."
    fi
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

  # issue #219, first half: ask again, as late as possible. See current_path_rev.
  if ! PATH_REV_NOW="$(current_path_rev)"; then
    echo 'Error: could not read this SVN path'"'"'s last-changed revision before committing; aborting (pins retained for retry).' >&2
    exit 1
  fi
  if (( LOCAL_REV < PATH_REV_NOW )); then
    echo "Error: this SVN path changed while the push was being prepared (local r$LOCAL_REV, this path last changed at r$PATH_REV_NOW). Nothing was sent to SVN." >&2
    exit "$EXIT_PATH_CHANGED_BEFORE_COMMIT"
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
  # issue #219, second half: did anyone else's revision land on this path between the last check
  # and our commit? If so, the revision we just created holds their changes as well as ours, the
  # closing `svn update` below will drop their changes into the bridge as uncommitted edits, and
  # /tp-pull-from-svn can never replay them (the working copy is past them). That used to happen
  # in silence; now it is the one thing this push reports instead of success.
  FOREIGN_REVS=''
  FOREIGN_UNVERIFIED=0
  if [[ "$NEW_REV" =~ ^[0-9]+$ ]]; then
    FOREIGN_REVS="$(list_foreign_revisions "$LOCAL_REV" "$NEW_REV")" || FOREIGN_UNVERIFIED=1
  fi
  # R14 marker for a TRUNK push: this push CREATED revision $NEW_REV, and the commit whose tree is
  # that revision is the branch tip we just pushed. Recording it here is what makes a locally
  # PUSHED revision resolvable at all -- pulls mark the revisions they replay, pushes mark the ones
  # they create, and the floor lookup / alignment advance no longer care which direction it came
  # from. Only the trunk branch is marked: refs/tp/svn/* maps TRUNK revisions, and a feature push
  # creates a revision on the branch path, not on trunk.
  #
  # Not when other revisions landed in between (issue #219): the branch tip then lacks their
  # changes, so it is NOT the tree of $NEW_REV, and marking it would tell every later pull and
  # alignment that git already holds what it does not.
  if [[ "$BRANCH" == "main" && "$NEW_REV" =~ ^[0-9]+$ && -z "$FOREIGN_REVS" ]]; then
    svn_rev_mark_set "$MAIN_WORKTREE" "$NEW_REV" "$(git -C "$MAIN_WORKTREE" rev-parse "$BRANCH")"
  fi
  # SVN has it now. If the git side then fails, the push itself still went through: resync the
  # working copy and report the revision as usual, then leave with EXIT_GIT_FAILED_AFTER_SVN so the
  # half-done guidance below (retry / unwind) is not given for a state it would be wrong about.
  GIT_FINALISED=1
  finalise_git_merge || GIT_FINALISED=0
  svn update > /dev/null || echo 'Warning: svn update after commit failed. Remote worktree may be stale.' >&2
  echo "Pushed to SVN r$NEW_REV"
  if [[ "$FOREIGN_UNVERIFIED" == 1 ]]; then
    {
      echo "Warning: could not ask SVN whether anyone else committed to this path while the push ran."
      echo "  Check by hand: svn log -r $((LOCAL_REV + 1)):$NEW_REV \"$SVN_URL\""
      echo "  Any revision listed there other than r$NEW_REV is missing from git."
    } >&2
  fi
  if [[ -n "$FOREIGN_REVS" ]]; then
    REMOTE_BRANCH="$(printf '%s' "$REMOTE_SPEC" | cut -d'|' -f2)"
    {
      echo ''
      echo 'TP_TOKEN:SVN_REVISIONS_MISSING_IN_GIT'
      echo "The push IS in SVN as r$NEW_REV. But while it was being sent, other revision(s) were"
      echo 'committed to this same SVN path, and svn accepted ours anyway because no file overlapped:'
      printf '%s\n' "$FOREIGN_REVS" | sed 's/^/  /'
      echo "So SVN r$NEW_REV contains their changes too, and git does not: '$REMOTE_BRANCH' and"
      echo "'$BRANCH' are both missing them. The closing svn update has put those changes into the"
      echo 'bridge as uncommitted edits, and /tp-pull-from-svn cannot replay them (the bridge is past them).'
      if [[ "$BRANCH" == "main" ]]; then
        echo "r$NEW_REV was NOT recorded as matching '$BRANCH'."
      fi
      echo ''
      echo 'To bring git back in line with SVN [check `git -C "'"$REMOTE_PATH"'" status` first: it should list'
      echo 'only the changes of the revision(s) above]:'
      echo "  1. git -C \"$REMOTE_PATH\" add -A"
      echo "  2. git -C \"$REMOTE_PATH\" commit -m \"<the message of the revision(s) above>\""
      if [[ "$BRANCH" == "main" ]]; then
        echo "  3. git -C \"$MAIN_WORKTREE\" update-ref refs/tp/svn/$NEW_REV \"\$(git -C \"$REMOTE_PATH\" rev-parse HEAD)\""
        echo "  4. with '$BRANCH' checked out in \"$MAIN_WORKTREE\": git -C \"$MAIN_WORKTREE\" merge --no-ff \"$REMOTE_BRANCH\""
      else
        echo "  3. with '$BRANCH' checked out in \"$MAIN_WORKTREE\": git -C \"$MAIN_WORKTREE\" merge --no-ff \"$REMOTE_BRANCH\""
      fi
      echo 'Anything built or tagged from this push before that is missing those revisions too.'
    } >&2
  fi
  [[ "$GIT_FINALISED" == 1 ]] || exit "$EXIT_GIT_FAILED_AFTER_SVN"
  [[ -z "$FOREIGN_REVS" ]] || exit "$EXIT_REVISIONS_MISSING_IN_GIT"
)
svn_commit_status=$?
set -e

if [[ $svn_commit_status -eq 0 ]]; then
  # SHA pin + svn-status pin + body pin cleanup runs only on success — a failed commit retains the pins for retry.
  rm -f "$SHA_FILE" 2>/dev/null || true
  rm -f "$SVN_STATUS_FILE" 2>/dev/null || true
  rm -f "$BODY_FILE" 2>/dev/null || true
elif [[ $svn_commit_status -eq $EXIT_GIT_FAILED_AFTER_SVN || $svn_commit_status -eq $EXIT_GIT_FAILED_NOTHING_SENT ]]; then
  # Only the git-side commit of the prepared merge failed. Nothing is left to retry on the SVN side,
  # so the pins go; the merge stays staged, and the one thing to do is commit it.
  rm -f "$SHA_FILE" "$SVN_STATUS_FILE" "$BODY_FILE" 2>/dev/null || true
  {
    echo ''
    echo 'TP_TOKEN:GIT_COMMIT_FAILED_AFTER_SVN'
    if [[ $svn_commit_status -eq $EXIT_GIT_FAILED_AFTER_SVN ]]; then
      echo 'The change IS in SVN (see the revision above). Only the local git commit of the prepared'
      echo 'merge failed, so the bridge still holds it staged.'
    else
      echo 'Nothing needed sending to SVN (every change was git-ignored). Only the local git commit of'
      echo 'the prepared merge failed, so the bridge still holds it staged.'
    fi
    echo 'Fix the git error above, then finish it with:'
    echo "  git -C \"$REMOTE_PATH\" commit --no-edit"
    echo 'Do NOT re-run /tp-push-to-svn or abort the merge first.'
  } >&2
  exit 1
elif [[ $svn_commit_status -eq $EXIT_REVISIONS_MISSING_IN_GIT ]]; then
  # SVN and the git merge are both done; what is left is the repair the subshell already printed.
  # Nothing here is retryable, so the pins go exactly as on success.
  rm -f "$SHA_FILE" "$SVN_STATUS_FILE" "$BODY_FILE" 2>/dev/null || true
  exit 1
elif [[ $svn_commit_status -eq $EXIT_PATH_CHANGED_BEFORE_COMMIT ]]; then
  # Unlike the generic half-done state below, the cause is known and a retry cannot succeed: the
  # path has moved on, so the prepared merge is built on a stale base. The only way forward is to
  # unwind, pull, and push again.
  {
    echo ''
    echo 'TP_TOKEN:SVN_PATH_CHANGED_DURING_PUSH'
    echo 'Someone committed to this SVN path while the push was being prepared. Nothing reached SVN.'
    echo 'Retrying cannot work: the prepared merge is built on the old revision. To push again:'
    echo "  1. svn revert -R \"$REMOTE_PATH\""
    echo "  2. git -C \"$REMOTE_PATH\" reset --hard HEAD"
    echo "  3. rm -f \"$SHA_FILE\" \"$SVN_STATUS_FILE\" \"$BODY_FILE\""
    echo "  4. /tp-pull-from-svn --branch $BRANCH"
    echo "  5. /tp-push-to-svn --branch $BRANCH"
    echo '  ORDER MATTERS: revert BEFORE the reset (see the half-done guidance for why).'
  } >&2
  exit 1
else
  # A failed svn step leaves the push half-way, and nothing else would report it (issue #34). Since
  # issue #187 the half is the git side staying UNcommitted: the merge is still pending (MERGE_HEAD
  # kept), svn may have some adds/deletes/properties scheduled in the bridge working copy, and the
  # pins are kept -- so a re-run of /tp-push-to-svn lands on PENDING_MERGE_DETECTED and "continue"
  # finishes the push without redoing the merge.
  #
  # No automatic rollback: whether to retry or unwind depends on WHY svn refused, and the script
  # cannot tell. A transient failure (network, lock, credentials) should be retried -- unwinding it
  # would throw away a correct merge. A rejected commit needs unwinding -- retrying just fails again.
  # So state the position plainly and give both exits.
  {
    echo ''
    echo 'TP_TOKEN:SVN_COMMIT_FAILED_HALF_DONE'
    echo 'The push to SVN failed. Nothing reached SVN (an svn commit is atomic), and locally:'
    echo '  - the merge is prepared on the bridge branch but NOT committed (it stays pending)'
    echo '  - some add/delete/property changes may be scheduled in the bridge working copy'
    echo '  - the prepare pins are kept, so a retry does not have to redo the merge'
    echo ''
    echo 'RETRY (the cause is fixed, or was transient -- network, lock, credentials): re-run'
    echo '  /tp-push-to-svn; it reports the pending merge, and continuing finishes this push.'
    echo 'UNWIND (the commit was rejected and would be rejected again):'
    echo "  1. svn revert -R \"$REMOTE_PATH\""
    echo "  2. git -C \"$REMOTE_PATH\" reset --hard HEAD"
    echo "  3. rm -f \"$SHA_FILE\" \"$SVN_STATUS_FILE\" \"$BODY_FILE\""
    echo '  ORDER MATTERS: revert BEFORE the reset. The other way round deletes the files from disk'
    echo '  while svn still has them scheduled, which is harder to clean up than this state.'
    echo '  (reset, not `git merge --abort`: after the revert the working files no longer match the'
    echo '  staged merge, and merge --abort refuses to run over that.)'
  } >&2
  exit $svn_commit_status
fi
