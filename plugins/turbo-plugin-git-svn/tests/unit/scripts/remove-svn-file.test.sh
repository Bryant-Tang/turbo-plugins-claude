#!/usr/bin/env bash
# remove-svn-file.test.sh (shUnit2)
#
# Script under test: scripts/remove-svn-file.sh.
# Contract: --path <bridge-relative> [--branch <name=main>]. Removes one path from the SVN side of
# a bridge. Pre-flight (before any svn delete): resolve the bridge, require the path to exist +
# be svn-tracked, classify git-tracked vs not on the bridge:
#   git-TRACKED (Un-track A) -> RECONCILE (svn delete + `sync: svn r<rev>` commit + `Merge branch
#                               '<r>' into <b>` --no-ff; formats MIRROR sync-from-svn.sh exactly);
#   git-UNTRACKED/-IGNORED (Inconsistency B) -> NO reconcile (bridge git tree stays clean).
# Not svn-tracked / missing path / missing bridge -> fail loudly, zero side effects.
#
# Mirrors Remove-SvnFile.test.ps1. svn-driven cases build a real bridge via initialize-git-svn-
# bridge.sh, so they SKIP when svn/svnadmin are unavailable. (The non-ASCII-filename reconcile is
# covered by the .ps1 suite + submit-svn-commit.sh's Chinese round-trip test; a bash re-pass of a
# non-ASCII argv follows the console codepage and is the known-limited area, so it is not repeated
# here.)
#
# KTD8 isolation: repo-relative gitignored sandbox; the test's OWN svn client calls (list) pass
# --config-dir; GIT_CEILING_DIRECTORIES fenced at the sandbox base.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/remove-svn-file.sh"
INIT_SCRIPT="$PLUGIN_ROOT/scripts/initialize-git-svn-bridge.sh"
BUILD_SCRIPT="$PLUGIN_ROOT/scripts/build-svn-commit.sh"
SUBMIT_SCRIPT="$PLUGIN_ROOT/scripts/submit-svn-commit.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"
SANDBOX_BASE="$PLUGIN_ROOT/tests/.sandbox/sandboxes"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
    mkdir -p "$SANDBOX_BASE"
    PREV_CEIL="${GIT_CEILING_DIRECTORIES:-}"
    export GIT_CEILING_DIRECTORIES="$SANDBOX_BASE"
}

oneTimeTearDown() {
    if [ -n "${PREV_CEIL:-}" ]; then
        export GIT_CEILING_DIRECTORIES="$PREV_CEIL"
    else
        unset GIT_CEILING_DIRECTORIES
    fi
}

setUp() {
    SB="$SANDBOX_BASE/tp-rmsvn-$$-${RANDOM}${RANDOM}"
    mkdir -p "$SB"
    CFG="$SB/.svnconfig"
}

tearDown() {
    if [ -n "${SB:-}" ] && [ -d "$SB" ]; then
        chmod -R +w "$SB" 2>/dev/null || true
        rm -rf "$SB" 2>/dev/null || true
    fi
}

svn_uri() {
    local repo="$1" win
    if command -v cygpath >/dev/null 2>&1; then
        win="$(cygpath -m "$repo")"
        printf 'file:///%s' "$win"
    else
        printf 'file://%s' "$repo"
    fi
}

bridge_path() { printf '%s' "$1/.turbo-plugin/worktrees/remote-svn-main"; }

# Build a bridge whose SVN content is: .gitignore(*.log) + app.txt + foo.csproj.user (git-tracked)
# + debug.log (git-IGNORED via *.log). Sets ROOT / BRIDGE globals. Returns non-zero on failure.
build_bridge_with_files() {
    ROOT="$SB/test-turbo-plugin"
    local repo="$SB/svnrepo" seed="$SB/seed" uri
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    uri="$(svn_uri "$repo")"
    mkdir -p "$seed"
    printf '*.log\n' > "$seed/.gitignore"
    printf 'app\n'   > "$seed/app.txt"
    printf 'prefs\n' > "$seed/foo.csproj.user"
    printf 'noise\n' > "$seed/debug.log"
    svn import "$seed" "$uri" -m seed --no-auto-props --config-dir "$CFG" >/dev/null 2>&1 || return 1

    mkdir -p "$ROOT"
    git -C "$ROOT" init -b main >/dev/null 2>&1 || git -C "$ROOT" init >/dev/null 2>&1
    git -C "$ROOT" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$ROOT" config user.name  'turbo-plugin-test' >/dev/null 2>&1
    ( cd "$ROOT" && bash "$INIT_SCRIPT" --svn-url "$uri" ) >/dev/null 2>&1 || return 1

    # tp-setup skeleton gitignore so main ignores the nested bridge container.
    printf '.turbo-plugin/worktrees/\n.svn/\n' >> "$ROOT/.gitignore"
    git -C "$ROOT" add .gitignore >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m 'chore: skeleton gitignore' >/dev/null 2>&1
    BRIDGE="$(bridge_path "$ROOT")"
    return 0
}

# Caller precondition for Un-track A: stop git-tracking on main (keep disk file) + ignore it.
untrack_on_main() {
    local rel="$1"
    git -C "$ROOT" rm --cached "$rel" >/dev/null 2>&1
    printf '%s\n' "$rel" >> "$ROOT/.gitignore"
    git -C "$ROOT" add .gitignore >/dev/null 2>&1
    git -C "$ROOT" -c commit.gpgsign=false commit -m "chore: stop tracking $rel" >/dev/null 2>&1
}

# Push main into the bridge (build + submit) to reach the NORMAL post-push state where
# remote-svn/main is ahead of main by a benign `Merge branch 'main' into remote-svn/main` commit.
push_main() {
    ( cd "$ROOT" && bash "$BUILD_SCRIPT" --branch main ) >/dev/null 2>&1 || return 1
    ( cd "$ROOT" && bash "$SUBMIT_SCRIPT" --branch main --title 'sync main to svn' ) >/dev/null 2>&1 || return 1
    return 0
}

# ── Case 0: script exists ─────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'remove-svn-file.sh exists' $?
}

# ── Case 1: missing --path -> required-arg error (no svn needed) ───────────────
test_missing_path() {
    local out rc
    out="$(cd "$SB" && bash "$SCRIPT_UNDER_TEST" --branch main 2>&1)"; rc=$?
    assertNotEquals "missing --path exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"--path"*) assertTrue 'mentions --path' 0 ;; *) fail "no --path wording: $out" ;; esac
}

# ── Case 2: Inconsistency B (git-ignored path) -> no-reconcile ─────────────────
test_inconsistency_b_no_reconcile() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    local rev_before rev_after out rc
    rev_before="$(git -C "$BRIDGE" rev-parse remote-svn/main)"
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path debug.log 2>&1)"; rc=$?
    assertEquals "no-reconcile exits 0 (out: $out)" 0 "$rc"
    if (cd "$BRIDGE" && svn list --config-dir "$CFG") | grep -q 'debug.log'; then fail 'debug.log still in svn'; else assertTrue 'debug.log removed from svn' 0; fi
    assertTrue 'bridge clean' "[ -z \"\$(git -C '$BRIDGE' status --porcelain)\" ]"
    rev_after="$(git -C "$BRIDGE" rev-parse remote-svn/main)"
    assertEquals 'remote-svn/main unchanged (no new commit)' "$rev_before" "$rev_after"
}

# ── Case 3: Un-track A (git-tracked path) -> reconcile, pull-identical formats ─
test_untrack_a_reconcile() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    untrack_on_main 'foo.csproj.user'
    assertTrue 'main clean before' "[ -z \"\$(git -C '$ROOT' status --porcelain)\" ]"

    local out rc tip main_tip
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path foo.csproj.user 2>&1)"; rc=$?
    assertEquals "reconcile exits 0 (out: $out)" 0 "$rc"

    if (cd "$BRIDGE" && svn list --config-dir "$CFG") | grep -q 'foo.csproj.user'; then fail 'foo.csproj.user still in svn'; else assertTrue 'removed from svn' 0; fi
    tip="$(git -C "$BRIDGE" log -1 --pretty=%s remote-svn/main)"
    case "$tip" in sync:\ svn\ r[0-9]*) assertTrue 'remote-svn/main tip is a sync commit' 0 ;; *) fail "remote-svn/main tip not a sync commit: '$tip'" ;; esac
    main_tip="$(git -C "$ROOT" log -1 --pretty=%s)"
    assertEquals 'main tip is the canonical merge commit' "Merge branch 'remote-svn/main' into main" "$main_tip"
    # every non-merge remote-svn/main commit is bridge-managed: a classic 'sync: svn r<N>' reconcile/
    # boundary commit, or a per-revision replay carrying an 'svn-revision:' trailer (U7 made the first
    # import per-revision). A stray bare commit matches neither.
    local bad=0 sha subj
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        subj="$(git -C "$BRIDGE" show -s --format=%s "$sha")"
        case "$subj" in sync:\ svn\ r[0-9]*) continue ;; esac
        if git -C "$BRIDGE" show -s --format=%B "$sha" | grep -qE '^svn-revision: [0-9]+$'; then continue; fi
        bad=1; echo "stray remote-svn/main commit: '$subj'" >&2
    done <<< "$(git -C "$BRIDGE" log --no-merges --pretty=%H remote-svn/main)"
    assertEquals 'remote-svn/main carries only bridge-managed commits (sync or replay-trailer)' 0 "$bad"
    # main keeps the disk file but no longer tracks it.
    assertTrue 'main keeps foo.csproj.user on disk' "[ -e '$ROOT/foo.csproj.user' ]"
    if git -C "$ROOT" ls-files foo.csproj.user | grep -q .; then fail 'main still tracks foo.csproj.user'; else assertTrue 'main untracks it' 0; fi
    assertTrue 'bridge clean' "[ -z \"\$(git -C '$BRIDGE' status --porcelain)\" ]"
}

# ── Case 4: pre-flight rejects a path not present in the bridge ───────────────
test_reject_missing_path() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    local list_before out rc
    list_before="$( (cd "$BRIDGE" && svn list --config-dir "$CFG") )"
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path nope.txt 2>&1)"; rc=$?
    assertNotEquals "missing path exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"not found in bridge"*) assertTrue 'reports not-found' 0 ;; *) fail "no not-found wording: $out" ;; esac
    assertEquals 'svn untouched' "$list_before" "$( (cd "$BRIDGE" && svn list --config-dir "$CFG") )"
}

# ── Case 5: pre-flight rejects an unversioned (not svn-tracked) path ──────────
test_reject_unversioned() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    # a *.log file: git-IGNORED (so the bridge porcelain stays clean and we reach the svn check),
    # but NOT under svn control -> svn status '?'.
    printf 'loose\n' > "$BRIDGE/extra.log"
    local out rc
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path extra.log 2>&1)"; rc=$?
    assertNotEquals "unversioned exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"not tracked by SVN"*) assertTrue 'reports not-svn-tracked' 0 ;; *) fail "no not-svn-tracked wording: $out" ;; esac
}

# ── Case 6: reconcile pre-flight refuses a DIRTY main worktree BEFORE the irreversible svn delete ─
test_reject_dirty_main() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    untrack_on_main 'foo.csproj.user'          # isolate the dirty condition
    printf 'locally modified\n' > "$ROOT/app.txt"   # dirty an UNRELATED tracked file
    local out rc
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path foo.csproj.user 2>&1)"; rc=$?
    assertNotEquals "dirty main exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"uncommitted changes"*) assertTrue 'reports dirty main' 0 ;; *) fail "no dirty-main wording: $out" ;; esac
    # svn delete did NOT happen; bridge unchanged.
    if (cd "$BRIDGE" && svn list --config-dir "$CFG") | grep -q 'foo.csproj.user'; then assertTrue 'foo.csproj.user still in svn' 0; else fail 'foo.csproj.user was deleted despite dirty main'; fi
    assertTrue 'bridge clean' "[ -z \"\$(git -C '$BRIDGE' status --porcelain)\" ]"
}

# ── Case 7: data-safety -- refuses when main still tracks the path (caller skipped git rm --cached) ─
test_reject_main_still_tracks() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    # DO NOT untrack_on_main: main still tracks foo.csproj.user (the contract violation).
    local out rc
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path foo.csproj.user 2>&1)"; rc=$?
    assertNotEquals "still-tracked exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"still git-tracked in the main worktree"*) assertTrue 'reports still-tracked' 0 ;; *) fail "no still-tracked wording: $out" ;; esac
    if (cd "$BRIDGE" && svn list --config-dir "$CFG") | grep -q 'foo.csproj.user'; then assertTrue 'still in svn' 0; else fail 'file deleted despite contract violation'; fi
    assertTrue 'file still on disk in main' "[ -e '$ROOT/foo.csproj.user' ]"
}

# ── Case 8: regression -- Un-track A works in the NORMAL post-push state ───────
# After a push, remote-svn/main is ahead of main by a benign `Merge branch 'main' into
# remote-svn/main` commit. Before the `--no-merges` guard fix, the unmerged-sync guard false-fired
# on that merge and refused. Verify it now reconciles cleanly.
test_untrack_a_after_push_regression() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    if ! push_main; then startSkipping; return 0; fi
    # Confirm the post-push state: remote-svn/main ahead by exactly ONE commit, and it is a MERGE.
    assertEquals 'remote-svn/main ahead by one commit (post-push)' 1 "$(git -C "$ROOT" rev-list --count main..remote-svn/main)"
    assertEquals 'the ahead commit is a merge (benign)' 0 "$(git -C "$ROOT" rev-list --count --no-merges main..remote-svn/main)"

    untrack_on_main 'foo.csproj.user'
    local out rc tip main_tip
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path foo.csproj.user 2>&1)"; rc=$?
    case "$out" in *"unmerged sync"*) fail "regressed: guard false-fired in post-push state: $out" ;; *) assertTrue 'no false unmerged-sync refusal' 0 ;; esac
    assertEquals "post-push reconcile exits 0 (out: $out)" 0 "$rc"
    if (cd "$BRIDGE" && svn list --config-dir "$CFG") | grep -q 'foo.csproj.user'; then fail 'foo.csproj.user still in svn'; else assertTrue 'removed from svn' 0; fi
    tip="$(git -C "$BRIDGE" log -1 --pretty=%s remote-svn/main)"
    case "$tip" in sync:\ svn\ r[0-9]*) assertTrue 'remote-svn/main tip is a sync commit' 0 ;; *) fail "tip not a sync commit: '$tip'" ;; esac
    main_tip="$(git -C "$ROOT" log -1 --pretty=%s)"
    assertEquals 'main tip is the canonical merge' "Merge branch 'remote-svn/main' into main" "$main_tip"
    assertTrue 'main keeps the disk file' "[ -e '$ROOT/foo.csproj.user' ]"
    assertTrue 'bridge clean' "[ -z \"\$(git -C '$BRIDGE' status --porcelain)\" ]"
}

# ── Case 9: a GENUINE orphaned sync (non-merge `sync:` ahead) must still be refused ────
# The --no-merges guard must NOT weaken protection: a real interrupted pull leaves a non-merge
# `sync:` commit ahead of main, and Remove-SvnFile must still refuse it.
test_reject_orphaned_sync_ahead() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if ! build_bridge_with_files; then startSkipping; return 0; fi
    # Simulate an interrupted pull: a non-merge sync commit on remote-svn/main not merged to main.
    git -C "$BRIDGE" -c commit.gpgsign=false commit --allow-empty -m 'sync: svn r777' >/dev/null 2>&1
    untrack_on_main 'foo.csproj.user'
    local out rc
    out="$(cd "$ROOT" && bash "$SCRIPT_UNDER_TEST" --branch main --path foo.csproj.user 2>&1)"; rc=$?
    assertNotEquals "orphaned sync refuses (out: $out)" 0 "$rc"
    case "$out" in *"unmerged sync"*) assertTrue 'refuses on genuine orphaned sync' 0 ;; *) fail "did not refuse orphaned sync: $out" ;; esac
    # No svn mutation happened.
    if (cd "$BRIDGE" && svn list --config-dir "$CFG") | grep -q 'foo.csproj.user'; then assertTrue 'file still in svn' 0; else fail 'file deleted despite orphaned-sync refusal'; fi
}

# shellcheck disable=SC1090
. "$SHUNIT2"
