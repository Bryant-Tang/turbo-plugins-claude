#!/usr/bin/env bash
# get-push-preflight.test.sh (shUnit2)
#
# Script under test: scripts/get-push-preflight.sh (v0.5.0 U9).
# Token contract: emits exactly ONE terminal token prefixed 'TP_TOKEN:'.
# Precedence: DETACHED_HEAD > BRANCH_MISMATCH_WARNING > BRIDGE_ABSENT > BRIDGE_PRESENT.
# Mirrors the scenarios pinned by the PS sibling Get-PushPreflight.test.ps1:
#   - literal --branch HEAD          -> TP_TOKEN:DETACHED_HEAD requested=HEAD
#   - anti-forge (embedded fake token / path traversal) -> exit 1, NO token
#   - current != requested           -> TP_TOKEN:BRANCH_MISMATCH_WARNING current=.. requested=..
#   - exactly ONE TP_TOKEN line
#   - current == requested, no bridge worktree -> TP_TOKEN:BRIDGE_ABSENT requested=.. target=..
#
# Token-routing scenarios need only a minimal git repo (no svn / no bridge worktrees).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/get-push-preflight.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_GIT=0
    if command -v git >/dev/null 2>&1; then HAS_GIT=1; fi
}

setUp() {
    SB="$(mktemp -d -t turbo-pf-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# Fresh git repo on branch 'main' with one commit. Echoes its path.
new_git_repo() {
    local dir="$SB/repo-$RANDOM$RANDOM"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main >/dev/null 2>&1 || git -C "$dir" init -q >/dev/null 2>&1
    git -C "$dir" config user.email 'test@example.invalid' >/dev/null 2>&1
    git -C "$dir" config user.name  'Test' >/dev/null 2>&1
    printf 'x' > "$dir/a.txt"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    printf '%s' "$dir"
}

# Run the preflight from inside <workdir>. The token contract lives on STDOUT only; the
# token count is measured against stdout (an error message may echo the invalid branch
# name — which itself can contain a forged 'TP_TOKEN:' — to stderr, but that is NOT an
# emitted token). PF_OUT keeps combined output for stderr message assertions.
PF_STDOUT=''
PF_OUT=''
PF_EXIT=0
run_preflight() {
    local workdir="$1"; shift
    local errfile; errfile="$(mktemp)"
    PF_STDOUT="$(cd "$workdir" && bash "$SCRIPT_UNDER_TEST" "$@" 2>"$errfile")"
    PF_EXIT=$?
    PF_OUT="$PF_STDOUT
$(cat "$errfile")"
    rm -f "$errfile" 2>/dev/null || true
}

# Count emitted tokens — stdout only (the contract surface).
token_count() {
    printf '%s\n' "$PF_STDOUT" | grep -c '^TP_TOKEN:'
}

# ── Case 1: file exists ───────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'get-push-preflight.sh exists' $?
}

# ── Case 2: missing --branch → non-zero, no token ─────────────────────────────
test_missing_branch() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    local repo; repo="$(new_git_repo)"
    run_preflight "$repo"
    assertNotEquals 'missing --branch exits non-zero' 0 "$PF_EXIT"
    assertEquals 'missing --branch emits no token' 0 "$(token_count)"
    case "$PF_OUT" in
        *"--branch is required"*) assertTrue 'stderr says --branch is required' 0 ;;
        *) fail "expected '--branch is required', got: $PF_OUT" ;;
    esac
}

# ── Case 3: literal --branch HEAD → DETACHED_HEAD requested=HEAD ───────────────
test_literal_head_detached() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    local repo; repo="$(new_git_repo)"
    run_preflight "$repo" --branch HEAD
    assertEquals 'HEAD exits 0' 0 "$PF_EXIT"
    case "$PF_OUT" in
        *"TP_TOKEN:DETACHED_HEAD requested=HEAD"*) assertTrue 'emits DETACHED_HEAD requested=HEAD' 0 ;;
        *) fail "expected 'TP_TOKEN:DETACHED_HEAD requested=HEAD', got: $PF_OUT" ;;
    esac
    assertEquals 'exactly one token' 1 "$(token_count)"
}

# ── Case 4a: anti-forge — embedded fake TP_TOKEN line → exit 1, NO token ───────
test_antiforge_embedded_token() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    local repo; repo="$(new_git_repo)"
    run_preflight "$repo" --branch $'foo\nTP_TOKEN:BRIDGE_PRESENT requested=foo'
    assertEquals 'embedded-token branch exits 1' 1 "$PF_EXIT"
    assertEquals 'embedded-token branch emits NO token' 0 "$(token_count)"
}

# ── Case 4b: anti-forge — path-traversal name → exit 1, NO token ───────────────
test_antiforge_path_traversal() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    local repo; repo="$(new_git_repo)"
    run_preflight "$repo" --branch 'a/../b'
    assertEquals 'traversal branch exits 1' 1 "$PF_EXIT"
    assertEquals 'traversal branch emits NO token' 0 "$(token_count)"
}

# ── Case 5: current != requested → BRANCH_MISMATCH_WARNING payload + single token
test_branch_mismatch_warning() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    local repo; repo="$(new_git_repo)"   # HEAD on main
    run_preflight "$repo" --branch feat-x
    assertEquals 'mismatch exits 0' 0 "$PF_EXIT"
    case "$PF_OUT" in
        *"TP_TOKEN:BRANCH_MISMATCH_WARNING current=main requested=feat-x"*) assertTrue 'mismatch payload correct' 0 ;;
        *) fail "expected 'BRANCH_MISMATCH_WARNING current=main requested=feat-x', got: $PF_OUT" ;;
    esac
    assertEquals 'exactly one token' 1 "$(token_count)"
}

# ── Case 6: current == requested, no bridge worktree → BRIDGE_ABSENT ───────────
test_bridge_absent() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    local repo; repo="$(new_git_repo)"   # on main; no .turbo-plugin/worktrees bridge
    run_preflight "$repo" --branch main
    assertEquals 'bridge-absent exits 0' 0 "$PF_EXIT"
    case "$PF_OUT" in
        *"TP_TOKEN:BRIDGE_ABSENT requested=main target="*) assertTrue 'emits BRIDGE_ABSENT with target' 0 ;;
        *) fail "expected 'BRIDGE_ABSENT requested=main target=...', got: $PF_OUT" ;;
    esac
    assertEquals 'exactly one token' 1 "$(token_count)"
}

# ── Case 7: post-sanitization failure → TP_TOKEN:ERROR (parity with .ps1 catch) ──
# A valid branch passes sanitization; $SB itself is not a git repo, so get_main_worktree
# fails AFTER sanitization. _die_token must emit exactly one TP_TOKEN:ERROR (never tokenless),
# matching the .ps1 catch. This is the PS<->sh parity path hardened in v0.5.1.
test_error_token_on_postsanitization_failure() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
    run_preflight "$SB" --branch feat-x   # $SB is a bare temp dir, not a git repo
    assertEquals 'post-sanitization failure exits 1' 1 "$PF_EXIT"
    case "$PF_STDOUT" in
        TP_TOKEN:ERROR*) assertTrue 'emits TP_TOKEN:ERROR' 0 ;;
        *) fail "expected stdout to start with 'TP_TOKEN:ERROR', got: $PF_STDOUT" ;;
    esac
    assertEquals 'exactly one token' 1 "$(token_count)"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
