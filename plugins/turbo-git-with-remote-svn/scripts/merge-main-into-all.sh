#!/usr/bin/env bash
# Merges main into every non-remote/* branch in the tgs project.
set -euo pipefail

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"

# Build branch -> worktree path map from `git worktree list --porcelain`
declare -A BRANCH_WORKTREE_MAP
current_path=''
while IFS= read -r line; do
  if [[ "$line" =~ ^worktree[[:space:]](.+)$ ]]; then
    current_path="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^branch[[:space:]]refs/heads/(.+)$ ]]; then
    BRANCH_WORKTREE_MAP["${BASH_REMATCH[1]}"]="$current_path"
  fi
done < <(git -C "$MAIN_WORKTREE" worktree list --porcelain)

# Collect target branches: not 'main', not 'remote/*'
mapfile -t TARGET_BRANCHES < <(
  git -C "$MAIN_WORKTREE" branch --format='%(refname:short)' |
  grep -v '^main$' |
  grep -v '^remote/'
)

if [[ ${#TARGET_BRANCHES[@]} -eq 0 ]]; then
  echo "No branches to merge into (only main and remote/* branches exist)."
  exit 0
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"
HAS_CONFLICT=false

for branch in "${TARGET_BRANCHES[@]}"; do
  dedicated="${BRANCH_WORKTREE_MAP[$branch]:-}"

  if [[ -n "$dedicated" && "$dedicated" != "$MAIN_WORKTREE" ]]; then
    # Branch is checked out in its own worktree
    status="$(git -C "$dedicated" status --porcelain)"
    if [[ -n "$status" ]]; then
      echo "SKIP $branch (dirty: $dedicated)"
      continue
    fi

    if ! git -C "$dedicated" merge main --no-ff -m "Merge branch 'main' into $branch"; then
      git -C "$dedicated" merge --abort
      echo "CONFLICT $branch (merge aborted)"
      HAS_CONFLICT=true
    else
      echo "OK $branch"
    fi
  else
    # Branch not currently checked out anywhere; use main worktree
    status="$(git -C "$MAIN_WORKTREE" status --porcelain)"
    if [[ -n "$status" ]]; then
      echo "SKIP $branch (main worktree is dirty)"
      continue
    fi

    if ! git -C "$MAIN_WORKTREE" checkout "$branch"; then
      echo "SKIP $branch (checkout failed)"
      continue
    fi

    if ! git -C "$MAIN_WORKTREE" merge main --no-ff -m "Merge branch 'main' into $branch"; then
      git -C "$MAIN_WORKTREE" merge --abort
      echo "CONFLICT $branch (merge aborted)"
      HAS_CONFLICT=true
    else
      echo "OK $branch"
    fi

    git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH"
  fi
done

if [[ "$HAS_CONFLICT" == true ]]; then exit 1; fi
