#!/usr/bin/env bash
# Usage: create-project.sh --svn-url <url> [--path <dir>] [--name <name>]
set -euo pipefail

SVN_URL=''
PROJ_PATH=''
PROJ_NAME=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svn-url)  [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    --path)     [[ $# -ge 2 ]] || { echo "Error: --path requires a value" >&2; exit 1; }; PROJ_PATH="$2"; shift 2 ;;
    --name)     [[ $# -ge 2 ]] || { echo "Error: --name requires a value" >&2; exit 1; }; PROJ_NAME="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$SVN_URL" ]]; then
  echo "Error: --svn-url is required" >&2
  exit 1
fi

PROJ_PATH="${PROJ_PATH:-$(pwd)}"
PROJ_PATH="$(cd "$PROJ_PATH" && pwd)"

if [[ -z "$PROJ_NAME" ]]; then
  PROJ_NAME="$(basename "$PROJ_PATH")"
fi

if [[ -z "$PROJ_NAME" ]]; then
  echo "Error: could not determine project name. Use --name explicitly." >&2
  exit 1
fi

PROJ_DIR="$PROJ_PATH/$PROJ_NAME"
WORKTREES_DIR="$PROJ_PATH/$PROJ_NAME.worktrees"
REMOTE_MAIN_DIR="$WORKTREES_DIR/remote-main"
WORKSPACE_FILE="$PROJ_PATH/$PROJ_NAME.code-workspace"

if [[ -d "$PROJ_DIR" ]] && [[ -n "$(ls -A "$PROJ_DIR" 2>/dev/null)" ]]; then
  echo "Error: directory already exists and is not empty: $PROJ_DIR" >&2
  exit 1
fi

echo "Creating project '$PROJ_NAME' at '$PROJ_PATH'..."

mkdir -p "$PROJ_DIR"
mkdir -p "$WORKTREES_DIR"

git -C "$PROJ_DIR" -c init.defaultBranch=main init

# Copy git user identity from current context into the new repo
GIT_USER_NAME="$(git config user.name 2>/dev/null || true)"
GIT_USER_EMAIL="$(git config user.email 2>/dev/null || true)"
[[ -n "$GIT_USER_NAME" ]]  && git -C "$PROJ_DIR" config user.name  "$GIT_USER_NAME"
[[ -n "$GIT_USER_EMAIL" ]] && git -C "$PROJ_DIR" config user.email "$GIT_USER_EMAIL"

printf '.svn/**/*\n' > "$PROJ_DIR/.gitignore"
git -C "$PROJ_DIR" add .gitignore
git -C "$PROJ_DIR" commit -m 'init'
git -C "$PROJ_DIR" branch 'remote/main'
git -C "$PROJ_DIR" worktree add "$REMOTE_MAIN_DIR" 'remote/main'

# .gitignore is already inherited from main's init commit; no separate commit needed

echo "Running: svn checkout $SVN_URL $REMOTE_MAIN_DIR"
svn checkout "$SVN_URL" "$REMOTE_MAIN_DIR"

# Tell SVN to ignore git metadata files so they are never accidentally committed
(cd "$REMOTE_MAIN_DIR" && printf '.git\n.gitignore\n' | svn propset svn:ignore --file - . && svn commit -m 'svn:ignore git metadata')

printf '{\n\t"folders": [\n\t\t{"name": "main", "path": "%s"},\n\t\t{"name": "remote-main", "path": "%s.worktrees/remote-main"}\n\t],\n\t"settings": {}\n}\n' "$PROJ_NAME" "$PROJ_NAME" > "$WORKSPACE_FILE"

echo ""
echo "Project '$PROJ_NAME' created successfully."
echo "  Main worktree : $PROJ_DIR"
echo "  SVN worktree  : $REMOTE_MAIN_DIR"
echo "  Workspace     : $WORKSPACE_FILE"
echo ""
echo "Next step: run '/tgs:pull-from-svn --branch main' to commit the SVN files into"
echo "  remote/main and merge them into main."
echo ""
echo "Recommended: open Claude Code in '$PROJ_DIR' and run /tgs:setup to configure"
echo "  tgs environment variable defaults for that working directory."
