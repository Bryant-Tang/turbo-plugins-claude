#!/usr/bin/env bash
# Phase 1 — svn-log.sh (Bash sibling — own argparse, not delegate)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/svn-log.sh"
TEST_ROOT="/c/Turbo/test-turbo-plugin"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }

# Ensure fixture .git
if [[ -d "$TEST_ROOT" && ! -d "$TEST_ROOT/.git" ]]; then
    (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
fi
if [[ ! -d "$TEST_ROOT" ]]; then
    echo "  [FAIL] setup: $TEST_ROOT not found"
    exit 1
fi

# Case 1: happy — adjusted for actual seed (top = r19, LAST_SHOWN_REV=15 at default --limit 5)
cd "$TEST_ROOT"
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: exit 0' '0' "$e1"
assert_match 'case1: contains r19' '^r19 \|' "$out1"
assert_match 'case1: trailer LAST_SHOWN_REV=15' '# LAST_SHOWN_REV=15' "$out1"

# Case 2: 中文 commit on r5
cd "$TEST_ROOT"
out2="$(bash "$SCRIPT_UNDER_TEST" --revision 5 2>/dev/null)"; e2=$?
cd "$PLUGIN_ROOT"
assert_eq 'case2: exit 0' '0' "$e2"
assert_match 'case2: r5 row present' '^r5 \|' "$out2"
# Bash + Git Bash subshell often goes through CP_ACP for native exe → console codepage may
# round-trip Chinese OK. Text comparison rather than byte-equal (F-3).
if echo "$out2" | grep -q '修正中文 commit 訊息亂碼'; then
    echo "  [PASS] case2: 中文 commit msg present in svn log output"
    ((passed++))
else
    # On Big5 Windows + Git Bash, decode may garble; record as FAIL for visibility but note
    # this is a known environment-specific path (depends on Console::OutputEncoding).
    echo "  [FAIL] case2: 中文 commit msg not found (likely codepage round-trip issue) head=${out2:0:200}"
    ((failed++))
fi

# Case 3: --revision 5 with default --limit 5 walks back r5..r1 (svn behavior).
# Just confirm the trailer is emitted.
assert_match 'case3: trailer emitted with revision spec' '# LAST_SHOWN_REV=[0-9]+' "$out2"

# Case 4: --limit 0 invalid
cd "$TEST_ROOT"
combined4="$(bash "$SCRIPT_UNDER_TEST" --limit 0 2>&1)"; e4=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case4: --limit 0 exit ≠ 0' "$e4"
assert_match 'case4: positive integer message' 'positive integer' "$combined4"

# Case 5: SKILL re-invoke
cd "$TEST_ROOT"
out5="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e5=$?
cd "$PLUGIN_ROOT"
assert_eq 'case5: SKILL-entry exit 0' '0' "$e5"
assert_match 'case5: trailer still present' '# LAST_SHOWN_REV=15' "$out5"

echo ""
echo "svn-log.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
