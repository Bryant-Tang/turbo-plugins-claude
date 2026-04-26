#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-iis-settings.sh
. "$SCRIPT_DIR/resolve-iis-settings.sh"
resolve_iis_settings "$SCRIPT_DIR" || exit 1

if [[ "$IIS_SCHEME" == "https" && -z "$APPLICATIONHOST_CONFIG_FILE" ]]; then
  echo "Configured IISUrl uses HTTPS: $IIS_URL" >&2
  echo "Missing RUN_IIS_APPLICATIONHOST_CONFIG_PATH in .claude/settings.local.json." >&2
  echo "Provide an applicationhost.config path so IIS Express can start with /config and /site." >&2
  exit 1
fi

if [[ -z "$IIS_EXPRESS_PATH" ]]; then
  echo "Missing RUN_IIS_EXPRESS_PATH in .claude/settings.local.json" >&2
  exit 1
fi

if [[ ! -f "$IIS_EXPRESS_PATH" ]]; then
  echo "Configured IIS Express executable does not exist: $IIS_EXPRESS_PATH" >&2
  exit 1
fi

if [[ -n "$APPLICATIONHOST_CONFIG_FILE" ]]; then
  # iisexpress.exe /config and /site arguments require Windows paths
  CONFIG_WIN="$(cygpath -w "$APPLICATIONHOST_CONFIG_FILE")"
  nohup "$IIS_EXPRESS_PATH" "/config:$CONFIG_WIN" "/site:$IIS_CONFIG_SITE_NAME" \
    >/dev/null 2>&1 &
  IIS_PID=$!
  echo "Started IIS Express with applicationhost.config site: $IIS_CONFIG_SITE_NAME (PID: $IIS_PID)"
else
  SITE_ROOT_WIN="$(cygpath -w "$SITE_ROOT")"
  nohup "$IIS_EXPRESS_PATH" "/path:$SITE_ROOT_WIN" "/port:$IIS_PORT" \
    >/dev/null 2>&1 &
  IIS_PID=$!
  echo "Started IIS Express background process (PID: $IIS_PID)"
fi
