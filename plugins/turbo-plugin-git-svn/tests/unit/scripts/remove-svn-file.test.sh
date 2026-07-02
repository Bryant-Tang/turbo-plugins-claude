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
    # every remote-svn/main subject is sync: or Merge branch
    local bad=0 s
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        case "$s" in sync:\ svn\ r[0-9]*) : ;; "Merge branch "*) : ;; *) bad=1 ;; esac
    done <<< "$(git -C "$BRIDGE" log --pretty=%s remote-svn/main)"
    assertEquals 'remote-svn/main carries only sync + merge commits' 0 "$bad"
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

# shellcheck disable=SC1090
. "$SHUNIT2"
