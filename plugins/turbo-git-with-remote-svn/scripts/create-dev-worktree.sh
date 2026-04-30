#!/usr/bin/env bash
# Usage: create-dev-worktree.sh --branch <branch> [--n <number>]
set -euo pipefail

BRANCH=''
N_ARG=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)  [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --n)       [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$BRANCH" ]]; then
  echo "Error: --branch is required" >&2; exit 1
fi

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"
WORKSPACE_FILE="$ROOT_DIR/$PROJ_NAME.code-workspace"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Are you inside a tgs project?" >&2; exit 1
fi

# Resolve <n>
if [[ -z "$N_ARG" ]]; then
  MAX_N=0
  for d in "$WORKTREES_DIR"/dev-*/; do
    [[ -d "$d" ]] || continue
    NAME="$(basename "$d")"
    if [[ "$NAME" =~ ^dev-([0-9]+)$ ]]; then
      NUM="${BASH_REMATCH[1]}"
      (( NUM > MAX_N )) && MAX_N=$NUM
    fi
  done
  IDX=$(( MAX_N + 1 ))
else
  if ! [[ "$N_ARG" =~ ^[0-9]+$ ]]; then
    echo "Error: --n must be a positive integer, got '$N_ARG'" >&2; exit 1
  fi
  IDX="$N_ARG"
fi

DEV_WORKTREE_NAME="dev-$IDX"
DEV_WORKTREE_PATH="$WORKTREES_DIR/$DEV_WORKTREE_NAME"

if [[ -d "$DEV_WORKTREE_PATH" ]]; then
  echo "Error: worktree '$DEV_WORKTREE_NAME' already exists at: $DEV_WORKTREE_PATH" >&2; exit 1
fi

# Create branch if missing
if ! git -C "$MAIN_WORKTREE" branch --list "$BRANCH" | grep -q .; then
  echo "Branch '$BRANCH' does not exist. Creating from HEAD of main..."
  git -C "$MAIN_WORKTREE" branch "$BRANCH"
fi

git -C "$MAIN_WORKTREE" worktree add "$DEV_WORKTREE_PATH" "$BRANCH"

CLOSE_LINE="$(grep -n $'^\t\],' "$WORKSPACE_FILE" | cut -d: -f1)"
if [[ -z "$CLOSE_LINE" ]]; then
  echo "Error: could not find folders closing bracket in $WORKSPACE_FILE" >&2; exit 1
fi
PREV_LINE=$(( CLOSE_LINE - 1 ))
TOTAL_LINES="$(wc -l < "$WORKSPACE_FILE")"
{
  head -n "$PREV_LINE" "$WORKSPACE_FILE" | sed '$s/$/,/'
  printf '\t\t{"name": "%s", "path": "%s.worktrees/%s"}\n' "$DEV_WORKTREE_NAME" "$PROJ_NAME" "$DEV_WORKTREE_NAME"
  tail -n $(( TOTAL_LINES - PREV_LINE )) "$WORKSPACE_FILE"
} > "${WORKSPACE_FILE}.tmp" && mv "${WORKSPACE_FILE}.tmp" "$WORKSPACE_FILE"

echo ""
echo "Dev worktree '$DEV_WORKTREE_NAME' created."
echo "  Branch   : $BRANCH"
echo "  Location : $DEV_WORKTREE_PATH"
echo ""
echo "Recommended: open Claude Code in '$DEV_WORKTREE_PATH' and run /tgs:setup to configure"
echo "  tgs environment variable defaults for that working directory."
