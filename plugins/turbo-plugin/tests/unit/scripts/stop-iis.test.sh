#!/usr/bin/env bash
# stop-iis.test.sh — bash sibling for stop-iis.sh
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/stop-iis.sh"

# Capability gate (U5): stop-iis.sh is a ps1-delegate (needs PowerShell + IIS Express). Skip
# cleanly on a runner without PowerShell before any fixture setup. Last line "OK" + exit 0 =
# orchestrator non-FAIL signal; on Windows the gate passes and the test runs as today.
if ! command -v powershell >/dev/null 2>&1 && ! command -v pwsh >/dev/null 2>&1; then
    echo "OK (SKIPPED: stop-iis.sh delegates to PowerShell/IIS; no powershell/pwsh on this runner)"
    exit 0
fi

TEST_ROOT="$PLUGIN_ROOT/tests/.sandbox/test-turbo-plugin"
CFG="$TEST_ROOT/.turbo-plugin/config.toml"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }

set_iis_enabled() {
    sed -i.bak -E "s/^enabled = (true|false)$/enabled = $1/" "$CFG" 2>/dev/null
    rm -f "${CFG}.bak" 2>/dev/null || true
}

if [[ -d "$TEST_ROOT" && ! -d "$TEST_ROOT/.git" ]]; then
    (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
fi
if [[ ! -d "$TEST_ROOT" ]]; then echo "  [FAIL] $TEST_ROOT missing"; exit 1; fi

# Case 1: no IIS running
cd "$TEST_ROOT"
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: no-IIS exit 0' '0' "$e1"
assert_match 'case1: stdout No IIS Express process found' 'No IIS Express process found' "$out1"

# Case 2: [iis]=false
set_iis_enabled false
cd "$TEST_ROOT"
combined2="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e2=$?
cd "$PLUGIN_ROOT"
set_iis_enabled true
assert_neq0 'case2: [iis]=false exit ≠ 0' "$e2"
assert_match 'case2: stderr IIS 已停用' 'IIS 已停用' "$combined2"

# Case 3: SKILL re-invoke no-IIS
cd "$TEST_ROOT"
out3="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e3=$?
cd "$PLUGIN_ROOT"
assert_eq 'case3: SKILL-entry no-IIS exit 0' '0' "$e3"

echo ""
echo "stop-iis.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
