#!/usr/bin/env bash
# initialize-git-svn-bridge.test.sh (shUnit2)
#
# Script under test: scripts/initialize-git-svn-bridge.sh.
# Contract: --svn-url <url> [--branch <name=main>]. First-bridge bootstrap that bridges the
# CURRENT repo to an SVN URL and merges the SVN content into the current branch. Two arms on
# "has root commit": case (a) no HEAD -> empty root commit + merge (unrelated histories);
# case (b) has HEAD -> merge into the current branch (can conflict on overlap). Pre-bridge
# guards: scheme allowlist (^(https?|svn|file)://) and a git-identity check emitting
# TP_TOKEN:IDENTITY_REQUIRED. A merge conflict emits TP_TOKEN:MERGE_CONFLICT (no abort/rollback).
# A mid-run failure AFTER the bridge worktree exists rolls back the local git side.
#
# Mirrors Initialize-GitSvnBridge.test.ps1 scenario-for-scenario. svn-driven cases SKIP when
# svn/svnadmin (or the seed dump) are unavailable.
#
# KTD8 isolation (stricter than new-remote-bridge.test.sh):
#   * REPO-RELATIVE gitignored sandbox under tests/.sandbox/sandboxes (NOT system mktemp), the
#     same root ScriptsCommon.ps1 uses; ReadOnly .svn/ files chmod +w'd before rm.
#   * EVERY svn CLIENT call the test makes (propget) passes --config-dir <sandbox>/.svnconfig so
#     the real ~/.subversion is untouched. svnadmin create/load take no --config-dir.
#   * GIT_CEILING_DIRECTORIES is fenced at the sandbox base: the sandbox lives INSIDE this plugin's
#     own git repo, so a not-yet-a-repo test dir (scenario 6 pre-init) would otherwise let the
#     script's git rev-parse / worktree / clean escape UPWARD into the real repo.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/initialize-git-svn-bridge.sh"
DUMP_PATH="$PLUGIN_ROOT/tests/fixtures/seed/svn-repo-r1-r20.dump"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"
SANDBOX_BASE="$PLUGIN_ROOT/tests/.sandbox/sandboxes"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
    HAS_DUMP=0
    if [ -f "$DUMP_PATH" ]; then HAS_DUMP=1; fi
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
    SB="$SANDBOX_BASE/tp-igsb-$$-${RANDOM}${RANDOM}"
    mkdir -p "$SB"
    CFG="$SB/.svnconfig"
}

tearDown() {
    if [ -n "${SB:-}" ] && [ -d "$SB" ]; then
        chmod -R +w "$SB" 2>/dev/null || true
        rm -rf "$SB" 2>/dev/null || true
    fi
}

# Echo a file:/// URI for an svn repo path (Windows drive form via cygpath when present).
svn_uri() {
    local repo="$1" win
    if command -v cygpath >/dev/null 2>&1; then
        win="$(cygpath -m "$repo")"
        printf 'file:///%s' "$win"
    else
        printf 'file://%s' "$repo"
    fi
}

# Create an svn repo. $1=path, $2=1 to load the seed dump (trunk + branches), else empty rev-0.
# svnadmin takes NO --config-dir. Returns non-zero on failure.
make_svn_repo() {
    local repo="$1" load="${2:-0}"
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    if [ "$load" -eq 1 ]; then
        svnadmin load "$repo" < "$DUMP_PATH" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# git init -b main + identity, no commit (case (a) base). Isolated by its own .git.
init_repo_with_identity() {
    local root="$1"
    mkdir -p "$root"
    git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo-plugin-test' >/dev/null 2>&1
    # Pin EOL handling so a replayed/merged tree never trips autocrlf normalisation mid-pull.
    git -C "$root" config core.autocrlf false >/dev/null 2>&1
}

# Build a small svn repo with <total> revisions at the ROOT (import=r1 + (total-1) file commits).
# Echoes the file:/// URI on success, nothing on failure. Client calls isolated via --config-dir.
make_small_svn_repo() {
    local repo="$1" total="$2" seed co n uri
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    uri="$(svn_uri "$repo")"
    seed="$SB/seed-$RANDOM"
    mkdir -p "$seed"
    printf 'app\n'   > "$seed/app.txt"
    printf '*.log\n' > "$seed/.gitignore"
    svn import "$seed" "$uri" -m 'import 1' --config-dir "$CFG" >/dev/null 2>&1 || return 1
    if (( total > 1 )); then
        co="$SB/co-$RANDOM"
        svn checkout "$uri" "$co" --config-dir "$CFG" >/dev/null 2>&1 || return 1
        for (( n = 2; n <= total; n++ )); do
            printf 'content %s\n' "$n" > "$co/file$n.txt"
            svn add "$co/file$n.txt" --config-dir "$CFG" >/dev/null 2>&1 || return 1
            ( cd "$co" && svn commit -m "change $n" --config-dir "$CFG" >/dev/null 2>&1 ) || return 1
        done
    fi
    printf '%s' "$uri"
}

# Count of trailer-bearing replay commits on remote-svn/main (numeric svn-revision trailers).
count_trailer_commits() {
    git -C "$1" log remote-svn/main --format='%(trailers:key=svn-revision,valueonly)' 2>/dev/null \
        | grep -cE '^[0-9]+$' || true
}

# Echo the bridge worktree path for the default 'main' branch.
bridge_path() { printf '%s' "$1/.turbo-plugin/worktrees/remote-svn-main"; }

# Count of remote-svn/main branches (0 when none).
bridge_branch_count() { git -C "$1" branch --list 'remote-svn/main' 2>/dev/null | grep -c . ; }

# ── Case 0: script exists ─────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'initialize-git-svn-bridge.sh exists' $?
}

# ── Scenario 1: case (a) + EMPTY svn -> clean connect, empty main ──────────────
test_case_a_empty_svn() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root bridge out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"   # case (a): no commit -> no HEAD
    if ! make_svn_repo "$SB/svnrepo" 0; then startSkipping; return 0; fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc=$?
    assertEquals "case (a) empty svn exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac

    assertEquals 'exactly one remote-svn/main' 1 "$(bridge_branch_count "$root")"
    bridge="$(bridge_path "$root")"
    assertTrue 'bridge worktree clean' "[ -z \"\$(git -C '$bridge' status --porcelain)\" ]"
    local ign
    ign="$(svn propget --config-dir "$CFG" svn:ignore "$bridge" 2>/dev/null | tr -d '\r\n')"
    assertEquals 'bridge svn:ignore is exactly .git' '.git' "$ign"
    # main is empty: only the merged .gitignore, no svn project files.
    assertEquals 'main has only .gitignore' '.gitignore' "$(git -C "$root" ls-files | tr -d '\r')"
}

# ── Scenario 2: case (a) + NON-EMPTY svn (/trunk, >5 revs) + squash -> single lump on main ─────
# The seed /trunk carries >5 revisions, so the first import needs a granularity choice; `squash`
# reproduces today's single-commit shape (one lump). Also pins the setup invariants.
test_case_a_nonempty_svn() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root bridge out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    if ! make_svn_repo "$SB/svnrepo" 1; then startSkipping; return 0; fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")/trunk" --granularity squash 2>&1)"; rc=$?
    assertEquals "case (a) trunk squash exits 0 (out: $out)" 0 "$rc"
    # squash => exactly ONE replay commit on remote-svn/main (single lump, not per-revision).
    assertEquals 'squash import is a single lump commit' 1 "$(git -C "$root" rev-list --count remote-svn/main)"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac

    if git -C "$root" ls-files | grep -q 'README.txt'; then assertTrue 'main has svn content' 0; else fail 'main missing README.txt'; fi
    bridge="$(bridge_path "$root")"
    assertTrue 'bridge worktree clean' "[ -z \"\$(git -C '$bridge' status --porcelain)\" ]"
    if grep -qxF '.svn/' "$bridge/.gitignore" 2>/dev/null; then assertTrue 'bridge .gitignore has .svn/' 0; else fail 'bridge .gitignore missing .svn/'; fi
    if git -C "$bridge" ls-files | grep -q '^\.svn'; then fail '.svn is tracked in git'; else assertTrue '.svn not tracked' 0; fi
}

# ── Scenario 3: case (b) + overlapping svn (different) -> MERGE_CONFLICT ────────
test_case_b_conflict() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    # trunk has README.txt; commit a DIFFERENT README.txt on the git side -> add/add conflict.
    printf 'GIT-SIDE README - intentional conflict\n' > "$root/README.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    if ! make_svn_repo "$SB/svnrepo" 1; then startSkipping; return 0; fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")/trunk" --granularity squash 2>&1)"; rc=$?
    assertNotEquals "conflict exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:MERGE_CONFLICT"*) assertTrue 'emits MERGE_CONFLICT token' 0 ;; *) fail "no MERGE_CONFLICT token: $out" ;; esac
    case "$out" in *"README.txt"*) assertTrue 'names the conflicted file' 0 ;; *) fail "conflict file not named: $out" ;; esac
    # Merge left in progress (NOT aborted).
    assertTrue 'MERGE_HEAD present (merge in progress)' "[ -f '$root/.git/MERGE_HEAD' ]"
}

# ── Scenario 4: case (b) + NON-overlapping svn -> clean merge of both sides ────
test_case_b_no_overlap() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    if [ "$HAS_DUMP" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    printf 'original git-only file\n' > "$root/original.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    if ! make_svn_repo "$SB/svnrepo" 1; then startSkipping; return 0; fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")/trunk" --granularity squash 2>&1)"; rc=$?
    assertEquals "no-overlap exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac
    if git -C "$root" ls-files | grep -q 'original.txt'; then assertTrue 'main keeps original' 0; else fail 'main missing original.txt'; fi
    if git -C "$root" ls-files | grep -q 'README.txt'; then assertTrue 'main gained svn content' 0; else fail 'main missing README.txt'; fi
}

# ── Scenario 5: case (b) + EMPTY svn -> no-op merge, original intact ───────────
test_case_b_empty_svn() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root bridge out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    printf 'keep me intact\n' > "$root/original.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    if ! make_svn_repo "$SB/svnrepo" 0; then startSkipping; return 0; fi
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc=$?
    assertEquals "case (b) empty svn exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac
    assertEquals 'original content intact' 'keep me intact' "$(cat "$root/original.txt" | tr -d '\r')"
    if git -C "$root" ls-files | grep -q 'original.txt'; then assertTrue 'main keeps original' 0; else fail 'main missing original.txt'; fi
    bridge="$(bridge_path "$root")"
    assertTrue 'bridge worktree clean' "[ -z \"\$(git -C '$bridge' status --porcelain)\" ]"
}

# ── Scenario 6: identity gate, then a clean re-run ────────────────────────────
test_identity_then_rerun() {
    local root out rc out2 rc2
    root="$SB/test-turbo-plugin"
    mkdir -p "$root"   # NOT a git repo yet -> script git-inits it (fenced by GIT_CEILING_DIRECTORIES)

    # Hide ambient git identity.
    printf '' > "$SB/empty-global.gitconfig"
    printf '' > "$SB/empty-system.gitconfig"
    export GIT_CONFIG_GLOBAL="$SB/empty-global.gitconfig"
    export GIT_CONFIG_SYSTEM="$SB/empty-system.gitconfig"

    # --- no identity -> TP_TOKEN:IDENTITY_REQUIRED, exit 1, .git created, no bridge ---
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc=$?
    assertEquals "no-identity exits 1 (out: $out)" 1 "$rc"
    case "$out" in *"TP_TOKEN:IDENTITY_REQUIRED"*) assertTrue 'emits IDENTITY_REQUIRED token' 0 ;; *) fail "no IDENTITY_REQUIRED token: $out" ;; esac
    assertTrue '.git created by the script' "[ -d '$root/.git' ]"
    assertEquals 'no bridge branch yet' 0 "$(bridge_branch_count "$root")"

    if [ "$HAS_SVN" -ne 1 ]; then
        unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
        return 0
    fi
    # --- set local identity + re-run -> success, exactly one remote-svn/main ---
    make_svn_repo "$SB/svnrepo" 0 || { unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM; startSkipping; return 0; }
    git -C "$root" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo-plugin-test' >/dev/null 2>&1
    out2="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc2=$?
    assertEquals "re-run exits 0 (out: $out2)" 0 "$rc2"
    case "$out2" in *"SVN bridge connected."*) assertTrue 'reports connected on re-run' 0 ;; *) fail "no connect line on re-run: $out2" ;; esac
    assertEquals 'exactly one remote-svn/main (no duplicate)' 1 "$(bridge_branch_count "$root")"

    unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
}

# ── Scenario 7: invalid SVN URL -> rejected before any side effect ────────────
test_invalid_url() {
    local root out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url 'not-a-url' 2>&1)"; rc=$?
    assertNotEquals "invalid url exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"invalid SVN URL"*) assertTrue 'reports invalid SVN URL' 0 ;; *) fail "no invalid-url wording: $out" ;; esac
    assertTrue 'no bridge dir created' "[ ! -d '$(bridge_path "$root")' ]"
}

# ── Scenario 8: unreachable (scheme-valid) SVN URL -> fail with no residue ────
test_rollback_on_checkout_failure() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc bogus
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    printf 'git-only\n' > "$root/original.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    # Scheme-valid file:// URL at a non-existent repo: passes URL/identity/case-split, then the U7
    # early granularity probe (svn info on the URL, BEFORE the worktree exists) fails -> clean exit,
    # nothing created. (The rollback trap still guards genuine mid-run failures past worktree add.)
    bogus="$(svn_uri "$SB/no-such-repo")"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$bogus" 2>&1)"; rc=$?
    assertNotEquals "checkout failure exits non-zero (out: $out)" 0 "$rc"
    assertEquals 'rollback removed bridge branch' 0 "$(bridge_branch_count "$root")"
    assertTrue 'rollback removed bridge worktree dir' "[ ! -d '$(bridge_path "$root")' ]"
}

# ── Scenario 9 (U7): <=5-revision URL -> per-revision auto import, each commit trailer-greppable ─
test_le5_per_revision_import() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root uri out rc ign
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    uri="$(make_small_svn_repo "$SB/svnrepo" 3)" || { startSkipping; return 0; }
    [ -n "$uri" ] || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri" 2>&1)"; rc=$?
    assertEquals "<=5 import exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac
    # No granularity prompt on a <=5 import (replays per-revision silently).
    case "$out" in *TP_TOKEN:GRANULARITY_REQUIRED*) fail "unexpected granularity prompt on <=5 import: $out" ;; *) assertTrue 'no prompt' 0 ;; esac
    # 3 revisions -> 3 trailer-bearing replay commits (NOT one squashed lump).
    assertEquals 'three per-revision replay commits (trailer-greppable)' 3 "$(count_trailer_commits "$root")"
    # Setup invariant: svn:ignore is exactly .git; the .svn metadata dir is not tracked by git.
    ign="$(svn propget --config-dir "$CFG" svn:ignore "$(bridge_path "$root")" 2>/dev/null | tr -d '\r\n')"
    assertEquals 'bridge svn:ignore is exactly .git' '.git' "$ign"
    if git -C "$(bridge_path "$root")" ls-files | grep -q '^\.svn'; then fail '.svn is tracked in git'; else assertTrue '.svn not tracked' 0; fi
}

# ── Scenario 10 (U7): >5-revision URL, no --granularity -> prompt token, ZERO residue ──────────
test_over5_prompts_residue_free() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root uri out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    uri="$(make_small_svn_repo "$SB/svnrepo" 7)" || { startSkipping; return 0; }
    [ -n "$uri" ] || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri" 2>&1)"; rc=$?
    assertEquals "needs-choice exits 0 (not a failure) (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:GRANULARITY_REQUIRED count=7"*) assertTrue 'emits granularity token count=7' 0 ;; *) fail "no granularity token: $out" ;; esac
    # Residue-free: nothing created, so a re-run (with a choice) is clean.
    assertEquals 'no bridge branch created' 0 "$(bridge_branch_count "$root")"
    assertTrue 'no bridge worktree dir' "[ ! -d '$(bridge_path "$root")' ]"
}

# ── Scenario 11 (U7): >5-revision URL + --granularity per-revision -> N replay commits ─────────
test_over5_per_revision() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root uri out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    uri="$(make_small_svn_repo "$SB/svnrepo" 7)" || { startSkipping; return 0; }
    [ -n "$uri" ] || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri" --granularity per-revision 2>&1)"; rc=$?
    assertEquals ">5 per-revision exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac
    assertEquals 'seven per-revision replay commits' 7 "$(count_trailer_commits "$root")"
}

# ── Scenario 12 (U7): after bootstrap, a subsequent tp-pull-from-svn finds nothing new ─────────
test_subsequent_pull_is_noop() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root uri out rc before pull_out pull_rc after
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    uri="$(make_small_svn_repo "$SB/svnrepo" 3)" || { startSkipping; return 0; }
    [ -n "$uri" ] || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri" 2>&1)"; rc=$?
    assertEquals "bootstrap exits 0 (out: $out)" 0 "$rc"
    # Skeleton .gitignore (as tp-setup writes post-bootstrap) so the nested bridge worktree dir does
    # not show as untracked and trip the pull's main-dirty guard.
    printf '%s\n' '/.turbo-plugin/worktrees/' '.svn/' '*.log' > "$root/.gitignore"
    git -C "$root" add .gitignore >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m 'chore: skeleton gitignore' >/dev/null 2>&1
    before="$(git -C "$root" rev-list --count remote-svn/main)"
    pull_out="$(cd "$root" && bash "$PLUGIN_ROOT/scripts/sync-from-svn.sh" --branch main 2>&1)"; pull_rc=$?
    assertEquals "subsequent pull exits 0 (out: $pull_out)" 0 "$pull_rc"
    case "$pull_out" in *"Already up to date"*) assertTrue 'follow-up pull is a no-op' 0 ;; *) fail "pull found new work: $pull_out" ;; esac
    after="$(git -C "$root" rev-list --count remote-svn/main)"
    assertEquals 'no new commits from the follow-up pull' "$before" "$after"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
