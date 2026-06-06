#!/usr/bin/env bash
# test-encoding-support.test.sh — bash sibling for check-encoding-support.sh (delegates to .ps1)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/test-encoding-support.sh"

# Capability gate (U5): test-encoding-support.sh is a ps1-delegate (needs PowerShell). Skip
# cleanly on a runner without PowerShell before any fixture setup. Last line "OK" + exit 0 =
# orchestrator non-FAIL signal; on Windows the gate passes and the test runs as today.
if ! command -v powershell >/dev/null 2>&1 && ! command -v pwsh >/dev/null 2>&1; then
    echo "OK (SKIPPED: test-encoding-support.sh delegates to PowerShell; no powershell/pwsh on this runner)"
    exit 0
fi

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }

# Case 1: tokens present
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
assert_eq 'case1: exit 0' '0' "$e1"
assert_match 'case1: PS_VERSION' 'PS_VERSION=' "$out1"
assert_match 'case1: ANSI_CODEPAGE' 'ANSI_CODEPAGE=' "$out1"
assert_match 'case1: ARGV_SAFE_FOR_UNICODE' 'ARGV_SAFE_FOR_UNICODE=(True|False)' "$out1"
assert_match 'case1: RECOMMENDATION' 'RECOMMENDATION=' "$out1"

# Case 2: SKILL re-invoke
out2="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
assert_eq 'case2: SKILL-entry exit 0' '0' "$e2"

echo ""
echo "check-encoding-support.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
