#!/usr/bin/env bash
# merge-main-into-branches.test.sh (shUnit2)
#
# Script under test: scripts/merge-main-into-branches.sh (git-only — no SVN).
# Contract:
#   merge-main-into-branches.sh [--branch <name>]   (--branch repeatable)
#   - no --branch  => target = every local branch except `main` and `remote-svn/*`
#   - --branch ... => target = exactly those; a missing/excluded one is `SKIP <b> ...`
#                     and the run continues
#   Guards: dirty main aborts; per-branch conflict aborts THAT merge & continues;
#           the original branch is restored at the end.
#
# All git-only — no SKIP needed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/merge-main-into-branches.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

setUp() {
    SB="$(mktemp -d -t turbo-mmb-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

git_init_main() {
    local root="$1"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$root/init.txt"
    mkdir -p "$root/.turbo-plugin/worktrees"
    printf '/.turbo-plugin/worktrees/\n' > "$root/.gitignore"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial --allow-empty >/dev/null 2>&1
}

commit_file() {
    local root="$1" name="$2" content="$3" msg="$4"
    printf '%s' "$content" > "$root/$name"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m "$msg" >/dev/null 2>&1
}

# main advanced + test-x/feature-y behind + remote-svn/main bridge. Echoes root.
make_merge_fixture() {
    local sandbox="$1"
    local root="$sandbox/test-turbo-plugin"
    git_init_main "$root"
    git -C "$root" branch test-x >/dev/null 2>&1
    git -C "$root" branch feature-y >/dev/null 2>&1
    git -C "$root" branch remote-svn/main >/dev/null 2>&1
    commit_file "$root" main-only.txt 'main tip' 'feat: main advances'
    printf '%s' "$root"
}

# ── Case 1: file exists ───────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'merge-main-into-branches.sh exists' $?
}

# ── Case 2: happy — both targets contain main tip; main & remote-svn/main untouched
test_happy_merges_all_targets() {
    local root main_sha remote_before out rc
    root="$(make_merge_fixture "$SB")"
    main_sha="$(git -C "$root" rev-parse main)"
    remote_before="$(git -C "$root" rev-parse remote-svn/main)"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertEquals 'happy exit 0' 0 "$rc"
    git -C "$root" merge-base --is-ancestor "$main_sha" test-x;    assertTrue 'test-x contains main tip' $?
    git -C "$root" merge-base --is-ancestor "$main_sha" feature-y; assertTrue 'feature-y contains main tip' $?
    assertEquals 'main tip unchanged' "$main_sha" "$(git -C "$root" rev-parse main)"
    assertEquals 'remote-svn/main untouched' "$remote_before" "$(git -C "$root" rev-parse remote-svn/main)"
}

# ── Case 3: exclude — no "OK main" / "OK remote-svn/*"; targets merged ─────────
test_excludes_main_and_remote_svn() {
    local root out
    root="$(make_merge_fixture "$SB")"
    git -C "$root" branch remote-svn/test-1 >/dev/null 2>&1
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"
    if echo "$out" | grep -qE '^OK main$'; then fail "found 'OK main' line: $out"; else assertTrue 'no OK main line' 0; fi
    if echo "$out" | grep -qE '^OK remote-svn/'; then fail "found 'OK remote-svn/*' line: $out"; else assertTrue 'no OK remote-svn/* line' 0; fi
    echo "$out" | grep -qE '^OK test-x$';    assertTrue 'test-x merged' $?
    echo "$out" | grep -qE '^OK feature-y$'; assertTrue 'feature-y merged' $?
}

# ── Case 4: --branch targets exactly the named branch ─────────────────────────
test_branch_filter_targets_named_only() {
    local root out main_sha
    root="$(make_merge_fixture "$SB")"
    main_sha="$(git -C "$root" rev-parse main)"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch test-x 2>&1)"
    echo "$out" | grep -qE '^OK test-x$'; assertTrue 'named test-x merged' $?
    if echo "$out" | grep -qE '^OK feature-y$'; then fail "feature-y should not be merged when only test-x requested: $out"; else assertTrue 'feature-y untouched' 0; fi
    git -C "$root" merge-base --is-ancestor "$main_sha" test-x; assertTrue 'test-x contains main tip' $?
    if git -C "$root" merge-base --is-ancestor "$main_sha" feature-y; then fail "feature-y unexpectedly advanced"; else assertTrue 'feature-y not advanced' 0; fi
}

# ── Case 5: --branch on a missing/excluded branch → SKIP, run continues ────────
test_missing_and_excluded_branch_skip() {
    local root out
    root="$(make_merge_fixture "$SB")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --branch ghost --branch main --branch test-x 2>&1)"
    echo "$out" | grep -qE '^SKIP ghost \(not found / excluded\)$'; assertTrue 'missing branch SKIP' $?
    echo "$out" | grep -qE '^SKIP main \(not found / excluded\)$';  assertTrue 'main excluded SKIP' $?
    echo "$out" | grep -qE '^OK test-x$';                           assertTrue 'valid branch still merged' $?
}

# ── Case 6: dirty main → abort before touching anything ────────────────────────
test_dirty_main_aborts() {
    local root out rc before_x
    root="$(make_merge_fixture "$SB")"
    before_x="$(git -C "$root" rev-parse test-x)"
    echo dirty > "$root/dirty.txt"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertNotEquals 'dirty main exits non-zero' 0 "$rc"
    case "$out" in
        *"dirty"*) assertTrue 'reports dirty main' 0 ;;
        *) fail "expected 'dirty', got: $out" ;;
    esac
    assertEquals 'test-x untouched after abort' "$before_x" "$(git -C "$root" rev-parse test-x)"
}

# ── Case 7: conflict — CONFLICT (aborted) + clean branch merges + branch restored
test_conflict_isolated_and_restored() {
    local root main_sha out rc start_branch end_branch status
    root="$SB/test-turbo-plugin"
    git_init_main "$root"
    commit_file "$root" shared.txt 'base' 'feat: add shared'
    git -C "$root" branch clean-branch >/dev/null 2>&1
    git -C "$root" branch conflict-branch >/dev/null 2>&1
    git -C "$root" checkout conflict-branch >/dev/null 2>&1
    commit_file "$root" shared.txt 'branch-version' 'feat: branch edits shared'
    git -C "$root" checkout main >/dev/null 2>&1
    commit_file "$root" shared.txt 'main-version' 'feat: main edits shared'
    main_sha="$(git -C "$root" rev-parse main)"
    git -C "$root" checkout clean-branch >/dev/null 2>&1
    start_branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"

    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertEquals 'conflict run exit 1' 1 "$rc"
    echo "$out" | grep -qE '^CONFLICT conflict-branch\b'; assertTrue 'conflict-branch reported CONFLICT' $?
    if git -C "$root" merge-base --is-ancestor "$main_sha" conflict-branch; then
        fail "conflict-branch should NOT be merged"
    else
        assertTrue 'conflict-branch NOT merged' 0
    fi
    git -C "$root" merge-base --is-ancestor "$main_sha" clean-branch; assertTrue 'clean-branch merged' $?
    status="$(git -C "$root" status --porcelain)"
    assertEquals 'worktree clean after run' '' "$status"
    end_branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
    assertEquals 'original branch restored' "$start_branch" "$end_branch"
}

# ── Case 8: git status failure (corrupt index) → fail-loud before merging ──────
test_git_status_failure_aborts() {
    local root out rc
    root="$(make_merge_fixture "$SB")"
    # Corrupt the index so `git status --porcelain` exits non-zero. get_main_worktree (runs
    # first and does not read the index) still succeeds, so this exercises the new
    # status-failure guard rather than an earlier failure.
    printf 'garbage-not-a-git-index' > "$root/.git/index"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertNotEquals 'git status failure exits non-zero' 0 "$rc"
    case "$out" in
        *"git status --porcelain failed"*) assertTrue 'reports git status failure' 0 ;;
        *) fail "expected 'git status --porcelain failed', got: $out" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
