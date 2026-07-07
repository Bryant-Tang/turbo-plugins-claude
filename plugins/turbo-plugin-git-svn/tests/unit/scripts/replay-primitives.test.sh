#!/usr/bin/env bash
# replay-primitives.test.sh (shUnit2)
#
# Unit coverage for the U1 per-revision SVN replay primitives in scripts/lib/common.sh:
#   - svn_enumerate_revisions   parse `svn log --xml` -> ascending NUL records, entity-decoded
#   - svn_replay_commit         one SVN revision -> one git commit (author/date/trailer, skips)
#   - svn_floor_commit_for_rev  newest `main` commit whose svn-revision trailer value is <= R
#
# svn is NEVER invoked: enumeration is fed SYNTHETIC `svn log --xml`, and replay/floor run
# against a throwaway git repo. So every case runs on every host (no svn-gated SKIP). Helpers
# are sed-extracted from common.sh (mirrors svn-log-xml-format.test.sh) so we exercise the
# shipped code without sourcing common.sh's `set -euo pipefail` (which would break shUnit2).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$PLUGIN_ROOT/scripts/lib/common.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

_load_helpers() {
    eval "$(sed -n '/^svn_enumerate_revisions()/,/^}/p' "$COMMON")"
    eval "$(sed -n '/^svn_replay_commit()/,/^}/p' "$COMMON")"
    eval "$(sed -n '/^svn_floor_commit_for_rev()/,/^}/p' "$COMMON")"
    declare -f svn_enumerate_revisions >/dev/null 2>&1 &&
        declare -f svn_replay_commit >/dev/null 2>&1 &&
        declare -f svn_floor_commit_for_rev >/dev/null 2>&1
}

# A synthetic `svn log --xml` document (descending, as `svn log` emits by default) with:
#   r7: entity-laden <msg> (&lt; &gt; &amp;) to prove entity decode
#   r5: a CJK <msg> to prove no mojibake
#   r3: a multi-line <msg> to prove internal newlines survive
_sample_xml() {
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry revision="7"><author>alice</author><date>2026-05-26T12:00:00.000000Z</date><msg>fix &lt;tag&gt; &amp; done</msg></logentry>
<logentry revision="5"><author>carol</author><date>2026-05-22T00:00:00.000000Z</date><msg>修正中文訊息</msg></logentry>
<logentry revision="3"><author>bob</author><date>2026-05-20T09:00:00.000000Z</date><msg>line one
line two</msg></logentry>
</log>
XML
}

# Parse svn_enumerate_revisions' NUL-record stream into parallel arrays REC_REV/AUTHOR/DATE/MSG.
_enumerate_into_arrays() {
    local xml="$1"
    REC_REV=(); REC_AUTHOR=(); REC_DATE=(); REC_MSG=()
    local rev author date msg
    while IFS=$'\037' read -r -d '' rev author date msg; do
        REC_REV+=("$rev"); REC_AUTHOR+=("$author"); REC_DATE+=("$date"); REC_MSG+=("$msg")
    done < <(printf '%s' "$xml" | svn_enumerate_revisions)
}

_commit_with_trailer() {  # <repo> <file> <content> <subject> <rev>
    local repo="$1" file="$2" content="$3" subject="$4" rev="$5"
    printf '%s\n' "$content" > "$repo/$file"
    git -C "$repo" add -A >/dev/null 2>&1
    git -C "$repo" -c commit.gpgsign=false commit -q -m "$subject" -m "svn-revision: $rev" >/dev/null 2>&1
}

setUp() {
    _load_helpers || fail 'U1 helpers failed to sed-load from common.sh'
    REPO="$(mktemp -d -t u1repl-XXXXXX)"
    git -C "$REPO" init -q -b main >/dev/null 2>&1 || {
        git -C "$REPO" init -q >/dev/null 2>&1; git -C "$REPO" checkout -q -b main >/dev/null 2>&1;
    }
    git -C "$REPO" config user.email 'test@turbo.invalid' >/dev/null 2>&1
    git -C "$REPO" config user.name 'Turbo Test' >/dev/null 2>&1
    git -C "$REPO" config core.autocrlf false >/dev/null 2>&1
    printf 'seed\n' > "$REPO/seed.txt"
    git -C "$REPO" add -A >/dev/null 2>&1
    git -C "$REPO" -c commit.gpgsign=false commit -q -m 'seed' >/dev/null 2>&1
}

tearDown() {
    [ -n "${REPO:-}" ] && rm -rf "$REPO" 2>/dev/null || true
}

# ── Enumeration: ascending order, three revisions ─────────────────────────────
test_enumerate_ascending_three_revs() {
    _enumerate_into_arrays "$(_sample_xml)"
    assertEquals 'three records enumerated' 3 "${#REC_REV[@]}"
    assertEquals 'ascending: first rev = 3' 3 "${REC_REV[0]}"
    assertEquals 'ascending: middle rev = 5' 5 "${REC_REV[1]}"
    assertEquals 'ascending: last rev = 7' 7 "${REC_REV[2]}"
    assertEquals 'author of r3' 'bob' "${REC_AUTHOR[0]}"
    assertEquals 'date of r7' '2026-05-26T12:00:00.000000Z' "${REC_DATE[2]}"
}

# ── Enumeration: XML entity decode in <msg> ───────────────────────────────────
test_enumerate_entity_decode() {
    _enumerate_into_arrays "$(_sample_xml)"
    assertEquals 'r7 msg entities decoded' 'fix <tag> & done' "${REC_MSG[2]}"
    # no raw entity survives
    case "${REC_MSG[2]}" in
        *'&lt;'*|*'&gt;'*|*'&amp;'*) fail 'raw XML entity survived in decoded message' ;;
    esac
}

# ── Enumeration: CJK message round-trips without mojibake ──────────────────────
test_enumerate_cjk_no_mojibake() {
    _enumerate_into_arrays "$(_sample_xml)"
    assertEquals 'r5 CJK msg intact' '修正中文訊息' "${REC_MSG[1]}"
}

# ── Enumeration: multi-line message keeps its internal newline ────────────────
test_enumerate_multiline_msg() {
    _enumerate_into_arrays "$(_sample_xml)"
    local first second
    first="$(printf '%s' "${REC_MSG[0]}" | sed -n '1p')"
    second="$(printf '%s' "${REC_MSG[0]}" | sed -n '2p')"
    assertEquals 'r3 msg line 1' 'line one' "$first"
    assertEquals 'r3 msg line 2' 'line two' "$second"
}

# ── Enumeration: empty <log> -> no records ────────────────────────────────────
test_enumerate_empty_log() {
    local out
    out="$(printf '%s' '<?xml version="1.0"?><log></log>' | svn_enumerate_revisions | tr -d '\000\037')"
    assertEquals 'empty log yields no output' '' "$out"
}

# ── Replay: author = "<user> <>", author-date = SVN date, trailer present ─────
test_replay_author_date_trailer() {
    printf 'feature\n' > "$REPO/f7.txt"
    local out
    out="$(svn_replay_commit "$REPO" 7 alice '2026-05-26T12:00:00.000000Z' 'add feature')"
    case "$out" in
        COMMIT:*) assertTrue 'replay reports COMMIT:<sha>' 0 ;;
        *) fail "expected COMMIT:<sha>, got: $out" ;;
    esac
    assertEquals 'author name = raw svn username' 'alice' "$(git -C "$REPO" log -1 --format='%an')"
    assertEquals 'author email empty (<>)' '' "$(git -C "$REPO" log -1 --format='%ae')"
    local aiso
    aiso="$(git -C "$REPO" log -1 --format='%aI')"
    case "$aiso" in
        2026-05-26T12:00:00*) assertTrue 'author-date = SVN date' 0 ;;
        *) fail "author-date not the SVN date: $aiso" ;;
    esac
    assertEquals 'svn-revision trailer = 7' '7' "$(git -C "$REPO" log -1 --format='%(trailers:key=svn-revision,valueonly)' | tr -d '[:space:]')"
    # committer-date is the replay moment (>= author date), not the SVN date (KTD6). Just assert
    # the subject is the SVN message so message wiring is confirmed too.
    assertEquals 'commit subject = SVN message' 'add feature' "$(git -C "$REPO" log -1 --format='%s')"
}

# ── Replay: message line beginning with '#' survives (cleanup=whitespace) ──────
test_replay_hash_line_survives() {
    printf 'x\n' > "$REPO/h.txt"
    svn_replay_commit "$REPO" 8 bob '2026-05-27T00:00:00.000000Z' $'#42 hotfix\nbody' >/dev/null
    local body
    body="$(git -C "$REPO" log -1 --format='%B')"
    case "$body" in
        '#42 hotfix'*) assertTrue "'#'-leading subject preserved" 0 ;;
        *) fail "'#' message line was stripped: $body" ;;
    esac
}

# ── Replay: empty delta -> SKIP:empty, no commit minted ───────────────────────
test_replay_empty_delta_skips() {
    local before after out
    before="$(git -C "$REPO" rev-list --count HEAD)"
    out="$(svn_replay_commit "$REPO" 9 bob '2026-05-28T00:00:00.000000Z' 'no tree change')"
    after="$(git -C "$REPO" rev-list --count HEAD)"
    assertEquals 'empty delta signals SKIP:empty' 'SKIP:empty' "$out"
    assertEquals 'no commit minted on empty delta' "$before" "$after"
}

# ── Replay: idempotent -> SKIP:idempotent when trailer already on HEAD ─────────
test_replay_idempotent_skips() {
    printf 'one\n' > "$REPO/r11.txt"
    svn_replay_commit "$REPO" 11 carol '2026-05-29T00:00:00.000000Z' 'rev eleven' >/dev/null
    local before after out
    before="$(git -C "$REPO" rev-list --count HEAD)"
    # even with a fresh working-tree change, re-replaying r11 must NOT mint a duplicate.
    printf 'changed\n' > "$REPO/r11.txt"
    out="$(svn_replay_commit "$REPO" 11 carol '2026-05-29T00:00:00.000000Z' 'rev eleven again')"
    after="$(git -C "$REPO" rev-list --count HEAD)"
    assertEquals 'idempotent replay signals SKIP:idempotent' 'SKIP:idempotent' "$out"
    assertEquals 'no duplicate commit on idempotent replay' "$before" "$after"
}

# ── Floor: nearest <= R when no exact match ───────────────────────────────────
test_floor_nearest_below() {
    _commit_with_trailer "$REPO" a.txt aa 'trunk five' 5
    _commit_with_trailer "$REPO" b.txt bb 'trunk ten' 10
    local sha5 sha10 got
    sha5="$(git -C "$REPO" log --grep='^svn-revision: 5$' -E --format='%H' main)"
    sha10="$(git -C "$REPO" log --grep='^svn-revision: 10$' -E --format='%H' main)"
    got="$(svn_floor_commit_for_rev "$REPO" 7)"
    assertEquals 'floor(7) = the r5 commit (nearest <= 7)' "$sha5" "$got"
    got="$(svn_floor_commit_for_rev "$REPO" 10)"
    assertEquals 'floor(10) = the r10 commit (exact)' "$sha10" "$got"
    got="$(svn_floor_commit_for_rev "$REPO" 20)"
    assertEquals 'floor(20) = the r10 commit (highest <= 20)' "$sha10" "$got"
}

# ── Floor: empty when no commit <= R exists ───────────────────────────────────
test_floor_empty_when_none_below() {
    _commit_with_trailer "$REPO" a.txt aa 'trunk five' 5
    local got
    got="$(svn_floor_commit_for_rev "$REPO" 3)"
    assertEquals 'floor(3) empty when nothing <= 3' '' "$got"
}

# ── Floor: fail-loud when the chosen value is carried by two commits ──────────
test_floor_fail_loud_on_duplicate() {
    _commit_with_trailer "$REPO" a.txt aa 'dup one' 4
    _commit_with_trailer "$REPO" b.txt bb 'dup two' 4
    local out rc
    out="$(svn_floor_commit_for_rev "$REPO" 6 2>&1)"; rc=$?
    assertNotEquals 'duplicate trailer value fails loud (non-zero)' 0 "$rc"
    case "$out" in
        *ambiguous*|*'non-unique'*) assertTrue 'duplicate error message explains ambiguity' 0 ;;
        *) fail "duplicate error message unexpected: $out" ;;
    esac
}

# ── Floor: scoped to main, never HEAD ─────────────────────────────────────────
test_floor_scoped_to_main_not_head() {
    _commit_with_trailer "$REPO" a.txt aa 'trunk five' 5
    # A commit carrying r99 exists ONLY on a side branch (reachable from HEAD if checked out,
    # but NOT from main). Floor must ignore it.
    git -C "$REPO" checkout -q -b side
    _commit_with_trailer "$REPO" side.txt ss 'side ninety-nine' 99
    git -C "$REPO" checkout -q main
    local got sha5
    sha5="$(git -C "$REPO" log --grep='^svn-revision: 5$' -E --format='%H' main)"
    got="$(svn_floor_commit_for_rev "$REPO" 99)"
    assertEquals 'floor ignores r99 that is off-main' "$sha5" "$got"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
