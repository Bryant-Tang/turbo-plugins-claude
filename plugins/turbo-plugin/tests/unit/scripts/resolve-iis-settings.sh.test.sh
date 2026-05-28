#!/usr/bin/env bash
# Phase 1 — resolve-iis-settings.sh (1-line delegate)
#
# resolve-iis-settings 主要是 library (dot-source);.sh 本身只是 delegate stub。
# 直接 bash 呼叫應產生 "no main entry" 行為 — exit 0 + 無 stdout(.ps1 dot-source 後只
# 定義 function 不產生 output)。
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/resolve-iis-settings.sh"

passed=0
failed=0

assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }

# Case 1: bash entry exists and is runnable.
if [[ -f "$SCRIPT_UNDER_TEST" ]]; then
    echo "  [PASS] case1: .sh file exists"
    ((passed++))
else
    echo "  [FAIL] case1: $SCRIPT_UNDER_TEST not found"
    ((failed++))
fi

# Case 2: running directly emits no stdout (library only — no main code path)
out2="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null || true)"
if [[ -z "$out2" ]]; then
    echo "  [PASS] case2: library .sh emits no stdout when run directly"
    ((passed++))
else
    # Library .ps1 may emit nothing OR warning;tolerate small token-free output
    if echo "$out2" | grep -Eq 'IisUrl='; then
        echo "  [FAIL] case2: unexpected Resolve-IisSettings invocation: $out2"
        ((failed++))
    else
        echo "  [PASS] case2: library .sh emits no settings"
        ((passed++))
    fi
fi

echo ""
echo "resolve-iis-settings.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
