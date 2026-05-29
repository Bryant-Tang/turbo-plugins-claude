#!/usr/bin/env bash
# Usage: submit-svn-commit.sh --branch <main|test-<n>> --message "commit message"
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

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
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

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
# Compare snapshot vs current: detect files that appeared after prepare
SNAPSHOT_PATHS="$(grep -oP '(?<=^.\s{7}).+' "$SVN_STATUS_FILE" 2>/dev/null || awk 'NF{print substr($0,9)}' "$SVN_STATUS_FILE")"
CURRENT_SVN_STATUS="$(svn status "$REMOTE_PATH")"
DRIFTED_FILES=''
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  filepath="${line:8}"
  filepath="${filepath#"${filepath%%[![:space:]]*}"}"
  if [[ -n "$filepath" ]] && ! printf '%s\n' "$SNAPSHOT_PATHS" | grep -qxF "$filepath" 2>/dev/null; then
    DRIFTED_FILES="${DRIFTED_FILES}${filepath} "
  fi
done < <(printf '%s\n' "$CURRENT_SVN_STATUS")
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

  # F-U(synth #14): capture svn status independently of the `tr` pipeline so its exit code
  # is observed (previously `$?` read tr's 0, masking real svn failures like server-down).
  SVN_STATUS_RAW="$(svn status)" || { echo "Error: svn status failed" >&2; exit 1; }
  SVN_STATUS_OUT="$(printf '%s' "$SVN_STATUS_RAW" | tr -d '\r')"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status="${line:0:1}"
    filepath="${line:8}"
    [[ -z "$filepath" ]] && continue
    [[ "$status" != '?' && "$status" != '!' && "$status" != 'M' ]] && continue

    if git -C "$REMOTE_PATH" check-ignore -q "$filepath" 2>/dev/null; then
      echo "Skipping git-ignored ($status): $filepath"
      continue
    fi

    case "$status" in
      '?') TO_ADD+=("$filepath") ;;
      '!') TO_DEL+=("$filepath") ;;
      'M') MODIFIED_TO_COMMIT+=("$filepath") ;;
    esac
  done < <(printf '%s\n' "$SVN_STATUS_OUT")

  if [[ ${#TO_ADD[@]} -gt 0 ]]; then
    echo "SVN adding ${#TO_ADD[@]} new file(s)..."
    svn add --parents "${TO_ADD[@]}" || exit 1
  fi
  if [[ ${#TO_DEL[@]} -gt 0 ]]; then
    echo "SVN deleting ${#TO_DEL[@]} removed file(s)..."
    svn delete "${TO_DEL[@]}" || exit 1
  fi

  COMMIT_TARGETS=()
  # F-U(synth #14): same tr-mask fix — capture svn status independently for second pass.
  SVN_STATUS_RAW2="$(svn status)" || { echo "Error: svn status (second pass) failed" >&2; exit 1; }
  SVN_STATUS_OUT2="$(printf '%s' "$SVN_STATUS_RAW2" | tr -d '\r')"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status="${line:0:1}"
    filepath="${line:8}"
    if [[ "$status" == 'A' || "$status" == 'D' ]]; then
      COMMIT_TARGETS+=("$filepath")
    fi
  done < <(printf '%s\n' "$SVN_STATUS_OUT2")
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
