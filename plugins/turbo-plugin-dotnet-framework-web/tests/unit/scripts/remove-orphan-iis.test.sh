#!/usr/bin/env bash
# remove-orphan-iis.test.sh (shUnit2)
# Script under test: scripts/remove-orphan-iis.sh (ps1-delegate -> needs PowerShell + IIS Express).
# Note: script has NO [iis] gate at script level (by design — gate is SKILL-level).
#
# U5 / R5 — delegate-smoke only: remove-orphan-iis.sh forwards to Remove-OrphanIis.ps1 via
#   lib/ps1-delegate.sh (no independent regex logic). The canonical regex-escape "誤殺防護"
#   assertions live in Remove-OrphanIis.test.ps1. Here we only verify the delegate dispatches
#   and surfaces the No-orphan happy path / exit codes.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/remove-orphan-iis.sh"
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

# Case 1: no orphan -> exit 0 + "No orphan IIS Express"
test_no_orphan() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local out e
    cd "$TEST_ROOT"
    out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    cd "$PLUGIN_ROOT"
    assertEquals 'case1: no-orphan exit 0' 0 "$e"
    echo "$out" | grep -Eq 'No orphan IIS Express'; assertTrue 'case1: No orphan message' $?
}

# Case 2: SKILL re-invoke -> exit 0
test_skill_reinvoke() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local e
    cd "$TEST_ROOT"
    bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1; e=$?
    cd "$PLUGIN_ROOT"
    assertEquals 'case2: SKILL re-invoke exit 0' 0 "$e"
}

# Case 3: [iis]=false — script has no gate by design, still exits 0 with No-orphan message.
test_no_script_level_gate() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local out e
    set_iis_enabled false
    cd "$TEST_ROOT"
    out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    cd "$PLUGIN_ROOT"
    set_iis_enabled true
    assertEquals 'case3 (deviation): no script-level gate, still exits 0' 0 "$e"
    echo "$out" | grep -Eq 'No orphan IIS Express'; assertTrue 'case3: 訊息仍是 No orphan' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
