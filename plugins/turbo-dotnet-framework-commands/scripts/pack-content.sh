#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

resolve_repo_path() {
  local repo_root="$1"
  local path_value="$2"
  if [[ "$path_value" =~ ^[A-Za-z]: ]] || [[ "$path_value" = /* ]]; then
    cygpath -u "$path_value"
  else
    echo "$repo_root/${path_value#./}"
  fi
}

if [[ -z "${BUILD_FRONTEND_DIR_PATH:-}" ]]; then
  echo "BUILD_FRONTEND_DIR_PATH is not configured. Skipping frontend packaging."
  exit 0
fi

FRONTEND_DIR="$(resolve_repo_path "$REPO_ROOT" "$BUILD_FRONTEND_DIR_PATH")"

if [[ ! -d "$FRONTEND_DIR" ]]; then
  echo "Configured frontend directory does not exist: $FRONTEND_DIR" >&2
  exit 1
fi

if [[ ! -f "$FRONTEND_DIR/package.json" ]]; then
  echo "Missing package.json in frontend directory: $FRONTEND_DIR" >&2
  exit 1
fi

INSTALL_CMD="${BUILD_FRONTEND_INSTALL_COMMAND:-}"
BUILD_CMD="${BUILD_FRONTEND_BUILD_COMMAND:-}"
FRONTEND_DIR_NAME="$(basename "$FRONTEND_DIR")"

if [[ -n "${BUILD_NODE_VERSION:-}" ]]; then
  CURRENT_NODE="$(node -v 2>/dev/null || true)"
  echo "Active Node version: $CURRENT_NODE"
  if [[ "$CURRENT_NODE" != *"$BUILD_NODE_VERSION"* ]]; then
    echo "Unexpected Node version. Required: $BUILD_NODE_VERSION" >&2
    exit 1
  fi
fi

if [[ -n "$INSTALL_CMD" ]]; then
  echo "Running frontend install command in $FRONTEND_DIR_NAME: $INSTALL_CMD"
  # eval is intentional: BUILD_FRONTEND_INSTALL_COMMAND may be a compound command
  # (e.g. "npm ci --prefer-offline") set by the project owner in settings.local.json.
  # Treat that value as trusted configuration.
  (cd "$FRONTEND_DIR" && eval "$INSTALL_CMD")
else
  echo "BUILD_FRONTEND_INSTALL_COMMAND is not set. Skipping install."
fi

if [[ -n "$BUILD_CMD" ]]; then
  echo "Running frontend build command in $FRONTEND_DIR_NAME: $BUILD_CMD"
  # eval is intentional: BUILD_FRONTEND_BUILD_COMMAND may be a compound command
  # set by the project owner in settings.local.json.
  (cd "$FRONTEND_DIR" && eval "$BUILD_CMD")
else
  echo "BUILD_FRONTEND_BUILD_COMMAND is not set. Skipping build."
fi
