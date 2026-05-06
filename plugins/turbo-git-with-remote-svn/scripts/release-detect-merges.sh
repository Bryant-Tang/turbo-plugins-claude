#!/usr/bin/env bash
# Usage: release-detect-merges.sh --n <number>
# Output (stdout, one per candidate):
#   <merge_hash>|<tip_hash>|<subject>|<branch_status>
# branch_status is one of:
#   AT_TIP:<comma-list>    branches still pointing exactly at tip
#   ADVANCED:<comma-list>  branches contain tip but their HEAD is past it
#   NONE                   no current branch corresponds
set -euo pipefail

N_ARG=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)  [[ $# -ge 2 ]] || { echo "Error: --n requires a value" >&2; exit 1; }; N_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$N_ARG" ]]; then
  echo "Error: --n is required" >&2; exit 1
fi
if ! [[ "$N_ARG" =~ ^[0-9]+$ ]]; then
  echo "Error: --n must be a positive integer, got '$N_ARG'" >&2; exit 1
fi
IDX="$N_ARG"
TEST_BRANCH="test-$IDX"
REMOTE_TEST_BRANCH="remote/test-$IDX"
REMOTE_MAIN='remote/main'

COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -z "$COMMON_GIT_DIR" ]]; then
  echo "Error: not inside a git repository." >&2; exit 1
fi
MAIN_WORKTREE="$(dirname "$(realpath "$COMMON_GIT_DIR")")"

ref_exists() {
  git -C "$MAIN_WORKTREE" rev-parse --verify --quiet "$1" >/dev/null 2>&1
}

is_ancestor() {
  # $1 = ancestor candidate, $2 = ref
  if ! ref_exists "$2"; then return 1; fi
  git -C "$MAIN_WORKTREE" merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

if ! ref_exists "$TEST_BRANCH"; then
  echo "Error: branch '$TEST_BRANCH' does not exist." >&2; exit 1
fi
if ! ref_exists 'main'; then
  echo "Error: branch 'main' does not exist." >&2; exit 1
fi

while IFS= read -r LINE; do
  [[ -z "$LINE" ]] && continue
  MERGE_HASH="${LINE%%|*}"
  REST="${LINE#*|}"
  PARENTS_RAW="${REST%%|*}"
  SUBJECT="${REST#*|}"
  # Need parent[1]
  read -r -a PARENTS <<< "$PARENTS_RAW"
  if (( ${#PARENTS[@]} < 2 )); then continue; fi
  TIP="${PARENTS[1]}"

  # Filter 1: SVN bridge merges
  if is_ancestor "$TIP" "$REMOTE_MAIN"; then continue; fi
  if is_ancestor "$TIP" "$REMOTE_TEST_BRANCH"; then continue; fi

  # Filter 2: tip already in main
  if is_ancestor "$TIP" 'main'; then continue; fi

  # Annotate current branch
  POINTS_AT="$(git -C "$MAIN_WORKTREE" branch --points-at "$TIP" --format='%(refname:short)' \
    | grep -v -E '^(main|test-[0-9]+|remote/)' \
    | grep -v '^$' \
    | paste -sd, -)"
  if [[ -n "$POINTS_AT" ]]; then
    BRANCH_STATUS="AT_TIP:$POINTS_AT"
  else
    CONTAINS="$(git -C "$MAIN_WORKTREE" branch --contains "$TIP" --format='%(refname:short)' \
      | grep -v -E '^(main|test-[0-9]+|remote/)' \
      | grep -v '^$' \
      | paste -sd, -)"
    if [[ -n "$CONTAINS" ]]; then
      BRANCH_STATUS="ADVANCED:$CONTAINS"
    else
      BRANCH_STATUS='NONE'
    fi
  fi

  printf '%s|%s|%s|%s\n' "$MERGE_HASH" "$TIP" "$SUBJECT" "$BRANCH_STATUS"
done < <(git -C "$MAIN_WORKTREE" log --merges --first-parent --format='%H|%P|%s' "main..$TEST_BRANCH")
