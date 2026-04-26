#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-iis-settings.sh
. "$SCRIPT_DIR/resolve-iis-settings.sh"
resolve_iis_settings "$SCRIPT_DIR" || exit 1

MATCHES="$(netstat -ano | grep ":${IIS_PORT}" || true)"

if [[ -z "$MATCHES" ]]; then
  echo "No listening socket found for IISUrl port: $IIS_PORT"
  exit 1
fi

LISTENING="$(echo "$MATCHES" | grep 'LISTENING' || true)"

if [[ -z "$LISTENING" ]]; then
  echo "Port is present but not LISTENING for IISUrl port: $IIS_PORT"
  echo "$MATCHES"
  exit 1
fi

echo "$LISTENING"
