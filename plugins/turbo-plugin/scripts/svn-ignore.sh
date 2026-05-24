#!/usr/bin/env bash
# Usage: svn-ignore.sh [--add <pattern>]... [--remove <pattern>]... [--path <dir>]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

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

MAIN_WORKTREE="$(get_main_worktree)"
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
  (cd "$wt" && svn propget svn:ignore "$SVN_PATH" 2>/dev/null) | grep -v '^$' || true
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

# ── ADD (two-pass: propset all → verify → commit all) ─────────────────────────
if [[ ${#ADD[@]} -gt 0 ]]; then
  # Collect which worktrees need committing; track propset failures.
  declare -a PENDING_WTS=()
  declare -a PENDING_ADDED=()
  declare -a PROPSET_FAILED=()

  # Pass 1: propset in each worktree
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

    if (cd "$wt" && printf '%s\n' "$NEW_PATTERNS" | awk '{printf "%s\r\n", $0}' | svn propset svn:ignore --file - "$SVN_PATH"); then
      PENDING_WTS+=("$wt")
      ADDED_LIST="$(IFS=', '; echo "${TO_ADD[*]}")"
      PENDING_ADDED+=("$ADDED_LIST")
    else
      PROPSET_FAILED+=("$name")
    fi
  done

  # If any propset failed, revert all that succeeded and abort.
  if [[ ${#PROPSET_FAILED[@]} -gt 0 ]]; then
    for wt in "${PENDING_WTS[@]}"; do
      (cd "$wt" && svn revert "$SVN_PATH" 2>/dev/null || true)
    done
    FAILED_LIST="$(IFS=', '; echo "${PROPSET_FAILED[*]}")"
    echo "Error: svn propset svn:ignore failed in: $FAILED_LIST. All worktrees reverted." >&2
    exit 1
  fi

  # Pass 2: commit each worktree. Capture per-iteration failure into a structured report so
  # partial commits are surfaced clearly — already-committed worktrees cannot be rolled back.
  SUCCEEDED_WTS=()
  FAILED_WTS=()
  for i in "${!PENDING_WTS[@]}"; do
    wt="${PENDING_WTS[$i]}"
    name="$(basename "$wt")"
    added="${PENDING_ADDED[$i]}"
    if commit_err="$(cd "$wt" && svn commit -m "svn:ignore: add $added" 2>&1)"; then
      echo "Added '$added' to svn:ignore in '$name'"
      SUCCEEDED_WTS+=("$name")
    else
      # Compact error to first line for the summary line; full message preserved in the listing below.
      first_line="$(printf '%s' "$commit_err" | head -1)"
      FAILED_WTS+=("$name: $first_line")
    fi
  done
  if [[ ${#FAILED_WTS[@]} -gt 0 ]]; then
    {
      echo "svn-ignore: pass-2 partial failure."
      if [[ ${#SUCCEEDED_WTS[@]} -gt 0 ]]; then
        printf 'Succeeded (%d worktrees): %s\n' "${#SUCCEEDED_WTS[@]}" "$(IFS=', '; echo "${SUCCEEDED_WTS[*]}")"
      else
        echo "Succeeded (0 worktrees): (none)"
      fi
      printf 'Failed (%d worktrees):\n' "${#FAILED_WTS[@]}"
      for f in "${FAILED_WTS[@]}"; do echo "  $f"; done
      echo "Already-committed worktrees cannot be rolled back. Inspect and 'svn revert' the failed worktrees manually."
    } >&2
    exit 1
  fi
  exit 0
fi

# ── REMOVE (two-pass: propset all → verify → commit all) ──────────────────────
if [[ ${#REMOVE[@]} -gt 0 ]]; then
  declare -a PENDING_WTS=()
  declare -a PENDING_REMOVED=()
  declare -a PROPSET_FAILED=()

  # Pass 1: propdel/propset in each worktree
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

    propset_ok=true
    if [[ -z "$NEW_PATTERNS" ]]; then
      if ! (cd "$wt" && svn propdel svn:ignore "$SVN_PATH"); then
        propset_ok=false
      fi
    else
      if ! (cd "$wt" && printf '%s\n' "$NEW_PATTERNS" | awk '{printf "%s\r\n", $0}' | svn propset svn:ignore --file - "$SVN_PATH"); then
        propset_ok=false
      fi
    fi

    if [[ "$propset_ok" == true ]]; then
      PENDING_WTS+=("$wt")
      REMOVED_LIST="$(IFS=', '; echo "${TO_REMOVE[*]}")"
      PENDING_REMOVED+=("$REMOVED_LIST")
    else
      PROPSET_FAILED+=("$name")
    fi
  done

  # If any propset/propdel failed, revert all that succeeded and abort.
  if [[ ${#PROPSET_FAILED[@]} -gt 0 ]]; then
    for wt in "${PENDING_WTS[@]}"; do
      (cd "$wt" && svn revert "$SVN_PATH" 2>/dev/null || true)
    done
    FAILED_LIST="$(IFS=', '; echo "${PROPSET_FAILED[*]}")"
    echo "Error: svn propset/propdel svn:ignore failed in: $FAILED_LIST. All worktrees reverted." >&2
    exit 1
  fi

  # Pass 2: commit each worktree. Capture per-iteration failure into a structured report so
  # partial commits are surfaced clearly — already-committed worktrees cannot be rolled back.
  SUCCEEDED_WTS=()
  FAILED_WTS=()
  for i in "${!PENDING_WTS[@]}"; do
    wt="${PENDING_WTS[$i]}"
    name="$(basename "$wt")"
    removed="${PENDING_REMOVED[$i]}"
    if commit_err="$(cd "$wt" && svn commit -m "svn:ignore: remove $removed" 2>&1)"; then
      echo "Removed '$removed' from svn:ignore in '$name'"
      SUCCEEDED_WTS+=("$name")
    else
      first_line="$(printf '%s' "$commit_err" | head -1)"
      FAILED_WTS+=("$name: $first_line")
    fi
  done
  if [[ ${#FAILED_WTS[@]} -gt 0 ]]; then
    {
      echo "svn-ignore: pass-2 partial failure."
      if [[ ${#SUCCEEDED_WTS[@]} -gt 0 ]]; then
        printf 'Succeeded (%d worktrees): %s\n' "${#SUCCEEDED_WTS[@]}" "$(IFS=', '; echo "${SUCCEEDED_WTS[*]}")"
      else
        echo "Succeeded (0 worktrees): (none)"
      fi
      printf 'Failed (%d worktrees):\n' "${#FAILED_WTS[@]}"
      for f in "${FAILED_WTS[@]}"; do echo "  $f"; done
      echo "Already-committed worktrees cannot be rolled back. Inspect and 'svn revert' the failed worktrees manually."
    } >&2
    exit 1
  fi
  exit 0
fi
