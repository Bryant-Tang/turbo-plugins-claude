#!/usr/bin/env bash
# Usage: release-merge-tips.sh --merge-commits "<csv>" | --hotfix-branches "<csv>"
# Exactly one of the two parameters must be provided.
set -euo pipefail

MERGE_COMMITS=''
HOTFIX_BRANCHES=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --merge-commits)    [[ $# -ge 2 ]] || { echo "Error: --merge-commits requires a value" >&2; exit 1; }; MERGE_COMMITS="$2"; shift 2 ;;
    --hotfix-branches)  [[ $# -ge 2 ]] || { echo "Error: --hotfix-branches requires a value" >&2; exit 1; }; HOTFIX_BRANCHES="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -n "$MERGE_COMMITS" && -n "$HOTFIX_BRANCHES" ]]; then
  echo "Error: provide exactly one of --merge-commits or --hotfix-branches, not both." >&2; exit 1
fi
if [[ -z "$MERGE_COMMITS" && -z "$HOTFIX_BRANCHES" ]]; then
  echo "Error: missing required argument: --merge-commits or --hotfix-branches" >&2; exit 1
fi

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"

# Build TIPS and MESSAGES arrays
declare -a TIPS=()
declare -a MESSAGES=()

if [[ -n "$MERGE_COMMITS" ]]; then
  IFS=',' read -r -a MARR <<< "$MERGE_COMMITS"
  for M in "${MARR[@]}"; do
    M="${M// /}"
    [[ -z "$M" ]] && continue
    TIP="$(git -C "$MAIN_WORKTREE" rev-parse "${M}^2" 2>/dev/null || true)"
    if [[ -z "$TIP" ]]; then
      echo "Error: cannot resolve parent[1] of merge commit $M" >&2; exit 1
    fi
    SUBJECT="$(git -C "$MAIN_WORKTREE" log -1 --format=%s "$M")"
    TIPS+=("$TIP")
    MESSAGES+=("Release: $SUBJECT")
  done
else
  IFS=',' read -r -a BARR <<< "$HOTFIX_BRANCHES"
  for B in "${BARR[@]}"; do
    B="${B// /}"
    [[ -z "$B" ]] && continue
    TIP="$(git -C "$MAIN_WORKTREE" rev-parse --verify "refs/heads/$B" 2>/dev/null || true)"
    if [[ -z "$TIP" ]]; then
      echo "Error: branch '$B' does not exist." >&2; exit 1
    fi
    TIPS+=("$TIP")
    MESSAGES+=("Release: Hotfix: $B")
  done
fi

if (( ${#TIPS[@]} == 0 )); then
  echo "Error: no items to release." >&2; exit 1
fi

MAIN_STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$MAIN_STATUS" ]]; then
  echo "Error: main worktree has uncommitted changes. Commit or stash before release." >&2
  echo "$MAIN_STATUS" >&2
  exit 1
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"

SWITCHED=false
if [[ "$ORIGINAL_BRANCH" != 'main' ]]; then
  echo "Switching main worktree from '$ORIGINAL_BRANCH' to 'main'..."
  git -C "$MAIN_WORKTREE" checkout 'main'
  SWITCHED=true
fi

for I in "${!TIPS[@]}"; do
  TIP="${TIPS[$I]}"
  MSG="${MESSAGES[$I]}"
  echo "Merging $TIP into main with subject: $MSG"
  if ! git -C "$MAIN_WORKTREE" merge --no-ff "$TIP" -m "$MSG"; then
    CONFLICTS="$(git -C "$MAIN_WORKTREE" diff --name-only --diff-filter=U)"
    echo "Error: merge conflict on $TIP. Resolve in main worktree (currently on 'main') and run 'git merge --continue', then re-run /tgs:release for any remaining items." >&2
    if [[ "$SWITCHED" == true ]]; then
      echo "After resolving, switch back to '$ORIGINAL_BRANCH' (e.g. 'git checkout $ORIGINAL_BRANCH')." >&2
    fi
    echo "Conflicting files:" >&2
    echo "$CONFLICTS" >&2
    exit 1
  fi
done

if [[ "$SWITCHED" == true ]]; then
  git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  echo "Switched back to '$ORIGINAL_BRANCH'."
fi

echo ''
echo "Merged ${#TIPS[@]} tip(s) into main."
