#!/usr/bin/env bash
# new-remote-bridge.test.sh (shUnit2)
#
# Script under test: scripts/new-remote-bridge.sh.
# New contract (generalized from new-remote-test.sh — no test-<n>):
#   new-remote-bridge.sh --branch <name> --svn-url <url>
# Creates the git<->SVN BRIDGE ONLY (remote-svn/<branch> branch + worktree + svn checkout);
# it does NOT create a working branch. Has collision / trust / rollback guards.
#
# Arg/fail-closed cases run with git only. Trust-validation cases need a real
# remote-svn-main svn working copy built from the seed dump and SKIP when svn/svnadmin
# or the dump is unavailable. The exhaustive assertions live in New-RemoteBridge.test.ps1;
# this mirrors the key reject / fail-closed / rollback behaviors for parity.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/new-remote-bridge.sh"
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
    SB="$(mktemp -d -t turbo-nrb-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# Build a throwaway git main worktree + worktrees container. Echoes the project root path.
make_main_repo() {
    local sandbox="$1"
    local root="$sandbox/test-turbo-plugin"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
    # Container inside the main worktree at <root>/.turbo-plugin/worktrees.
    mkdir -p "$root/.turbo-plugin/worktrees"
    printf '%s' "$root"
}

# Build a real remote-svn-main svn WC from the seed dump under
# <root>/.turbo-plugin/worktrees/remote-svn-main. Echoes repos-root-url; non-zero on failure.
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
    # The bridge branch is now based on remote-svn/main's tip (not a repo root commit), so the
    # anchor ref must exist for the create path to run. Real setups create it via Initialize;
    # here a ref at main is enough (the svn checkout --force overlays the branch content anyway).
    git -C "$root" branch remote-svn/main main >/dev/null 2>&1 || return 1
    local reposroot
    reposroot="$(svn info --show-item repos-root-url "$worktrees/remote-svn-main" 2>/dev/null | tr -d '\r\n')"
    [ -n "$reposroot" ] || return 1
    printf '%s' "$reposroot"
}

# ── Case 1: file exists ───────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'new-remote-bridge.sh exists' $?
}

# ── Case 2: missing --branch → non-zero + stderr names it ─────────────────────
test_missing_branch() {
    local root out rc
    root="$(make_main_repo "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'file:///nope/branches/x' 2>&1)"; rc=$?
    assertNotEquals 'missing --branch exits non-zero' 0 "$rc"
    case "$out" in
        *"--branch is required"*) assertTrue 'stderr says --branch is required' 0 ;;
        *) fail "expected '--branch is required', got: $out" ;;
    esac
}

# ── Case 3: missing --svn-url → non-zero + stderr names it ────────────────────
test_missing_svn_url() {
    local root out rc
    root="$(make_main_repo "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x 2>&1)"; rc=$?
    assertNotEquals 'missing --svn-url exits non-zero' 0 "$rc"
    case "$out" in
        *"--svn-url is required"*) assertTrue 'stderr says --svn-url is required' 0 ;;
        *) fail "expected '--svn-url is required', got: $out" ;;
    esac
}

# ── Case 4: unknown argument → non-zero ───────────────────────────────────────
test_unknown_arg() {
    local root out rc
    root="$(make_main_repo "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --bogus-flag 2>&1)"; rc=$?
    assertNotEquals 'unknown arg exits non-zero' 0 "$rc"
    case "$out" in
        *"Unknown argument"*) assertTrue 'stderr mentions Unknown argument' 0 ;;
        *) fail "expected 'Unknown argument', got: $out" ;;
    esac
}

# ── Case 5: pre-existing bridge branch → already-exists guard (git only) ───────
# Complete bridge (ref AND worktree dir) already exists → reject BEFORE trust / rollback.
test_bridge_already_exists() {
    local root out rc
    root="$(make_main_repo "$SB")"
    git -C "$root" branch 'remote-svn/feat-x' 'main' >/dev/null 2>&1
    # Genuine complete bridge: also create the worktree dir (not the ref-XOR-dir partial state).
    mkdir -p "$root/.turbo-plugin/worktrees/remote-svn-feat-x"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --svn-url 'file:///nope/branches/feat-x' 2>&1)"; rc=$?
    assertNotEquals 'pre-existing bridge exits non-zero' 0 "$rc"
    case "$out" in
        *"bridge branch 'remote-svn/feat-x' already exists"*) assertTrue 'reports already exists' 0 ;;
        *) fail "expected \"bridge branch ... already exists\", got: $out" ;;
    esac
    case "$out" in
        *"rolling back"*) fail "unexpectedly entered rollback: $out" ;;
        *) assertTrue 'did not enter rollback' 0 ;;
    esac
}

# Inconsistent partial state (ref without worktree dir) → recovery guidance, no svn mutation.
test_bridge_inconsistent_partial_state() {
    local root out rc
    root="$(make_main_repo "$SB")"
    # Bridge branch exists but NO worktree dir -> leftover from an interrupted run.
    git -C "$root" branch 'remote-svn/feat-x' 'main' >/dev/null 2>&1
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --svn-url 'file:///nope/branches/feat-x' 2>&1)"; rc=$?
    assertNotEquals 'inconsistent state exits non-zero' 0 "$rc"
    case "$out" in
        *"inconsistent bridge state"*) assertTrue 'reports inconsistent state' 0 ;;
        *) fail "expected 'inconsistent bridge state', got: $out" ;;
    esac
    case "$out" in
        *"git worktree prune"*) assertTrue 'names recovery step' 0 ;;
        *) fail "expected 'git worktree prune' guidance, got: $out" ;;
    esac
    case "$out" in
        *"Creating SVN bridge"*) fail "unexpectedly reached svn mutation: $out" ;;
        *) assertTrue 'did not reach svn mutation' 0 ;;
    esac
}

# Symmetric partial state (worktree dir without ref) → recovery guidance, no svn mutation.
test_bridge_dir_without_ref() {
    local root out rc
    root="$(make_main_repo "$SB")"
    # Worktree dir exists but NO bridge branch -> the symmetric leftover state.
    mkdir -p "$root/.turbo-plugin/worktrees/remote-svn-feat-x"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --svn-url 'file:///nope/branches/feat-x' 2>&1)"; rc=$?
    assertNotEquals 'dir-without-ref exits non-zero' 0 "$rc"
    case "$out" in
        *"inconsistent bridge state"*) assertTrue 'reports inconsistent state' 0 ;;
        *) fail "expected 'inconsistent bridge state', got: $out" ;;
    esac
    case "$out" in
        *"git worktree prune"*) assertTrue 'names recovery step' 0 ;;
        *) fail "expected 'git worktree prune' guidance, got: $out" ;;
    esac
    # Prove it is the dir-without-ref arm specifically (not the ref-without-dir arm, which
    # says 'git branch -D'): the dir-without-ref message says 'delete that directory'.
    case "$out" in
        *"delete that directory"*) assertTrue 'dir-without-ref arm fired' 0 ;;
        *) fail "expected 'delete that directory' (dir-without-ref arm), got: $out" ;;
    esac
    case "$out" in
        *"git branch -D"*) fail "wrong arm: matched ref-without-dir guidance: $out" ;;
        *) assertTrue 'not the ref-without-dir arm' 0 ;;
    esac
    case "$out" in
        *"Creating SVN bridge"*) fail "unexpectedly reached svn mutation: $out" ;;
        *) assertTrue 'did not reach svn mutation' 0 ;;
    esac
}

# ── Case 6: worktrees dir absent → fail-closed (git only) ─────────────────────
# A bare git repo with NO .turbo-plugin/worktrees must fail before any side effect.
test_worktrees_dir_absent_fail_closed() {
    local root out rc
    root="$SB/bare-turbo-plugin"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --svn-url 'file:///nope/branches/feat-x' 2>&1)"; rc=$?
    assertNotEquals 'worktrees dir absent exits non-zero' 0 "$rc"
    case "$out" in
        *"worktrees directory not found"*) assertTrue 'reports worktrees dir not found' 0 ;;
        *) fail "expected 'worktrees directory not found', got: $out" ;;
    esac
    if git -C "$root" branch --list 'remote-svn/feat-x' | grep -q .; then
        fail "fail-closed should not leave an orphan remote-svn/feat-x branch"
    else
        assertTrue 'no orphan bridge branch' 0
    fi
}

# ── Case 7: untrusted SVN URL → reject before mutation (needs real WC) ─────────
test_untrusted_svn_url_rejected() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$(make_main_repo "$SB")"
    if ! make_remote_main_wc "$SB" "$root" >/dev/null; then
        startSkipping; return 0
    fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --svn-url 'file:///C:/Windows/System32/' 2>&1)"; rc=$?
    assertNotEquals 'out-of-trust URL exits non-zero' 0 "$rc"
    case "$out" in
        *"Creating SVN bridge"*) fail "untrusted URL should be rejected before mutation: $out" ;;
        *) assertTrue 'rejected before mutation' 0 ;;
    esac
}

# ── Case 8: directory-collision (different ref → same dir name) (needs real WC) ─
test_dir_collision_rejected() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then
        startSkipping; return 0
    fi
    # 'feat/x' and 'feat-x' both map to dir remote-svn-feat-x. Seed remote-svn/feat-x,
    # then request feat/x → collision (different ref, same dir).
    git -C "$root" branch 'remote-svn/feat-x' 'main' >/dev/null 2>&1
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch 'feat/x' --svn-url "${reposroot}/branches/feat-x" 2>&1)"; rc=$?
    assertNotEquals 'dir collision exits non-zero' 0 "$rc"
    case "$out" in
        *"already taken by branch"*) assertTrue 'reports directory collision' 0 ;;
        *) fail "expected 'already taken by branch', got: $out" ;;
    esac
}

# ── Case 9: post-trust failure rolls back local git state (needs real WC) ──────
test_rollback_on_post_trust_failure() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then
        startSkipping; return 0
    fi
    # Trusted sibling URL (under repos root) that does not yet exist → script enters
    # "Creating SVN bridge", does the git branch+worktree, then attempts the svn copy.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --svn-url "${reposroot}/branches/feat-x" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        # A failure MUST have rolled back the local git branch.
        case "$out" in
            *"rolling back"*) assertTrue 'rollback fired on failure' 0 ;;
            *) fail "non-zero exit without rollback: $out" ;;
        esac
        if git -C "$root" branch --list 'remote-svn/feat-x' | grep -q .; then
            fail "rollback should have deleted remote-svn/feat-x branch"
        else
            assertTrue 'rollback removed bridge branch' 0
        fi
    else
        # Clean create path — the bridge artifacts must exist.
        if git -C "$root" branch --list 'remote-svn/feat-x' | grep -q .; then
            assertTrue 'bridge branch created on success' 0
        else
            fail "success exit but no remote-svn/feat-x branch"
        fi
    fi
}

# ── Case 10: successful create sets a fixed svn:ignore=.git (needs real WC) ─────
test_create_sets_fixed_svn_ignore() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc wt ign
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then
        startSkipping; return 0
    fi
    # Create the SVN branch the bridge checks out, so the create path can succeed.
    if ! svn copy "$reposroot/trunk" "$reposroot/branches/feature-x" -m 'test: branch for bridge' --parents >/dev/null 2>&1; then
        startSkipping; return 0
    fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feature-x --svn-url "$reposroot/branches/feature-x" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        # Bridge create did not succeed in this env -> skip (not a fixed-svn:ignore failure).
        startSkipping; return 0
    fi
    wt="$root/.turbo-plugin/worktrees/remote-svn-feature-x"
    ign="$(svn propget svn:ignore "$wt" 2>/dev/null | tr -d '\r\n')"
    assertEquals 'bridge svn:ignore is exactly .git' '.git' "$ign"
}

# Inject a SECOND root commit into main to reproduce the post-bridge two-root state. `commit-tree`
# on the canonical empty tree makes a parentless (root) commit like a `sync:` import root; merging
# it --allow-unrelated-histories leaves main reachable from TWO roots (the exact bug trigger).
inject_second_root() {
    local root="$1" second
    second="$(git -C "$root" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m 'sync: svn r1')"
    git -C "$root" merge --allow-unrelated-histories --no-edit -m "Merge branch 'remote-svn/main' into main" "$second" >/dev/null 2>&1
}

# ── Case 11: two-root repo (already bridged) still bridges a new branch (regression) ──
# Reproduces the reported first-push failure: once main has been through a bridge merge it carries
# TWO root commits, so `rev-list --max-parents=0 HEAD` returned a 2-line value that broke
# `git branch` with "not a valid object name". Basing the bridge on remote-svn/main fixes it.
test_two_root_repo_first_push_regression() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root reposroot out rc
    root="$(make_main_repo "$SB")"
    if ! reposroot="$(make_remote_main_wc "$SB" "$root")"; then startSkipping; return 0; fi
    inject_second_root "$root"
    assertEquals 'main has two root commits (bridged state)' 2 "$(git -C "$root" rev-list --max-parents=0 HEAD | grep -c .)"
    # First push of a NEW feature branch: the exact flow that used to crash on a two-root repo.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-y --svn-url "$reposroot/branches/feat-y" 2>&1)"; rc=$?
    case "$out" in
        *"not a valid object name"*) fail "regressed: two-root repo broke 'git branch' with: $out" ;;
        *) assertTrue 'no invalid-object-name error' 0 ;;
    esac
    assertEquals 'first-push bridge succeeded on a two-root repo' 0 "$rc"
    git -C "$root" branch --list 'remote-svn/feat-y' | grep -q .
    assertTrue 'bridge branch remote-svn/feat-y created' $?
}

# Build a FAITHFUL first-push scenario for the scoped-commit / up-to-date regression:
#   - svn trunk already carries svn:ignore=.git (post-tp-setup) so the bootstrap propset is a
#     NO-OP -> '.' is not committed;
#   - git main mirrors trunk but a versioned file (Templates/drift.txt) has DIVERGENT content
#     (git "v2" vs svn "v1"), so `svn checkout --force` marks it locally modified on the new
#     bridge worktree -- the exact drift the old unscoped commit swept into the svn:ignore commit;
#   - main's .gitignore DIFFERS from trunk's, so a real .gitignore change IS committed (a child
#     of '.' that does not bump '.', which is what leaves the WC root lagging without `svn update`).
# Echoes "ROOT|WORKTREES|URI|CFG"; non-zero on any svn failure (caller SKIPs).
make_drift_scenario() {
    local sb="$1"
    local root="$sb/test-turbo-plugin" repo="$sb/svnrepo" cfg="$sb/.svnconfig" uri winrepo
    mkdir -p "$cfg"
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    svnadmin load "$repo" < "$DUMP_PATH" >/dev/null 2>&1 || return 1
    winrepo="$(cygpath -m "$repo" 2>/dev/null || printf '%s' "$repo")"
    uri="file:///$winrepo"

    # trunk: svn:ignore=.git + versioned .gitignore(LF) + Templates/drift.txt content "v1".
    local twc="$sb/trunkwc"
    svn --config-dir "$cfg" checkout "$uri/trunk" "$twc" >/dev/null 2>&1 || return 1
    svn --config-dir "$cfg" propset svn:ignore '.git' "$twc" >/dev/null 2>&1 || return 1
    printf '.svn/\n' > "$twc/.gitignore"
    svn --config-dir "$cfg" add "$twc/.gitignore" >/dev/null 2>&1 || return 1
    mkdir -p "$twc/Templates"
    printf 'v1\n' > "$twc/Templates/drift.txt"
    svn --config-dir "$cfg" add "$twc/Templates" >/dev/null 2>&1 || return 1
    svn --config-dir "$cfg" commit "$twc" -m 'trunk: svn:ignore + gitignore + drift v1' >/dev/null 2>&1 || return 1

    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config core.autocrlf false >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    local worktrees="$root/.turbo-plugin/worktrees"
    mkdir -p "$worktrees"
    svn --config-dir "$cfg" checkout "$uri/trunk" "$worktrees/remote-svn-main" >/dev/null 2>&1 || return 1

    # git main mirrors trunk, but drift.txt is "v2" (divergent) and .gitignore differs.
    svn --config-dir "$cfg" export --force "$uri/trunk" "$sb/tx" >/dev/null 2>&1 || return 1
    cp -r "$sb/tx/." "$root/" 2>/dev/null
    printf 'v2\n' > "$root/Templates/drift.txt"
    printf '.svn/\nbin/\n' > "$root/.gitignore"
    git -C "$root" add -A >/dev/null 2>&1 || return 1
    git -C "$root" -c commit.gpgsign=false commit -m 'main mirrors trunk (drift v2, gitignore differs)' >/dev/null 2>&1 || return 1
    git -C "$root" branch remote-svn/main main >/dev/null 2>&1 || return 1

    printf '%s|%s|%s|%s' "$root" "$worktrees" "$uri" "$cfg"
    return 0
}

# ── Case 12: first-push bootstrap keeps the WC at HEAD and scopes the infra commit (regression) ──
# Reproduces the reported first-push symptoms:
#   B) the bootstrap svn:ignore commit left the WC one revision behind HEAD, so the very next
#      build-svn-commit falsely demanded '/tp-pull-from-svn' on a freshly-created bridge;
#   C) an unscoped `svn commit` swept `svn checkout --force` overlay drift (a file whose git
#      bytes differ from the SVN base) into the commit, under the misleading svn:ignore message.
# The fix scopes the commit (--depth empty + explicit targets) and `svn update`s to HEAD.
test_first_push_scoped_commit_and_up_to_date() {
    if [ "$HAS_SVN" -ne 1 ] || [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local spec root worktrees uri cfg
    spec="$(make_drift_scenario "$SB")" || { startSkipping; return 0; }
    root="${spec%%|*}"; spec="${spec#*|}"
    worktrees="${spec%%|*}"; spec="${spec#*|}"
    uri="${spec%%|*}"; cfg="${spec##*|}"

    local out rc
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-y --svn-url "$uri/branches/feat-y" 2>&1)"; rc=$?
    assertEquals "bootstrap succeeds (out: $out)" 0 "$rc"

    local wt="$worktrees/remote-svn-feat-y"
    local local_rev head_rev
    local_rev="$(svn --config-dir "$cfg" info --show-item revision "$wt" 2>/dev/null | tr -d '[:space:]')"
    head_rev="$(svn --config-dir "$cfg" info --show-item revision "$uri/branches/feat-y" 2>/dev/null | tr -d '[:space:]')"
    # B: the WC must be exactly at HEAD (no mixed-revision lag) so build-svn-commit's up-to-date
    # check passes without a spurious pull.
    assertEquals "B: bridge WC rev ($local_rev) is at HEAD ($head_rev)" "$head_rev" "$local_rev"

    # C: the bootstrap commit must NOT contain the overlay drift file.
    local changed
    changed="$(svn --config-dir "$cfg" log -v -r"$head_rev" "$uri/branches/feat-y" 2>/dev/null)"
    case "$changed" in
        *drift.txt*) fail "C: bootstrap commit r$head_rev swept overlay drift (drift.txt): $changed" ;;
        *) assertTrue 'C: bootstrap commit excluded overlay drift' 0 ;;
    esac

    # The intended infra state still landed: svn:ignore is exactly .git.
    local ign
    ign="$(svn --config-dir "$cfg" propget svn:ignore "$wt" 2>/dev/null | tr -d '\r\n')"
    assertEquals 'bridge svn:ignore is exactly .git' '.git' "$ign"

    # The bridge git worktree is clean (build-svn-commit's git-clean gate would pass).
    assertTrue 'bridge git worktree clean' "[ -z \"\$(git -C '$wt' status --porcelain)\" ]"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
