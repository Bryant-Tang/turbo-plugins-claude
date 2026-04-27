#!/usr/bin/env bash
# Usage: build-web.sh [--configuration <value>] [--platform <value>]
# Env var defaults: BUILD_DEFAULT_CONFIGURATION (default: Debug), BUILD_DEFAULT_PLATFORM (default: AnyCPU)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

BUILD_CONFIGURATION=""
BUILD_PLATFORM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) BUILD_CONFIGURATION="$2"; shift 2 ;;
    --platform)      BUILD_PLATFORM="$2";      shift 2 ;;
    *) echo "Unknown argument: '$1'. Supported: --configuration <value>, --platform <value>." >&2; exit 1 ;;
  esac
done
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-${BUILD_DEFAULT_CONFIGURATION:-Debug}}"
BUILD_PLATFORM="${BUILD_PLATFORM:-${BUILD_DEFAULT_PLATFORM:-AnyCPU}}"

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
  "-p:Platform=$BUILD_PLATFORM"

PACK_CONTENT_SCRIPT="$SCRIPT_DIR/pack-content.sh"

if [[ ! -f "$PACK_CONTENT_SCRIPT" ]]; then
  echo "Warning: Content pack script not found. Skipping frontend packaging: $PACK_CONTENT_SCRIPT"
  exit 0
fi

if ! bash "$PACK_CONTENT_SCRIPT"; then
  echo "Frontend packaging failed." >&2
  exit 1
fi
