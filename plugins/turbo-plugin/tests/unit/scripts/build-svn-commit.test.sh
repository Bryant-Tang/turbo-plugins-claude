#!/usr/bin/env bash
# build-svn-commit.test.sh — bash sibling for push-to-svn-prepare.sh
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/build-svn-commit.sh"
TEST_ROOT="/c/Turbo/test-turbo-plugin"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }

# Ensure fixture has .git
if [[ -d "$TEST_ROOT" && ! -d "$TEST_ROOT/.git" ]]; then
    (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
fi

if [[ ! -d "$TEST_ROOT" ]]; then
    echo "  [FAIL] setup: $TEST_ROOT not found"
    exit 1
fi

# Case 1: missing --branch
cd "$TEST_ROOT"
combined1="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e1=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case1: missing --branch exit ≠ 0' "$e1"

# Case 2: SKILL re-invoke
cd "$TEST_ROOT"
combined2="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e2=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case2: SKILL-entry exit ≠ 0' "$e2"

# Case 3: unknown branch
cd "$TEST_ROOT"
combined3="$(bash "$SCRIPT_UNDER_TEST" --branch test-99 2>&1)"; e3=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case3: unknown branch exit ≠ 0' "$e3"

echo ""
echo "push-to-svn-prepare.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
