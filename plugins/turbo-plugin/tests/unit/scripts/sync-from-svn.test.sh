#!/usr/bin/env bash
# sync-from-svn.test.sh (shUnit2)
#
# Bash entry coverage for sync-from-svn.sh:
#   1. file exists
#   2. missing --branch → exit non-zero + stderr mentions branch required
#   3. unknown argument → exit non-zero
# Full happy-path / 中文 / merge-conflict cases covered in Sync-FromSvn.Tests.ps1.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/sync-from-svn.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    TMPDIR_CASE="$(mktemp -d -t turbo-pfs-XXXXXX)"
    git -C "$TMPDIR_CASE" init -b main >/dev/null 2>&1 || git -C "$TMPDIR_CASE" init >/dev/null 2>&1
    git -C "$TMPDIR_CASE" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$TMPDIR_CASE" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$TMPDIR_CASE/init.txt"
    git -C "$TMPDIR_CASE" add -A >/dev/null 2>&1
    git -C "$TMPDIR_CASE" commit -m initial --allow-empty >/dev/null 2>&1
}

oneTimeTearDown() {
    [ -n "${TMPDIR_CASE:-}" ] && rm -rf "$TMPDIR_CASE" 2>/dev/null || true
}

test_script_exists() {
    [ -f "$SCRIPT" ]
    assertTrue 'sync-from-svn.sh exists' $?
}

test_missing_branch_exits_nonzero_and_mentions_branch() {
    local out rc
    out=$(cd "$TMPDIR_CASE" && bash "$SCRIPT" 2>&1); rc=$?
    assertNotEquals 'missing --branch exits non-zero' 0 "$rc"
    case "$out" in
        *--branch*|*required*) assertTrue 'missing --branch stderr mentions branch' 0 ;;
        *) fail "missing --branch stderr unexpected: $out" ;;
    esac
}

test_unknown_arg_exits_nonzero() {
    local rc
    (cd "$TMPDIR_CASE" && bash "$SCRIPT" --bogus >/dev/null 2>&1); rc=$?
    assertNotEquals 'unknown arg exits non-zero' 0 "$rc"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
