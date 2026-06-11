#!/usr/bin/env bash
# Usage: submit-svn-commit.sh --branch <branch> --message "commit message"
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

# Parse `svn status --xml` and emit "<status_char>\t<relpath>" per changed entry.
# Rationale: plain `svn status` prints non-ASCII filenames in the console/ANSI codepage
# (CP_ACP, e.g. Big5 on zh-TW Windows). When those captured bytes are re-passed as argv to
# svn/git through Git Bash/MSYS (which assumes UTF-8), they are mangled -> "not under version
# control". `svn status --xml` always emits UTF-8 paths, which round-trip correctly. Using XML
# here also removes the CRLF-fragility of the old column-offset text parsing.
svn_status_xml() {
  local wc="$1"
  local xml
  xml="$(cd "$wc" && svn status --xml | tr '\n' ' ')"
  local -a _paths _items
  # Parse with grep -oE (ERE) + sed, NOT grep -oP (PCRE): PCRE refuses to run in non-UTF-8
  # locales ("grep: -P supports only unibyte and UTF-8 locales"), which is exactly the zh-TW
  # Windows Git Bash default. ERE is byte-based and locale-agnostic. (item="" is unique to
  # <wc-status> in plain `svn status --xml`; <target>/<entry> both carry path=, so anchor on
  # <entry> to skip the target node.)
  mapfile -t _paths < <(printf '%s' "$xml" | grep -oE '<entry[[:space:]]+path="[^"]*"' | sed 's/^[^"]*"//; s/"$//')
  mapfile -t _items < <(printf '%s' "$xml" | grep -oE 'item="[^"]*"' | sed 's/^[^"]*"//; s/"$//')
  local idx sc
  for idx in "${!_paths[@]}"; do
    case "${_items[$idx]}" in
      unversioned) sc='?' ;;
      missing)     sc='!' ;;
      modified)    sc='M' ;;
      added)       sc='A' ;;
      deleted)     sc='D' ;;
      *) continue ;;
    esac
    printf '%s\t%s\n' "$sc" "${_paths[$idx]}"
  done
}

BRANCH=''
MESSAGE=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --message)  [[ $# -ge 2 ]] || { echo "Error: --message requires a value" >&2; exit 1; }; MESSAGE="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi
if [[ -z "$MESSAGE" ]]; then echo "Error: --message is required" >&2; exit 1; fi

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
DRIFTED_FILES=''
while IFS=$'\t' read -r _sc filepath; do
  [[ -z "$filepath" ]] && continue
  if ! printf '%s\n' "$SNAPSHOT_PATHS" | grep -qxF "$filepath" 2>/dev/null; then
    DRIFTED_FILES="${DRIFTED_FILES}${filepath} "
  fi
done < <(svn_status_xml "$REMOTE_PATH")
if [[ -n "${DRIFTED_FILES// /}" ]]; then
  echo "Error: Remote worktree changed since prepare — file(s) appeared: ${DRIFTED_FILES}. Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to recompute." >&2
  exit 1
fi

echo "Finalising merge commit..."
if ! git -C "$REMOTE_PATH" commit --no-edit; then
  echo "Error: git commit failed when finalising the prepared merge." >&2
  exit 1
fi

MSG_FILE="$(mktemp)"
# Cleanup the temp message file unconditionally; SHA_FILE only on success
# (a failed commit retains the pin for retry — pin staleness is rechecked at top).
trap 'rm -f "$MSG_FILE"' EXIT
write_utf8_no_bom "$MSG_FILE" "$MESSAGE"

# Run the commit work in a subshell so a failure inside doesn't kill our cleanup logic.
# Capture its exit status so we can gate the SHA pin removal on success.
set +e
(
  cd "$REMOTE_PATH"

  TO_ADD=()
  TO_DEL=()
  MODIFIED_TO_COMMIT=()

  # Capture via `svn status --xml` (UTF-8 paths) so non-ASCII filenames re-pass cleanly.
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
  done < <(svn_status_xml "$REMOTE_PATH")

  if [[ ${#TO_ADD[@]} -gt 0 ]]; then
    echo "SVN adding ${#TO_ADD[@]} new file(s)..."
    svn add --parents "${TO_ADD[@]}" || exit 1
  fi
  if [[ ${#TO_DEL[@]} -gt 0 ]]; then
    echo "SVN deleting ${#TO_DEL[@]} removed file(s)..."
    svn delete "${TO_DEL[@]}" || exit 1
  fi

  COMMIT_TARGETS=()
  # Second pass after add/delete: collect scheduled A/D entries (UTF-8 paths via --xml).
  while IFS=$'\t' read -r status filepath; do
    [[ -z "$filepath" ]] && continue
    if [[ "$status" == 'A' || "$status" == 'D' ]]; then
      COMMIT_TARGETS+=("$filepath")
    fi
  done < <(svn_status_xml "$REMOTE_PATH")
  if [[ ${#MODIFIED_TO_COMMIT[@]} -gt 0 ]]; then
    COMMIT_TARGETS+=("${MODIFIED_TO_COMMIT[@]}")
  fi

  if [[ ${#COMMIT_TARGETS[@]} -eq 0 ]]; then
    echo "No changes to commit to SVN (all pending changes are git-ignored)"
    svn update > /dev/null || echo 'Warning: svn update on no-commit path failed. Remote worktree may be stale.' >&2
    exit 0
  fi

  echo "Committing to SVN..."
  COMMIT_OUT="$(svn commit "${COMMIT_TARGETS[@]}" --file "$MSG_FILE" --encoding UTF-8)" || exit 1
  printf '%s\n' "$COMMIT_OUT"
  NEW_REV="$(printf '%s\n' "$COMMIT_OUT" | sed -n 's/Committed revision \([0-9]*\)\./\1/p' | tail -1)"
  [ -z "$NEW_REV" ] && NEW_REV='?'
  svn update > /dev/null || echo 'Warning: svn update after commit failed. Remote worktree may be stale.' >&2
  echo "Pushed to SVN r$NEW_REV"
)
svn_commit_status=$?
set -e

if [[ $svn_commit_status -eq 0 ]]; then
  # SHA pin + svn-status pin cleanup runs only on success — a failed commit retains the pins for retry.
  rm -f "$SHA_FILE" 2>/dev/null || true
  rm -f "$SVN_STATUS_FILE" 2>/dev/null || true
else
  exit $svn_commit_status
fi
