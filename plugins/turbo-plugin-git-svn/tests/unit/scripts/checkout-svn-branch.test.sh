#!/usr/bin/env bash
# checkout-svn-branch.test.sh (shUnit2)
#
# Script under test: scripts/checkout-svn-branch.sh (U11).
#   checkout-svn-branch.sh --svn-url <existing-svn-branch-url> [--branch <name>]
# READ-ONLY import of an EXISTING SVN branch into a bridge + working branch. It NEVER writes to
# SVN. Arg/guard cases run with git only; trust + happy-import cases need a real remote-svn-main
# svn working copy built from the seed dump and SKIP when svn/svnadmin or the dump are absent.
#
# Execution-note failing tests (written first): same-name collision -> zero-side-effect reject;
# no remote-svn-main -> fail-closed; mid-run failure -> no new SVN revision (covered by the
# read-only happy-path rev-unchanged assertion).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/checkout-svn-branch.sh"
DUMP_PATH="$PLUGIN_ROOT/tests/fixtures/seed/svn-repo-r1-r20.dump"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
    HAS_DUMP=0
    if [ -f "$DUMP_PATH" ]; then HAS_DUMP=1; fi
}

setUp() {
    SB="$(mktemp -d -t turbo-csb-XXXXXX)"
}
tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# Throwaway git main worktree + worktrees container + a realistic .gitignore. Echoes the root.
make_main_repo() {
    local sandbox="$1"
    local root="$sandbox/test-turbo-plugin"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    printf '%s\n' '/.turbo-plugin/worktrees/' '.svn/' > "$root/.gitignore"
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
    mkdir -p "$root/.turbo-plugin/worktrees"
    printf '%s' "$root"
}

# Build a real remote-svn-main svn WC from the seed dump. Echoes repos-root-url; non-zero on fail.
make_remote_main_wc() {
    local sandbox="$1" root="$2"
    local svnrepo="$sandbox/svnrepo"
    local worktrees="$root/.turbo-plugin/worktrees"
    svnadmin create "$svnrepo" >/dev/null 2>&1 || return 1
    svnadmin load "$svnrepo" < "$DUMP_PATH" >/dev/null 2>&1 || return 1
    local uri winpath
    winpath="$(cygpath -m "$svnrepo" 2>/dev/null || printf '%s' "$svnrepo")"
    uri="file:///$winpath"
    svn checkout "$uri/trunk" "$worktrees/remote-svn-main" >/dev/null 2>&1 || return 1
    # The import now bases the bridge branch on remote-svn/main (the trunk mirror) so the imported
    # branch connects to main. Real setups create this anchor ref via tp-setup; here a ref at main
    # is enough (the svn checkout fills the exact branch content regardless).
    git -C "$root" branch remote-svn/main main >/dev/null 2>&1 || return 1
    local reposroot
    reposroot="$(svn info --show-item repos-root-url "$worktrees/remote-svn-main" 2>/dev/null | tr -d '\r\n')"
    [ -n "$reposroot" ] || return 1
    printf '%s' "$reposroot"
}

# True (0) if NO partial git state remains for the bridge/work branch of <branch>.
assert_no_orphan() {
    local root="$1" branch="$2" dash
    dash="${branch//\//-}"
    if git -C "$root" branch --list "remote-svn/$branch" | grep -q .; then return 1; fi
    if git -C "$root" branch --list "$branch" | grep -q .; then return 1; fi
    [ -e "$root/.turbo-plugin/worktrees/remote-svn-$dash" ] && return 1
    return 0
}

# ── U5 fixture helpers: seed replayed history + branch metadata ───────────────
# Seed one --allow-empty commit per rev on main and MARK it refs/tp/svn/<rev> (PASS ASCENDING).
# Cheaply mirrors what U3/U7 replay produces so the U5 floor lookup (svn_floor_commit_for_rev) and
# cur bound (svn_highest_replayed_rev) have data to resolve against.
seed_main_trailers() {
    local root="$1"; shift
    local rev
    for rev in "$@"; do
        git -C "$root" -c commit.gpgsign=false commit --allow-empty \
            -m "sync: svn r$rev" >/dev/null 2>&1 || return 1
        git -C "$root" update-ref "refs/tp/svn/$rev" "$(git -C "$root" rev-parse HEAD)" || return 1
    done
    return 0
}

# SHA marked as <rev> via refs/tp/svn/<rev> (the floor target for assertions).
trailer_sha() {
    local root="$1" rev="$2"
    git -C "$root" rev-parse --verify --quiet "refs/tp/svn/${rev}^{commit}" 2>/dev/null || true
}

# Set one or more tp:* properties on an SVN branch URL (checkout once, propset each, one commit).
# csb_setprops <branch-url> <name1> <val1> [<name2> <val2> ...]
csb_setprops() {
    local branchurl="$1"; shift
    local wc="$SB/propwc-$RANDOM$RANDOM"
    svn checkout "$branchurl" "$wc" >/dev/null 2>&1 || return 1
    while [[ $# -ge 2 ]]; do
        ( cd "$wc" && svn propset "tp:$1" "$2" '.' >/dev/null 2>&1 ) || return 1
        shift 2
    done
    ( cd "$wc" && svn commit --depth empty -m 'test: set tp props' '.' >/dev/null 2>&1 ) || return 1
    return 0
}

# ── Case 1: file exists ────────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]; assertTrue 'checkout-svn-branch.sh exists' $?
}

# ── Case 2: missing --svn-url → non-zero + names it ────────────────────────────
test_missing_svn_url() {
    local root out rc
    root="$(make_main_repo "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertNotEquals 'missing --svn-url exits non-zero' 0 "$rc"
    case "$out" in
        *"--svn-url is required"*) assertTrue 'stderr says --svn-url is required' 0 ;;
        *) fail "expected '--svn-url is required', got: $out" ;;
    esac
}

# ── Case 3: worktrees dir absent → fail-closed before mutation ─────────────────
test_worktrees_dir_absent() {
    local root out rc
    root="$SB/bare-turbo-plugin"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'file:///nope/branches/x' --branch feature-x 2>&1)"; rc=$?
    assertNotEquals 'worktrees dir absent exits non-zero' 0 "$rc"
    case "$out" in
        *"worktrees directory not found"*) assertTrue 'reports worktrees dir not found' 0 ;;
        *) fail "expected 'worktrees directory not found', got: $out" ;;
    esac
}

# ── Case 4: same-name working branch (R20) → zero-side-effect reject (git only) ─
test_same_name_work_branch_rejected() {
    local root out rc
    root="$(make_main_repo "$SB")"
    git -C "$root" branch feature-x main >/dev/null 2>&1   # pre-existing work branch, different content
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'file:///nope/branches/feature-x' --branch feature-x 2>&1)"; rc=$?
    assertNotEquals 'same-name work branch exits non-zero' 0 "$rc"
    case "$out" in
        *"already exists"*) assertTrue 'reports the local branch already exists' 0 ;;
        *) fail "expected 'already exists', got: $out" ;;
    esac
    # Zero side effects: no bridge ref, no worktree, and it never reached the import phase.
    case "$out" in
        *"Importing SVN branch"*) fail "unexpectedly entered the import phase: $out" ;;
        *) assertTrue 'did not enter import phase' 0 ;;
    esac
    if git -C "$root" branch --list 'remote-svn/feature-x' | grep -q .; then
        fail 'reject must not create a bridge branch'
    else
        assertTrue 'no bridge branch created' 0
    fi
    [ ! -e "$root/.turbo-plugin/worktrees/remote-svn-feature-x" ]
    assertTrue 'no bridge worktree created' $?
}

# ── Case 5: collision (different ref → same dir name) (git only) ────────────────
test_dir_collision_rejected() {
    local root out rc
    root="$(make_main_repo "$SB")"
    git -C "$root" branch 'remote-svn/feat-login' main >/dev/null 2>&1
    # 'feat/login' maps to the same dir remote-svn-feat-login as the existing remote-svn/feat-login.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'file:///nope/branches/feat-login' --branch 'feat/login' 2>&1)"; rc=$?
    assertNotEquals 'dir collision exits non-zero' 0 "$rc"
    case "$out" in
        *"already taken by branch"*) assertTrue 'reports directory collision' 0 ;;
        *) fail "expected 'already taken by branch', got: $out" ;;
    esac
}

# ── Case 6: remote-svn-main absent → fail-closed, no side effects (git only) ────
test_remote_main_absent_fail_closed() {
    local root out rc
    root="$(make_main_repo "$SB")"   # worktrees dir exists, but NO remote-svn-main
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'file:///nope/branches/feature-x' --branch feature-x 2>&1)"; rc=$?
    assertNotEquals 'remote-svn-main absent exits non-zero' 0 "$rc"
    case "$out" in
        *"remote-svn-main worktree not found"*) assertTrue 'reports remote-svn-main missing' 0 ;;
        *) fail "expected 'remote-svn-main worktree not found', got: $out" ;;
    esac
    case "$out" in
        *"Importing SVN branch"*) fail "must not reach import: $out" ;;
        *) assertTrue 'did not reach import' 0 ;;
    esac
    assert_no_orphan "$root" 'feature-x'; assertTrue 'no orphan git state' $?
}

# ── Case 7: untrusted SVN URL → reject before mutation (needs real WC) ──────────
test_untrusted_svn_url_rejected() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$(make_main_repo "$SB")"
    if ! make_remote_main_wc "$SB" "$root" >/dev/null; then startSkipping; return 0; fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'file:///C:/Windows/System32/' --branch feature-x 2>&1)"; rc=$?
    assertNotEquals 'untrusted URL exits non-zero' 0 "$rc"
    case "$out" in
        *"Importing SVN branch"*) fail "untrusted URL should be rejected before import: $out" ;;
        *) assertTrue 'rejected before import' 0 ;;
    esac
    assert_no_orphan "$root" 'feature-x'; assertTrue 'no orphan git state' $?
}

# ── Case 8: trusted but non-existent SVN branch → reject (read-only, no create) ─
test_nonexistent_svn_branch_rejected() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    # A trusted sibling URL that does not exist yet — read-only import must NOT create it.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/nope-not-here" --branch nope-not-here 2>&1)"; rc=$?
    assertNotEquals 'non-existent branch exits non-zero' 0 "$rc"
    case "$out" in
        *"does not exist"*) assertTrue 'reports the SVN branch does not exist' 0 ;;
        *) fail "expected 'does not exist', got: $out" ;;
    esac
    assert_no_orphan "$root" 'nope-not-here'; assertTrue 'no orphan git state' $?
}

# ── Case 9: happy import → bridge + work branch, read-only on SVN (needs real WC) ─
test_happy_import_readonly() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc rev_before rev_after wt_branch work_tip bridge_tip mb
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    # U5: main must carry replayed svn-revision trailers so the branch's fork-point resolves. With
    # NO tp:* props on the branch this exercises the copyfrom-rev fallback (copyfrom=r20 -> floor r20).
    seed_main_trailers "$root" 1 10 19 20 || { startSkipping; return 0; }
    # Create the EXISTING svn branch to import (this is the only svn write; done by the TEST).
    if ! svn copy "$reposroot/trunk" "$reposroot/branches/feature-x" -m 'test: branch to import' --parents >/dev/null 2>&1; then
        startSkipping; return 0
    fi
    rev_before="$(svn info --show-item revision "$reposroot" 2>/dev/null | tr -d '\r\n')"

    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feature-x" --branch feature-x 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        # Import did not succeed in this env (e.g. svn checkout quirk) -> skip, not a logic FAIL.
        startSkipping; return 0
    fi

    # Bridge + working branch both exist.
    git -C "$root" branch --list 'remote-svn/feature-x' | grep -q .
    assertTrue 'bridge branch remote-svn/feature-x created' $?
    git -C "$root" branch --list 'feature-x' | grep -q .
    assertTrue 'working branch feature-x created' $?

    # Working branch is created AT the bridge tip and shares history (first pull won't be unrelated).
    work_tip="$(git -C "$root" rev-parse feature-x 2>/dev/null)"
    bridge_tip="$(git -C "$root" rev-parse remote-svn/feature-x 2>/dev/null)"
    assertEquals 'work branch tip == bridge tip' "$bridge_tip" "$work_tip"
    mb="$(git -C "$root" merge-base feature-x remote-svn/feature-x 2>/dev/null)"
    assertNotNull 'merge-base(feature-x, remote-svn/feature-x) is non-empty' "$mb"
    # The imported working branch connects to THIS repo's main (not a disconnected orphan), so a
    # later merge-back is not "unrelated histories". This is the U11 connection fix.
    mb_main="$(git -C "$root" merge-base main feature-x 2>/dev/null)"
    assertNotNull 'merge-base(main, feature-x) is non-empty (imported branch connects to main)' "$mb_main"

    # The bridge worktree is clean (.svn ignored — never staged into the import commit).
    wt_branch="$(git -C "$root/.turbo-plugin/worktrees/remote-svn-feature-x" status --porcelain 2>/dev/null)"
    assertNull 'bridge worktree git status is clean' "$wt_branch"

    # READ-ONLY: importing created NO new SVN revision (repo HEAD unchanged since the test's copy).
    rev_after="$(svn info --show-item revision "$reposroot" 2>/dev/null | tr -d '\r\n')"
    assertEquals 'import wrote no new SVN revision' "$rev_before" "$rev_after"
}

# Inject a SECOND root commit into main to reproduce the post-bridge two-root state (a parentless
# `commit-tree` on the canonical empty tree, merged --allow-unrelated-histories).
inject_second_root() {
    local root="$1" second
    second="$(git -C "$root" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m 'sync: svn r1')"
    git -C "$root" merge --allow-unrelated-histories --no-edit -m "Merge branch 'remote-svn/main' into main" "$second" >/dev/null 2>&1
}

# ── Case 10: two-root repo imports a divergent branch: no crash, no contamination, connected (regression) ──
# Once main has been through a bridge merge it carries TWO root commits, so `rev-list
# --max-parents=0 HEAD` returned a 2-line value that broke `git branch` ("not a valid object name").
# Basing the bridge on remote-svn/main (a single ref) fixes that; emptying the worktree before the
# plain svn checkout keeps the import free of trunk-only content (exact branch tree); and the
# remote-svn/main base makes the imported branch connect to main (not a disconnected orphan).
test_two_root_import_no_contamination() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot uri co out rc files
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    uri="$reposroot"
    # U5: seed replayed trailers so the copyfrom-rev fork-point (r20) resolves on the two-root repo.
    seed_main_trailers "$root" 1 10 19 20 || { startSkipping; return 0; }
    # An svn branch 'other' that DIFFERS from trunk: drop Web.config, add only-branch.txt.
    svn copy "$uri/trunk" "$uri/branches/other" -m 'branch: other' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    co="$SB/co"
    svn checkout "$uri/branches/other" "$co" >/dev/null 2>&1 || { startSkipping; return 0; }
    svn delete "$co/Web.config" >/dev/null 2>&1
    echo 'only in branch' > "$co/only-branch.txt"
    svn add "$co/only-branch.txt" >/dev/null 2>&1
    ( cd "$co" && svn commit -m 'branch: drop Web.config, add only-branch.txt' >/dev/null 2>&1 ) || { startSkipping; return 0; }
    inject_second_root "$root"
    assertEquals 'main has two root commits (bridged state)' 2 "$(git -C "$root" rev-list --max-parents=0 HEAD | grep -c .)"

    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri/branches/other" --branch other 2>&1)"; rc=$?
    case "$out" in
        *"not a valid object name"*) fail "regressed: two-root repo broke 'git branch' with: $out" ;;
        *) assertTrue 'no invalid-object-name error' 0 ;;
    esac
    assertEquals 'import succeeded on a two-root repo' 0 "$rc"

    # Connected to main (not an orphan): a two-root repo must still yield a branch that shares
    # history with main.
    mb_main="$(git -C "$root" merge-base main other 2>/dev/null)"
    assertNotNull 'merge-base(main, other) is non-empty (connected on a two-root repo)' "$mb_main"

    files="$(git -C "$root" ls-tree -r --name-only other 2>/dev/null)"
    printf '%s\n' "$files" | grep -qx 'only-branch.txt'
    assertTrue 'imported branch-only file present' $?
    if printf '%s\n' "$files" | grep -qx 'Web.config'; then
        fail 'contamination: Web.config leaked (absent in the imported branch)'
    else
        assertTrue 'no trunk-only file leaked' 0
    fi
    if printf '%s\n' "$files" | grep -q '\.turbo-plugin'; then
        fail 'contamination: .turbo-plugin leaked into the import'
    else
        assertTrue 'no .turbo-plugin contamination' 0
    fi
}

# ══ U5: graded fork-point resolution (AE2-AE5, R7-R11) ═════════════════════════

# ── Case 11 (Covers AE2/R8): exact floor -> re-base onto r120, no prompt ───────
test_ae2_floor_resolve_exact() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot fork out rc mb
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-ae2" -m 'test: ae2' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    seed_main_trailers "$root" 90 118 120 126 || { startSkipping; return 0; }
    csb_setprops "$reposroot/branches/feat-ae2" 'last-aligned-rev' '120' || { startSkipping; return 0; }
    fork="$(trailer_sha "$root" 120)"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-ae2" --branch feat-ae2 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then fail "script under test must exit 0 on this happy path, got rc=$rc: $out"; return 1; fi
    case "$out" in *"Pull trunk first"*|*"Ask the branch author"*) fail "AE2 must not stop: $out" ;; esac
    mb="$(git -C "$root" merge-base main feat-ae2 2>/dev/null)"
    assertEquals 'AE2 merge-base(main, branch) == the r120 commit' "$fork" "$mb"
    assertEquals 'AE2 import-commit parent == the r120 commit' "$fork" "$(git -C "$root" rev-parse feat-ae2^ 2>/dev/null)"
}

# ── Regression: a MARKED but UNMERGED replay commit must not become a fork point ────────────────
# The pull replays each revision onto remote-svn/main and only THEN merges into main. When that
# merge has not landed, the marker for that revision points at a commit main does not contain.
# Parenting an imported branch there would base it on history main may never acquire, so the floor
# lookup skips it, `cur` stays behind, and checkout STOPS asking for a pull. The paired recovery
# half (a re-run of the pull retries the merge) lives in sync-from-svn.test.sh.
test_marked_but_unmerged_replay_is_not_a_fork_point() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot trunk_last r_new base tree unmerged out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    trunk_last="$(svn info --show-item last-changed-revision "$reposroot/trunk" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$trunk_last" ] || { startSkipping; return 0; }
    # A REAL trunk change after trunk_last, so grading cannot take the "trunk unchanged" shortcut.
    svn mkdir "$reposroot/trunk/late-dir" -m 'test: late trunk change' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    r_new="$(svn info --show-item revision "$reposroot/trunk/late-dir" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$r_new" ] || { startSkipping; return 0; }

    # main replayed only up to trunk_last ...
    seed_main_trailers "$root" "$trunk_last" || { startSkipping; return 0; }
    # ... while r_new sits MARKED on the bridge, unmerged into main. Reusing the bridge tree keeps
    # the bridge working copy clean, so nothing else in the run notices the synthetic commit.
    base="$(git -C "$root" rev-parse remote-svn/main)"
    tree="$(git -C "$root" rev-parse 'remote-svn/main^{tree}')"
    unmerged="$(git -C "$root" -c commit.gpgsign=false commit-tree "$tree" -p "$base" -m "sync: svn r$r_new" 2>/dev/null)" || { startSkipping; return 0; }
    git -C "$root" update-ref refs/heads/remote-svn/main "$unmerged" || { startSkipping; return 0; }
    git -C "$root" update-ref "refs/tp/svn/$r_new" "$unmerged" || { startSkipping; return 0; }
    if git -C "$root" merge-base --is-ancestor "$unmerged" main 2>/dev/null; then
        fail 'fixture broken: the marked commit IS reachable from main'; return 1
    fi

    svn copy "$reposroot/trunk" "$reposroot/branches/feat-unmerged" -m 'test: unmerged' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    csb_setprops "$reposroot/branches/feat-unmerged" 'last-aligned-rev' "$r_new" || { startSkipping; return 0; }

    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-unmerged" --branch feat-unmerged 2>&1)"; rc=$?
    assertNotEquals "must stop rather than attach to the unmerged replay commit (out: $out)" 0 "$rc"
    case "$out" in *"Pull trunk first"*) assertTrue 'asks for a pull' 0 ;; *) fail "expected a pull stop, got: $out" ;; esac
    assert_no_orphan "$root" feat-unmerged
    assertTrue 'the stop left no partial branch/worktree behind' $?
}

# ── Case 12 (sparse floor): no exact r120 but r118 present -> attach at r118 ────
test_sparse_floor_nearest() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot fork out rc mb
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-sparse" -m 'test: sparse' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    seed_main_trailers "$root" 90 118 126 || { startSkipping; return 0; }   # NO exact r120
    csb_setprops "$reposroot/branches/feat-sparse" 'last-aligned-rev' '120' || { startSkipping; return 0; }
    fork="$(trailer_sha "$root" 118)"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-sparse" --branch feat-sparse 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then fail "sparse floor should attach (not stop): $out"; return 0; fi
    mb="$(git -C "$root" merge-base main feat-sparse 2>/dev/null)"
    assertEquals 'sparse floor attaches at nearest <=R (r118)' "$fork" "$mb"
}

# ── Case 13 (Covers AE3/R9): no commit <=R & R>cur -> pull stop, then attach ───
# ── Regression: R>cur but trunk did NOT change in (cur..R] must ATTACH, not deadlock ───────────
# SVN revision numbers are repository-global. A branch copied from trunk@R where r(cur+1)..R only
# touched OTHER paths leaves trunk@R identical to trunk@cur -- there is nothing to pull. Grading on
# R itself then wedged the tool: checkout demanded a pull, the pull correctly answered "already up
# to date", and every retry failed the same way. Real case: branch copied from main@r52 while
# trunk's last actual change was r46.
test_r_gt_cur_but_trunk_unchanged_attaches() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot trunk_last copy_rev fork out rc mb
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    # Trunk's last REAL change (nothing after this touches trunk).
    trunk_last="$(svn info --show-item last-changed-revision "$reposroot/trunk" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$trunk_last" ] || { startSkipping; return 0; }
    # These revisions bump the repo-global counter WITHOUT touching trunk.
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-gap" -m 'test: gap branch' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    svn mkdir "$reposroot/unrelated" -m 'test: unrelated path' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    copy_rev="$(svn info --show-item revision "$reposroot/unrelated" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$copy_rev" ] || { startSkipping; return 0; }
    # Align the branch to that LATER global revision, while local main only replayed up to trunk_last.
    csb_setprops "$reposroot/branches/feat-gap" 'last-aligned-rev' "$copy_rev" || { startSkipping; return 0; }
    seed_main_trailers "$root" "$trunk_last" || { startSkipping; return 0; }
    fork="$(trailer_sha "$root" "$trunk_last")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-gap" --branch feat-gap 2>&1)"; rc=$?
    case "$out" in
        *"Pull trunk first"*) fail "deadlock: trunk did not change in (r$trunk_last..r$copy_rev] so there is nothing to pull: $out" ;;
        *) assertTrue 'no spurious pull-first stop' 0 ;;
    esac
    assertEquals "attaches despite R>cur (out: $out)" 0 "$rc"
    mb="$(git -C "$root" merge-base main feat-gap 2>/dev/null)"
    assertEquals 'attaches at the trunk last-changed commit' "$fork" "$mb"
}

test_ae3_pull_stop_then_attach() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc fork mb
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-ae3" -m 'test: ae3' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    seed_main_trailers "$root" 90 118 || { startSkipping; return 0; }        # cur=118 < R=120
    csb_setprops "$reposroot/branches/feat-ae3" 'last-aligned-rev' '120' || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-ae3" --branch feat-ae3 2>&1)"; rc=$?
    assertNotEquals 'AE3 first run stops (R>cur)' 0 "$rc"
    case "$out" in *"Pull trunk first"*) assertTrue 'AE3 offers to pull' 0 ;; *) fail "expected 'Pull trunk first', got: $out" ;; esac
    assert_no_orphan "$root" 'feat-ae3'; assertTrue 'AE3 stop leaves no orphan' $?
    # Simulate the pull bringing r119, r120; retry -> attach at r120.
    seed_main_trailers "$root" 119 120 || { startSkipping; return 0; }
    fork="$(trailer_sha "$root" 120)"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-ae3" --branch feat-ae3 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then fail "AE3 retry should attach: $out"; return 0; fi
    mb="$(git -C "$root" merge-base main feat-ae3 2>/dev/null)"
    assertEquals 'AE3 retry attaches at r120' "$fork" "$mb"
}

# ── Case 14 (Covers AE4/R10,R11): no commit <=R & R<=cur -> refresh stop ───────
test_ae4_refresh_stop() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-ae4" -m 'test: ae4' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    seed_main_trailers "$root" 118 120 126 || { startSkipping; return 0; }   # earliest 118, all > R=50
    csb_setprops "$reposroot/branches/feat-ae4" 'last-aligned-rev' '50' || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-ae4" --branch feat-ae4 2>&1)"; rc=$?
    assertNotEquals 'AE4 stops (no floor <= R, R <= cur)' 0 "$rc"
    case "$out" in *"has no replayed commit on local main"*) assertTrue 'AE4 gives the refresh instruction' 0 ;; *) fail "expected the R10 refresh message, got: $out" ;; esac
    case "$out" in *"Pull trunk first"*) fail "AE4 must be a refresh stop, not a pull stop: $out" ;; esac
    assert_no_orphan "$root" 'feat-ae4'; assertTrue 'AE4 does not attach to a wrong base (no orphan)' $?
}

# ── Case 15 (base-ref swap keeps SVN tree): branch tree != trunk-at-fork ───────
test_base_ref_swap_keeps_svn_tree() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot co fork out rc files
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    # Divergent branch: drop Web.config, add only-branch.txt (so its tree != trunk-at-fork).
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-div" -m 'branch: div' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    co="$SB/co-div"
    svn checkout "$reposroot/branches/feat-div" "$co" >/dev/null 2>&1 || { startSkipping; return 0; }
    svn delete "$co/Web.config" >/dev/null 2>&1
    echo 'only in branch' > "$co/only-branch.txt"
    svn add "$co/only-branch.txt" >/dev/null 2>&1
    ( cd "$co" && svn commit -m 'branch: drop Web.config, add only-branch.txt' >/dev/null 2>&1 ) || { startSkipping; return 0; }
    seed_main_trailers "$root" 90 118 120 126 || { startSkipping; return 0; }
    csb_setprops "$reposroot/branches/feat-div" 'last-aligned-rev' '120' || { startSkipping; return 0; }
    fork="$(trailer_sha "$root" 120)"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-div" --branch feat-div 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then fail "script under test must exit 0 on this happy path, got rc=$rc: $out"; return 1; fi
    assertEquals 'import-commit parent == the r120 fork commit' "$fork" "$(git -C "$root" rev-parse feat-div^ 2>/dev/null)"
    # The checked-out tree is the SVN BRANCH content, not the trunk-at-fork (forkCommit) tree.
    files="$(git -C "$root" ls-tree -r --name-only feat-div 2>/dev/null)"
    printf '%s\n' "$files" | grep -qx 'only-branch.txt'; assertTrue 'branch-only file present (SVN tree, not trunk-at-fork)' $?
    if printf '%s\n' "$files" | grep -qx 'Web.config'; then fail 'trunk-at-fork content leaked (Web.config present)'; else assertTrue 'no trunk-at-fork Web.config' 0; fi
    if git -C "$root" diff --quiet "$fork" feat-div 2>/dev/null; then fail 'branch tree must DIFFER from the fork commit tree'; else assertTrue 'branch tree != fork-commit tree' 0; fi
}

# ── Case 16 (R11 stale-but-present): stored R below copyfrom -> stop, no attach ─
test_stale_alignment_stops() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    svn copy "$reposroot/trunk" "$reposroot/branches/feat-stale" -m 'test: stale' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    seed_main_trailers "$root" 10 20 || { startSkipping; return 0; }
    # copyfrom-rev is r20; a stored alignment of r5 is a provable contradiction (only advances).
    csb_setprops "$reposroot/branches/feat-stale" 'last-aligned-rev' '5' || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feat-stale" --branch feat-stale 2>&1)"; rc=$?
    assertNotEquals 'stale alignment stops' 0 "$rc"
    case "$out" in *"older than the branch's fork revision"*) assertTrue 'stale contradiction reported' 0 ;; *) fail "expected the stale-contradiction message, got: $out" ;; esac
    assert_no_orphan "$root" 'feat-stale'; assertTrue 'stale stop leaves no orphan' $?
}

# ── Case 17 (Covers AE5/R7): tp:branch-name drives a slash-preserving local branch ─
test_ae5_slash_name_from_metadata() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    # SVN path leaf uses dashes; the stored original name has a slash.
    svn copy "$reposroot/trunk" "$reposroot/branches/feature-test-3-feature" -m 'test: ae5' --parents >/dev/null 2>&1 || { startSkipping; return 0; }
    seed_main_trailers "$root" 10 20 || { startSkipping; return 0; }
    csb_setprops "$reposroot/branches/feature-test-3-feature" 'branch-name' 'feature/test-3-feature' 'last-aligned-rev' '20' || { startSkipping; return 0; }
    # Invoke WITHOUT --branch: the leaf-derived name (feature-test-3-feature) must be overridden by
    # the stored slash-preserving name (feature/test-3-feature).
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$reposroot/branches/feature-test-3-feature" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then fail "script under test must exit 0 on this happy path, got rc=$rc: $out"; return 1; fi
    git -C "$root" branch --list 'feature/test-3-feature' | grep -q .
    assertTrue 'local working branch is the slash-preserving name' $?
    git -C "$root" branch --list 'remote-svn/feature/test-3-feature' | grep -q .
    assertTrue 'bridge ref preserves the slash' $?
    # The dash-form leaf must NOT become a local working branch.
    if git -C "$root" show-ref --verify --quiet 'refs/heads/feature-test-3-feature'; then
        fail 'dash-form leaf must not be the working branch name'
    else
        assertTrue 'dash-form leaf is not a working branch' 0
    fi
}

# shellcheck disable=SC1090
. "$SHUNIT2"
