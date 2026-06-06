#!/usr/bin/env bash
# tag-release.sh — create a lightweight git tag pointing at the remote-svn branch tip.
#
# Usage: tag-release.sh --branch <main|test-<n>>
#
# Branch → ref mapping (NEW remote-svn naming — NOT the old remote/* scheme):
#   --branch main      → remote-svn/main
#   --branch test-<n>  → remote-svn/test-<n>
# (resolved via the canonical resolve_remote_worktree in lib/common.sh).
#
# Tag naming: <branch>-release-<yyyy-MM-dd>-<NNN> with auto-incrementing 3-digit serial.
# The date is computed from the system clock at runtime — intentional for the runtime tool.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

BRANCH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi

probe_git_version

MAIN_WORKTREE="$(get_main_worktree)"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

RESOLVED="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_BRANCH="$(printf '%s' "$RESOLVED" | cut -d'|' -f2)"

# Confirm the remote-svn ref exists before tagging — fail loudly otherwise.
if ! git -C "$MAIN_WORKTREE" rev-parse --verify "${REMOTE_BRANCH}^{commit}" >/dev/null 2>&1; then
  echo "Error: remote-svn branch '$REMOTE_BRANCH' not found. Run /tp-setup or /tp-create-remote-test first." >&2
  exit 1
fi

PREFIX="${BRANCH}-release-$(date +%Y-%m-%d)"
EXISTING="$(git -C "$MAIN_WORKTREE" tag -l "${PREFIX}-[0-9][0-9][0-9]" | sort | tail -1)"

if [[ -z "$EXISTING" ]]; then
  SERIAL="001"
else
  LAST_NUM="${EXISTING##*-}"
  SERIAL="$(printf '%03d' $(( 10#$LAST_NUM + 1 )))"
fi

TAG_NAME="${PREFIX}-${SERIAL}"
git -C "$MAIN_WORKTREE" tag "$TAG_NAME" "$REMOTE_BRANCH"
echo "Created tag: $TAG_NAME"
