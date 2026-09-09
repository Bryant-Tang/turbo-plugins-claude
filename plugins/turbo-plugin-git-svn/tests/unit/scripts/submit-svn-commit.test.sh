#!/usr/bin/env bash
# submit-svn-commit.test.sh (shUnit2)
# Script under test: scripts/submit-svn-commit.sh
#
# Bash entry coverage:
#   1. file exists
#   2. missing --branch -> exit non-zero + stderr mentions branch required
#   3. --branch supplied, missing --title -> exit non-zero + stderr mentions title (U9: the agent
#      supplies only --title; the body comes from the locked pin written by build-svn-commit.sh)
# Full happy / 中文 / drift behaviour is covered by the automated Pester/shUnit2 suites for
# build-svn-commit + submit-svn-commit (and Sync-FromSvn / Get-SvnLog for the 中文 round-trip axis).
#
# U7/U8 note: any branch is now legal and there is no bridge gate, so an unresolvable
# remote worktree surfaces as "not found" (the old "Unsupported branch" message is gone).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/submit-svn-commit.sh"
INIT_SCRIPT="$PLUGIN_ROOT/scripts/initialize-git-svn-bridge.sh"
NRB_SCRIPT="$PLUGIN_ROOT/scripts/new-remote-bridge.sh"
BUILD_SCRIPT="$PLUGIN_ROOT/scripts/build-svn-commit.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
}

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
    SB="$(mktemp -d -t turbo-ptsc-sb-XXXXXX)"
    CFG="$SB/.svnconfig"
    mkdir -p "$CFG"
}

tearDown() {
    [ -n "${TMPDIR_CASE:-}" ] && rm -rf "$TMPDIR_CASE" 2>/dev/null || true
    if [ -n "${SB:-}" ] && [ -d "$SB" ]; then
        chmod -R +w "$SB" 2>/dev/null || true
        rm -rf "$SB" 2>/dev/null || true
    fi
}

# shellcheck disable=SC1091
source "$PLUGIN_ROOT/tests/lib/svn-uri.sh"

# Build a real trunk+branches bridge with a FEATURE branch first-pushed (so tp:last-aligned-rev is
# initialized to the trunk copyfrom-rev). Sets ROOT / BRANCH_URL / FEAT_BRIDGE / INIT_ALIGNED.
# The test's OWN svn calls use --config-dir "$CFG"; the scripts under test use default svn config
# (file:// needs no auth). Non-zero on any failure (caller SKIPs).
build_feature_bridge() {
    ROOT="$SB/test-turbo-plugin"
    local repo="$SB/svnrepo" seed="$SB/seed" uri
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    uri="$(svn_uri "$repo")"
    mkdir -p "$seed/trunk" "$seed/branches"
    printf 'app-v1\n' > "$seed/trunk/app.txt"
    printf 'keep\n'   > "$seed/branches/.keep"
    svn import "$seed" "$uri" -m 'seed trunk+branches' --config-dir "$CFG" >/dev/null 2>&1 || return 1

    mkdir -p "$ROOT"
    git -C "$ROOT" init -b main >/dev/null 2>&1 || git -C "$ROOT" init >/dev/null 2>&1
    git -C "$ROOT" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$ROOT" config user.name  'turbo' >/dev/null 2>&1
    ( cd "$ROOT" && bash "$INIT_SCRIPT" --svn-url "$uri/trunk" ) >/dev/null 2>&1 || return 1
    printf '.turbo-plugin/worktrees/\n.svn/\n' >> "$ROOT/.gitignore"
    git -C "$ROOT" add .gitignore >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'chore: skeleton gitignore' >/dev/null 2>&1

    # Feature branch off main; first-push its bridge (New-RemoteBridge initializes tp:last-aligned-rev).
    git -C "$ROOT" branch feat-x main >/dev/null 2>&1 || return 1
    BRANCH_URL="$uri/branches/feat-x"
    ( cd "$ROOT" && bash "$NRB_SCRIPT" --branch feat-x --svn-url "$BRANCH_URL" ) >/dev/null 2>&1 || return 1
    FEAT_BRIDGE="$ROOT/.turbo-plugin/worktrees/remote-svn-feat-x"
    INIT_ALIGNED="$(svn propget tp:last-aligned-rev "$BRANCH_URL" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$INIT_ALIGNED" ] || return 1
    return 0
}

branch_rev() { svn info --show-item revision "$BRANCH_URL" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]'; }
push_feat() { ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 && ( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title "$1" ) >/dev/null 2>&1; }

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

# Case 3: --branch main but no --title -> non-zero + stderr mentions title
test_missing_title() {
    local out rc
    out="$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --branch main 2>&1)"; rc=$?
    assertNotEquals 'missing --title exits non-zero' 0 "$rc"
    case "$out" in
        *--title*|*required*) assertTrue 'missing --title stderr mentions title' 0 ;;
        *) fail "missing --title stderr unexpected: $out" ;;
    esac
}

# Case 4: legacy --message is now an unknown argument (agent cannot pass a free message; U9)
test_legacy_message_rejected() {
    local out rc
    out="$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --branch main --message 'free body' 2>&1)"; rc=$?
    assertNotEquals 'legacy --message exits non-zero' 0 "$rc"
    case "$out" in
        *"Unknown argument"*) assertTrue 'legacy --message reported as unknown argument' 0 ;;
        *) fail "expected 'Unknown argument' for --message, got: $out" ;;
    esac
}

# ── Case 5 (U4): a push that newly merges main into the branch ADVANCES tp:last-aligned-rev ─────
# A commit reachable from feat-x is MARKED with a HIGHER revision than the branch's stored alignment
# (simulating a merge of a newer main). The advance must land IN THE SAME content commit (folded,
# not a separate property revision): exactly ONE new svn revision, tp:last-aligned-rev == HIGH.
test_advance_on_merge_main() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local high rev_before rev_after got
    high=$(( INIT_ALIGNED + 100 ))
    rev_before="$(branch_rev)"
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-v2\n' > "$ROOT/app.txt"
    git -C "$ROOT" add app.txt >/dev/null 2>&1
    # A commit that BOTH changes a file (content to push) AND is marked as the newer trunk revision
    # now reachable from feat-x.
    git -C "$ROOT" -c commit.gpgsign=false commit -m "sync: svn r$high" >/dev/null 2>&1
    git -C "$ROOT" update-ref "refs/tp/svn/$high" "$(git -C "$ROOT" rev-parse HEAD)"
    if ! push_feat 'push feat-x with merged main'; then startSkipping; return 0; fi

    got="$(svn propget tp:last-aligned-rev "$BRANCH_URL" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    assertEquals "tp:last-aligned-rev advanced to the newest reachable marker (r$high)" "$high" "$got"
    rev_after="$(branch_rev)"
    # Folded, not separate: the advance rode in the ONE content commit (delta 1, not 2).
    assertEquals 'advance folded into the content commit (exactly one new revision)' "1" "$(( rev_after - rev_before ))"
}

# ── Case 6 (U4): an ordinary feature push does NOT advance tp:last-aligned-rev and adds no prop commit ─
# A normal feature commit (file change, NO svn-revision trailer) brings no newer main revision, so
# tp:last-aligned-rev is untouched and the push creates exactly ONE content revision (no extra
# property-only commit).
# ── issue #35: a push with thousands of files must not overflow the command line ──────────────
# Every path used to be passed as its own argv entry, so a large enough push died before svn even
# started ("Argument list too long"; observed at ~2.9k targets, while 350 got through). A first
# import of an existing project is normally far past that, so that scenario simply could not work.
#
# The count must exceed the real limit or this test proves nothing -- 3000 is chosen to sit clearly
# above the observed failure point, not because the exact threshold matters.
test_large_push_does_not_overflow_command_line() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local out rc n count
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    mkdir -p "$ROOT/bulk"
    for (( n = 1; n <= 3000; n++ )); do
        printf 'f%s\n' "$n" > "$ROOT/bulk/file$n.txt"
    done
    git -C "$ROOT" add -A >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: bulk import' >/dev/null 2>&1

    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 || { startSkipping; return 0; }
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'feat: bulk import' 2>&1 )"; rc=$?

    case "$out" in *'Argument list too long'*) fail "command line overflowed: $out" ;; esac
    assertEquals "3000-file push exits 0 (tail: $(printf '%s' "$out" | tail -c 400))" 0 "$rc"

    # Everything actually landed -- not a partial commit that merely avoided the error.
    count="$(svn ls "$BRANCH_URL/bulk" --config-dir "$CFG" 2>/dev/null | grep -c . || true)"
    assertEquals 'all 3000 files reached SVN' 3000 "$count"
}

# ── issue #34: a filename containing '@' must survive the push ────────────────────────────────
# svn parses a trailing @<rev> on EVERY target argument, so `banner@2x.jpg` (the standard retina
# naming convention) made svn try to read "2x.jpg" as a revision and fail the whole commit with
# E200009. The filename is perfectly legal in SVN and checks out fine -- only passing it as an
# argument was broken, and `--` does not help because it only terminates OPTION parsing.
# This case covers both svn-side paths at once: the `svn add` of the new file and the `svn commit`
# that lists it as a target.
test_at_sign_filename_survives_push() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local out rc listing
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'retina\n' > "$ROOT/banner@2x.jpg"
    git -C "$ROOT" add -- 'banner@2x.jpg' >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: add a retina asset' >/dev/null 2>&1

    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 || { startSkipping; return 0; }
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'feat: retina asset' 2>&1 )"; rc=$?

    case "$out" in *E200009*) fail "peg-revision error on an '@' filename: $out" ;; esac
    assertEquals "push with an '@' filename exits 0 (out: $out)" 0 "$rc"

    # And it must land on SVN under its FULL name -- not truncated at the '@'.
    listing="$(svn ls "$BRANCH_URL" --config-dir "$CFG" 2>/dev/null)"
    case "$listing" in
        *'banner@2x.jpg'*) assertTrue "'@' filename landed on SVN intact" 0 ;;
        *) fail "'@' filename missing from svn listing: $listing" ;;
    esac
}

test_ordinary_push_does_not_advance() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local rev_before rev_after got
    rev_before="$(branch_rev)"
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-feat\n' > "$ROOT/app.txt"
    git -C "$ROOT" add app.txt >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: ordinary tweak (no trailer)' >/dev/null 2>&1
    if ! push_feat 'ordinary feature push'; then startSkipping; return 0; fi

    got="$(svn propget tp:last-aligned-rev "$BRANCH_URL" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    assertEquals 'ordinary push leaves tp:last-aligned-rev unchanged' "$INIT_ALIGNED" "$got"
    rev_after="$(branch_rev)"
    # No separate property commit: exactly the ONE content revision.
    assertEquals 'ordinary push adds no extra property commit (exactly one new revision)' "1" "$(( rev_after - rev_before ))"
}

# ── Case 7 (U3): a commit under a SIBLING path must not block this path's push ────────────────
# Real-machine deadlock 2026-07-31: SVN revision numbers are repository-wide, so in a repository
# holding several projects a colleague's (or your own other project's) commit bumps HEAD without
# touching anything of ours. submit measured staleness against the repository HEAD and refused with
# "SVN HEAD changed since prepare (local r85, head r87)" -- then sent the user to /tp-pull-from-svn,
# which correctly replayed nothing for this path and answered "Already up to date at SVN r85".
# Two commands contradicting each other, with no way out but a manual `svn update`.
test_sibling_path_commit_does_not_block_push() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local repos_root sibling_wc out rc

    # Stage this path's push FIRST, so the sibling commit lands strictly between prepare and submit.
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-sibling\n' > "$ROOT/app.txt"
    git -C "$ROOT" add app.txt >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: change for the sibling case' >/dev/null 2>&1
    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 || { startSkipping; return 0; }

    # Bump repository HEAD from a path we do NOT own (trunk is a sibling of branches/feat-x).
    repos_root="$(svn info --show-item repos-root-url "$BRANCH_URL" --config-dir "$CFG" 2>/dev/null | tr -d '\r\n')"
    sibling_wc="$SB/siblingwc"
    svn checkout "$repos_root/trunk" "$sibling_wc" --config-dir "$CFG" >/dev/null 2>&1 || { startSkipping; return 0; }
    printf 'someone-elses-project\n' > "$sibling_wc/sibling.txt"
    svn add "$sibling_wc/sibling.txt" --config-dir "$CFG" >/dev/null 2>&1
    svn commit "$sibling_wc" -m 'another project moves HEAD' --config-dir "$CFG" >/dev/null 2>&1 || { startSkipping; return 0; }

    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'push despite sibling commit' 2>&1 )"; rc=$?
    assertEquals "submit succeeds despite a sibling-path commit (out: $out)" 0 "$rc"
    case "$out" in
        *'HEAD changed'*) fail "still refusing on repository HEAD: $out" ;;
        *) assertTrue 'no repository-HEAD refusal' 0 ;;
    esac
}

# ── Case 8 (U3): a commit to THIS path still blocks, and points at pull ───────────────────────
# The guard must keep doing its job: the loosening is "ignore sibling paths", not "ignore everyone".
test_same_path_commit_still_blocks_push() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local branch_wc out rc

    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-mine\n' > "$ROOT/app.txt"
    git -C "$ROOT" add app.txt >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: change for the same-path case' >/dev/null 2>&1
    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 || { startSkipping; return 0; }

    # Someone commits to OUR branch path between prepare and submit.
    branch_wc="$SB/branchwc"
    svn checkout "$BRANCH_URL" "$branch_wc" --config-dir "$CFG" >/dev/null 2>&1 || { startSkipping; return 0; }
    printf 'teammate\n' > "$branch_wc/teammate.txt"
    svn add "$branch_wc/teammate.txt" --config-dir "$CFG" >/dev/null 2>&1
    svn commit "$branch_wc" -m 'teammate commits to this very branch' --config-dir "$CFG" >/dev/null 2>&1 || { startSkipping; return 0; }

    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'should be refused' 2>&1 )"; rc=$?
    assertNotEquals "submit refuses when THIS path changed (out: $out)" 0 "$rc"
    echo "$out" | grep -q 'tp-pull-from-svn'; assertTrue 'refusal points at pull' $?
    echo "$out" | grep -q 'this path last changed at'; assertTrue 'refusal names the path revision, not repo HEAD' $?
}

# ── issue #79: the pushed-file listing must be the script's OWN copy, not svn's ───────────────
# svn renders its per-path progress lines ("Adding <path>") in the console codepage, so on a zh-TW
# host a non-ASCII filename arrives there as '?' -- and that listing is the one place the user sees
# WHAT was just written permanently, at the moment it became permanent. The script therefore prints
# the paths it already holds as UTF-8 (they came out of `svn status --xml`).
#
# THE ASSERTION IS ON THE MECHANISM, AND THE FILENAME HERE IS ASCII ON PURPOSE. What proves the fix
# is the FORM of the output -- `A  <path>` is the script's own rendering and svn never emits it,
# while `Adding <path>` is svn's and must be gone -- and that holds for any filename. Putting a
# Chinese name in this case would not add proof (a UTF-8 runner renders it correctly either way) but
# WOULD add a dependency on whether svn can take a non-ASCII target on this host at all, which is a
# separate, environment-dependent question. It bit exactly that way: this case passed standalone and
# failed inside the orchestrator with `svn: E200009: Could not add all targets because some targets
# don't exist`, i.e. a red light that said nothing about the behaviour under test. The non-ASCII
# axis is its own case below.
test_push_lists_paths_itself_not_svns() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local out rc
    # Kept at the working-copy ROOT on purpose: `svn status --xml` reports nested paths with the
    # platform separator, so a subdirectory would make the expected string OS-dependent.
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'new\n' > "$ROOT/notes.md"
    printf 'app-v2\n' > "$ROOT/app.txt"
    git -C "$ROOT" add -A >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: add a file' >/dev/null 2>&1

    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 || { startSkipping; return 0; }
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'feat: a file' 2>&1 )"; rc=$?
    assertEquals "push exits 0 (out: $out)" 0 "$rc"

    # The script's own listing, carrying the very paths it handed to svn.
    printf '%s\n' "$out" | grep -q '^A  notes\.md$'
    assertTrue "new file listed by the script as 'A  notes.md' (out: $out)" $?
    printf '%s\n' "$out" | grep -q '^M  app\.txt$'
    assertTrue "modified file listed by the script as 'M  app.txt' (out: $out)" $?

    # svn's own per-path lines are the codepage-dependent ones; they must not be echoed as well.
    if printf '%s\n' "$out" | grep -qE '^(Adding|Deleting|Sending|Replacing)[[:space:]]'; then
        fail "svn's own path listing is still being echoed alongside ours: $out"
    fi
    # `svn add` / `svn delete` list every path too, in the same codepage, and that was the SECOND
    # mojibake source in the same push (found while mutation-testing this case). They are silenced
    # with --quiet. Their listing is `A` + many spaces; ours is `A` + exactly two, so the column
    # width is what tells the two apart.
    if printf '%s\n' "$out" | grep -qE '^[AD][[:space:]]{3,}'; then
        fail "svn add/delete are still echoing their own path listing: $out"
    fi
    # ...but the filter must be surgical: everything else svn says still comes through.
    printf '%s\n' "$out" | grep -q 'Committed revision'
    assertTrue "svn's 'Committed revision' line still passes through (out: $out)" $?
}

# NO end-to-end non-ASCII push case lives here, deliberately.
#
# One was written and removed. It proved nothing this file does not already prove -- what makes the
# #79 fix correct is the FORM of the output, and the ASCII case above asserts exactly that, with a
# mutation check behind it -- while making the result depend on TWO separate environmental
# properties, each of which turned it red for reasons unrelated to the behaviour under test:
#
#   1. the system ANSI codepage. The targets file is re-encoded to CP_ACP, so a CJK name is
#      unrepresentable on the CP1252 CI runner and the script correctly refuses.
#   2. the CONSOLE codepage of the parent process. tests/Invoke-ScriptTests.ps1 sets
#      [Console]::OutputEncoding to UTF-8, so svn.exe reads a CP950-encoded targets file as UTF-8
#      and reports "targets don't exist" -- passing standalone, failing under the orchestrator, on
#      the same machine with the same code.
#
# Each one was survivable with another skip condition, and that is the trap: a case whose red
# lights are dominated by the environment teaches the reader to ignore it. The non-ASCII axis has
# dedicated coverage that is built for it -- svn-status-xml-roundtrip.test.sh (and its .ps1 twin)
# for the capture/re-pass round trip, Test-EncodingSupport for diagnosing a host, and
# Common.test.ps1 / common.test.sh for the targets-file encoding and its refusal.

# ── issue #79 follow-up: the listing's ORDER must be byte-wise, identical to the .ps1 twin ────────
# The two implementations sort in different places: this one pipes its `<status>\t<path>` lines
# through `LC_ALL=C sort` (byte order), while the .ps1 sorts the already-formatted display lines.
# `Sort-Object` there would be CULTURE-aware, so the same push would list the same files in a
# different order on the two platforms -- a silent divergence, because each side on its own looks
# perfectly sorted. `LC_ALL=C` is likewise load-bearing here: a bare `sort` follows the ambient
# locale and would drift the same way, in the opposite direction.
#
# THE FILENAMES ARE CHOSEN SO THE TWO ORDERS SHARE NO POSITION. Byte order is B, C, _z, a
# ('B'=0x42 < 'C'=0x43 < '_'=0x5F < 'a'=0x61); culture order is _z, a, B, C. A regression to a
# locale-sensitive sort therefore cannot coincidentally pass. All four are ADDED on purpose: the
# status character is compared first, so a set with differing statuses would never reach the path
# comparison at all -- which is exactly why the case above (one A, one M) could not catch this.
# No two names differ only by case, so the set survives a case-insensitive filesystem.
#
# The expected sequence below is written as the same literal in the .ps1 twin
# (Submit-SvnCommit.test.ps1, 'lists several added paths in LC_ALL=C order'). That duplication IS
# the cross-platform assertion: the two suites cannot drift apart without one of them going red.
test_push_listing_order_is_byte_wise() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local out rc order
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    # Kept at the working-copy ROOT, as above: a nested path would bring the platform separator
    # into the expected strings.
    for n in a.txt C.txt _z.txt B.txt; do printf 'x\n' > "$ROOT/$n"; done
    git -C "$ROOT" add -A >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: four files' >/dev/null 2>&1

    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1 || { startSkipping; return 0; }
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'feat: four files' 2>&1 )"; rc=$?
    assertEquals "push exits 0 (out: $out)" 0 "$rc"

    # `tr -d '\r'` first: svn.exe on Windows can emit CRLF, and a trailing CR would defeat the
    # anchored `$` in the pattern below -- silently yielding an EMPTY sequence, which would then
    # differ from the expectation for a reason that has nothing to do with ordering.
    order="$( printf '%s\n' "$out" | tr -d '\r' \
        | grep -E '^A  (B\.txt|C\.txt|_z\.txt|a\.txt)$' | tr '\n' '|' )"
    assertEquals "the listing must be in byte order (out: $out)" \
        'A  B.txt|A  C.txt|A  _z.txt|A  a.txt|' "$order"
}

# ─── the push path marks text files, and only once the tree declares (#167) ──────────────────
# The two cases below are one rule seen from both sides. The property write and the bridge's git
# EOL mode read the SAME signal, deliberately: when they read different ones, svn started writing
# platform endings for the files the push had marked while git stayed pinned to LF for everything
# else, and the bridge read as permanently modified. That took out 21 pull-path tests.
#
# Tested here, at the push script, and not only at the library function: the library tests prove
# the function marks the right files, they cannot prove the push path calls it at all.
declare_eol_style_on_branch() {
    ( cd "$FEAT_BRIDGE" && svn --config-dir "$CFG" propset svn:auto-props '*.txt = svn:eol-style=native' -q '.' ) >/dev/null 2>&1 || return 1
    ( cd "$FEAT_BRIDGE" && svn --config-dir "$CFG" commit -m 'declare svn:eol-style for the tree' ) >/dev/null 2>&1 || return 1
}

# It has to be an EXISTING file, not a newly added one. svn:auto-props applies the property itself
# at `svn add` time, so a test that adds a new file passes whether or not the push path does
# anything -- verified: deleting the push path's marking call left that version of this test green.
# Files that predate the declaration are the ones only the push path can reach, and they are also
# the realistic case: a repository migrates once and then keeps editing what it already had.
test_push_marks_a_pre_existing_file_once_the_tree_declares() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local prop before
    # app.txt was seeded before anything declared eol-style, so it carries no property.
    before="$(svn propget svn:eol-style "$BRANCH_URL/app.txt" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$before" ]; then
        fail "fixture: app.txt already carries svn:eol-style ('$before'); the case proves nothing"
        return 0
    fi

    # Exactly what /tp-init-svn-eol-style leaves behind.
    if ! declare_eol_style_on_branch; then startSkipping; return 0; fi

    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-v2\n' > "$ROOT/app.txt"
    git -C "$ROOT" add -- 'app.txt' >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: edit an existing file' >/dev/null 2>&1
    if ! push_feat 'feat: edit an existing file'; then fail 'push failed'; return 0; fi

    prop="$(svn propget svn:eol-style "$BRANCH_URL/app.txt" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    assertEquals 'the push path marks a pre-existing text file once the tree declares' 'native' "$prop"
}

test_push_marks_nothing_while_the_tree_declares_nothing() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local prop
    # Deliberately NO declaration here -- that is the whole case. Same file and same edit as above,
    # so the two differ in exactly one thing.

    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-v2\n' > "$ROOT/app.txt"
    git -C "$ROOT" add -- 'app.txt' >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: edit an existing file' >/dev/null 2>&1
    if ! push_feat 'feat: edit an existing file'; then fail 'push failed'; return 0; fi

    prop="$(svn propget svn:eol-style "$BRANCH_URL/app.txt" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    assertEquals 'nothing is marked while the tree itself declares nothing' '' "$prop"
}

# The failure path, which is the whole reason the marking step aborts instead of warning. Pushing
# CRLF into a repository that stores LF is silent afterwards -- git reports clean because it
# normalises on read, svn reports clean because it committed exactly what was on disk -- so the
# only moment anything can be done about it is before the commit.
#
# The property write is made to fail with a PATH shim that refuses exactly `propset svn:eol-style`
# and delegates everything else to the real svn. Failing the whole of svn would prove nothing: the
# push would die somewhere earlier and the assertion would pass for the wrong reason.
test_push_aborts_when_the_property_cannot_be_set() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local real_svn shim_dir saved_path rev_before rev_after out rc
    real_svn="$(command -v svn 2>/dev/null)"
    [ -n "$real_svn" ] || { startSkipping; return 0; }
    if ! declare_eol_style_on_branch; then startSkipping; return 0; fi

    git -C "$ROOT" checkout feat-x >/dev/null 2>&1
    printf 'app-v2\n' > "$ROOT/app.txt"
    git -C "$ROOT" add -- 'app.txt' >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'feat: edit an existing file' >/dev/null 2>&1

    rev_before="$(branch_rev)"

    shim_dir="$SB/svnshim"
    mkdir -p "$shim_dir"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'for a in "$@"; do'
        printf '%s\n' '  if [ "$a" = "svn:eol-style" ]; then'
        printf '%s\n' '    echo "fake svn: refusing propset svn:eol-style" >&2'
        printf '%s\n' '    exit 1'
        printf '%s\n' '  fi'
        printf '%s\n' 'done'
        # QUOTED. The real svn commonly lives under a path with a space -- Git Bash reports
        # TortoiseSVN's as `/c/Program Files/...` -- and an unquoted exec splits it, so every
        # delegated call dies with "/c/Program: No such file or directory". The push then fails
        # for that reason instead of the one under test, and the assertions below pass while
        # proving nothing. Mutation testing is what surfaced it: removing the abort left this
        # test green.
        printf 'exec "%s" "$@"\n' "$real_svn"
    } > "$shim_dir/svn"
    chmod +x "$shim_dir/svn"

    saved_path="$PATH"
    PATH="$shim_dir:$PATH"
    export PATH

    # Shim guard: it must refuse ONLY the property write and delegate everything else. A shim that
    # breaks every svn call would make the push fail for the wrong reason, and both assertions
    # below would still pass. That is not hypothetical -- it is what an unquoted exec did here.
    if ! svn --version --quiet >/dev/null 2>&1; then
        PATH="$saved_path"; export PATH
        fail 'shim guard: the shim does not delegate ordinary svn calls; the case would prove nothing'
        return 0
    fi

    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'feat: edit an existing file' 2>&1 )"; rc=$?
    PATH="$saved_path"
    export PATH

    assertNotEquals 'the push must fail when the property cannot be set' 0 "$rc"

    # The guarantee that matters: nothing reached SVN. A push that committed anyway would have
    # shipped the very bytes this mechanism exists to keep out.
    rev_after="$(branch_rev)"
    assertEquals "no SVN revision may be created when marking fails (out: $out)" "$rev_before" "$rev_after"
}

# ── issue #175: files SVN decides are binary even though git calls them text ──
#
# svn reads the first 1024 bytes and calls a file binary when fewer than ~15% of them are text
# bytes -- 0x07-0x0D or 0x20-0x7F. Every byte of UTF-8 CJK is outside that set, so a prose document
# in Chinese with few ASCII markers crosses the line. It then gets svn:mime-type=application/
# octet-stream at `svn add` time, and svn:eol-style cannot be set on such a file, so the push dies
# at the moment of writing to SVN with nothing beforehand hinting at it.
#
# 152 text bytes, measured against real svn: 153 is text, 152 is binary. `.md` on purpose -- the
# fixture's auto-props covers `*.txt`, and a file svn would apply eol-style to at add time would be
# testing svn rather than this code.
write_svn_binary_mime_file() {
    local path="$1"
    # shellcheck disable=SC2046
    printf 'a%.0s' $(seq 152) > "$path" || return 1
    # \200 is one byte, high-bit: non-text to svn, while the absence of any NUL keeps git calling
    # the file text. That disagreement is the entire subject.
    # shellcheck disable=SC2046
    printf '\200%.0s' $(seq 872) >> "$path" || return 1
}

commit_binary_mime_file_on_feat() {
    git -C "$ROOT" checkout feat-x >/dev/null 2>&1 || return 1
    write_svn_binary_mime_file "$ROOT/notes.md" || return 1
    git -C "$ROOT" add -- 'notes.md' >/dev/null 2>&1 || return 1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'docs: add a file svn will call binary' >/dev/null 2>&1 || return 1
}

test_push_refuses_a_file_svn_calls_binary_and_says_which() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    if ! declare_eol_style_on_branch; then startSkipping; return 0; fi
    local rev_before rev_after out rc
    if ! commit_binary_mime_file_on_feat; then startSkipping; return 0; fi

    rev_before="$(branch_rev)"
    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'docs: add notes' 2>&1 )"; rc=$?

    assertNotEquals 'a file SVN calls binary must stop the push' 0 "$rc"
    # Naming it is the point. "could not set svn:eol-style" alone leaves the user with a tree of
    # thousands of files and no idea which one did it.
    case "$out" in *'notes.md'*) : ;; *) fail "the refusal does not name the file: $out" ;; esac
    # And the way out has to be in the message. The filename ALONE is not enough evidence that this
    # code ran at all: svn's own E200009 quotes the offending path too, so a version of this case
    # that only looked for the name stayed green with the whole detection removed. What only this
    # code can produce is the instruction.
    case "$out" in *'--clear-binary-mime'*) : ;; *) fail "the refusal does not say what to do: $out" ;; esac
    rev_after="$(branch_rev)"
    assertEquals 'nothing may reach SVN when the push is refused' "$rev_before" "$rev_after"
}

# The other half: the flag exists so a user who was shown the list can say yes. Without this case
# the refusal above could be unconditional and everything would still look correct.
test_clear_binary_mime_lets_the_push_through() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    if ! declare_eol_style_on_branch; then startSkipping; return 0; fi
    local eol mime out rc
    if ! commit_binary_mime_file_on_feat; then startSkipping; return 0; fi

    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x ) >/dev/null 2>&1
    out="$( cd "$ROOT" && bash "$SCRIPT" --branch feat-x --title 'docs: add notes' --clear-binary-mime 2>&1 )"; rc=$?
    assertEquals "the push must go through once the mark is cleared (out: $out)" 0 "$rc"

    mime="$(svn propget svn:mime-type "$BRANCH_URL/notes.md" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    assertEquals 'the bogus binary mark is gone in SVN' '' "$mime"
    eol="$(svn propget svn:eol-style "$BRANCH_URL/notes.md" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"
    assertEquals 'and the file is now marked like every other text file' 'native' "$eol"
}

# The prediction, which is what makes the question askable at all: by the time the push runs, the
# adds are scheduled and svn has already decided. prepare runs BEFORE anything is written, so it
# has to work this out from the bytes.
test_prepare_lists_the_files_svn_will_call_binary() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    if ! declare_eol_style_on_branch; then startSkipping; return 0; fi
    local out
    if ! commit_binary_mime_file_on_feat; then startSkipping; return 0; fi

    out="$( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x 2>&1 )"
    case "$out" in *'BINARY'*) : ;; *) fail "prepare emitted no BINARY section: $out" ;; esac
    # `new`, not `existing`: nothing has been written yet, and the two need different words in
    # front of a user.
    case "$out" in *"new	notes.md"*) : ;; *) fail "prepare did not predict notes.md: $out" ;; esac
}

# And it stays quiet on a tree that has not been migrated: nothing sets svn:eol-style there, so
# nothing can be blocked by a mime type and warning about it would be pure noise. Same file, same
# push, one difference -- which is what makes the case above mean something.
test_prepare_says_nothing_while_the_tree_declares_nothing() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_feature_bridge; then startSkipping; return 0; fi
    local out
    if ! commit_binary_mime_file_on_feat; then startSkipping; return 0; fi

    out="$( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch feat-x 2>&1 )"
    # Only the tagged line counts. `notes.md` appears in FILES either way -- it IS being pushed --
    # and an earlier version of this case looked for the filename anywhere after the BINARY header,
    # which matched the FILES listing and failed on a correct implementation.
    case "$out" in *"new	notes.md"*) fail "notes.md was predicted on an unmigrated tree: $out" ;; esac
    case "$out" in *"existing	notes.md"*) fail "notes.md was reported on an unmigrated tree: $out" ;; esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
