#!/usr/bin/env bash
# svn-log-xml-format.test.sh (shUnit2)
#
# Unit coverage for svn_log_format_xml (scripts/lib/common.sh) -- the pure-shell
# formatter that turned `svn log --xml` into plain text after xmllint was dropped.
#
# Why this matters: xmllint is typically ABSENT in Git Bash on Windows (the primary
# host), so the old xmllint-preferred code path never ran there -- users got an
# untested grep+awk fallback that listed NO changed paths under --verbose and did
# NOT decode XML entities. get-svn-log.sh now always calls svn_log_format_xml, so
# the shipped path is the tested path. These cases feed synthetic `svn log --xml`
# to the REAL function (sed-extracted from common.sh): deterministic, no svn needed.
#
# Layers:
#   1. Structural guards (always run): common.sh defines the helper + entity-decodes;
#      get-svn-log.sh calls it and no longer references xmllint.
#   2. Behavioral (always run, svn-free): entity decode (& < > " ' + &amp; decoded
#      LAST), --verbose per-path listing with decoded paths, multi-line <msg>
#      preservation, the LAST_SHOWN_REV trailer, and empty-log -> empty output.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$PLUGIN_ROOT/scripts/lib/common.sh"
GET_SVN_LOG="$PLUGIN_ROOT/scripts/get-svn-log.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

# Load the REAL svn_log_format_xml out of common.sh (sed-extract the function so we
# exercise the shipped code without sourcing common.sh's `set -euo pipefail`, which
# would break shUnit2). Mirrors _load_svn_status_xml in svn-status-xml-roundtrip.test.sh.
_load_svn_log_format_xml() {
    eval "$(sed -n '/^svn_log_format_xml()/,/^}/p' "$COMMON")"
    declare -f svn_log_format_xml >/dev/null 2>&1
}

# A realistic `svn log --xml -v` document with:
#   - r7: entity-laden <msg> (& < > " ') and two <paths> (one path name contains &);
#         the first <path> pretty-prints attributes across lines with action NOT first
#         (kind before action) to prove order-independent action extraction.
#   - r5: a msg with &amp;lt; to prove &amp; is decoded LAST (stays literal "&lt;").
#   - r3: a multi-line <msg> to prove line breaks survive.
_sample_xml() {
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry
   revision="7">
<author>alice</author>
<date>2026-05-26T12:00:00.000000Z</date>
<paths>
<path
   kind="file"
   action="M">/trunk/a &amp; b.txt</path>
<path
   action="A"
   kind="file">/trunk/plain.txt</path>
</paths>
<msg>fix &lt;tag&gt; &amp; &quot;q&quot; &apos;a&apos;</msg>
</logentry>
<logentry
   revision="5">
<author>carol</author>
<date>2026-05-22T00:00:00.000000Z</date>
<msg>amp last: &amp;lt; stays literal</msg>
</logentry>
<logentry
   revision="3">
<author>bob</author>
<date>2026-05-20T09:00:00.000000Z</date>
<msg>line one
line two</msg>
</logentry>
</log>
XML
}

# ── Structural guards ─────────────────────────────────────────────────────────
test_common_defines_helper_and_entity_decodes() {
    grep -q '^svn_log_format_xml()' "$COMMON"
    assertTrue 'common.sh defines svn_log_format_xml' $?
    grep -q '&amp;' "$COMMON"
    assertTrue 'common.sh svn_log_format_xml entity-decodes &amp;' $?
}

test_get_svn_log_calls_helper_and_drops_xmllint() {
    grep -q 'svn_log_format_xml' "$GET_SVN_LOG"
    assertTrue 'get-svn-log.sh calls svn_log_format_xml' $?
    if grep -q 'xmllint' "$GET_SVN_LOG"; then
        fail 'get-svn-log.sh still references xmllint (should be a single awk path)'
    else
        assertTrue 'no xmllint reference remains in get-svn-log.sh' 0
    fi
}

# ── Behavioral: entity decode in <msg> (all five predefined entities) ─────────
test_msg_entity_decode() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(_sample_xml | svn_log_format_xml false)"
    # r7 msg must be fully decoded: fix <tag> & "q" 'a'
    echo "$out" | grep -qF "fix <tag> & \"q\" 'a'"
    assertTrue 'r7 msg decodes & < > " and apostrophe' $?
    # No raw entity may survive in the r7 line. (Scoped to r7: r5 intentionally
    # produces a LITERAL "&lt;" to prove &amp; is decoded last, so a whole-output
    # scan would false-positive on that.)
    local r7line
    r7line="$(printf '%s\n' "$out" | grep -E '^r7 \|')"
    if printf '%s\n' "$r7line" | grep -q '&amp;\|&lt;\|&gt;\|&quot;\|&apos;'; then
        fail 'raw XML entity survived in r7 formatted output'
    else
        assertTrue 'no raw XML entity in r7 output' 0
    fi
}

# ── Behavioral: &amp; decoded LAST so &amp;lt; stays literal "&lt;" ────────────
test_amp_decoded_last() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(_sample_xml | svn_log_format_xml false)"
    echo "$out" | grep -qF 'amp last: &lt; stays literal'
    assertTrue '&amp;lt; decodes to literal &lt; (amp decoded last)' $?
}

# ── Behavioral: --verbose lists changed paths, entity-decoded, action first ───
test_verbose_lists_decoded_paths() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(_sample_xml | svn_log_format_xml true)"
    # action extracted even though 'kind' precedes 'action' in the first <path>,
    # and the '&' in the path name is decoded.
    echo "$out" | grep -Eq '^   M /trunk/a & b\.txt$'
    assertTrue 'verbose: "M /trunk/a & b.txt" (order-independent action + decoded &)' $?
    echo "$out" | grep -Eq '^   A /trunk/plain\.txt$'
    assertTrue 'verbose: "A /trunk/plain.txt"' $?
}

# ── Behavioral: non-verbose omits the per-path change lines ───────────────────
test_nonverbose_omits_paths() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(_sample_xml | svn_log_format_xml false)"
    if printf '%s\n' "$out" | grep -Eq '^   [AMDR] /trunk/'; then
        fail 'non-verbose output leaked per-path change lines'
    else
        assertTrue 'non-verbose omits per-path lines' 0
    fi
}

# ── Behavioral: multi-line <msg> preserves the internal line break ────────────
test_multiline_msg_preserved() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(_sample_xml | svn_log_format_xml false)"
    echo "$out" | grep -Eq '^r3 \|.*\| line one$'
    assertTrue 'r3 first msg line stays on the r3 header line' $?
    echo "$out" | grep -Eq '^line two$'
    assertTrue 'r3 second msg line survives on its own line' $?
}

# ── Behavioral: LAST_SHOWN_REV trailer = smallest revision shown ──────────────
test_trailer_is_min_rev() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(_sample_xml | svn_log_format_xml false)"
    echo "$out" | grep -Eq '^# LAST_SHOWN_REV=3$'
    assertTrue 'trailer reports the oldest (min) revision shown = 3' $?
}

# ── Behavioral: empty log -> no output, no trailer ────────────────────────────
test_empty_log_no_output() {
    _load_svn_log_format_xml || { fail 'svn_log_format_xml failed to load'; return 0; }
    local out
    out="$(printf '%s' '<?xml version="1.0" encoding="UTF-8"?>
<log>
</log>' | svn_log_format_xml false)"
    assertEquals 'empty <log> yields no output' '' "$out"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
