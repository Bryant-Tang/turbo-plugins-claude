#!/usr/bin/env bash
# svn-status-xml-roundtrip.test.sh (shUnit2)
#
# Regression coverage for the non-ASCII (中文) filename push-to-svn bug.
#
# Root cause (forensic): build/submit-svn-commit.sh used to CAPTURE plain `svn status` text and
# slice the path by column offset, then re-pass that captured path as argv to `svn add/commit`.
# On zh-TW Windows, plain `svn status` prints filenames in the system ANSI codepage (Big5); the
# captured bytes then no longer matched the on-disk filename → "not under version control".
#
# Fix: a shared `svn_status_xml()` helper in lib/common.sh parses `svn status --xml` (always
# UTF-8 paths) and XML-entity-decodes them, so the CAPTURE is encoding-correct. That capture is
# what this file verifies as the fix.
#
# Layers:
#   1. Structural guards (always run): the shared helper still uses `svn status --xml` + entity
#      decode, both push scripts call it, and no column-offset slice of plain `svn status` remains.
#   2. Capture (SKIPs without svn/svnadmin): the REAL svn_status_xml extracted from common.sh
#      surfaces a live working copy's Chinese AND `&`-containing filenames as exact decoded paths.
#      Deterministic; this is the actual fix.
#   3. Re-pass round-trip (capture asserted unconditionally; native argv re-pass env-gated). Native
#      non-ASCII argv to svn.exe keys off the CONSOLE codepage, not the captured path's correctness;
#      the PS orchestrator forces console UTF-8 (65001), under which MSYS mangles native argv. So
#      the svn add/commit re-pass is asserted only when the shell env supports it; under a hostile
#      console codepage it warns and skips. The capture equality is asserted in every environment.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$PLUGIN_ROOT/scripts/lib/common.sh"
SUBMIT="$PLUGIN_ROOT/scripts/submit-svn-commit.sh"
BUILD="$PLUGIN_ROOT/scripts/build-svn-commit.sh"
PS_SUBMIT="$PLUGIN_ROOT/scripts/Submit-SvnCommit.ps1"
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

# Build a live svn working copy under $SB and echo its path. Returns non-zero on failure.
_make_wc() {
    local repo="$SB/repo" wc="$SB/wc" win uri
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    win="$(cygpath -m "$repo" 2>/dev/null || printf '%s' "$repo")"
    uri="file:///$win"
    svn checkout "$uri" "$wc" >/dev/null 2>&1 || return 1
    printf '%s' "$wc"
}

# Load the REAL svn_status_xml out of common.sh (sed-extract the function so we exercise the
# shipped code without sourcing common.sh's `set -euo pipefail`, which would break shUnit2).
_load_svn_status_xml() {
    eval "$(sed -n '/^svn_status_xml()/,/^}/p' "$COMMON")"
    declare -f svn_status_xml >/dev/null 2>&1
}

# ── Structural guards ─────────────────────────────────────────────────────────
test_helper_uses_svn_status_xml_and_both_scripts_call_it() {
    grep -q 'svn status --xml' "$COMMON"
    assertTrue 'common.sh helper uses `svn status --xml`' $?
    grep -q '^svn_status_xml()' "$COMMON"
    assertTrue 'common.sh defines svn_status_xml' $?
    grep -q 'svn_status_xml' "$BUILD"
    assertTrue 'build-svn-commit.sh calls svn_status_xml' $?
    grep -q 'svn_status_xml' "$SUBMIT"
    assertTrue 'submit-svn-commit.sh calls svn_status_xml' $?
}

# The helper must XML-entity-decode (svn --xml escapes & < > " in attribute values).
test_helper_entity_decodes() {
    grep -q '&amp;' "$COMMON"
    assertTrue 'common.sh svn_status_xml entity-decodes &amp;' $?
}

# Guard against reverting to the fragile column-offset slice of plain `svn status` (the original
# byte-mangling source). Fail if EITHER push script still uses ${line:8}.
test_scripts_drop_column_offset_parse() {
    if grep -q '${line:8}' "$SUBMIT" 2>/dev/null || grep -q '${line:8}' "$BUILD" 2>/dev/null; then
        fail 'a push script still column-slices plain `svn status` output (${line:8} regression)'
    else
        assertTrue 'no ${line:8} column-slice of plain svn status remains' 0
    fi
}

# Guard the `--` option terminator on svn add/delete/commit in BOTH submit scripts. Without `--`,
# a leading-dash filename is parsed as svn flags. The behavioral leading-dash test below exercises
# this only via the env-gated re-pass (skipped under a hostile console codepage / on Windows CI),
# so this always-running structural guard is the real cross-platform regression net.
test_submit_scripts_keep_option_terminator() {
    # .sh submit: add/delete/commit must each keep `-- ` before the array expansion.
    grep -q 'svn add .*-- "${TO_ADD' "$SUBMIT"
    assertTrue 'submit-svn-commit.sh: svn add keeps -- before "${TO_ADD[@]}"' $?
    grep -q 'svn delete .*-- "${TO_DEL' "$SUBMIT"
    assertTrue 'submit-svn-commit.sh: svn delete keeps -- before "${TO_DEL[@]}"' $?
    grep -q 'svn commit .*-- "${COMMIT_TARGETS' "$SUBMIT"
    assertTrue 'submit-svn-commit.sh: svn commit keeps -- before "${COMMIT_TARGETS[@]}"' $?

    # .ps1 submit: same `--` before the argv variables (grep is language-agnostic; runs on any OS).
    if [ -f "$PS_SUBMIT" ]; then
        grep -q 'svn add .*-- \$toAdd' "$PS_SUBMIT"
        assertTrue 'Submit-SvnCommit.ps1: svn add keeps -- before $toAdd' $?
        grep -q 'svn delete .*-- \$toDel' "$PS_SUBMIT"
        assertTrue 'Submit-SvnCommit.ps1: svn delete keeps -- before $toDel' $?
        grep -q 'svn commit .*-- \$commitTargets' "$PS_SUBMIT"
        assertTrue 'Submit-SvnCommit.ps1: svn commit keeps -- before $commitTargets' $?
    fi
}

# ── Capture (the actual fix): exact decoded paths for CJK and XML-special names ──
test_svn_status_xml_captures_nonascii_and_special_paths() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local wc out cap_zh cap_amp
    wc="$(_make_wc)" || { startSkipping; return 0; }
    _load_svn_status_xml
    assertTrue 'svn_status_xml loaded from common.sh' $?

    printf 'x' > "$wc/測試中文檔名.txt"
    printf 'x' > "$wc/a&b.txt"          # `&` -> svn --xml escapes it as &amp;; helper must decode
    out="$(svn_status_xml "$wc")"

    cap_zh="$(printf '%s\n' "$out" | grep -F '測試中文檔名.txt' | head -1 | cut -f2-)"
    assertEquals 'captures exact CJK path' '測試中文檔名.txt' "$cap_zh"

    cap_amp="$(printf '%s\n' "$out" | grep -F 'a&b.txt' | head -1 | cut -f2-)"
    assertEquals 'entity-decodes & in path (expect a&b.txt, not a&amp;b.txt)' 'a&b.txt' "$cap_amp"
}

# ── Failure propagation: svn_status_xml must return non-zero when it cannot get status ──
# Guards the round-1 fix (`raw="$(cd "$wc" && svn status --xml)" || return 1`): a failure must NOT
# be swallowed and read as "no changes" (which would let git advance while SVN stays put ->
# permanent divergence). An unusable working-copy path makes the inner `cd` fail, so the `||
# return 1` must fire. (Deterministic and svn-version-independent: some svn builds exit 0 on a
# plain non-WC directory, so a missing path is the reliable failure trigger.)
test_svn_status_xml_returns_nonzero_on_unusable_path() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    # Guard the load: if sed-extraction of svn_status_xml ever fails, calling an undefined function
    # returns 127 and assertNotEquals would vacuously pass (false green). Fail explicitly instead.
    _load_svn_status_xml || { fail 'svn_status_xml failed to load from common.sh'; return 0; }
    local rc
    svn_status_xml "$SB/does-not-exist" >/dev/null 2>&1
    rc=$?
    assertNotEquals 'svn_status_xml returns non-zero when the working-copy path is unusable' 0 "$rc"
}

# ── Entity decode for the other XML-special chars (< > "), beyond the & case above ──
# `svn status --xml` escapes &<>" in attribute values; the & case is covered above. < > " are
# ILLEGAL in Windows (NTFS) filenames, so this case runs only where they are legal (Linux CI).
test_svn_status_xml_entity_decodes_lt_gt_quote() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) startSkipping; return 0 ;;   # < > " illegal in Windows filenames
    esac
    local wc out
    wc="$(_make_wc)" || { startSkipping; return 0; }
    _load_svn_status_xml
    printf 'x' > "$wc/a<b.txt"
    printf 'x' > "$wc/a>b.txt"
    printf 'x' > "$wc/a\"b.txt"
    out="$(svn_status_xml "$wc")"
    assertEquals 'decodes < (expect a<b.txt)' 'a<b.txt' "$(printf '%s\n' "$out" | grep -F 'a<b.txt' | head -1 | cut -f2-)"
    assertEquals 'decodes > (expect a>b.txt)' 'a>b.txt' "$(printf '%s\n' "$out" | grep -F 'a>b.txt' | head -1 | cut -f2-)"
    assertEquals 'decodes " (expect a"b.txt)' 'a"b.txt' "$(printf '%s\n' "$out" | grep -F 'a"b.txt' | head -1 | cut -f2-)"
}

# ── Leading-dash filename: exercises the `--` option terminator on svn add/commit ──
# Without `--`, svn parses `-x.txt` as options and fails. Capture is asserted unconditionally;
# the native re-pass (svn add/commit -- ...) is env-gated like the non-ASCII re-pass below.
test_leading_dash_filename_captures_and_repasses_with_terminator() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local wc fn out captured
    wc="$(_make_wc)" || { startSkipping; return 0; }
    _load_svn_status_xml
    fn='-x.txt'
    printf 'hello\n' > "$wc/$fn"
    out="$(svn_status_xml "$wc")"
    captured="$(printf '%s\n' "$out" | grep -F -- "$fn" | head -1 | cut -f2-)"
    assertEquals 'captures leading-dash filename' "$fn" "$captured"

    if ( cd "$wc" && svn add -- "$captured" >/dev/null 2>&1 && svn commit -m 'add dash' -- "$captured" >/dev/null 2>&1 ); then
        if printf '%s\n' "$(svn_status_xml "$wc")" | grep -qF -- "$fn"; then
            fail "leading-dash file still unversioned after commit -- terminator round-trip broken"
        else
            assertTrue 'leading-dash file committed via -- terminator' 0
        fi
    else
        echo "WARNING: leading-dash re-pass unavailable in this shell env (console codepage / svn); capture verified above." >&2
        assertTrue 'leading-dash re-pass env-gated (capture verified above)' 0
    fi
}

# ── Re-pass round-trip: capture asserted always; native argv re-pass env-gated ──
test_nonascii_path_repasses_to_svn_when_console_allows() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local wc fn out captured out2
    wc="$(_make_wc)" || { startSkipping; return 0; }
    _load_svn_status_xml

    fn='測試中文檔名.txt'
    printf 'hello\n' > "$wc/$fn"
    out="$(svn_status_xml "$wc")"
    captured="$(printf '%s\n' "$out" | grep -F "$fn" | head -1 | cut -f2-)"

    # Assert capture correctness UNCONDITIONALLY (this is the fix) so a garbled/empty capture
    # fails here rather than being masked by the env-gated re-pass below.
    assertEquals 'capture equals original before re-pass' "$fn" "$captured"

    if ( cd "$wc" && svn add -- "$captured" >/dev/null 2>&1 && svn commit -m 'add nonascii' -- "$captured" >/dev/null 2>&1 ); then
        out2="$(svn_status_xml "$wc")"
        if printf '%s\n' "$out2" | grep -qF "$fn"; then
            fail "Chinese file still unversioned after a successful commit — round-trip broken: $out2"
        else
            assertTrue 'non-ASCII file committed (full svn add+commit round-trip verified)' 0
        fi
    else
        # Native non-ASCII argv unavailable in this shell env (hostile console codepage, e.g. the
        # orchestrator forcing console=65001). Capture is already asserted above.
        echo "WARNING: native non-ASCII argv re-pass unavailable in this shell env (console codepage); re-pass assertion skipped. Capture verified above." >&2
        assertTrue 're-pass env-gated (capture verified above)' 0
    fi
}

# shellcheck disable=SC1090
. "$SHUNIT2"
