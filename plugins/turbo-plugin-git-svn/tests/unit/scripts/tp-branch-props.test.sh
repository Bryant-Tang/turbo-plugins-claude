#!/usr/bin/env bash
# tp-branch-props.test.sh (shUnit2)
#
# Unit coverage for the U2 tp:* branch-metadata property helpers in scripts/lib/common.sh:
#   - svn_copyfrom_rev_xml         pure parser: `svn log -v --stop-on-copy --xml` -> trunk copyfrom-rev
#   - get_svn_branch_copyfrom_rev  thin svn wrapper around the parser
#   - get_tp_branch_prop           `svn propget tp:<name> <target>` (absent -> empty, never error)
#   - set_tp_branch_prop           propset + scoped `svn commit --depth empty` + `svn update`
#
# The PURE parser (svn_copyfrom_rev_xml) is fed synthetic XML and runs on EVERY host (no SKIP).
# The svn-touching cases (copyfrom reader / getter / setter round-trip / property-only commit /
# absent-prop) build a real svn repo from the seed dump and SKIP when svn/svnadmin or the dump is
# unavailable. Helpers are sed-extracted from common.sh (mirrors replay-primitives.test.sh) so we
# exercise the shipped code without sourcing common.sh's `set -euo pipefail` (breaks shUnit2).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$PLUGIN_ROOT/scripts/lib/common.sh"
DUMP_PATH="$PLUGIN_ROOT/tests/fixtures/seed/svn-repo-r1-r20.dump"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

_load_helpers() {
    eval "$(sed -n '/^svn_copyfrom_rev_xml()/,/^}/p' "$COMMON")"
    eval "$(sed -n '/^get_svn_branch_copyfrom_rev()/,/^}/p' "$COMMON")"
    eval "$(sed -n '/^get_tp_branch_prop()/,/^}/p' "$COMMON")"
    eval "$(sed -n '/^set_tp_branch_prop()/,/^}/p' "$COMMON")"
    declare -f svn_copyfrom_rev_xml >/dev/null 2>&1 &&
        declare -f get_svn_branch_copyfrom_rev >/dev/null 2>&1 &&
        declare -f get_tp_branch_prop >/dev/null 2>&1 &&
        declare -f set_tp_branch_prop >/dev/null 2>&1
}

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
    HAS_DUMP=0
    if [ -f "$DUMP_PATH" ]; then HAS_DUMP=1; fi
}

setUp() {
    _load_helpers || fail 'U2 helpers failed to sed-load from common.sh'
    SB="$(mktemp -d -t turbo-tpprop-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# Build a real svn repo from the seed dump under $SB and echo its file:// URI (isolated config
# dir so the runner's global svn config is never touched). Non-zero on any svn failure.
make_svn_repo() {
    local repo="$SB/svnrepo" cfg="$SB/.svnconfig" winrepo
    mkdir -p "$cfg"
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    svnadmin load "$repo" < "$DUMP_PATH" >/dev/null 2>&1 || return 1
    winrepo="$(cygpath -m "$repo" 2>/dev/null || printf '%s' "$repo")"
    printf 'file:///%s' "$winrepo"
}

CFG() { printf '%s' "$SB/.svnconfig"; }

# ── Pure parser: pretty-printed (multi-line) copy path -> trunk copyfrom-rev ───
# Mirrors the real `svn log -v --stop-on-copy --xml` shape where svn splits the <path>
# open tag across lines; the awk whitespace-collapse must still find copyfrom-rev.
test_copyfrom_parser_multiline_tag() {
    local xml out
    xml='<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry
   revision="21">
<author>alice</author>
<date>2026-07-09T01:00:00.000000Z</date>
<paths>
<path
   copyfrom-path="/trunk"
   copyfrom-rev="20"
   action="A"
   kind="dir">/branches/feature-x</path>
</paths>
<msg>create branch</msg>
</logentry>
</log>'
    out="$(printf '%s' "$xml" | svn_copyfrom_rev_xml)"
    assertEquals 'trunk copyfrom-rev extracted (not the r21 creation rev)' '20' "$out"
}

# ── Pure parser: picks the copyfrom of the SMALLEST-revision (copy) entry ──────
# A branch with a post-copy commit yields two logentries; only the oldest (copy) carries a
# branch-root copyfrom-rev. svn emits descending, so the copy entry comes LAST -- the parser
# must still return the copy's copyfrom-rev, not skip it.
test_copyfrom_parser_picks_oldest_copy_entry() {
    local xml out
    xml='<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry revision="25">
<paths>
<path action="M" kind="file">/branches/feature-x/README.txt</path>
</paths>
<msg>later edit</msg>
</logentry>
<logentry revision="21">
<paths>
<path copyfrom-path="/trunk" copyfrom-rev="20" action="A" kind="dir">/branches/feature-x</path>
</paths>
<msg>create branch</msg>
</logentry>
</log>'
    out="$(printf '%s' "$xml" | svn_copyfrom_rev_xml)"
    assertEquals 'copyfrom-rev from the oldest copy entry' '20' "$out"
}

# ── Pure parser: no copyfrom path (not a copied branch) -> empty ──────────────
test_copyfrom_parser_no_copy_is_empty() {
    local xml out
    xml='<?xml version="1.0"?><log><logentry revision="5"><paths><path action="M" kind="file">/trunk/a.txt</path></paths><msg>edit</msg></logentry></log>'
    out="$(printf '%s' "$xml" | svn_copyfrom_rev_xml)"
    assertEquals 'no copyfrom path yields empty' '' "$out"
}

# ── svn: copyfrom reader returns the TRUNK copyfrom-rev, not the branch creation rev ──
test_branch_copyfrom_rev_is_trunk_rev() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local uri cfg trunk_rev branch_rev got
    uri="$(make_svn_repo)" || { startSkipping; return 0; }
    cfg="$(CFG)"
    trunk_rev="$(svn --config-dir "$cfg" info --show-item revision "$uri/trunk" 2>/dev/null | tr -d '[:space:]')"
    svn --config-dir "$cfg" copy "$uri/trunk" "$uri/branches/feature-x" -m 'create branch' >/dev/null 2>&1 || { startSkipping; return 0; }
    branch_rev="$(svn --config-dir "$cfg" info --show-item revision "$uri/branches/feature-x" 2>/dev/null | tr -d '[:space:]')"
    got="$(get_svn_branch_copyfrom_rev "$uri/branches/feature-x")"
    assertEquals "copyfrom reader = trunk rev ($trunk_rev)" "$trunk_rev" "$got"
    assertNotEquals "copyfrom reader is NOT the branch creation rev ($branch_rev)" "$branch_rev" "$got"
}

# ── svn: set -> get tp:branch-name with a slash-bearing value round-trips exactly ──
test_set_get_branch_name_slash_roundtrip() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local uri cfg wc got
    uri="$(make_svn_repo)" || { startSkipping; return 0; }
    cfg="$(CFG)"
    svn --config-dir "$cfg" copy "$uri/trunk" "$uri/branches/feature-x" -m 'create branch' >/dev/null 2>&1 || { startSkipping; return 0; }
    wc="$SB/wc"
    svn --config-dir "$cfg" checkout "$uri/branches/feature-x" "$wc" >/dev/null 2>&1 || { startSkipping; return 0; }
    set_tp_branch_prop 'branch-name' 'feature/test-3-feature' "$wc" || fail 'set_tp_branch_prop failed'
    got="$(get_tp_branch_prop 'branch-name' "$wc")"
    assertEquals 'slash-bearing branch name round-trips exactly' 'feature/test-3-feature' "$got"
}

# ── svn: tp:last-aligned-rev numeric round-trip ───────────────────────────────
test_set_get_last_aligned_rev_numeric() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local uri cfg wc got
    uri="$(make_svn_repo)" || { startSkipping; return 0; }
    cfg="$(CFG)"
    svn --config-dir "$cfg" copy "$uri/trunk" "$uri/branches/feature-x" -m 'create branch' >/dev/null 2>&1 || { startSkipping; return 0; }
    wc="$SB/wc"
    svn --config-dir "$cfg" checkout "$uri/branches/feature-x" "$wc" >/dev/null 2>&1 || { startSkipping; return 0; }
    set_tp_branch_prop 'last-aligned-rev' '20' "$wc" || fail 'set_tp_branch_prop failed'
    got="$(get_tp_branch_prop 'last-aligned-rev' "$wc")"
    assertEquals 'numeric last-aligned-rev round-trips' '20' "$got"
}

# ── svn: the property commit touches ONLY the property (no file drift swept in) ──
test_property_commit_touches_only_property() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local uri cfg wc head npaths rootpaths
    uri="$(make_svn_repo)" || { startSkipping; return 0; }
    cfg="$(CFG)"
    svn --config-dir "$cfg" copy "$uri/trunk" "$uri/branches/feature-x" -m 'create branch' >/dev/null 2>&1 || { startSkipping; return 0; }
    wc="$SB/wc"
    svn --config-dir "$cfg" checkout "$uri/branches/feature-x" "$wc" >/dev/null 2>&1 || { startSkipping; return 0; }
    set_tp_branch_prop 'branch-name' 'feature/x' "$wc" || fail 'set_tp_branch_prop failed'
    head="$(svn --config-dir "$cfg" info --show-item revision "$uri/branches/feature-x" 2>/dev/null | tr -d '[:space:]')"
    # The property commit must change exactly ONE path -- the branch-root dir (property mod) --
    # and NO child file. Count </path> closing tags in the -v XML log of that revision (</path>
    # does NOT match the </paths> container tag, unlike a '<path' prefix count).
    npaths="$(svn --config-dir "$cfg" log -v -r "$head" --xml "$uri/branches/feature-x" 2>/dev/null | grep -c '</path>')"
    assertEquals 'property commit changed exactly one path (the branch root)' '1' "$npaths"
    # And that single path is the branch root itself, not a descendant file.
    rootpaths="$(svn --config-dir "$cfg" log -v -r "$head" --xml "$uri/branches/feature-x" 2>/dev/null | grep -c '>/branches/feature-x<')"
    assertEquals 'the changed path is the branch root dir' '1' "$rootpaths"
}

# ── svn: absent property -> getter returns empty, NOT an error ────────────────
test_absent_property_returns_empty_not_error() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local uri cfg wc got rc
    uri="$(make_svn_repo)" || { startSkipping; return 0; }
    cfg="$(CFG)"
    svn --config-dir "$cfg" copy "$uri/trunk" "$uri/branches/feature-x" -m 'create branch' >/dev/null 2>&1 || { startSkipping; return 0; }
    wc="$SB/wc"
    svn --config-dir "$cfg" checkout "$uri/branches/feature-x" "$wc" >/dev/null 2>&1 || { startSkipping; return 0; }
    # No tp:branch-name has been set on this fresh branch WC.
    got="$(get_tp_branch_prop 'branch-name' "$wc")"; rc=$?
    assertEquals 'getter succeeds (exit 0) on an absent property' 0 "$rc"
    assertEquals 'absent property reads back empty' '' "$got"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
