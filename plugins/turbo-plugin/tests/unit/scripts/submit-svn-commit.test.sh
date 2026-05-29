#!/usr/bin/env bash
# push-to-svn-commit.sh.test.sh
#
# Bash entry coverage:
#   1. file exists
#   2. missing --branch → exit non-zero + stderr mentions branch required
#   3. --branch supplied, missing --message → exit non-zero + stderr mentions message
# Full happy / 中文 / drift cases are in push-to-svn-commit.Tests.ps1 (PS) and Phase 2.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/submit-svn-commit.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

if [[ -f "$SCRIPT" ]]; then
    record_pass "push-to-svn-commit.sh exists"
else
    record_fail "push-to-svn-commit.sh exists" "not found"
fi

TMPDIR_CASE="$(mktemp -d -t turbo-ptsc-XXXXXX)"
trap 'rm -rf "$TMPDIR_CASE" 2>/dev/null || true' EXIT
pushd "$TMPDIR_CASE" >/dev/null
git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
git config user.email 'test@turbo' >/dev/null 2>&1
git config user.name  'turbo' >/dev/null 2>&1
echo init > init.txt
git add -A >/dev/null 2>&1
git commit -m initial --allow-empty >/dev/null 2>&1

# Case 2: missing --branch
out=$(bash "$SCRIPT" 2>&1)
rc=$?
if [[ $rc -ne 0 ]]; then
    record_pass "missing --branch exits non-zero (rc=$rc)"
else
    record_fail "missing --branch" "expected non-zero"
fi
if [[ "$out" == *"--branch"* || "$out" == *"required"* ]]; then
    record_pass "missing --branch stderr mentions branch"
else
    record_fail "missing --branch stderr" "unexpected: $out"
fi

# Case 3: --branch main but no --message
out2=$(bash "$SCRIPT" --branch main 2>&1)
rc2=$?
popd >/dev/null

if [[ $rc2 -ne 0 ]]; then
    record_pass "missing --message exits non-zero (rc=$rc2)"
else
    record_fail "missing --message" "expected non-zero"
fi
if [[ "$out2" == *"--message"* || "$out2" == *"required"* ]]; then
    record_pass "missing --message stderr mentions message"
else
    record_fail "missing --message stderr" "unexpected: $out2"
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "push-to-svn-commit.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
