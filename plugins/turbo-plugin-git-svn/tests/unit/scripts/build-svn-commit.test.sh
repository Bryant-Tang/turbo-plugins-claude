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

# ── issue #161: the branch-mismatch backstop uses the same predicate as the pre-flight ──
#
# These cases build their OWN sandbox rather than using $TEST_ROOT: the point is the worktree
# LAYOUT (a branch held by a linked worktree vs. a branch nobody holds), which the shared fixture
# does not provide. Only the token line is asserted -- the script legitimately goes on to do
# svn-side work afterwards and may fail there, which says nothing about the gate.

bs_sandbox() {
    local sb dir
    sb="$(mktemp -d -t tp-bsc-XXXXXX)"
    dir="$sb/proj"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main >/dev/null 2>&1
    git -C "$dir" config user.email 'test@example.invalid' >/dev/null 2>&1
    git -C "$dir" config user.name 'Test' >/dev/null 2>&1
    printf 'x' > "$dir/a.txt"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    printf '%s' "$sb"
}

# Create the bridge worktree the script requires before it reaches the backstop.
bs_bridge() {
    local dir="$1" branch="$2" name="$3"
    git -C "$dir" worktree add -q -b "remote-svn/$branch" \
        "$dir/.turbo-plugin/worktrees/remote-svn-$name" >/dev/null 2>&1
}

bs_run() {
    local dir="$1" branch="$2"
    ( cd "$dir" && bash "$SCRIPT_UNDER_TEST" --branch "$branch" 2>/dev/null ) | grep '^TP_TOKEN:' || true
}

test_backstop_silent_when_a_linked_worktree_holds_the_branch() {
    local sb dir out
    sb="$(bs_sandbox)"; dir="$sb/proj"
    git -C "$dir" worktree add -q -b feat-x "$sb/wt-feat-x" >/dev/null 2>&1
    if [ "$(git -C "$sb/wt-feat-x" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" != 'feat-x' ]; then
        rm -rf "$sb" 2>/dev/null || true
        fail 'fixture: worktree add did not put feat-x in place'
        return 1
    fi
    bs_bridge "$dir" 'feat-x' 'feat-x'

    out="$(bs_run "$dir" 'feat-x')"
    rm -rf "$sb" 2>/dev/null || true
    case "$out" in
        *BRANCH_MISMATCH_WARNING*)
            fail "backstop must not warn while a linked worktree holds feat-x, got: $out" ;;
        *) assertTrue 'no mismatch warning for a branch a linked worktree holds' 0 ;;
    esac
}

# The other direction, so the case above cannot pass by the backstop having gone silent for good.
test_backstop_still_warns_for_a_branch_no_worktree_holds() {
    local sb dir out
    sb="$(bs_sandbox)"; dir="$sb/proj"
    git -C "$dir" branch feat-parked >/dev/null 2>&1
    bs_bridge "$dir" 'feat-parked' 'feat-parked'

    out="$(bs_run "$dir" 'feat-parked')"
    rm -rf "$sb" 2>/dev/null || true
    case "$out" in
        *"TP_TOKEN:BRANCH_MISMATCH_WARNING"*"requested=feat-parked"*)
            assertTrue 'still warns when nobody holds the branch' 0 ;;
        *) fail "expected the backstop to warn for feat-parked, got: $out" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
