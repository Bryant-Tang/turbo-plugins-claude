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

remove_one() {
  local wt="$1" owner
  owner="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$owner" ]]; then
    log "not a git worktree, leaving alone: $wt"
    return 1
  fi
  if git -C "$(dirname "$owner")" worktree remove "$wt" 2>/dev/null; then
    return 0
  fi
  log "refused to remove (uncommitted changes?), leaving alone: $wt"
  return 1
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
