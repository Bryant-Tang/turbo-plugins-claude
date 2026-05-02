#!/usr/bin/env bash
# Usage: publish-web.sh [--profile <path-to.pubxml>] [--configuration <value>] [--platform <value>]
# Env var defaults: PUBLISH_PUBXML_PATH, PUBLISH_DEFAULT_CONFIGURATION (default: Release), PUBLISH_DEFAULT_PLATFORM (default: AnyCPU)
set -euo pipefail

REPO_ROOT="$(pwd)"

PUBXML_PATH=""
PUBLISH_CONFIGURATION=""
PUBLISH_PLATFORM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       [[ $# -ge 2 ]] || { echo "Error: --profile requires a value" >&2; exit 1; };       PUBXML_PATH="$2";           shift 2 ;;
    --configuration) [[ $# -ge 2 ]] || { echo "Error: --configuration requires a value" >&2; exit 1; }; PUBLISH_CONFIGURATION="$2"; shift 2 ;;
    --platform)      [[ $# -ge 2 ]] || { echo "Error: --platform requires a value" >&2; exit 1; };      PUBLISH_PLATFORM="$2";      shift 2 ;;
    *) echo "Unknown argument: '$1'. Supported: --profile <path>, --configuration <value>, --platform <value>." >&2; exit 1 ;;
  esac
done

if [[ -z "$PUBXML_PATH" ]]; then
  PUBXML_PATH="${PUBLISH_PUBXML_PATH:-}"
fi
PUBLISH_CONFIGURATION="${PUBLISH_CONFIGURATION:-${PUBLISH_DEFAULT_CONFIGURATION:-Release}}"
PUBLISH_PLATFORM="${PUBLISH_PLATFORM:-${PUBLISH_DEFAULT_PLATFORM:-AnyCPU}}"

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

# MSBuild requires Windows paths.
PROJECT_FILE_WIN="$(cygpath -w "$PROJECT_FILE")"
PUBLISH_PROFILE_NAME="$(basename "$PUBXML_UNIX" .pubxml)"
PUBLISH_PROFILE_DIR_WIN="$(cygpath -w "$(dirname "$PUBXML_UNIX")")"

echo "Running MSBuild Publish for $BUILD_PROJECT_PATH (Configuration: $PUBLISH_CONFIGURATION, Platform: $PUBLISH_PLATFORM)"
echo "  Publish profile: $PUBLISH_PROFILE_NAME"
echo "  Profile root:    $PUBLISH_PROFILE_DIR_WIN"

"$BUILD_MSBUILD_PATH" "$PROJECT_FILE_WIN" \
  "-p:DeployOnBuild=true" \
  "-p:PublishProfile=$PUBLISH_PROFILE_NAME" \
  "-p:PublishProfileRootFolder=$PUBLISH_PROFILE_DIR_WIN" \
  "-p:Configuration=$PUBLISH_CONFIGURATION" \
  "-p:Platform=$PUBLISH_PLATFORM"

echo "Publish succeeded."

export TNF_PUBXML_PATH="$(cygpath -w "$PUBXML_UNIX")"
export TNF_PROJECT_FILE="$PROJECT_FILE_WIN"

powershell -NoProfile -ExecutionPolicy Bypass -Command '
$pubxmlPath  = $env:TNF_PUBXML_PATH
$projectFile = $env:TNF_PROJECT_FILE
try {
    $pubxml = [xml](Get-Content -LiteralPath $pubxmlPath -Raw)
} catch {
    [Console]::Error.WriteLine("Warning: failed to parse publish profile XML; output path unknown. ($($_.Exception.Message))")
    exit 0
}
$publishUrlNodes = $pubxml.SelectNodes("//*[local-name()=`"PublishUrl`"]")
$methodNodes     = $pubxml.SelectNodes("//*[local-name()=`"WebPublishMethod`"]")
$method = if ($null -ne $methodNodes -and $methodNodes.Count -gt 0) { $methodNodes[$methodNodes.Count - 1].InnerText.Trim() } else { "" }
if ([string]::IsNullOrWhiteSpace($method)) { $method = "FileSystem" }
Write-Output "Method: $method"
if ($null -eq $publishUrlNodes -or $publishUrlNodes.Count -eq 0) {
    [Console]::Error.WriteLine("Warning: <PublishUrl> not found in profile; output path unknown.")
    exit 0
}
$publishUrlRaw = $publishUrlNodes[$publishUrlNodes.Count - 1].InnerText.Trim()
if ([string]::IsNullOrWhiteSpace($publishUrlRaw)) {
    [Console]::Error.WriteLine("Warning: <PublishUrl> is empty; output path unknown.")
    exit 0
}
if ($publishUrlRaw.Contains("`$(")) {
    [Console]::Error.WriteLine("Warning: <PublishUrl> contains MSBuild properties; cannot resolve statically.")
    Write-Output "Published to: $publishUrlRaw"
    exit 0
}
if ($method -eq "FileSystem") {
    if ([System.IO.Path]::IsPathRooted($publishUrlRaw)) {
        $resolved = [System.IO.Path]::GetFullPath($publishUrlRaw)
    } else {
        $projectDir = [System.IO.Path]::GetDirectoryName($projectFile)
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $projectDir $publishUrlRaw))
    }
    $resolved = $resolved.TrimEnd("\")
    $displayPath = "file:///" + ($resolved -replace "\\", "/")
} else {
    $resolved = $publishUrlRaw
    $displayPath = $resolved
}
Write-Output "Published to: $displayPath"
Write-Output "PUBLISH_OUTPUT_PATH=$resolved"
'
