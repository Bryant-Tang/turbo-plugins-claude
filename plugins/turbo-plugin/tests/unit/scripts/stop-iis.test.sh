#!/usr/bin/env bash
# stop-iis.test.sh (shUnit2)
# Script under test: scripts/stop-iis.sh (ps1-delegate -> needs PowerShell + IIS Express).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/stop-iis.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

TEST_ROOT="$PLUGIN_ROOT/tests/.sandbox/test-turbo-plugin"
CFG="$TEST_ROOT/.turbo-plugin/config.toml"

oneTimeSetUp() {
    # U5: ps1-delegate (needs PowerShell + IIS Express). On a runner without PowerShell, SKIP.
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi

    if [ -d "$TEST_ROOT" ] && [ ! -d "$TEST_ROOT/.git" ]; then
        (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
    fi
}

set_iis_enabled() {
    sed -i.bak -E "s/^enabled = (true|false)$/enabled = $1/" "$CFG" 2>/dev/null
    rm -f "${CFG}.bak" 2>/dev/null || true
}

# Case 1: no IIS running -> exit 0 + "No IIS Express process found"
test_no_iis_running() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local out e
    cd "$TEST_ROOT"
    out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    cd "$PLUGIN_ROOT"
    assertEquals 'case1: no-IIS exit 0' 0 "$e"
    echo "$out" | grep -Eq 'No IIS Express process found'; assertTrue 'case1: stdout No IIS Express process found' $?
}

# Case 2: [iis]=false -> exit != 0 + "IIS 已停用"
test_iis_disabled() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local combined e
    set_iis_enabled false
    cd "$TEST_ROOT"
    combined="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    set_iis_enabled true
    assertNotEquals 'case2: [iis]=false exit != 0' 0 "$e"
    echo "$combined" | grep -Eq 'IIS 已停用'; assertTrue 'case2: stderr IIS 已停用' $?
}

# Case 3: SKILL re-invoke no-IIS -> exit 0
test_skill_reinvoke_no_iis() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local e
    cd "$TEST_ROOT"
    bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1; e=$?
    cd "$PLUGIN_ROOT"
    assertEquals 'case3: SKILL-entry no-IIS exit 0' 0 "$e"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
