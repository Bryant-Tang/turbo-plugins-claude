#!/usr/bin/env bash
# reset-remote-test.sh.test.sh
#
# Lightweight bash entry coverage for reset-remote-test.sh.
# We verify:
#   1. arg validation:  --n required → stderr + exit 1
#   2. arg validation:  --n non-integer → stderr + exit 1
#   3. file present
#
# Full happy-path coverage is in reset-remote-test.Tests.ps1.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/reset-remote-test.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

# Case 1: file exists
if [[ -f "$SCRIPT" ]]; then
    record_pass "reset-remote-test.sh exists"
else
    record_fail "reset-remote-test.sh exists" "not found"
fi

# Case 2: missing --n → exit 1 + stderr msg
TMPDIR_CASE="$(mktemp -d -t turbo-resetrt-XXXXXX)"
trap 'rm -rf "$TMPDIR_CASE" 2>/dev/null || true' EXIT
pushd "$TMPDIR_CASE" >/dev/null
git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
git config user.email 'test@turbo' >/dev/null 2>&1
git config user.name  'turbo' >/dev/null 2>&1
echo init > init.txt
git add -A >/dev/null 2>&1
git commit -m initial --allow-empty >/dev/null 2>&1
out=$(bash "$SCRIPT" 2>&1)
rc=$?
popd >/dev/null

if [[ $rc -ne 0 ]]; then
    record_pass "missing --n exits non-zero (rc=$rc)"
else
    record_fail "missing --n" "expected non-zero exit, got 0"
fi
if [[ "$out" == *"--n"* || "$out" == *"required"* ]]; then
    record_pass "missing --n stderr mentions --n"
else
    record_fail "missing --n stderr" "unexpected: $out"
fi

# Case 3: non-integer --n
pushd "$TMPDIR_CASE" >/dev/null
out2=$(bash "$SCRIPT" --n abc 2>&1)
rc2=$?
popd >/dev/null

if [[ $rc2 -ne 0 ]]; then
    record_pass "non-int --n exits non-zero (rc=$rc2)"
else
    record_fail "non-int --n" "expected non-zero exit, got 0"
fi
if [[ "$out2" == *"positive integer"* || "$out2" == *"integer"* ]]; then
    record_pass "non-int --n stderr mentions integer"
else
    record_fail "non-int --n stderr" "unexpected: $out2"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "reset-remote-test.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
