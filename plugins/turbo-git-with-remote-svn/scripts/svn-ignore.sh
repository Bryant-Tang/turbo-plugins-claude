#!/usr/bin/env bash
# Usage: svn-ignore.sh [--add <pattern>] [--remove <pattern>] [--path <dir>]
set -euo pipefail

ADD=''
REMOVE=''
SVN_PATH='.'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)    [[ $# -ge 2 ]] || { echo "Error: --add requires a value" >&2; exit 1; }; ADD="$2"; shift 2 ;;
    --remove) [[ $# -ge 2 ]] || { echo "Error: --remove requires a value" >&2; exit 1; }; REMOVE="$2"; shift 2 ;;
    --path)   [[ $# -ge 2 ]] || { echo "Error: --path requires a value" >&2; exit 1; }; SVN_PATH="$2"; shift 2 ;;
    *) echo "Error: unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -n "$ADD" && -n "$REMOVE" ]]; then
  echo "Error: use either --add or --remove, not both." >&2; exit 1
fi

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

if [[ ! -d "$WORKTREES_DIR" ]]; then
  echo "Error: worktrees directory not found: $WORKTREES_DIR. Are you inside a tgs project?" >&2; exit 1
fi

# Collect all remote worktrees
REMOTE_WORKTREES=()
for d in "$WORKTREES_DIR"/remote-main "$WORKTREES_DIR"/remote-test-*/; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  if [[ "$name" == 'remote-main' || "$name" =~ ^remote-test-[0-9]+$ ]]; then
    REMOTE_WORKTREES+=("${d%/}")
  fi
done

if [[ ${#REMOTE_WORKTREES[@]} -eq 0 ]]; then
  echo "Error: no remote worktrees found in: $WORKTREES_DIR" >&2; exit 1
fi

get_patterns() {
  local wt="$1"
  svn propget svn:ignore "$SVN_PATH" "$wt" 2>/dev/null | grep -v '^$' || true
}

# ── LIST ──────────────────────────────────────────────────────────────────────
if [[ -z "$ADD" && -z "$REMOVE" ]]; then
  REMOTE_MAIN="$WORKTREES_DIR/remote-main"
  if [[ ! -d "$REMOTE_MAIN" ]]; then
    echo "Error: remote-main worktree not found at: $REMOTE_MAIN" >&2; exit 1
  fi
  CANONICAL="$(get_patterns "$REMOTE_MAIN")"
  if [[ -z "$CANONICAL" ]]; then
    echo "No SVN ignore patterns at '$SVN_PATH'"
  else
    echo "SVN ignore patterns at '$SVN_PATH':"
    while IFS= read -r p; do echo "  $p"; done <<< "$CANONICAL"
  fi

  for wt in "${REMOTE_WORKTREES[@]}"; do
    name="$(basename "$wt")"
    [[ "$name" == 'remote-main' ]] && continue
    WT_PATTERNS="$(get_patterns "$wt")"
    if [[ "$WT_PATTERNS" != "$CANONICAL" ]]; then
      echo "Warning: svn:ignore in '$name' differs from remote-main — run 'svn-ignore --add/--remove' to re-sync"
    fi
  done
  exit 0
fi

# ── ADD ───────────────────────────────────────────────────────────────────────
if [[ -n "$ADD" ]]; then
  for wt in "${REMOTE_WORKTREES[@]}"; do
    name="$(basename "$wt")"

    SVN_DIRTY="$(svn status "$wt" 2>/dev/null || true)"
    if [[ -n "$SVN_DIRTY" ]]; then
      echo "Warning: '$name' has pending SVN changes — skipping (commit or revert first)"
      continue
    fi

    CURRENT="$(get_patterns "$wt")"
    if echo "$CURRENT" | grep -qxF "$ADD"; then
      echo "'$name': '$ADD' already in svn:ignore — skipping"
      continue
    fi

    # Warn if pattern matches already-tracked SVN files (best effort)
    TRACKED_MATCHES="$(svn list -R "$SVN_PATH" "$wt" 2>/dev/null | while IFS= read -r item; do
      item="${item%/}"
      fname="$(basename "$item")"
      # Simple glob match using case
      case "$fname" in
        $ADD) echo "  $item" ;;
      esac
      case "$item" in
        $ADD|$ADD/*) echo "  $item" ;;
      esac
    done | sort -u | head -5 || true)"
    if [[ -n "$TRACKED_MATCHES" ]]; then
      echo "Warning ('$name'): svn:ignore won't affect already-tracked files:"
      echo "$TRACKED_MATCHES"
      echo "  To stop pushing modifications, use 'git rm --cached' + .gitignore instead."
    fi

    if [[ -z "$CURRENT" ]]; then
      NEW_PATTERNS="$ADD"
    else
      NEW_PATTERNS="$CURRENT
$ADD"
    fi
    (cd "$wt" && printf '%s\n' "$NEW_PATTERNS" | svn propset svn:ignore --file - "$SVN_PATH")
    (cd "$wt" && svn commit -m "svn:ignore: add $ADD")
    echo "Added '$ADD' to svn:ignore in '$name'"
  done
  exit 0
fi

# ── REMOVE ────────────────────────────────────────────────────────────────────
if [[ -n "$REMOVE" ]]; then
  for wt in "${REMOTE_WORKTREES[@]}"; do
    name="$(basename "$wt")"

    SVN_DIRTY="$(svn status "$wt" 2>/dev/null || true)"
    if [[ -n "$SVN_DIRTY" ]]; then
      echo "Warning: '$name' has pending SVN changes — skipping (commit or revert first)"
      continue
    fi

    CURRENT="$(get_patterns "$wt")"
    if ! echo "$CURRENT" | grep -qxF "$REMOVE"; then
      echo "'$name': '$REMOVE' not found in svn:ignore — skipping"
      continue
    fi

    NEW_PATTERNS="$(echo "$CURRENT" | grep -vxF "$REMOVE" || true)"
    if [[ -z "$NEW_PATTERNS" ]]; then
      (cd "$wt" && svn propdel svn:ignore "$SVN_PATH")
    else
      (cd "$wt" && printf '%s\n' "$NEW_PATTERNS" | svn propset svn:ignore --file - "$SVN_PATH")
    fi
    (cd "$wt" && svn commit -m "svn:ignore: remove $REMOVE")
    echo "Removed '$REMOVE' from svn:ignore in '$name'"
  done
  exit 0
fi
