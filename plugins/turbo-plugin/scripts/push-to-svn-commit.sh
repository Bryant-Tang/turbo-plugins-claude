#!/usr/bin/env bash
# Usage: push-to-svn-commit.sh --branch <main|test-<n>> --message "commit message"
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
if [[ -f "$SHA_FILE" ]]; then
  PINNED_SHA="$(tr -d '[:space:]' < "$SHA_FILE")"
  CURRENT_SHA="$(git -C "$MAIN_WORKTREE" rev-parse "$BRANCH")"
  if [[ "$PINNED_SHA" != "$CURRENT_SHA" ]]; then
    PIN_SHORT="${PINNED_SHA:0:8}"
    CUR_SHORT="${CURRENT_SHA:0:8}"
    echo "Error: Branch '$BRANCH' has new commits since prepare (pinned: $PIN_SHORT, current: $CUR_SHORT). Abort the merge with 'git -C $REMOTE_PATH merge --abort' and rerun /tp-push-to-svn to include new commits." >&2
    exit 1
  fi
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

  SVN_STATUS_OUT="$(svn status | tr -d '\r')"
  if [[ $? -ne 0 ]]; then
    echo "Error: svn status failed" >&2
    exit 1
  fi
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
  SVN_STATUS_OUT2="$(svn status | tr -d '\r')"
  if [[ $? -ne 0 ]]; then
    echo "Error: svn status failed" >&2
    exit 1
  fi
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
    svn update > /dev/null
    exit 0
  fi

  echo "Committing to SVN..."
  COMMIT_OUT="$(svn commit "${COMMIT_TARGETS[@]}" --file "$MSG_FILE" --encoding UTF-8)" || exit 1
  printf '%s\n' "$COMMIT_OUT"
  NEW_REV="$(printf '%s\n' "$COMMIT_OUT" | sed -n 's/Committed revision \([0-9]*\)\./\1/p' | tail -1)"
  [ -z "$NEW_REV" ] && NEW_REV='?'
  svn update > /dev/null
  echo "Pushed to SVN r$NEW_REV"
)
svn_commit_status=$?
set -e

if [[ $svn_commit_status -eq 0 ]]; then
  # SHA pin cleanup runs only on success — a failed commit retains the pin for retry.
  rm -f "$SHA_FILE" 2>/dev/null || true
else
  exit $svn_commit_status
fi
