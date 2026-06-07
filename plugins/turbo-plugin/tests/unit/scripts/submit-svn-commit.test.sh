#!/usr/bin/env bash
# submit-svn-commit.test.sh (shUnit2)
# Script under test: scripts/submit-svn-commit.sh
#
# Bash entry coverage:
#   1. file exists
#   2. missing --branch -> exit non-zero + stderr mentions branch required
#   3. --branch supplied, missing --message -> exit non-zero + stderr mentions message
# Full happy / 中文 / drift cases are in push-to-svn-commit.Tests.ps1 (PS) and Phase 2.
#
# U7/U8 note: any branch is now legal and there is no bridge gate, so an unresolvable
# remote worktree surfaces as "not found" (the old "Unsupported branch" message is gone).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/submit-svn-commit.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

setUp() {
    TMPDIR_CASE="$(mktemp -d -t turbo-ptsc-XXXXXX)"
    (
        cd "$TMPDIR_CASE"
        git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
        git config user.email 'test@turbo' >/dev/null 2>&1
        git config user.name  'turbo' >/dev/null 2>&1
        echo init > init.txt
        git add -A >/dev/null 2>&1
        git commit -m initial --allow-empty >/dev/null 2>&1
    )
}

tearDown() {
    [ -n "${TMPDIR_CASE:-}" ] && rm -rf "$TMPDIR_CASE" 2>/dev/null || true
}

# Case 1: script file exists
test_script_exists() {
    [ -f "$SCRIPT" ]; assertTrue 'submit-svn-commit.sh exists' $?
}

# Case 2: missing --branch -> non-zero + stderr mentions branch
test_missing_branch() {
    local out rc
    out="$(cd "$TMPDIR_CASE" && bash "$SCRIPT" 2>&1)"; rc=$?
    assertNotEquals 'missing --branch exits non-zero' 0 "$rc"
    case "$out" in
        *--branch*|*required*) assertTrue 'missing --branch stderr mentions branch' 0 ;;
        *) fail "missing --branch stderr unexpected: $out" ;;
    esac
}

# Case 3: --branch main but no --message -> non-zero + stderr mentions message
test_missing_message() {
    local out rc
    out="$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --branch main 2>&1)"; rc=$?
    assertNotEquals 'missing --message exits non-zero' 0 "$rc"
    case "$out" in
        *--message*|*required*) assertTrue 'missing --message stderr mentions message' 0 ;;
        *) fail "missing --message stderr unexpected: $out" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
