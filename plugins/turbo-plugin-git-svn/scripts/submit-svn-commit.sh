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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --title)    [[ $# -ge 2 ]] || { echo "Error: --title requires a value" >&2; exit 1; }; TITLE="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$TITLE" ]]; then echo "Error: --title is required" >&2; exit 1; fi

MAIN_WORKTREE="$(get_main_worktree)"
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

SVN_URL="$(svn info --show-item url "$REMOTE_PATH")"
LOCAL_REV="$(svn info --show-item revision "$REMOTE_PATH")"
HEAD_REV="$(svn info --show-item revision "$SVN_URL")"
if [[ "$LOCAL_REV" != "$HEAD_REV" ]]; then
  echo "Error: SVN HEAD changed since prepare (local r$LOCAL_REV, head r$HEAD_REV). Abort the merge with 'git -C $REMOTE_PATH merge --abort', then run '/tp-pull-from-svn --branch $BRANCH'." >&2; exit 1
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
SNAPSHOT_PATHS="$(cut -f2- "$SVN_STATUS_FILE")"
# Capture-first so an svn failure propagates (svn_status_xml returns non-zero on `svn status`
# failure); a process-substitution in the while-redirect would otherwise swallow that exit code.
CURRENT_XML="$(svn_status_xml "$REMOTE_PATH")" || { echo "Error: svn status failed (drift check). Re-run /tp-push-to-svn." >&2; exit 1; }
DRIFTED_FILES=''
while IFS=$'\t' read -r _sc filepath; do
  [[ -z "$filepath" ]] && continue
  if ! printf '%s\n' "$SNAPSHOT_PATHS" | grep -qxF "$filepath" 2>/dev/null; then
    DRIFTED_FILES="${DRIFTED_FILES}${filepath} "
  fi
done <<< "$CURRENT_XML"
if [[ -n "${DRIFTED_FILES// /}" ]]; then
  echo "Error: Remote worktree changed since prepare — file(s) appeared: ${DRIFTED_FILES}. Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to recompute." >&2
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
FULL_MESSAGE="$(printf '%s\n\n%s' "$TITLE_LINE" "$SVN_BODY")"

echo "Finalising merge commit..."
if ! git -C "$REMOTE_PATH" commit --no-edit; then
  echo "Error: git commit failed when finalising the prepared merge." >&2
  exit 1
fi

MSG_FILE="$(mktemp)"
# Cleanup the temp message file unconditionally; SHA_FILE only on success
# (a failed commit retains the pin for retry — pin staleness is rechecked at top).
trap 'rm -f "$MSG_FILE"' EXIT
write_utf8_no_bom "$MSG_FILE" "$FULL_MESSAGE"

# Run the commit work in a subshell so a failure inside doesn't kill our cleanup logic.
# Capture its exit status so we can gate the SHA pin removal on success.
set +e
(
  cd "$REMOTE_PATH"

  TO_ADD=()
  TO_DEL=()
  MODIFIED_TO_COMMIT=()

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

    case "$status" in
      '?') TO_ADD+=("$filepath") ;;
      '!') TO_DEL+=("$filepath") ;;
      'M') MODIFIED_TO_COMMIT+=("$filepath") ;;
    esac
  done <<< "$XML_PASS1"

  # `--` terminates option parsing so a filename beginning with '-' is never read as an svn flag.
  if [[ ${#TO_ADD[@]} -gt 0 ]]; then
    echo "SVN adding ${#TO_ADD[@]} new file(s)..."
    svn add --parents -- "${TO_ADD[@]}" || exit 1
  fi
  if [[ ${#TO_DEL[@]} -gt 0 ]]; then
    echo "SVN deleting ${#TO_DEL[@]} removed file(s)..."
    svn delete -- "${TO_DEL[@]}" || exit 1
  fi

  COMMIT_TARGETS=()
  # Second pass after add/delete: collect scheduled A/D entries (UTF-8 paths via --xml).
  XML_PASS2="$(svn_status_xml "$REMOTE_PATH")" || { echo "Error: svn status (second pass) failed; aborting." >&2; exit 1; }
  while IFS=$'\t' read -r status filepath; do
    [[ -z "$filepath" ]] && continue
    if [[ "$status" == 'A' || "$status" == 'D' ]]; then
      COMMIT_TARGETS+=("$filepath")
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

  echo "Committing to SVN..."
  COMMIT_OUT="$(svn commit --file "$MSG_FILE" --encoding UTF-8 -- "${COMMIT_TARGETS[@]}")" || exit 1
  printf '%s\n' "$COMMIT_OUT"
  NEW_REV="$(printf '%s\n' "$COMMIT_OUT" | sed -n 's/Committed revision \([0-9]*\)\./\1/p' | tail -1)"
  [ -z "$NEW_REV" ] && NEW_REV='?'
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
  exit $svn_commit_status
fi
