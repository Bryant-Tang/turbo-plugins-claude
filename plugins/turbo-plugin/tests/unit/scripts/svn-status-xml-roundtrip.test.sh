#!/usr/bin/env bash
# svn-status-xml-roundtrip.test.sh (shUnit2)
#
# Regression coverage for the non-ASCII (中文) filename push-to-svn bug (v0.5.2).
#
# Root cause (forensic): build/submit-svn-commit.sh used to capture plain `svn status`
# text and slice the path by column offset, then re-pass that captured path as argv to
# `svn add/commit`. On zh-TW Windows, plain `svn status` prints filenames in the system
# ANSI codepage (Big5); Git Bash/MSYS then re-encodes the captured bytes as UTF-8 when
# building the child argv → svn looks for the wrong bytes → "not under version control".
#
# Fix: a shared `svn_status_xml()` helper parses `svn status --xml` (always UTF-8 paths),
# so capture→re-pass round-trips losslessly.
#
# This file has two layers:
#   1. Structural guard (always runs): the scripts still use `svn status --xml`, not the
#      old column-offset text parse, so the fix cannot be silently reverted.
#   2. Behavioral round-trip (SKIPs without svn/svnadmin): extracts the REAL svn_status_xml
#      function out of submit-svn-commit.sh and drives it against a live svn working copy
#      holding a Chinese-named file, then re-passes the captured path back through
#      `svn add` + `svn commit`. On a Big5 Git Bash this FAILS with the old code and PASSES
#      with the fix; on a UTF-8 runner (CI) it passes either way but still exercises --xml.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SUBMIT="$PLUGIN_ROOT/scripts/submit-svn-commit.sh"
BUILD="$PLUGIN_ROOT/scripts/build-svn-commit.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
}

setUp() {
    SB="$(mktemp -d -t turbo-ssx-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# ── Structural guard: both scripts parse `svn status --xml` (not column-offset text) ──
test_scripts_use_svn_status_xml() {
    grep -q 'svn status --xml' "$SUBMIT"
    assertTrue 'submit-svn-commit.sh uses `svn status --xml`' $?
    grep -q 'svn status --xml' "$BUILD"
    assertTrue 'build-svn-commit.sh uses `svn status --xml`' $?
    grep -q 'svn_status_xml' "$SUBMIT"
    assertTrue 'submit-svn-commit.sh defines/uses svn_status_xml helper' $?
}

# The commit-path must NOT re-introduce the fragile `${line:8}` column slice over plain
# `svn status` output (that was the exact byte-mangling source).
test_scripts_drop_column_offset_parse() {
    if grep -q 'svn status)"' "$SUBMIT" 2>/dev/null && grep -q '\${line:8}' "$SUBMIT" 2>/dev/null; then
        fail 'submit-svn-commit.sh still column-slices plain `svn status` output (regression)'
    else
        assertTrue 'submit-svn-commit.sh no longer column-slices plain svn status' 0
    fi
}

# ── Behavioral round-trip against a live svn WC with a Chinese filename ──
test_nonascii_filename_roundtrips_through_real_svn() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi

    local repo wc uri winpath fn out path rc
    repo="$SB/repo"
    wc="$SB/wc"
    svnadmin create "$repo" >/dev/null 2>&1 || { startSkipping; return 0; }
    winpath="$(cygpath -m "$repo" 2>/dev/null || printf '%s' "$repo")"
    uri="file:///$winpath"
    svn checkout "$uri" "$wc" >/dev/null 2>&1 || { startSkipping; return 0; }

    # Extract the REAL helper from the script under test and define it here, so we exercise
    # the shipped code path rather than a hand-rolled copy.
    eval "$(sed -n '/^svn_status_xml()/,/^}/p' "$SUBMIT")"

    fn='測試中文檔名.txt'
    printf 'hello\n' > "$wc/$fn"

    # Capture: the helper must surface the unversioned Chinese path as "?<TAB>測試中文檔名.txt".
    out="$(svn_status_xml "$wc")"
    if ! printf '%s\n' "$out" | grep -qF "$fn"; then
        fail "svn_status_xml did not surface the Chinese filename; got: $out"
        return
    fi

    # Re-pass: feed the captured path straight back to svn add + commit. This is the step
    # that mangled under the old text-parse on Big5 Git Bash.
    path="$(printf '%s\n' "$out" | grep -F "$fn" | head -1 | cut -f2-)"
    ( cd "$wc" && svn add "$path" >/dev/null 2>&1 && svn commit -m 'add nonascii' "$path" >/dev/null 2>&1 )
    rc=$?
    assertEquals 'svn add+commit of the captured Chinese path succeeds' 0 "$rc"

    # After commit the file is versioned, so the helper must no longer report it as '?'.
    out="$(svn_status_xml "$wc")"
    if printf '%s\n' "$out" | grep -qF "$fn"; then
        fail "Chinese file still reported unversioned after commit; round-trip failed: $out"
    else
        assertTrue 'Chinese file committed (no longer unversioned)' 0
    fi
}

# shellcheck disable=SC1090
. "$SHUNIT2"
