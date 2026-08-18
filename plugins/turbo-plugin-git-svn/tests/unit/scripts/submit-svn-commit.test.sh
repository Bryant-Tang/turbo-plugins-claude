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

# shellcheck disable=SC1090
. "$SHUNIT2"
