#!/usr/bin/env bash
# pull-from-svn.sh.test.sh
#
# Bash entry coverage for pull-from-svn.sh:
#   1. file exists
#   2. missing --branch → exit non-zero + stderr mentions branch required
#   3. unknown argument → exit non-zero
# Full happy-path / 中文 / merge-conflict cases covered in pull-from-svn.Tests.ps1.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/pull-from-svn.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

if [[ -f "$SCRIPT" ]]; then
    record_pass "pull-from-svn.sh exists"
else
    record_fail "pull-from-svn.sh exists" "not found"
fi

TMPDIR_CASE="$(mktemp -d -t turbo-pfs-XXXXXX)"
trap 'rm -rf "$TMPDIR_CASE" 2>/dev/null || true' EXIT
pushd "$TMPDIR_CASE" >/dev/null
git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
git config user.email 'test@turbo' >/dev/null 2>&1
git config user.name  'turbo' >/dev/null 2>&1
echo init > init.txt
git add -A >/dev/null 2>&1
git commit -m initial --allow-empty >/dev/null 2>&1

# Case: missing --branch
out=$(bash "$SCRIPT" 2>&1); rc=$?
popd >/dev/null

if [[ $rc -ne 0 ]]; then
    record_pass "missing --branch exits non-zero (rc=$rc)"
else
    record_fail "missing --branch" "expected non-zero exit"
fi
if [[ "$out" == *"--branch"* || "$out" == *"required"* ]]; then
    record_pass "missing --branch stderr mentions branch"
else
    record_fail "missing --branch stderr" "unexpected: $out"
fi

pushd "$TMPDIR_CASE" >/dev/null
out2=$(bash "$SCRIPT" --bogus 2>&1); rc2=$?
popd >/dev/null

if [[ $rc2 -ne 0 ]]; then
    record_pass "unknown arg exits non-zero (rc=$rc2)"
else
    record_fail "unknown arg" "expected non-zero exit"
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "pull-from-svn.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
