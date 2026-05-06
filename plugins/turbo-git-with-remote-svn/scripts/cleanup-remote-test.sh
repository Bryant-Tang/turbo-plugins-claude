#!/usr/bin/env bash
# Usage: cleanup-remote-test.sh --n <number>
set -euo pipefail

# Track sed -i.bak backup so it always gets cleaned, even on error mid-flow.
WORKSPACE_BAK=''
trap 'if [[ -n "$WORKSPACE_BAK" ]]; then rm -f "$WORKSPACE_BAK"; fi' EXIT

N_ARG=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)  [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$N_ARG" ]]; then
  echo "Error: --n is required" >&2; exit 1
fi
if ! [[ "$N_ARG" =~ ^[0-9]+$ ]]; then
  echo "Error: --n must be a positive integer, got '$N_ARG'" >&2; exit 1
fi
IDX="$N_ARG"
TEST_BRANCH="test-$IDX"
REMOTE_BRANCH="remote/test-$IDX"
REMOTE_WORKTREE_NAME="remote-test-$IDX"

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"
WORKSPACE_FILE="$ROOT_DIR/$PROJ_NAME.code-workspace"
REMOTE_WORKTREE_PATH="$WORKTREES_DIR/$REMOTE_WORKTREE_NAME"

# Pre-flight: not currently checked out on test-<n>
CURRENT_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" == "$TEST_BRANCH" ]]; then
  echo "Error: main worktree is currently on '$TEST_BRANCH'. Switch to 'main' first (e.g. 'git checkout main') before cleanup." >&2
  exit 1
fi

# Pre-flight: main worktree clean
MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before cleanup." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

# Pre-flight: remote-test-<n> worktree clean (if present)
if [[ -d "$REMOTE_WORKTREE_PATH" ]]; then
  REMOTE_STATUS="$(git -C "$REMOTE_WORKTREE_PATH" status --porcelain)"
  if [[ -n "$REMOTE_STATUS" ]]; then
    echo "Error: remote test worktree has uncommitted changes. Run /tgs:push-to-svn or /tgs:pull-from-svn before cleanup." >&2
    echo "$REMOTE_STATUS" >&2
    exit 1
  fi
fi

echo "Removing test environment $IDX..."

# Remove worktree (if present)
if [[ -d "$REMOTE_WORKTREE_PATH" ]]; then
  git -C "$MAIN_WORKTREE" worktree remove --force "$REMOTE_WORKTREE_PATH"
  echo "  - Removed worktree: $REMOTE_WORKTREE_PATH"
else
  echo "  - Worktree '$REMOTE_WORKTREE_NAME' was not present, skipping."
fi

# Delete branches
if git -C "$MAIN_WORKTREE" branch --list "$TEST_BRANCH" | grep -q .; then
  git -C "$MAIN_WORKTREE" branch -D "$TEST_BRANCH"
  echo "  - Deleted branch: $TEST_BRANCH"
else
  echo "  - Branch '$TEST_BRANCH' was not present, skipping."
fi

if git -C "$MAIN_WORKTREE" branch --list "$REMOTE_BRANCH" | grep -q .; then
  git -C "$MAIN_WORKTREE" branch -D "$REMOTE_BRANCH"
  echo "  - Deleted branch: $REMOTE_BRANCH"
else
  echo "  - Branch '$REMOTE_BRANCH' was not present, skipping."
fi

# Workspace cleanup: remove the folder entry whose "name" matches.
# Handles both single-line entries (as written by create-remote-test.sh) and
# multi-line entries (as VS Code or hand-formatting would write).
if [[ -f "$WORKSPACE_FILE" ]]; then
  WORKSPACE_BAK="${WORKSPACE_FILE}.bak"
  TARGET_LINE="$(grep -n "\"name\":[[:space:]]*\"$REMOTE_WORKTREE_NAME\"" "$WORKSPACE_FILE" | head -n1 | cut -d: -f1 || true)"
  if [[ -n "$TARGET_LINE" ]]; then
    LINE_CONTENT="$(sed -n "${TARGET_LINE}p" "$WORKSPACE_FILE")"
    if [[ "$LINE_CONTENT" == *'{'* && "$LINE_CONTENT" == *'}'* ]]; then
      # Single-line entry: delete this line; if it had a trailing comma, the
      # remaining entries are well-formed; if not, strip a trailing comma from
      # the previous folder line.
      if [[ "$LINE_CONTENT" =~ ,[[:space:]]*$ ]]; then
        sed -i.bak "${TARGET_LINE}d" "$WORKSPACE_FILE"
      else
        PREV_LINE=$(( TARGET_LINE - 1 ))
        sed -i.bak -e "${TARGET_LINE}d" -e "${PREV_LINE}s/,[[:space:]]*$//" "$WORKSPACE_FILE"
      fi
    else
      # Multi-line entry: walk back to the opening '{' (at line start, after
      # optional whitespace) and forward to the closing '}' (same anchor) to
      # determine the block range, then delete it. The leading-whitespace
      # anchor avoids stopping on braces embedded inside string values.
      START_LINE=$TARGET_LINE
      while (( START_LINE > 1 )); do
        L="$(sed -n "${START_LINE}p" "$WORKSPACE_FILE")"
        if [[ "$L" =~ ^[[:space:]]*\{ ]]; then break; fi
        START_LINE=$(( START_LINE - 1 ))
      done
      END_LINE=$TARGET_LINE
      TOTAL_LINES="$(wc -l < "$WORKSPACE_FILE")"
      while (( END_LINE <= TOTAL_LINES )); do
        L="$(sed -n "${END_LINE}p" "$WORKSPACE_FILE")"
        if [[ "$L" =~ ^[[:space:]]*\} ]]; then break; fi
        END_LINE=$(( END_LINE + 1 ))
      done
      END_CONTENT="$(sed -n "${END_LINE}p" "$WORKSPACE_FILE")"
      HAD_TRAILING_COMMA=0
      if [[ "$END_CONTENT" =~ \},[[:space:]]*$ ]]; then HAD_TRAILING_COMMA=1; fi
      sed -i.bak "${START_LINE},${END_LINE}d" "$WORKSPACE_FILE"
      if (( HAD_TRAILING_COMMA == 0 )); then
        # Block was the last folder entry; trim trailing comma off the new
        # last entry's closing brace.
        PREV_END=$(( START_LINE - 1 ))
        while (( PREV_END > 0 )); do
          L="$(sed -n "${PREV_END}p" "$WORKSPACE_FILE")"
          if [[ -n "$L" ]]; then
            if [[ "$L" =~ \},[[:space:]]*$ ]]; then
              sed -i.bak "${PREV_END}s/},[[:space:]]*$/}/" "$WORKSPACE_FILE"
            fi
            break
          fi
          PREV_END=$(( PREV_END - 1 ))
        done
      fi
    fi
    echo "  - Removed workspace entry: $REMOTE_WORKTREE_NAME"
  else
    echo "  - Workspace entry '$REMOTE_WORKTREE_NAME' was not present, skipping."
  fi
else
  echo "  - No code-workspace file found, skipping workspace cleanup."
fi

echo ''
echo "Cleanup complete for test-$IDX."
echo "Note: SVN path is preserved as history. Next /tgs:create-remote-test will use a fresh number; if you want to reuse the same SVN URL, pass --svn-url to a new test slot."
