#!/usr/bin/env bash
# Phase 1 — check-encoding-support.sh (delegates to .ps1)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/turbo-plugin/scripts/check-encoding-support.sh"

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
