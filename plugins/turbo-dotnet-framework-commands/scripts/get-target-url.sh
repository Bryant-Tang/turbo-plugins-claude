#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-iis-settings.sh
. "$SCRIPT_DIR/resolve-iis-settings.sh"
resolve_iis_settings "$SCRIPT_DIR" || exit 1

echo "IIS URL: $IIS_URL"
