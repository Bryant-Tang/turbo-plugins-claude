#!/usr/bin/env bash
# merge-main-into-branches.sh -- merge the latest `main` into a set of local branches.
#
#   - Default (no --branch given): target = every local branch that is neither `main`
#     itself nor a `remote-svn/*` bridge branch.
#   - With one or more `--branch <name>`: target = exactly those branches. Each is
#     validated to exist (git branch --list) and to be neither `main` nor `remote-svn/*`.
#     A missing or excluded branch is reported as `SKIP <b> (not found / excluded)` and
#     skipped, never aborting the whole run.
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

# Collect any --branch <name> args (repeatable). No --branch => default to all.
REQUESTED=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      if [[ $# -lt 2 ]]; then echo "Error: --branch requires a value." >&2; exit 1; fi
      REQUESTED+=("$2")
      shift 2
      ;;
    --branch=*)
      REQUESTED+=("${1#--branch=}")
      shift
      ;;
    *)
      echo "Error: unknown argument '$1'." >&2
      exit 1
      ;;
  esac
done

probe_git_version

MAIN_WORKTREE="$(get_main_worktree)"

# Refuse to run against a dirty main worktree.
if ! STATUS="$(git -C "$MAIN_WORKTREE" status --porcelain)"; then
  echo "Error: git status --porcelain failed in $MAIN_WORKTREE" >&2
  exit 1
fi
if [[ -n "$STATUS" ]]; then
  echo "Error: main worktree is dirty ($MAIN_WORKTREE). Commit or stash changes before merging main into branches." >&2
  exit 1
fi

TARGET_BRANCHES=()
if [[ ${#REQUESTED[@]} -gt 0 ]]; then
  # Caller specified branches: validate each (exists, not main, not remote-svn/*).
  for b in "${REQUESTED[@]+"${REQUESTED[@]}"}"; do
    if [[ -z "$b" ]]; then continue; fi
    if [[ "$b" == "main" || "$b" == remote-svn/* ]]; then
      echo "SKIP $b (not found / excluded)"
      continue
    fi
    if [[ -z "$(git -C "$MAIN_WORKTREE" branch --list "$b")" ]]; then
      echo "SKIP $b (not found / excluded)"
      continue
    fi
    TARGET_BRANCHES+=("$b")
  done
else
  # Default: all local branches except 'main' and 'remote-svn/*'.
  mapfile -t TARGET_BRANCHES < <(
    git -C "$MAIN_WORKTREE" branch --format='%(refname:short)' |
    grep -v '^main$' |
    grep -v '^remote-svn/' || true
  )
fi

if [[ ${#TARGET_BRANCHES[@]} -eq 0 ]]; then
  echo "No branches to merge into."
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
