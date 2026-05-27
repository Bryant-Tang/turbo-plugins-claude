#!/usr/bin/env bash
# build-seed-repo.sh
#
# Bash equivalent of build-seed-repo.ps1 for turbo-plugin v1.0 Phase 1 SVN seed.
#
# Strategy: on Windows (Git Bash / MSYS) delegate to the PowerShell version since
# it already handles the F-2 / F-3 quirks (cmd /c dump redirect + svnadmin setlog
# for CJK revprops). On true Linux / macOS the same quirks don't apply (no codepage
# transcoding through cmd.exe), so a native bash impl is trivial — but the test plan
# (K-Decision in plan doc) defers native Linux/macOS support to follow-up. We mirror
# that decision here.
#
# Idempotent: re-runs without -Force are a no-op when dump exists.

set -euo pipefail

FORCE=0
for arg in "$@"; do
    case "$arg" in
        -Force|--force|-f)
            FORCE=1
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dump_path="$script_dir/svn-repo-r1-r20.dump"

if [[ -f "$dump_path" ]] && [[ $FORCE -eq 0 ]]; then
    echo "dump already exists at $dump_path — re-run with -Force to rebuild."
    exit 0
fi

# Locate PowerShell (Windows PowerShell 5.1 preferred, then pwsh as fallback)
if command -v powershell.exe >/dev/null 2>&1; then
    ps_exe="powershell.exe"
elif command -v pwsh >/dev/null 2>&1; then
    ps_exe="pwsh"
else
    echo "Neither powershell.exe nor pwsh found on PATH." >&2
    echo "build-seed-repo.sh currently delegates to PowerShell — native Linux/macOS support is deferred (see plan doc)." >&2
    exit 1
fi

# Convert script path to Windows-style if running under Git Bash so PS reads it correctly.
ps_script="$script_dir/build-seed-repo.ps1"
if [[ "$ps_exe" == "powershell.exe" ]] && command -v cygpath >/dev/null 2>&1; then
    ps_script="$(cygpath -w "$ps_script")"
fi

ps_args=("-NoProfile" "-ExecutionPolicy" "Bypass" "-File" "$ps_script")
if [[ $FORCE -eq 1 ]]; then
    ps_args+=("-Force")
fi

echo "Delegating to $ps_exe $ps_script"
"$ps_exe" "${ps_args[@]}"
