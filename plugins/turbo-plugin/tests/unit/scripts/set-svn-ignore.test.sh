#!/usr/bin/env bash
# svn-ignore.sh.test.sh
#
# Bash entry coverage:
#   1. file exists
#   2. --add and --remove together → error
#   3. unknown argument → error
#   4. running outside a git repo → "Not inside a git repository" (or similar)
# Full happy-path cross-worktree assertions are in svn-ignore.Tests.ps1.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/set-svn-ignore.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

if [[ -f "$SCRIPT" ]]; then
    record_pass "svn-ignore.sh exists"
else
    record_fail "svn-ignore.sh exists" "not found"
fi

TMPDIR_CASE="$(mktemp -d -t turbo-svnig-XXXXXX)"
trap 'rm -rf "$TMPDIR_CASE" 2>/dev/null || true' EXIT
pushd "$TMPDIR_CASE" >/dev/null
git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
git config user.email 'test@turbo' >/dev/null 2>&1
git config user.name  'turbo' >/dev/null 2>&1
echo init > init.txt
git add -A >/dev/null 2>&1
git commit -m initial --allow-empty >/dev/null 2>&1

# Case 2: --add + --remove → error
out=$(bash "$SCRIPT" --add obj/ --remove tmp/ 2>&1)
rc=$?
if [[ $rc -ne 0 ]]; then
    record_pass "both --add and --remove exits non-zero (rc=$rc)"
else
    record_fail "both --add --remove" "expected non-zero"
fi
if [[ "$out" == *"either"* || "$out" == *"not both"* ]]; then
    record_pass "both --add --remove stderr explains"
else
    record_fail "both --add --remove stderr" "unexpected: $out"
fi

# Case 3: unknown arg
out2=$(bash "$SCRIPT" --bogus 2>&1)
rc2=$?
if [[ $rc2 -ne 0 ]]; then
    record_pass "unknown arg exits non-zero (rc=$rc2)"
else
    record_fail "unknown arg" "expected non-zero"
fi

# Case 4: no .worktrees/ dir → fail-loudly
out3=$(bash "$SCRIPT" --add obj/ 2>&1)
rc3=$?
popd >/dev/null

if [[ $rc3 -ne 0 ]]; then
    record_pass "missing worktrees dir exits non-zero (rc=$rc3)"
else
    record_fail "missing worktrees dir" "expected non-zero"
fi
if [[ "$out3" == *"Worktrees directory"* || "$out3" == *"worktree"* ]]; then
    record_pass "missing worktrees dir stderr mentions worktree"
else
    record_fail "missing worktrees dir stderr" "unexpected: $out3"
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "svn-ignore.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
