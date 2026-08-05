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

# shellcheck disable=SC1091
source "$PLUGIN_ROOT/tests/lib/svn-uri.sh"

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

# Build an svn repo whose FIRST revision has NO .gitignore and where a LATER revision ADDS one.
# This is the shape that used to deadlock a per-revision bootstrap: the bridge .gitignore was
# written while the WC sat at r1, so the incoming add at r3 hit a tree conflict and svn sat on its
# interactive prompt forever. Echoes the file:/// URI on success, nothing on failure.
make_svn_repo_gitignore_added_later() {
    local repo="$1" seed co uri
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    uri="$(svn_uri "$repo")"
    seed="$SB/seedgi-$RANDOM"
    mkdir -p "$seed"
    printf 'app\n' > "$seed/app.txt"                       # r1: deliberately NO .gitignore
    svn import "$seed" "$uri" -m 'import 1' --config-dir "$CFG" >/dev/null 2>&1 || return 1
    co="$SB/cogi-$RANDOM"
    svn checkout "$uri" "$co" --config-dir "$CFG" >/dev/null 2>&1 || return 1
    printf 'two\n' > "$co/file2.txt"
    svn add "$co/file2.txt" --config-dir "$CFG" >/dev/null 2>&1 || return 1
    ( cd "$co" && svn commit -m 'change 2' --config-dir "$CFG" >/dev/null 2>&1 ) || return 1
    printf '*.log\n' > "$co/.gitignore"                    # r3: SVN adds its own .gitignore
    svn add "$co/.gitignore" --config-dir "$CFG" >/dev/null 2>&1 || return 1
    ( cd "$co" && svn commit -m 'add gitignore' --config-dir "$CFG" >/dev/null 2>&1 ) || return 1
    printf '%s' "$uri"
}

# Count of MARKED revisions (refs/tp/svn/<N>) -- one per replayed revision.
count_trailer_commits() {
    git -C "$1" for-each-ref --format='%(refname:lstrip=3)' 'refs/tp/svn/*' 2>/dev/null \
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
    # main is empty and STAYS empty. Since U4 the bridge no longer invents a .gitignore, so an
    # empty SVN URL contributes nothing at all -- the project's own .gitignore is tp-setup's job,
    # after this script returns.
    assertEquals 'main has no files (the bridge invents nothing)' '' "$(git -C "$root" ls-files | tr -d '\r')"
}

# Build an svn repo that HAS HISTORY, plus a landing path that EXISTS BUT IS EMPTY. That is the
# exact shape `new-svn-path` produces: a brand-new project gets its trunk created inside a
# repository several other projects already share, so the repo HEAD is well past r0 while the path
# itself has never had a single file. Echoes the file:/// URI OF THE EMPTY TRUNK.
#
# This is NOT the same as Scenario 1's empty repo. There, HEAD is r0 and the import has no
# revisions to consider at all; here the import walks real revisions and finds that none of them
# touched this path -- which lands in a different branch of the bootstrap and left the bridge
# branch unborn (step 13 then died on "not something we can merge", misreported as a conflict).
make_svn_repo_with_empty_trunk() {
    local repo="$1" seed co uri n
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    uri="$(svn_uri "$repo")"
    svn mkdir --parents -m 'layout' "$uri/other/trunk" "$uri/proj-new/trunk" --config-dir "$CFG" >/dev/null 2>&1 || return 1
    co="$SB/co-other-$RANDOM"
    svn checkout "$uri/other/trunk" "$co" --config-dir "$CFG" >/dev/null 2>&1 || return 1
    for (( n = 1; n <= 3; n++ )); do
        printf 'other %s\n' "$n" > "$co/other$n.txt"
        svn add "$co/other$n.txt" --config-dir "$CFG" >/dev/null 2>&1 || return 1
        ( cd "$co" && svn commit -m "other change $n" --config-dir "$CFG" >/dev/null 2>&1 ) || return 1
    done
    printf '%s' "$uri/proj-new/trunk"
}

# ── Scenario 1b: case (a) + a landing path that EXISTS BUT IS EMPTY, in a repo with history ────
test_case_a_empty_trunk_in_populated_repo() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root bridge url out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    url="$(make_svn_repo_with_empty_trunk "$SB/svnrepo")"
    if [ -z "$url" ]; then startSkipping; return 0; fi

    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$url" 2>&1)"; rc=$?
    assertEquals "empty landing path exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"SVN bridge connected."*) assertTrue 'reports connected' 0 ;; *) fail "no connect line: $out" ;; esac
    # The failure this locks down reported a conflict with an EMPTY conflict list.
    case "$out" in *MERGE_CONFLICT*) fail "claimed a merge conflict: $out" ;; esac
    case "$out" in *MERGE_FAILED*)  fail "merge was refused: $out" ;; esac

    assertEquals 'exactly one remote-svn/main' 1 "$(bridge_branch_count "$root")"
    bridge="$(bridge_path "$root")"
    # The bridge branch must be a real commit, not an unborn ref: that is what step 13 merges.
    git -C "$bridge" rev-parse --verify --quiet HEAD >/dev/null 2>&1
    assertTrue 'bridge branch has at least one commit' $?
    assertTrue 'bridge worktree clean' "[ -z \"\$(git -C '$bridge' status --porcelain)\" ]"
    assertTrue 'main has a commit' "git -C '$root' rev-parse --verify --quiet HEAD >/dev/null 2>&1"
    assertEquals 'main has no files (the empty path contributes nothing)' '' "$(git -C "$root" ls-files | tr -d '\r')"
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
    # The bridge mirrors SVN exactly. This seed's /trunk carries no .gitignore, so neither does the
    # bridge -- before U4 the bootstrap invented one containing '.svn/', which is what made a
    # first-time takeover conflict with any project that had a .gitignore of its own.
    # Keeping '.svn/' out of git is info/exclude's job now, checked by the assertion after this one.
    if [ -e "$bridge/.gitignore" ]; then fail "bridge invented a .gitignore SVN does not have: $(cat "$bridge/.gitignore")"; else assertTrue 'bridge invented no .gitignore' 0; fi
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

# ── Scenario 3b (U4): case (b) where the project ALREADY has a .gitignore -> no conflict ───────
# The real-machine symptom (2026-07-31): proj-1 had no .gitignore and connected cleanly; proj-2 had
# ONE line (`*.log`) and hit a merge conflict every time. Cause: the bootstrap wrote `.svn/` into
# the bridge's .gitignore and committed it, so both unrelated histories "added" that file with
# different content -- and git conflicts on add/add unless the two sides are byte-identical
# (verified: a strict superset conflicts too). Since practically every real project has a
# .gitignore, first-time takeover conflicted essentially always, on a file the tool itself dirtied.
test_case_b_existing_gitignore_does_not_conflict() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root uri out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    # The project's own .gitignore -- one ordinary line, nothing to do with SVN.
    printf '*.log\n' > "$root/.gitignore"
    printf 'app\n'   > "$root/app-git.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m 'initial with gitignore' >/dev/null 2>&1
    # An SVN side with content but NO .gitignore of its own -- proj-2's exact shape, and the reason
    # the old code conflicted: with SVN contributing none, the ONLY .gitignore on the bridge side
    # was the `.svn/` line the bootstrap wrote itself.
    svnadmin create "$SB/svnrepo" >/dev/null 2>&1 || { startSkipping; return 0; }
    uri="$(svn_uri "$SB/svnrepo")"
    mkdir -p "$SB/seed-nogi"
    printf 'svn-side\n' > "$SB/seed-nogi/app-svn.txt"
    svn import "$SB/seed-nogi" "$uri" -m 'import (no gitignore)' --config-dir "$CFG" >/dev/null 2>&1 || { startSkipping; return 0; }
    # One revision, so no granularity choice is involved -- this case is purely about the merge.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri" 2>&1)"; rc=$?
    assertEquals "takeover of a project that already has .gitignore exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:MERGE_CONFLICT"*) fail "manufactured a .gitignore conflict: $out" ;; *) assertTrue 'no merge conflict' 0 ;; esac
    # The project's rule survived untouched -- the fix must not silently rewrite the user's file.
    if grep -qxF '*.log' "$root/.gitignore" 2>/dev/null; then assertTrue "project's own .gitignore rule kept" 0; else fail "project .gitignore lost its rule: $(cat "$root/.gitignore" 2>/dev/null)"; fi
    if git -C "$root" ls-files | grep -q 'app-git.txt'; then assertTrue 'project files kept' 0; else fail 'project files lost'; fi
}

# ── Scenario 3c (U5): "cannot reach" and "path does not exist" are told apart ──────────────────
# Both used to collapse into "could not read SVN revision from '<url>'. Is the URL reachable?" with
# svn's own stderr thrown away -- so pointing it at a perfectly reachable repository with a typo'd
# or not-yet-created path produced a message about reachability, which is simply false. They need
# opposite responses: unreachable is an environment problem, a missing path is normal and offerable
# to create (nothing in this plugin ever ran `svn mkdir`, so the landing spot had to exist first).
test_svn_unreachable_is_classified() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/no-such-repo")" 2>&1)"; rc=$?
    assertNotEquals "unreachable exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:SVN_UNREACHABLE"*) assertTrue 'emits SVN_UNREACHABLE' 0 ;; *) fail "no SVN_UNREACHABLE token: $out" ;; esac
    case "$out" in *"TP_TOKEN:SVN_PATH_MISSING"*) fail "misclassified as a missing path: $out" ;; *) assertTrue 'not misclassified' 0 ;; esac
    # svn's own words must survive -- they name the actual cause (auth, DNS, a typo).
    case "$out" in *"svn: "*) assertTrue "svn's message is passed through" 0 ;; *) fail "svn stderr was swallowed: $out" ;; esac
    # Zero residue: nothing created, so a re-run after fixing the URL is clean.
    assertEquals 'no bridge branch created' 0 "$(bridge_branch_count "$root")"
    assertTrue 'no bridge worktree created' "[ ! -e '$(bridge_path "$root")' ]"
}

test_svn_path_missing_is_classified() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    if ! make_svn_repo "$SB/svnrepo" 0; then startSkipping; return 0; fi
    # The repository is reachable; only the project's landing path is absent.
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")/proj-3/trunk" 2>&1)"; rc=$?
    assertNotEquals "missing path exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:SVN_PATH_MISSING"*) assertTrue 'emits SVN_PATH_MISSING' 0 ;; *) fail "no SVN_PATH_MISSING token: $out" ;; esac
    case "$out" in *"TP_TOKEN:SVN_UNREACHABLE"*) fail "misclassified as unreachable: $out" ;; *) assertTrue 'not misclassified' 0 ;; esac
    case "$out" in *"reachable"*) assertTrue 'says the repository IS reachable' 0 ;; *) fail "did not distinguish reachability: $out" ;; esac
    assertEquals 'no bridge branch created' 0 "$(bridge_branch_count "$root")"
    assertTrue 'no bridge worktree created' "[ ! -e '$(bridge_path "$root")' ]"
}

# ── Scenario 3d (U5): New-SvnPath creates the landing path, only when asked ────────────────────
test_new_svn_path_creates_layout() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local mk uri out rc
    mk="$PLUGIN_ROOT/scripts/new-svn-path.sh"
    if ! make_svn_repo "$SB/svnrepo" 0; then startSkipping; return 0; fi
    uri="$(svn_uri "$SB/svnrepo")"

    # --dry-run touches nothing: the whole point of "we ask before writing" is that asking is free.
    out="$(bash "$mk" --svn-url "$uri/proj-3/trunk" --standard-layout --dry-run 2>&1)"; rc=$?
    assertEquals "dry-run exits 0 (out: $out)" 0 "$rc"
    case "$out" in *"proj-3/branches"*) assertTrue 'dry-run lists branches/' 0 ;; *) fail "dry-run missed branches/: $out" ;; esac
    svn info "$uri/proj-3" --config-dir "$CFG" >/dev/null 2>&1
    assertNotEquals 'dry-run wrote nothing to SVN' 0 $?

    out="$(bash "$mk" --svn-url "$uri/proj-3/trunk" --standard-layout 2>&1)"; rc=$?
    assertEquals "create exits 0 (out: $out)" 0 "$rc"
    # trunk / branches / tags all exist -- and `branches` is not decoration: creating a branch is an
    # `svn copy` WITHOUT --parents, so an absent branches/ makes the first branch push fail outright.
    local missing=''
    for leaf in trunk branches tags; do
        svn info "$uri/proj-3/$leaf" --config-dir "$CFG" >/dev/null 2>&1 || missing="$missing $leaf"
    done
    assertEquals "trunk/branches/tags all created (missing:$missing)" '' "$missing"
    # One revision for the whole layout, so a half-created structure is not reachable.
    assertEquals 'the layout landed in a single revision' 1 "$(svn info --show-item revision "$uri" --config-dir "$CFG" 2>/dev/null | tr -d '[:space:]')"

    # Creating something that already exists is an error, not a silent no-op.
    out="$(bash "$mk" --svn-url "$uri/proj-3/trunk" 2>&1)"; rc=$?
    assertNotEquals 'creating an existing path fails' 0 "$rc"
    case "$out" in *"already exists"*) assertTrue 'says it already exists' 0 ;; *) fail "unclear message: $out" ;; esac

    # --standard-layout only has an unambiguous meaning under /trunk.
    out="$(bash "$mk" --svn-url "$uri/proj-4" --standard-layout 2>&1)"; rc=$?
    assertNotEquals '--standard-layout without /trunk is refused' 0 "$rc"
    svn info "$uri/proj-4" --config-dir "$CFG" >/dev/null 2>&1
    assertNotEquals 'refusal wrote nothing' 0 $?
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

# ── Scenario 7b: wrong-repo guard 1 -- refuse to bootstrap from a LINKED worktree ─
# Regression for a real incident: the script resolves its target from the AMBIENT cwd, so an
# invocation made inside a linked worktree bootstrapped a bridge into a DIFFERENT checkout (the
# repo's main worktree) and merged SVN content into ITS current branch. No svn needed -- the guard
# fires before any svn call.
test_refuses_linked_worktree() {
    local root peer out rc
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    printf 'seed\n' > "$root/seed.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    peer="$SB/peer-worktree"
    git -C "$root" worktree add -b peer-branch "$peer" >/dev/null 2>&1 || { startSkipping; return 0; }

    out="$(cd "$peer" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc=$?
    assertNotEquals "linked-worktree bootstrap exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"linked worktree"*) assertTrue 'reports the linked-worktree refusal' 0 ;; *) fail "no linked-worktree wording: $out" ;; esac
    # The OTHER checkout must be untouched.
    assertEquals 'no bridge branch created in the main worktree' 0 "$(bridge_branch_count "$root")"
    assertTrue 'no bridge worktree dir created' "[ ! -d '$(bridge_path "$root")' ]"
    assertTrue 'main worktree left clean' "[ -z \"\$(git -C '$root' status --porcelain)\" ]"
}

# ── Scenario 7c: wrong-repo guard 2 -- existing git remote gates on confirmation ─
# A repo that already has a git remote already has a git server, which is not what this plugin
# bridges; overwhelmingly it means the cwd was wrong. Token + zero changes, overridable by flag.
test_existing_git_remote_gate() {
    local root out rc out2 rc2
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    printf 'seed\n' > "$root/seed.txt"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    git -C "$root" remote add origin 'https://example.invalid/some/repo.git' >/dev/null 2>&1

    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc=$?
    assertNotEquals "existing-remote gate exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:EXISTING_GIT_REMOTE"*) assertTrue 'emits EXISTING_GIT_REMOTE token' 0 ;; *) fail "no EXISTING_GIT_REMOTE token: $out" ;; esac
    case "$out" in *"remotes=origin"*) assertTrue 'token names the offending remote' 0 ;; *) fail "token lacks the remote name: $out" ;; esac
    assertEquals 'gate changed nothing: no bridge branch' 0 "$(bridge_branch_count "$root")"
    assertTrue 'gate changed nothing: no bridge worktree dir' "[ ! -d '$(bridge_path "$root")' ]"
    assertTrue 'gate changed nothing: worktree still clean' "[ -z \"\$(git -C '$root' status --porcelain)\" ]"

    # --allow-existing-remote takes the gate down. The run still fails later on the unreachable
    # URL; we assert only that the gate itself no longer fires.
    out2="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/no-such-repo")" --allow-existing-remote 2>&1)"; rc2=$?
    case "$out2" in
        *"TP_TOKEN:EXISTING_GIT_REMOTE"*) fail "gate still fired despite --allow-existing-remote (rc=$rc2): $out2" ;;
        *) assertTrue 'flag suppresses the gate' 0 ;;
    esac
}

# ── Scenario 7d: wrong-repo guard 3 -- refuse to git init over sibling repos ────
# A folder that is not a repo but holds sibling projects that are. `git rev-parse` only searches
# UPWARD, so guards 1 and 2 see "no git here" and fall through to `git init` -- which would wrap
# every sibling project into one repository. Nothing later undoes that.
test_nested_git_repos_gate() {
    local ws out rc out2 rc2 name
    ws="$SB/proj-root"
    mkdir -p "$ws"
    for name in proj-1 proj-2; do
        init_repo_with_identity "$ws/$name"
        echo 'seed' > "$ws/$name/seed.txt"
        git -C "$ws/$name" add -A >/dev/null 2>&1
        git -C "$ws/$name" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    done

    out="$(cd "$ws" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" 2>&1)"; rc=$?
    assertNotEquals "nested-repos gate exits non-zero (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:NESTED_GIT_REPOS"*) assertTrue 'emits NESTED_GIT_REPOS token' 0 ;; *) fail "no NESTED_GIT_REPOS token: $out" ;; esac
    case "$out" in *proj-1*) assertTrue 'token names proj-1' 0 ;; *) fail "token lacks proj-1: $out" ;; esac
    case "$out" in *proj-2*) assertTrue 'token names proj-2' 0 ;; *) fail "token lacks proj-2: $out" ;; esac

    # the load-bearing assertion: no repository was created over the workspace folder.
    assertTrue 'no repository created over the workspace folder' "[ ! -e '$ws/.git' ]"
    for name in proj-1 proj-2; do
        assertTrue "sibling $name left clean" "[ -z \"\$(git -C '$ws/$name' status --porcelain)\" ]"
    done

    # --allow-nested-repos takes the gate down (a real project may hold a vendored sub-repo). The
    # run still fails later on the unreachable URL; assert only that the gate itself no longer fires.
    out2="$(cd "$ws" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/no-such-repo")" --allow-nested-repos 2>&1)"; rc2=$?
    case "$out2" in
        *"TP_TOKEN:NESTED_GIT_REPOS"*) fail "gate still fired despite --allow-nested-repos (rc=$rc2): $out2" ;;
        *) assertTrue 'flag suppresses the gate' 0 ;;
    esac
}

# ── Scenario 7e: guard 3 scans the --repo-root target, not the working directory ──
# Same guard, but the workspace is NAMED instead of being the cwd. Without this the guard would
# scan the (clean) cwd, find nothing, fall through, and git init the workspace it was pointed at --
# the exact outcome guard 3 exists to prevent, reached through the very argument added to make
# targeting explicit.
test_nested_git_repos_gate_scans_repo_root() {
    local ws elsewhere out rc name out2 rc2 absent
    ws="$SB/g3-root"
    elsewhere="$SB/g3-elsewhere"
    mkdir -p "$ws" "$elsewhere"
    for name in proj-1 proj-2; do
        init_repo_with_identity "$ws/$name"
        echo 'seed' > "$ws/$name/seed.txt"
        git -C "$ws/$name" add -A >/dev/null 2>&1
        git -C "$ws/$name" -c commit.gpgsign=false commit -m initial >/dev/null 2>&1
    done

    out="$(cd "$elsewhere" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" --repo-root "$ws" 2>&1)"; rc=$?
    assertNotEquals "gate fires for the NAMED workspace (out: $out)" 0 "$rc"
    case "$out" in *"TP_TOKEN:NESTED_GIT_REPOS"*) assertTrue 'emits NESTED_GIT_REPOS token' 0 ;; *) fail "no NESTED_GIT_REPOS token: $out" ;; esac
    case "$out" in *proj-1*) assertTrue 'token names proj-1' 0 ;; *) fail "token lacks proj-1: $out" ;; esac
    case "$out" in *proj-2*) assertTrue 'token names proj-2' 0 ;; *) fail "token lacks proj-2: $out" ;; esac

    # the load-bearing pair: nothing was created at EITHER location.
    assertTrue 'no repository created over the named workspace' "[ ! -e '$ws/.git' ]"
    assertTrue 'no repository created over the working directory' "[ ! -e '$elsewhere/.git' ]"

    # Complement: the guard must not fire merely because --repo-root was used. Pointing it at a
    # genuine single project gets past guard 3 (the run then fails on the unreachable URL).
    out2="$(cd "$elsewhere" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/no-such-repo")" --repo-root "$ws/proj-1" 2>&1)"; rc2=$?
    case "$out2" in
        *"TP_TOKEN:NESTED_GIT_REPOS"*) fail "gate fired for a genuine single project (rc=$rc2): $out2" ;;
        *) assertTrue 'gate does not fire for a genuine single project' 0 ;;
    esac
    assertTrue 'working directory still not a repository' "[ ! -e '$elsewhere/.git' ]"

    # A --repo-root that does not exist is refused before anything is created.
    absent="$SB/g3-no-such-dir"
    out="$(cd "$elsewhere" && bash "$SCRIPT_UNDER_TEST" --svn-url "$(svn_uri "$SB/svnrepo")" --repo-root "$absent" 2>&1)"; rc=$?
    assertNotEquals 'missing --repo-root exits non-zero' 0 "$rc"
    case "$out" in *'repo root not found'*) assertTrue 'names the missing repo root' 0 ;; *) fail "expected 'repo root not found', got: $out" ;; esac
    assertTrue 'missing repo root was not created' "[ ! -e '$absent' ]"
    assertTrue 'working directory untouched' "[ ! -e '$elsewhere/.git' ]"
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

# ── Regression: a LATER revision adding .gitignore must not conflict/deadlock the import ───────
# Real-world failure: the bootstrap wrote the bridge .gitignore while the WC was at r1, so replaying
# forward to the revision that ADDS .gitignore raised "An unversioned file was found in the working
# copy" and svn blocked on its interactive conflict prompt (looked like the script had frozen).
test_gitignore_added_later_does_not_conflict() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local root uri out rc bridge
    root="$SB/test-turbo-plugin"
    init_repo_with_identity "$root"
    uri="$(make_svn_repo_gitignore_added_later "$SB/svnrepo")" || { startSkipping; return 0; }
    [ -n "$uri" ] || { startSkipping; return 0; }
    out="$(cd "$root" && bash "$SCRIPT_UNDER_TEST" --svn-url "$uri" 2>&1)"; rc=$?
    assertEquals "per-revision import over a later-added .gitignore exits 0 (out: $out)" 0 "$rc"
    case "$out" in
        *"Tree conflict"*|*"unversioned file"*) fail "svn tree conflict during import: $out" ;;
        *) assertTrue 'no tree conflict' 0 ;;
    esac
    assertEquals 'three per-revision replay commits' 3 "$(count_trailer_commits "$root")"
    bridge="$(bridge_path "$root")"
    # End state matches the squash path: the bridge carries SVN's .gitignore and only that.
    if grep -qxF '.svn/' "$bridge/.gitignore" 2>/dev/null; then fail 'bridge invented a .gitignore line (the U4 conflict cause)'; else assertTrue 'bridge added nothing to .gitignore' 0; fi
    if grep -qxF '*.log' "$bridge/.gitignore" 2>/dev/null; then assertTrue "svn's own .gitignore content preserved" 0; else fail "svn .gitignore content clobbered"; fi
    if git -C "$bridge" ls-files | grep -q '^\.svn'; then fail '.svn tracked in git'; else assertTrue '.svn not tracked' 0; fi
    # A dirty bridge breaks the next push (regression e2ad936), so the .gitignore edit must be committed.
    assertEquals 'bridge worktree is git-clean' '' "$(git -C "$bridge" status --porcelain)"
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
