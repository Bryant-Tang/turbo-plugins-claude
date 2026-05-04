#!/usr/bin/env bash
# Usage: svn-ignore.sh [--add <pattern>]... [--remove <pattern>]... [--path <dir>]
set -euo pipefail

ADD=()
REMOVE=()
SVN_PATH='.'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)    [[ $# -ge 2 ]] || { echo "Error: --add requires a value" >&2; exit 1; }; ADD+=("$2"); shift 2 ;;
    --remove) [[ $# -ge 2 ]] || { echo "Error: --remove requires a value" >&2; exit 1; }; REMOVE+=("$2"); shift 2 ;;
    --path)   [[ $# -ge 2 ]] || { echo "Error: --path requires a value" >&2; exit 1; }; SVN_PATH="$2"; shift 2 ;;
    *) echo "Error: unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ ${#ADD[@]} -gt 0 && ${#REMOVE[@]} -gt 0 ]]; then
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
if [[ ${#ADD[@]} -eq 0 && ${#REMOVE[@]} -eq 0 ]]; then
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
if [[ ${#ADD[@]} -gt 0 ]]; then
  for wt in "${REMOTE_WORKTREES[@]}"; do
    name="$(basename "$wt")"

    SVN_DIRTY="$(svn status "$wt" 2>/dev/null | grep -E '^([MACDR!~]|.[MC])' || true)"
    if [[ -n "$SVN_DIRTY" ]]; then
      echo "Warning: '$name' has pending SVN changes — skipping (commit or revert first)"
      continue
    fi

    CURRENT="$(get_patterns "$wt")"

    TO_ADD=()
    for p in "${ADD[@]}"; do
      if [[ -n "$CURRENT" ]] && echo "$CURRENT" | grep -qxF "$p"; then
        echo "'$name': '$p' already in svn:ignore — skipping"
      else
        TO_ADD+=("$p")
      fi
    done
    [[ ${#TO_ADD[@]} -eq 0 ]] && continue

    # Warn if any new pattern matches already-tracked SVN files (best effort)
    TRACKED_LIST="$(svn list -R "$SVN_PATH" "$wt" 2>/dev/null || true)"
    for p in "${TO_ADD[@]}"; do
      TRACKED_MATCHES="$(echo "$TRACKED_LIST" | while IFS= read -r item; do
        item="${item%/}"
        fname="$(basename "$item")"
        case "$fname" in $p) echo "  $item" ;; esac
        case "$item" in $p|$p/*) echo "  $item" ;; esac
      done | sort -u | head -5 || true)"
      if [[ -n "$TRACKED_MATCHES" ]]; then
        echo "Warning ('$name'): svn:ignore won't affect already-tracked files matching '$p':"
        echo "$TRACKED_MATCHES"
        echo "  To stop pushing modifications, use 'git rm --cached' + .gitignore instead."
      fi
    done

    NEW_PATTERNS="$CURRENT"
    for p in "${TO_ADD[@]}"; do
      if [[ -n "$NEW_PATTERNS" ]]; then
        NEW_PATTERNS="${NEW_PATTERNS}"$'\n'"$p"
      else
        NEW_PATTERNS="$p"
      fi
    done
    (cd "$wt" && printf '%s\n' "$NEW_PATTERNS" | awk '{printf "%s\r\n", $0}' | svn propset svn:ignore --file - "$SVN_PATH")
    ADDED_LIST="$(IFS=', '; echo "${TO_ADD[*]}")"
    (cd "$wt" && svn commit -m "svn:ignore: add $ADDED_LIST")
    echo "Added '$ADDED_LIST' to svn:ignore in '$name'"
  done
  exit 0
fi

# ── REMOVE ────────────────────────────────────────────────────────────────────
if [[ ${#REMOVE[@]} -gt 0 ]]; then
  for wt in "${REMOTE_WORKTREES[@]}"; do
    name="$(basename "$wt")"

    SVN_DIRTY="$(svn status "$wt" 2>/dev/null | grep -E '^([MACDR!~]|.[MC])' || true)"
    if [[ -n "$SVN_DIRTY" ]]; then
      echo "Warning: '$name' has pending SVN changes — skipping (commit or revert first)"
      continue
    fi

    CURRENT="$(get_patterns "$wt")"

    TO_REMOVE=()
    for p in "${REMOVE[@]}"; do
      if [[ -n "$CURRENT" ]] && echo "$CURRENT" | grep -qxF "$p"; then
        TO_REMOVE+=("$p")
      else
        echo "'$name': '$p' not found in svn:ignore — skipping"
      fi
    done
    [[ ${#TO_REMOVE[@]} -eq 0 ]] && continue

    NEW_PATTERNS="$CURRENT"
    for p in "${TO_REMOVE[@]}"; do
      NEW_PATTERNS="$(echo "$NEW_PATTERNS" | grep -vxF "$p" || true)"
    done

    if [[ -z "$NEW_PATTERNS" ]]; then
      (cd "$wt" && svn propdel svn:ignore "$SVN_PATH")
    else
      (cd "$wt" && printf '%s\n' "$NEW_PATTERNS" | awk '{printf "%s\r\n", $0}' | svn propset svn:ignore --file - "$SVN_PATH")
    fi
    REMOVED_LIST="$(IFS=', '; echo "${TO_REMOVE[*]}")"
    (cd "$wt" && svn commit -m "svn:ignore: remove $REMOVED_LIST")
    echo "Removed '$REMOVED_LIST' from svn:ignore in '$name'"
  done
  exit 0
fi
