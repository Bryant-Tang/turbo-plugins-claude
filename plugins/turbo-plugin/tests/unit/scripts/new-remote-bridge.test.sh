#!/usr/bin/env bash
# new-remote-bridge.test.sh (shUnit2)
#
# Script under test: scripts/new-remote-bridge.sh (v0.5.0 U9).
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

# shellcheck disable=SC1090
. "$SHUNIT2"
