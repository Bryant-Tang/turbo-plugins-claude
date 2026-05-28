#!/usr/bin/env bash
# create-remote-test.sh.test.sh
#
# Bash entry coverage:
#   1. file exists
#   2. missing --svn-url → exit non-zero + stderr mentions svn-url required
#   3. unknown arg → exit non-zero
# Full happy/rollback paths covered in create-remote-test.Tests.ps1.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/create-remote-test.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

# Case 1: file exists
if [[ -f "$SCRIPT" ]]; then
    record_pass "create-remote-test.sh exists"
else
    record_fail "create-remote-test.sh exists" "not found"
fi

# Case 2: in a git repo, missing --svn-url → non-zero exit
TMPDIR_CASE="$(mktemp -d -t turbo-crt-XXXXXX)"
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
    record_pass "missing --svn-url exits non-zero (rc=$rc)"
else
    record_fail "missing --svn-url" "expected non-zero exit, got 0"
fi
if [[ "$out" == *"svn-url"* || "$out" == *"required"* ]]; then
    record_pass "missing --svn-url stderr mentions svn-url"
else
    record_fail "missing --svn-url stderr" "unexpected: $out"
fi

# Case 3: unknown argument
pushd "$TMPDIR_CASE" >/dev/null
out2=$(bash "$SCRIPT" --bogus-flag 2>&1)
rc2=$?
popd >/dev/null
if [[ $rc2 -ne 0 ]]; then
    record_pass "unknown arg exits non-zero (rc=$rc2)"
else
    record_fail "unknown arg" "expected non-zero exit"
fi
if [[ "$out2" == *"Unknown argument"* || "$out2" == *"bogus"* ]]; then
    record_pass "unknown arg stderr mentions Unknown"
else
    record_fail "unknown arg stderr" "unexpected: $out2"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "create-remote-test.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
