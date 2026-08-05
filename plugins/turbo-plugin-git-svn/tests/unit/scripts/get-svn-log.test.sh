#!/usr/bin/env bash
# get-svn-log.test.sh (shUnit2) — bash sibling for get-svn-log.sh (own argparse, not delegate)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/get-svn-log.sh"
TEST_ROOT="$PLUGIN_ROOT/tests/.sandbox/test-turbo-plugin"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_SVN=0
    command -v svn >/dev/null 2>&1 && HAS_SVN=1
    # Ensure fixture .git
    if [ -d "$TEST_ROOT" ] && [ ! -d "$TEST_ROOT/.git" ]; then
        (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
    fi
}

# get-svn-log.sh runs `svn log`; without svn (or the seeded svn fixture) SKIP.
gate() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return; }
    [ -d "$TEST_ROOT" ] || fail "setup: $TEST_ROOT not found"
}

# Case 1: happy — top = r19, LAST_SHOWN_REV=15 at default --limit 5.
test_happy_default_limit() {
    gate
    local out e
    out="$(cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case1: exit 0' 0 "$e"
    echo "$out" | grep -Eq '^r19 \|'; assertTrue 'case1: contains r19' $?
    echo "$out" | grep -Eq '# LAST_SHOWN_REV=15'; assertTrue 'case1: trailer LAST_SHOWN_REV=15' $?
}

# Case 2 + 3: 中文 commit on r5, plus trailer emitted with revision spec.
test_chinese_commit_and_trailer() {
    gate
    local out e
    out="$(cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" --revision 5 2>/dev/null)"; e=$?
    assertEquals 'case2: exit 0' 0 "$e"
    echo "$out" | grep -Eq '^r5 \|'; assertTrue 'case2: r5 row present' $?
    # Accept canonical CJK OR the F-3 Windows cp1252 mojibake form (both prove bytes survived).
    echo "$out" | grep -qE '修正中文 commit 訊息亂碼|ä¿®æ­£'
    assertTrue 'case2: 中文 commit msg present (canonical or F-3 mojibake form)' $?
    # Case 3: trailer emitted with revision spec.
    echo "$out" | grep -Eq '# LAST_SHOWN_REV=[0-9]+'; assertTrue 'case3: trailer emitted with revision spec' $?
}

# Case 4: --limit 0 invalid.
test_limit_zero_invalid() {
    gate
    local out e
    out="$(cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" --limit 0 2>&1)"; e=$?
    assertTrue 'case4: --limit 0 exit != 0' "[ $e -ne 0 ]"
    echo "$out" | grep -Eq 'positive integer'; assertTrue 'case4: positive integer message' $?
}

# Case 5: SKILL re-invoke.
test_skill_reinvoke() {
    gate
    local out e
    out="$(cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case5: SKILL-entry exit 0' 0 "$e"
    echo "$out" | grep -Eq '# LAST_SHOWN_REV=15'; assertTrue 'case5: trailer still present' $?
}

# Case 6: --verbose lists changed paths (regression: the old xmllint-absent fallback
# listed NO paths). r2 adds /trunk/README.txt, so `-r 2 --verbose` must show it.
test_verbose_lists_changed_paths() {
    gate
    local out e
    out="$(cd "$TEST_ROOT" && bash "$SCRIPT_UNDER_TEST" --revision 2 --verbose 2>/dev/null)"; e=$?
    assertEquals 'case6: verbose exit 0' 0 "$e"
    echo "$out" | grep -Eq '^r2 \|'; assertTrue 'case6: r2 header row present' $?
    echo "$out" | grep -qF '變更:'; assertTrue 'case6: 變更 section present' $?
    echo "$out" | grep -Eq '^A  .*/trunk/README\.txt$'; assertTrue 'case6: verbose shows "A  /trunk/README.txt"' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
