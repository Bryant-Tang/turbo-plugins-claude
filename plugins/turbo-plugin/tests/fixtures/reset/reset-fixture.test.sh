#!/usr/bin/env bash
# reset-fixture.test.sh
#
# Bash-side meta-test for reset-fixture.sh (mirror of Reset-Fixture.test.ps1).
# Smoke test that idempotently runs reset-fixture.sh and checks expected output.
#
# Scenarios:
#   1. Happy reset:   fresh sandbox → reset (--skip-svn) → expected sentinel file present
#   2. Dirty reset:   pre-populate sandbox with extras/garbage.txt → reset → garbage gone
#   3. Idempotency:   run reset twice → both succeed with same final state
#
# Skips SVN scenarios (covered in Reset-Fixture.test.ps1 — Bash sibling is smoke-only).
#
# Exit code 0 = all PASS, 1 = any FAIL. Last line is `OK: ...` or `FAIL: ...`
# (parsed by Invoke-ScriptTests.ps1 .sh case driver).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET_SH="$SCRIPT_DIR/reset-fixture.sh"
BASE_DIR="$(cd "$SCRIPT_DIR/../base" && pwd 2>/dev/null)" || BASE_DIR=""

if [[ ! -f "$RESET_SH" ]]; then
    echo "FAIL: reset-fixture.sh not found at $RESET_SH"
    exit 1
fi
if [[ -z "$BASE_DIR" || ! -d "$BASE_DIR" ]]; then
    echo "FAIL: base fixture dir not found"
    exit 1
fi

passed=0
failed=0
failures=()

assert_true() {
    local name="$1"
    local cond="$2"
    if [[ "$cond" == "1" ]]; then
        passed=$((passed+1))
        echo "  [PASS] $name"
    else
        failed=$((failed+1))
        failures+=("$name")
        echo "  [FAIL] $name"
    fi
}

make_sandbox() {
    local prefix="${TMPDIR:-/tmp}"
    # Sanitize TMPDIR on Windows Git Bash where it can be empty or use /c/...
    [[ -d "$prefix" ]] || prefix="/tmp"
    local stamp="$(date +%s)-$$-$RANDOM"
    local sb="$prefix/turbo-plugin-reset-bash-test-$stamp"
    mkdir -p "$sb"
    echo "$sb"
}

remove_sandbox() {
    local sb="$1"
    [[ -n "$sb" && -d "$sb" ]] && rm -rf "$sb"
}

# ─── Scenario 1: Happy reset ──────────────────────────────────────────────────

echo ""
echo "Scenario 1: Happy reset (fresh base → --skip-svn → sandbox populated)"
sb1="$(make_sandbox)"
test_root_1="$sb1/test-turbo-plugin"
svn_repo_1="$sb1/test-turbo-plugin-svn-repo"

bash "$RESET_SH" --test-root "$test_root_1" --svn-repo "$svn_repo_1" --skip-svn >/dev/null
rc=$?
[[ $rc -eq 0 ]] && c=1 || c=0
assert_true "reset exit code 0" "$c"
[[ -d "$test_root_1" ]] && c=1 || c=0
assert_true "test_root directory created" "$c"

remove_sandbox "$sb1"

# ─── Scenario 2: Dirty reset (garbage vanishes) ──────────────────────────────

echo ""
echo "Scenario 2: Dirty reset (extras/garbage.txt → vanishes)"
sb2="$(make_sandbox)"
test_root_2="$sb2/test-turbo-plugin"
svn_repo_2="$sb2/test-turbo-plugin-svn-repo"

mkdir -p "$test_root_2/extras"
echo "garbage content" > "$test_root_2/extras/garbage.txt"
[[ -f "$test_root_2/extras/garbage.txt" ]] && pre=1 || pre=0
assert_true "garbage exists before reset" "$pre"

bash "$RESET_SH" --test-root "$test_root_2" --svn-repo "$svn_repo_2" --skip-svn >/dev/null
rc=$?
[[ $rc -eq 0 ]] && c=1 || c=0
assert_true "dirty reset exit code 0" "$c"
[[ -f "$test_root_2/extras/garbage.txt" ]] && c=0 || c=1
assert_true "garbage.txt removed after reset" "$c"

remove_sandbox "$sb2"

# ─── Scenario 3: Idempotency ─────────────────────────────────────────────────

echo ""
echo "Scenario 3: Idempotency (2 consecutive resets → both succeed)"
sb3="$(make_sandbox)"
test_root_3="$sb3/test-turbo-plugin"
svn_repo_3="$sb3/test-turbo-plugin-svn-repo"

bash "$RESET_SH" --test-root "$test_root_3" --svn-repo "$svn_repo_3" --skip-svn >/dev/null
rc1=$?
[[ $rc1 -eq 0 ]] && c=1 || c=0
assert_true "first reset exit code 0" "$c"

bash "$RESET_SH" --test-root "$test_root_3" --svn-repo "$svn_repo_3" --skip-svn >/dev/null
rc2=$?
[[ $rc2 -eq 0 ]] && c=1 || c=0
assert_true "second reset exit code 0 (idempotent)" "$c"

[[ -d "$test_root_3" ]] && c=1 || c=0
assert_true "test_root still present after 2 resets" "$c"

remove_sandbox "$sb3"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "reset-fixture.test.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    echo "Failures:"
    for f in "${failures[@]}"; do echo "  - $f"; done
    echo "FAIL: $failed scenario(s) failed"
    exit 1
fi
echo "OK: all $passed scenarios passed"
exit 0
