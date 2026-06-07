#!/usr/bin/env bash
# build-svn-commit.test.sh (shUnit2) — bash sibling for build-svn-commit.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/build-svn-commit.sh"
TEST_ROOT="$PLUGIN_ROOT/tests/.sandbox/test-turbo-plugin"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    # Ensure fixture has .git
    if [ -d "$TEST_ROOT" ] && [ ! -d "$TEST_ROOT/.git" ]; then
        (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
    fi
}

test_missing_branch() {
    [ -d "$TEST_ROOT" ] || fail "setup: $TEST_ROOT not found"
    local e
    ( cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1 ); e=$?
    assertTrue 'case1: missing --branch exit != 0' "[ $e -ne 0 ]"
}

test_skill_reinvoke() {
    [ -d "$TEST_ROOT" ] || fail "setup: $TEST_ROOT not found"
    local e
    ( cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1 ); e=$?
    assertTrue 'case2: SKILL-entry exit != 0' "[ $e -ne 0 ]"
}

test_unknown_branch() {
    [ -d "$TEST_ROOT" ] || fail "setup: $TEST_ROOT not found"
    local e
    ( cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" --branch test-99 >/dev/null 2>&1 ); e=$?
    assertTrue 'case3: unknown branch exit != 0' "[ $e -ne 0 ]"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
