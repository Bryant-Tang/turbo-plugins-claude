#!/usr/bin/env bash
# Usage: publish-web.sh [--profile <path-to.pubxml>]
# Env var default: PUBLISH_PUBXML_PATH
set -euo pipefail

REPO_ROOT="$(pwd)"

PUBXML_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PUBXML_PATH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'. Supported: --profile <path>." >&2; exit 1 ;;
  esac
done

if [[ -z "$PUBXML_PATH" ]]; then
  PUBXML_PATH="${PUBLISH_PUBXML_PATH:-}"
fi

resolve_repo_path() {
  local repo_root="$1"
  local path_value="$2"
  if [[ "$path_value" =~ ^[A-Za-z]: ]] || [[ "$path_value" = /* ]]; then
    cygpath -u "$path_value"
  else
    echo "$repo_root/${path_value#./}"
  fi
}

if [[ -z "${BUILD_PROJECT_PATH:-}" ]]; then
  echo "Missing BUILD_PROJECT_PATH environment variable" >&2
  exit 1
fi

if [[ -z "${BUILD_MSBUILD_PATH:-}" ]]; then
  echo "Missing BUILD_MSBUILD_PATH environment variable" >&2
  exit 1
fi

if [[ -z "$PUBXML_PATH" ]]; then
  echo "No publish profile specified. Provide --profile <path> or set PUBLISH_PUBXML_PATH environment variable" >&2
  exit 1
fi

PROJECT_FILE="$(resolve_repo_path "$REPO_ROOT" "$BUILD_PROJECT_PATH")"
BUILD_MSBUILD_PATH="$(resolve_repo_path "$REPO_ROOT" "$BUILD_MSBUILD_PATH")"
PUBXML_UNIX="$(resolve_repo_path "$REPO_ROOT" "$PUBXML_PATH")"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Configured project file does not exist: $PROJECT_FILE" >&2
  exit 1
fi

if [[ ! -f "$BUILD_MSBUILD_PATH" ]]; then
  echo "Configured MSBuild executable does not exist: $BUILD_MSBUILD_PATH" >&2
  exit 1
fi

if [[ ! -f "$PUBXML_UNIX" ]]; then
  echo "Publish profile does not exist: $PUBXML_UNIX" >&2
  exit 1
fi

# MSBuild requires Windows paths. Use - prefix to prevent MSYS2 path conversion.
PROJECT_FILE_WIN="$(cygpath -w "$PROJECT_FILE")"
PUBXML_WIN="$(cygpath -w "$PUBXML_UNIX")"

echo "Running MSBuild Publish for $BUILD_PROJECT_PATH"
echo "  Publish profile: $PUBXML_WIN"

"$BUILD_MSBUILD_PATH" "$PROJECT_FILE_WIN" \
  -t:Publish \
  "-p:PublishProfile=$PUBXML_WIN"
