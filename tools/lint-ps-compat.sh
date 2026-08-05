#!/usr/bin/env bash
# Bash wrapper that re-enters PowerShell to run lint-ps-compat.ps1.
# (The actual lint logic is .ps1-only — checking PS-specific syntax requires PS.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec powershell -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/lint-ps-compat.ps1" "$@"
