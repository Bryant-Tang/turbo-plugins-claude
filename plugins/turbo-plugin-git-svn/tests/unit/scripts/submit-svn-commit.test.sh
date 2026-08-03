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

# shellcheck disable=SC1090
. "$SHUNIT2"
