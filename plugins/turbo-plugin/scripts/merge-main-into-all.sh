#!/usr/bin/env bash
# merge-main-into-all.sh — merge the latest `main` into every local branch that is
# neither `main` itself nor a `remote-svn/*` bridge branch.
#
# NEW semantics vs the old tgs merge-main-into-all this was ported from:
#   - Exclude filter excludes `main` AND `remote-svn/*` only. The old `^archives/`
#     exclusion is DROPPED (turbo-plugin retired the dev-flow / archive worktrees).
#   - NO worktree-aware path. turbo-plugin does not manage dev/archive worktrees, so we
#     operate purely in the main worktree: for each target branch checkout -> merge main
#     -> (abort on conflict) and restore the original branch at the end.
#   - Conflict handling is per-branch: on conflict we `git merge --abort` THAT branch,
#     mark it CONFLICT, and CONTINUE to the next branch (never leave a conflicted tree,
#     never stop the whole run).
#
# Guard: if the main worktree is dirty at start, fail loudly before touching anything.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

probe_git_version

MAIN_WORKTREE="$(get_main_worktree)"

# Refuse to run against a dirty main worktree.
STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"
if [[ -n "$STATUS" ]]; then
  echo "Error: main worktree is dirty ($MAIN_WORKTREE). Commit or stash changes before merging main into all branches." >&2
  exit 1
fi

# Collect target branches: not 'main', not 'remote-svn/*'.
mapfile -t TARGET_BRANCHES < <(
  git -C "$MAIN_WORKTREE" branch --format='%(refname:short)' |
  grep -v '^main$' |
  grep -v '^remote-svn/' || true
)

if [[ ${#TARGET_BRANCHES[@]} -eq 0 ]]; then
  echo "No branches to merge into (only main and remote-svn/* branches exist)."
  exit 0
fi

ORIGINAL_BRANCH="$(git -C "$MAIN_WORKTREE" rev-parse --abbrev-ref HEAD)"

MERGED=()
CONFLICT=()

for branch in "${TARGET_BRANCHES[@]}"; do
  if ! git -C "$MAIN_WORKTREE" checkout "$branch" >/dev/null 2>&1; then
    CONFLICT+=("$branch")
    echo "CONFLICT $branch (checkout failed)"
    continue
  fi

  if git -C "$MAIN_WORKTREE" merge main --no-ff -m "Merge branch 'main' into $branch" >/dev/null 2>&1; then
    MERGED+=("$branch")
    echo "OK $branch"
  else
    git -C "$MAIN_WORKTREE" merge --abort >/dev/null 2>&1 || true
    CONFLICT+=("$branch")
    echo "CONFLICT $branch (merge aborted)"
  fi
done

# Restore the branch we started on.
if ! git -C "$MAIN_WORKTREE" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1; then
  echo "Error: could not switch back to original branch '$ORIGINAL_BRANCH'." >&2
  exit 1
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
if [[ ${#MERGED[@]} -gt 0 ]]; then
  echo "Merged cleanly: ${MERGED[*]}"
else
  echo "Merged cleanly: (none)"
fi
if [[ ${#CONFLICT[@]} -gt 0 ]]; then
  echo "CONFLICT (aborted): ${CONFLICT[*]}"
else
  echo "CONFLICT (aborted): (none)"
fi

if [[ ${#CONFLICT[@]} -gt 0 ]]; then exit 1; fi
exit 0
