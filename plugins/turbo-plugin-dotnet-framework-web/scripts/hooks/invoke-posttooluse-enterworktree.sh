#!/usr/bin/env bash
# Thin wrapper: on Windows / Git Bash, hand stdin off to the PowerShell native impl.
# On other platforms there's no IIS Express to manage; silently no-op.
set -uo pipefail

uname_s="$(uname -s 2>/dev/null || echo unknown)"
case "$uname_s" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
    PS1_PATH="${PLUGIN_ROOT}/scripts/hooks/Invoke-PostToolUseEnterWorktree.ps1"
    if [[ "$PS1_PATH" =~ ^/([a-zA-Z])/(.*)$ ]]; then
      PS1_PATH="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
    fi
    # Explicitly pipe stdin so PowerShell receives the hook JSON payload on Windows/Git Bash.
    # Without `cat |`, stdin can be detached and powershell may not read the hook event correctly.
    cat | powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PS1_PATH"
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      echo "turbo-plugin invoke-posttooluse-enterworktree: powershell exited $exit_code" >&2
    fi
    # Hooks must never block the session.
    exit 0
    ;;
  *)
    # No IIS Express on non-Windows; nothing to do.
    printf '{}'
    exit 0
    ;;
esac
