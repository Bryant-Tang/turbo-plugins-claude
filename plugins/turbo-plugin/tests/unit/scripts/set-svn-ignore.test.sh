#!/usr/bin/env bash
# set-svn-ignore.test.sh (shUnit2)
# Script under test: scripts/set-svn-ignore.sh
#
# Bash entry coverage:
#   1. file exists
#   2. --add and --remove together -> error
#   3. unknown argument -> error
#   4. no worktrees dir -> "worktrees directory not found" (fail-loudly)
# Full happy-path cross-worktree assertions are in svn-ignore.Tests.ps1.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/set-svn-ignore.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

setUp() {
    TMPDIR_CASE="$(mktemp -d -t turbo-svnig-XXXXXX)"
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
    [ -f "$SCRIPT" ]; assertTrue 'set-svn-ignore.sh exists' $?
}

# Case 2: --add + --remove together -> non-zero + stderr explains
test_add_and_remove_conflict() {
    local out rc
    out="$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --add obj/ --remove tmp/ 2>&1)"; rc=$?
    assertNotEquals 'both --add and --remove exits non-zero' 0 "$rc"
    case "$out" in
        *either*|*"not both"*) assertTrue 'both --add --remove stderr explains' 0 ;;
        *) fail "both --add --remove stderr unexpected: $out" ;;
    esac
}

# Case 3: unknown arg -> non-zero
test_unknown_arg() {
    local rc
    (cd "$TMPDIR_CASE" && bash "$SCRIPT" --bogus) >/dev/null 2>&1; rc=$?
    assertNotEquals 'unknown arg exits non-zero' 0 "$rc"
}

# Case 4: no .turbo-plugin/worktrees/ dir -> fail-loudly mentioning worktree
test_missing_worktrees_dir() {
    local out rc
    out="$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --add obj/ 2>&1)"; rc=$?
    assertNotEquals 'missing worktrees dir exits non-zero' 0 "$rc"
    case "$out" in
        *"worktrees directory"*|*worktree*) assertTrue 'missing worktrees dir stderr mentions worktree' 0 ;;
        *) fail "missing worktrees dir stderr unexpected: $out" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
