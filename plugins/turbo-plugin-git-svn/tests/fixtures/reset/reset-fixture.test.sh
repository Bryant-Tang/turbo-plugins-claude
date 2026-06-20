#!/usr/bin/env bash
# reset-fixture.test.sh (shUnit2)
# Script under test: tests/fixtures/reset/reset-fixture.sh
#
# Bash-side meta-test for reset-fixture.sh (mirror of Reset-Fixture.test.ps1).
# Smoke test that idempotently runs reset-fixture.sh and checks expected output.
#
# Scenarios:
#   1. Happy reset:   fresh sandbox → reset (--skip-svn) → test_root present
#   2. Dirty reset:   pre-populate sandbox with extras/garbage.txt → reset → gone
#   3. Idempotency:   run reset twice → both succeed with same final state
#
# Skips SVN scenarios (covered in Reset-Fixture.test.ps1 — Bash sibling is smoke-only).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
RESET_SH="$SCRIPT_DIR/reset-fixture.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    if [[ ! -f "$RESET_SH" ]]; then
        fail "reset-fixture.sh not found at $RESET_SH"
        return 1
    fi
    BASE_DIR="$(cd "$SCRIPT_DIR/../base" && pwd 2>/dev/null)" || BASE_DIR=""
    if [[ -z "$BASE_DIR" || ! -d "$BASE_DIR" ]]; then
        fail "base fixture dir not found"
        return 1
    fi
}

setUp() {
    local prefix="${TMPDIR:-/tmp}"
    # Sanitize TMPDIR on Windows Git Bash where it can be empty.
    [[ -d "$prefix" ]] || prefix="/tmp"
    SANDBOX="$prefix/turbo-plugin-reset-bash-test-$(date +%s)-$$-$RANDOM"
    mkdir -p "$SANDBOX"
}

tearDown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    SANDBOX=""
}

# ─── Scenario 1: Happy reset (fresh base → --skip-svn → sandbox populated) ────
test_happy_reset() {
    local test_root="$SANDBOX/test-turbo-plugin"
    local svn_repo="$SANDBOX/test-turbo-plugin-svn-repo"

    bash "$RESET_SH" --test-root "$test_root" --svn-repo "$svn_repo" --skip-svn >/dev/null
    assertEquals 'reset exit code 0' 0 $?

    [[ -d "$test_root" ]]
    assertTrue 'test_root directory created' $?
}

# ─── Scenario 2: Dirty reset (extras/garbage.txt → vanishes) ──────────────────
test_dirty_reset_removes_garbage() {
    local test_root="$SANDBOX/test-turbo-plugin"
    local svn_repo="$SANDBOX/test-turbo-plugin-svn-repo"

    mkdir -p "$test_root/extras"
    echo "garbage content" > "$test_root/extras/garbage.txt"
    [[ -f "$test_root/extras/garbage.txt" ]]
    assertTrue 'garbage exists before reset' $?

    bash "$RESET_SH" --test-root "$test_root" --svn-repo "$svn_repo" --skip-svn >/dev/null
    assertEquals 'dirty reset exit code 0' 0 $?

    [[ ! -f "$test_root/extras/garbage.txt" ]]
    assertTrue 'garbage.txt removed after reset' $?
}

# ─── Scenario 3: Idempotency (2 consecutive resets → both succeed) ────────────
test_idempotent_double_reset() {
    local test_root="$SANDBOX/test-turbo-plugin"
    local svn_repo="$SANDBOX/test-turbo-plugin-svn-repo"

    bash "$RESET_SH" --test-root "$test_root" --svn-repo "$svn_repo" --skip-svn >/dev/null
    assertEquals 'first reset exit code 0' 0 $?

    bash "$RESET_SH" --test-root "$test_root" --svn-repo "$svn_repo" --skip-svn >/dev/null
    assertEquals 'second reset exit code 0 (idempotent)' 0 $?

    [[ -d "$test_root" ]]
    assertTrue 'test_root still present after 2 resets' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
