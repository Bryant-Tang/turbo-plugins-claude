#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-iis-settings.sh
. "$SCRIPT_DIR/resolve-iis-settings.sh"
resolve_iis_settings "$SCRIPT_DIR" || exit 1

IIS_EXE_NAME="iisexpress.exe"

if [[ -n "$APPLICATIONHOST_CONFIG_FILE" ]]; then
  CONFIG_WIN="$(cygpath -w "$APPLICATIONHOST_CONFIG_FILE")"
  # Escape backslashes for wmic WHERE clause
  CONFIG_WIN_ESC="${CONFIG_WIN//\\/\\\\}"
  PIDS="$(wmic process where \
    "Name='$IIS_EXE_NAME' and CommandLine like '%${CONFIG_WIN_ESC}%' and CommandLine like '%${IIS_CONFIG_SITE_NAME}%'" \
    get ProcessId //FORMAT:LIST 2>/dev/null \
    | grep -oP '(?<=ProcessId=)\d+' || true)"
else
  SITE_ROOT_WIN="$(cygpath -w "$SITE_ROOT")"
  SITE_ROOT_WIN_ESC="${SITE_ROOT_WIN//\\/\\\\}"
  PIDS="$(wmic process where \
    "Name='$IIS_EXE_NAME' and CommandLine like '%${SITE_ROOT_WIN_ESC}%' and CommandLine like '%/port:${IIS_PORT}%'" \
    get ProcessId //FORMAT:LIST 2>/dev/null \
    | grep -oP '(?<=ProcessId=)\d+' || true)"
fi

if [[ -z "$PIDS" ]]; then
  echo "No repo-specific $IIS_EXE_NAME process found."
  exit 0
fi

while IFS= read -r PID; do
  [[ -z "$PID" ]] && continue
  if ! taskkill //PID "$PID" //F 2>/dev/null; then
    echo "Warning: Failed to kill PID $PID" >&2
  fi
done <<< "$PIDS"
