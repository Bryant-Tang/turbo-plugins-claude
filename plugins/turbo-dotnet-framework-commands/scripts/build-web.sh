#!/usr/bin/env bash
# Usage: build-web.sh [release-build]
# Pass 'release-build' to build with Configuration=Release. Defaults to Debug.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

BUILD_CONFIGURATION="Debug"
if [[ "${1:-}" == "release-build" ]]; then
  BUILD_CONFIGURATION="Release"
elif [[ -n "${1:-}" ]]; then
  echo "Unknown build argument: '${1}'. Supported values: 'release-build'." >&2
  exit 1
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

PROJECT_FILE="$(resolve_repo_path "$REPO_ROOT" "$BUILD_PROJECT_PATH")"
BUILD_MSBUILD_PATH="$(resolve_repo_path "$REPO_ROOT" "$BUILD_MSBUILD_PATH")"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Configured project file does not exist: $PROJECT_FILE" >&2
  exit 1
fi

if [[ ! -f "$BUILD_MSBUILD_PATH" ]]; then
  echo "Configured MSBuild executable does not exist: $BUILD_MSBUILD_PATH" >&2
  exit 1
fi

# MSBuild requires Windows paths for the project file and SolutionDir.
# Use - prefix for all MSBuild switches: Git Bash (MSYS2) converts arguments
# starting with / to Windows paths, breaking /restore, /t:Build, /p:... etc.
PROJECT_FILE_WIN="$(cygpath -w "$PROJECT_FILE")"
SOLUTION_DIR_WIN="$(cygpath -m "$REPO_ROOT")/"

echo "Running MSBuild for $BUILD_PROJECT_PATH (Configuration: $BUILD_CONFIGURATION)"
"$BUILD_MSBUILD_PATH" "$PROJECT_FILE_WIN" \
  -restore -t:Build \
  "-p:SolutionDir=$SOLUTION_DIR_WIN" \
  -p:RestorePackagesConfig=true \
  "-p:Configuration=$BUILD_CONFIGURATION" \
  -p:Platform=AnyCPU

PACK_CONTENT_SCRIPT="$SCRIPT_DIR/pack-content.sh"

if [[ ! -f "$PACK_CONTENT_SCRIPT" ]]; then
  echo "Warning: Content pack script not found. Skipping frontend packaging: $PACK_CONTENT_SCRIPT"
  exit 0
fi

bash "$PACK_CONTENT_SCRIPT"
