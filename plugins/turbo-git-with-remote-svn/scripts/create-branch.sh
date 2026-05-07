#!/usr/bin/env bash
set -euo pipefail

NAME=""
BASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            NAME="${2-}"
            shift 2
            ;;
        --base)
            BASE="${2-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "Missing required argument: --name <full-branch-name>" >&2
    exit 1
fi
if [[ -z "$BASE" ]]; then
    echo "Missing required argument: --base <base-branch>" >&2
    exit 1
fi

if [[ ! "$NAME" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "Invalid branch name '$NAME'. Use only letters, digits, dot, underscore, slash, hyphen." >&2
    exit 1
fi

COMMON_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "Not inside a git repository." >&2
    exit 1
}
MAIN_WORKTREE=$(cd "$(dirname "$COMMON_GIT_DIR")" && pwd)

if git -C "$MAIN_WORKTREE" rev-parse --verify -q "refs/heads/$NAME" >/dev/null 2>&1; then
    echo "Branch '$NAME' already exists." >&2
    exit 1
fi

if ! git -C "$MAIN_WORKTREE" rev-parse --verify -q "refs/heads/$BASE" >/dev/null 2>&1; then
    echo "Base branch '$BASE' does not exist." >&2
    exit 1
fi

STATUS=$(git -C "$MAIN_WORKTREE" status --porcelain)
if [[ -n "$STATUS" ]]; then
    echo "Main worktree has uncommitted changes. Commit or stash before creating a new branch." >&2
    echo "$STATUS" >&2
    exit 1
fi

git -C "$MAIN_WORKTREE" checkout -b "$NAME" "$BASE"

echo "Created branch '$NAME' from '$BASE' in main worktree."
