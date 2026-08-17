#!/usr/bin/env bash
# WorktreeRemove hook — turbo-plugin-multi-repo-workspace. Pairs with create-worktree.sh.
#
# Removes what that hook created: either the single worktree under <repo>/.claude/worktrees/<name>
# (ordinary repo) or every project worktree under <workspace>/.worktrees/<name> plus the mirror
# directory itself (multi-repo workspace).
#
# NEVER destroys work. `git worktree remove` without --force refuses when the worktree has
# uncommitted changes, and a refusal here is left alone and reported. Failures are non-fatal by
# contract (the docs say WorktreeRemove failures are logged in debug mode only), so the worst case
# is a leftover directory the user can see and delete -- never a lost edit.
set -uo pipefail

log() { printf 'turbo-plugin worktree-remove: %s\n' "$*" >&2; }

payload="$(cat)"

json_str() {
  printf '%s' "$payload" |
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' |
    head -n 1
}

to_unix_path() {
  local p="$1"
  p="${p//\\\\//}"
  p="${p//\\//}"
  printf '%s' "$p"
}

NAME="$(json_str name)"

# A name is pasted straight into a path and a branch name below. It is a Claude Code session slug
# today, not user input, but a separator or a `..` in it would silently place the target outside
# the directory we mean to touch -- and this script removes things. Refuse loudly instead.
case "$NAME" in
  */*|*\\*|*..*|-*) log "refusing an implausible worktree name: $NAME"; exit 0 ;;
esac

# The payload field naming for the created location is not pinned down in the docs, so try the
# plausible spellings first.
TARGET=''
for key in worktreePath worktree_path path; do
  TARGET="$(to_unix_path "$(json_str "$key")")"
  [[ -n "$TARGET" ]] && break
done

# No path field: reconstruct. BOTH shapes create-worktree.sh can produce have to be considered --
# the mirror in a workspace AND the ordinary-repo worktree. Only checking the mirror would leave
# every ordinary-repo worktree behind forever, and the ordinary repo is the COMMON case, because
# this hook replaces the built-in everywhere and not just in workspaces.
if [[ -z "$TARGET" && -n "$NAME" ]]; then
  base="$(to_unix_path "$(json_str cwd)")"
  if [[ -n "$base" ]]; then
    if [[ -d "$base/.worktrees/$NAME" ]]; then
      TARGET="$base/.worktrees/$NAME"
    else
      top="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null || true)"
      [[ -n "$top" && -d "$top/.claude/worktrees/$NAME" ]] && TARGET="$top/.claude/worktrees/$NAME"
    fi
  fi
fi

[[ -n "$TARGET" ]] || { log "nothing identifiable to remove"; exit 0; }
[[ -d "$TARGET" ]] || { log "already gone: $TARGET"; exit 0; }

# create-worktree.sh opens ONE BRANCH PER PROJECT (`worktree add -b <name>`), so removal has to take
# them back down as well. Without this, every isolated session leaves a branch behind in every
# project -- eight projects means eight per session -- all named after a session slug that nobody
# can attribute after the fact, until `git branch` is unreadable (issue #87).
#
# Never a bare force-delete: that is precisely what turns "a leftover branch" into "lost commits".
# The safe delete goes first. If git refuses, the branch is force-deleted ONLY once another ref is
# shown to contain the same tip (so deleting it cannot lose anything); otherwise it is kept, with a
# line saying why. Leaving a branch behind is a tidiness problem; deleting the wrong one is not.
delete_branch() {
  local repo="$1" branch="$2" tip others
  [[ -n "$branch" ]] || return 0
  git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 || return 0

  if git -C "$repo" branch --quiet --delete "$branch" 2>/dev/null; then
    return 0
  fi

  # `git branch --delete` only counts "merged into HEAD or into its upstream". A worktree branched
  # from origin/<default> while the main checkout sits on some other branch is refused by that test
  # even though it carries no commits of its own -- so ask the question that actually matters:
  # is this exact tip already reachable from some other ref?
  tip="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || true)"
  if [[ -n "$tip" ]]; then
    others="$(git -C "$repo" for-each-ref --contains "$tip" --format='%(refname)' refs/heads refs/remotes 2>/dev/null |
                grep -v -x "refs/heads/$branch" | head -n 1)"
    if [[ -n "$others" ]] && git -C "$repo" branch --quiet --delete --force "$branch" 2>/dev/null; then
      return 0
    fi
  fi

  log "branch '$branch' carries commits of its own; keeping it in $repo"
  return 0
}

remove_one() {
  local wt="$1" owner repo
  owner="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$owner" ]]; then
    log "not a git worktree, leaving alone: $wt"
    return 1
  fi
  repo="$(dirname "$owner")"
  if ! git -C "$repo" worktree remove "$wt" 2>/dev/null; then
    log "refused to remove (uncommitted changes?), leaving alone: $wt"
    return 1
  fi
  # `git worktree remove` clears the registration and reports SUCCESS even when it could not delete
  # every file underneath (on Windows an open handle is the usual reason). Left at that, the
  # directory stays forever while `git worktree list` insists it is gone -- which is exactly the
  # half-removed state issue #87 describes. git has already declared this tree expendable, so
  # finish the job it reported as done rather than leave the two views disagreeing.
  if [[ -d "$wt" ]]; then
    rm -rf "$wt" 2>/dev/null || log "unregistered, but the directory could not be deleted: $wt"
  fi
  delete_branch "$repo" "$NAME"
  return 0
}

# The mirror case: TARGET holds one worktree per project.
leftovers=0
if [[ ! -e "$TARGET/.git" ]]; then
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    remove_one "$child" || leftovers=$(( leftovers + 1 ))
  done < <(find "$TARGET" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  if (( leftovers == 0 )); then
    rmdir "$TARGET" 2>/dev/null || log "mirror not empty, leaving alone: $TARGET"
  else
    log "$leftovers worktree(s) kept; leaving the mirror in place: $TARGET"
  fi
  exit 0
fi

# The ordinary-repo case: TARGET is itself the worktree.
remove_one "$TARGET" || true
exit 0
