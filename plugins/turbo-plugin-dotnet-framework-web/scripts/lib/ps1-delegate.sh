#!/usr/bin/env bash
# Delegate to a PowerShell .ps1 sibling.
# Args: <script-name-without-ext> <forwarded-args...>
# Example: ps1-delegate.sh build-web --configuration Release
set -euo pipefail

SCRIPT_NAME="$1"; shift
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PS1_PATH="${SCRIPTS_DIR}/${SCRIPT_NAME}.ps1"

# Convert Git Bash /c/foo → C:/foo so PowerShell can resolve the path.
if [[ "$PS1_PATH" =~ ^/([a-zA-Z])/(.*)$ ]]; then
  PS1_PATH="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
fi

exec powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1_PATH" "$@"
