#!/usr/bin/env bash
# test-encoding-support.test.sh (shUnit2)
# Script under test: scripts/test-encoding-support.sh (ps1-delegate -> needs PowerShell).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/test-encoding-support.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    # `powershell` specifically, NOT "powershell or pwsh". ps1-delegate.sh runs
    # `exec powershell ...` literally, so pwsh being installed does not make the delegate work --
    # and ubuntu runners DO have pwsh (Pester needs it), which made this gate report "PowerShell is
    # available" and then fail with `powershell: not found`, exit 127.
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1; then HAS_PS=1; fi
}

# ps1-delegate needs PowerShell; on a runner without it, SKIP (Unix x Windows-only-tool).
test_tokens_present() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local out e
    out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case1 exit 0' 0 "$e"
    echo "$out" | grep -Eq 'PS_VERSION=';                    assertTrue 'PS_VERSION token'  $?
    echo "$out" | grep -Eq 'ANSI_CODEPAGE=';                 assertTrue 'ANSI_CODEPAGE token' $?
    echo "$out" | grep -Eq 'ARGV_SAFE_FOR_UNICODE=(True|False)'; assertTrue 'ARGV_SAFE token' $?
    echo "$out" | grep -Eq 'RECOMMENDATION=';                assertTrue 'RECOMMENDATION token' $?
}

test_skill_reinvoke_consistent() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local out e
    out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case2 exit 0' 0 "$e"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
