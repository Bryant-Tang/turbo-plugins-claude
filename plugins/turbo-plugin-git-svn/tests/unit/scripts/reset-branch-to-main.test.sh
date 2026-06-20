#!/usr/bin/env bash
# reset-branch-to-main.test.sh (shUnit2)
#
# Script under test: scripts/reset-branch-to-main.sh (v0.5.0).
# New contract (generalized from reset-remote-test.sh — no test-<n>):
#   reset-branch-to-main.sh --branch <name> [--diff-only]
# Emits LOSE / GAIN / FILES_LOST_AFTER_PUSH previews; early-exits "already equals main".
# Errors: --branch missing / branch absent / main absent / remote worktree not found / dirty.
#
# Arg + missing-precondition cases are git-only. The diff-only / already-equals previews
# need the remote-svn bridge WORKTREE present (`git worktree add`), which can fail under
# very deep sandbox paths (GIT_DIR too big) — those cases self-SKIP on detection.
# Full happy-path coverage is in Reset-BranchToMain.test.ps1.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/reset-branch-to-main.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    # Probe whether `git worktree add` works at the sandbox depth on this machine.
    WORKTREE_OK=0
    local probe root wt
    probe="$(mktemp -d -t turbo-rbm-probe-XXXXXX)"
    root="$probe/test-turbo-plugin"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
    mkdir -p "$root/.turbo-plugin/worktrees"
    git -C "$root" branch 'remote-svn/probe' 'main' >/dev/null 2>&1
    wt="$root/.turbo-plugin/worktrees/remote-svn-probe"
    if git -C "$root" worktree add "$wt" 'remote-svn/probe' >/dev/null 2>&1; then
        WORKTREE_OK=1
    fi
    rm -rf "$probe" 2>/dev/null || true
}

setUp() {
    SB="$(mktemp -d -t turbo-rbm-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# Main repo with worktrees container. Echoes root.
make_main_repo() {
    local sandbox="$1"
    local root="$sandbox/test-turbo-plugin"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$root/init.txt"
    # Gitignore the worktree container so the main worktree stays "clean" for the
    # dirty-guard (the bridge worktrees live under .turbo-plugin/worktrees).
    printf '/.turbo-plugin/worktrees/\n' > "$root/.gitignore"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
    mkdir -p "$root/.turbo-plugin/worktrees"
    printf '%s' "$root"
}

commit_file() {
    local root="$1" name="$2" content="$3" msg="$4"
    printf '%s' "$content" > "$root/$name"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m "$msg" >/dev/null 2>&1
}

# Create branch <b> + its remote-svn/<b> bridge branch + worktree. Returns non-zero
# if `git worktree add` fails (caller should startSkipping).
add_branch_with_bridge() {
    local root="$1" b="$2"
    git -C "$root" branch "$b" 'main' >/dev/null 2>&1
    git -C "$root" branch "remote-svn/$b" 'main' >/dev/null 2>&1
    git -C "$root" worktree add "$root/.turbo-plugin/worktrees/remote-svn-$b" "remote-svn/$b" >/dev/null 2>&1
}

# ── Case 1: file exists ───────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'reset-branch-to-main.sh exists' $?
}

# ── Case 2: missing --branch → non-zero + stderr names it ─────────────────────
test_missing_branch() {
    local root out rc
    root="$(make_main_repo "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertNotEquals 'missing --branch exits non-zero' 0 "$rc"
    case "$out" in
        *"--branch is required"*) assertTrue 'stderr says --branch is required' 0 ;;
        *) fail "expected '--branch is required', got: $out" ;;
    esac
}

# ── Case 3: branch does not exist → non-zero (git only) ────────────────────────
test_branch_not_exist() {
    local root out rc
    root="$(make_main_repo "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch ghost 2>&1)"; rc=$?
    assertNotEquals 'absent branch exits non-zero' 0 "$rc"
    case "$out" in
        *"branch 'ghost' does not exist"*) assertTrue 'reports branch does not exist' 0 ;;
        *) fail "expected \"branch 'ghost' does not exist\", got: $out" ;;
    esac
}

# ── Case 4: remote-svn worktree not found → non-zero (git only) ────────────────
# branch + main exist, but no bridge worktree on disk.
test_remote_worktree_not_found() {
    local root out rc
    root="$(make_main_repo "$SB")"
    git -C "$root" branch feat-x 'main' >/dev/null 2>&1
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x 2>&1)"; rc=$?
    assertNotEquals 'missing remote worktree exits non-zero' 0 "$rc"
    case "$out" in
        *"remote-svn worktree not found"*) assertTrue 'reports remote worktree not found' 0 ;;
        *) fail "expected 'remote-svn worktree not found', got: $out" ;;
    esac
}

# ── Case 5: dirty main worktree → non-zero ────────────────────────────────────
test_dirty_main_rejected() {
    if [ "$WORKTREE_OK" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$(make_main_repo "$SB")"
    if ! add_branch_with_bridge "$root" feat-x; then startSkipping; return 0; fi
    # Make main dirty.
    echo dirty > "$root/dirty.txt"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x 2>&1)"; rc=$?
    assertNotEquals 'dirty main exits non-zero' 0 "$rc"
    case "$out" in
        *"uncommitted changes"*) assertTrue 'reports uncommitted changes' 0 ;;
        *) fail "expected 'uncommitted changes', got: $out" ;;
    esac
}

# ── Case 6: --diff-only emits LOSE / GAIN / FILES_LOST_AFTER_PUSH ──────────────
test_diff_only_emits_tokens() {
    if [ "$WORKTREE_OK" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$(make_main_repo "$SB")"
    if ! add_branch_with_bridge "$root" feat-x; then startSkipping; return 0; fi
    # Diverge: feat-x gains its own commit (LOSE), main advances (GAIN).
    git -C "$root" checkout feat-x >/dev/null 2>&1
    commit_file "$root" feat.txt 'feat' 'feat: branch-only commit'
    git -C "$root" checkout main >/dev/null 2>&1
    commit_file "$root" main.txt 'main' 'feat: main advances'
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x --diff-only 2>&1)"; rc=$?
    assertEquals 'diff-only exit 0' 0 "$rc"
    echo "$out" | grep -qE '^LOSE$';                  assertTrue 'LOSE token present' $?
    echo "$out" | grep -qE '^GAIN$';                  assertTrue 'GAIN token present' $?
    echo "$out" | grep -qE '^FILES_LOST_AFTER_PUSH$'; assertTrue 'FILES_LOST_AFTER_PUSH token present' $?
    # --diff-only must NOT actually reset (preview only).
    case "$out" in
        *"Reset feat-x to main"*) fail "--diff-only should not reset: $out" ;;
        *) assertTrue 'diff-only did not reset' 0 ;;
    esac
}

# ── Case 7: already equals main → early-exit message ──────────────────────────
test_already_equals_main() {
    if [ "$WORKTREE_OK" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$(make_main_repo "$SB")"
    if ! add_branch_with_bridge "$root" feat-x; then startSkipping; return 0; fi
    # feat-x was branched from main and neither advanced → already equals main.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch feat-x 2>&1)"; rc=$?
    assertEquals 'already-equals exit 0' 0 "$rc"
    case "$out" in
        *"already equals main"*) assertTrue 'reports already equals main' 0 ;;
        *) fail "expected 'already equals main', got: $out" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
