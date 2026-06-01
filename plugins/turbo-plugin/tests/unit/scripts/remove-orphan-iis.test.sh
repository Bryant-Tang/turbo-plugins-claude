#!/usr/bin/env bash
# remove-orphan-iis.test.sh — bash sibling for remove-orphan-iis.sh
# Note: script has NO [iis] gate at script level (by design — gate is SKILL-level).
#
# U5 / R5 — delegate-smoke only: remove-orphan-iis.sh is a ps1-delegate (forwards to
#   Remove-OrphanIis.ps1 via lib/ps1-delegate.sh; no independent regex logic). The canonical
#   regex-escape "誤殺防護" assertions (Test-OrphanSiteNameMatch with metacharacter stems) live
#   in Remove-OrphanIis.test.ps1. Here we only verify the delegate dispatches and surfaces the
#   No-orphan happy path / exit codes (errors bubble up).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/remove-orphan-iis.sh"
TEST_ROOT="/c/Turbo/test-turbo-plugin"
CFG="$TEST_ROOT/.turbo-plugin/config.toml"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }

set_iis_enabled() {
    sed -i.bak -E "s/^enabled = (true|false)$/enabled = $1/" "$CFG" 2>/dev/null
    rm -f "${CFG}.bak" 2>/dev/null || true
}

if [[ -d "$TEST_ROOT" && ! -d "$TEST_ROOT/.git" ]]; then
    (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
fi
if [[ ! -d "$TEST_ROOT" ]]; then echo "  [FAIL] $TEST_ROOT missing"; exit 1; fi

# Case 1: no orphan
cd "$TEST_ROOT"
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: no-orphan exit 0' '0' "$e1"
assert_match 'case1: No orphan message' 'No orphan IIS Express' "$out1"

# Case 2: SKILL re-invoke
cd "$TEST_ROOT"
out2="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
cd "$PLUGIN_ROOT"
assert_eq 'case2: SKILL re-invoke exit 0' '0' "$e2"

# Case 3: [iis]=false — script has no gate by design
set_iis_enabled false
cd "$TEST_ROOT"
out3="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e3=$?
cd "$PLUGIN_ROOT"
set_iis_enabled true
assert_eq 'case3 (deviation): no script-level gate, still exits 0' '0' "$e3"
assert_match 'case3: 訊息仍是 No orphan' 'No orphan IIS Express' "$out3"

echo ""
echo "cleanup-orphan-iis.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
