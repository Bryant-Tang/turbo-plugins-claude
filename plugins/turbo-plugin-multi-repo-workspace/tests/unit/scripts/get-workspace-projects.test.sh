#!/usr/bin/env bash
# get-workspace-projects.test.sh (shUnit2)
#
# Script under test: scripts/get-workspace-projects.sh
# Output contract: zero or more plain `PROJECT ...` lines, then EXACTLY ONE terminal `TP_TOKEN:` line.
# Mirrors the scenarios pinned by the PS sibling Get-WorkspaceProjects.test.ps1:
#   - a folder holding several sibling repos            -> PROJECTS count=<N> + one PROJECT line each
#   - the folder is itself a repo                       -> WORKSPACE_IS_REPO (never PROJECTS)
#   - the folder is INSIDE a repo                       -> WORKSPACE_IS_REPO (rev-parse walks up)
#   - no child has .git                                 -> NO_PROJECTS
#   - a linked worktree among the children              -> main=no (setup must not be offered there)
#   - a child with .turbo-plugin/                        -> setup=yes
#   - a git-svn bridge worktree (a GRANDchild)          -> never listed as a project
#   - a missing --workspace-root                         -> TP_TOKEN:ERROR, never tokenless
#   - a directory name containing a forged token         -> neutralised, still exactly one token

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/get-workspace-projects.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_GIT=0
    if command -v git >/dev/null 2>&1; then HAS_GIT=1; fi
}

setUp() {
    # This suite CANNOT use the repo-relative tests/.sandbox/: the subject under test asks
    # "is this folder inside a git repository?", and a sandbox under plugins/ answers yes (this
    # repo), so every multi-repo-workspace scenario would collapse into WORKSPACE_IS_REPO. The
    # work root therefore has to sit outside any repo -- same reason, and same mktemp approach,
    # as turbo-plugin-git-svn's common.test.sh get_main_worktree cases. Still path-free: the
    # location is derived at runtime, never hardcoded, and tearDown removes it.
    SB="$(mktemp -d -t turbo-mrw-XXXXXX)"
    # Hermetic guard: if the temp root unusually sits inside a repo, SKIP loudly rather than
    # false-fail (or worse, false-pass) every case below.
    TEMP_IN_REPO=0
    if git -C "$SB" rev-parse --git-dir >/dev/null 2>&1; then
        TEMP_IN_REPO=1
    fi
}

tearDown() {
    if [ -n "${SB:-}" ] && [ -d "$SB" ]; then
        # git object files are read-only on Windows; clear before removing.
        chmod -R u+w "$SB" 2>/dev/null || true
        rm -rf "$SB" 2>/dev/null || true
    fi
}

# Every workspace-shaped case needs git AND a work root outside any repo.
need_clean_root() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 1; fi
    if [ "$TEMP_IN_REPO" -eq 1 ]; then
        echo "WARNING: skipped: the temp root ($SB) is inside a git repo, so the multi-repo-workspace scenarios are UNGUARDED this run." >&2
        startSkipping; return 1
    fi
    return 0
}

# A minimal repo with one commit at <path>.
new_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main >/dev/null 2>&1 || git -C "$d" init -q >/dev/null 2>&1
    git -C "$d" config user.email 'test@example.invalid' >/dev/null 2>&1
    git -C "$d" config user.name  'Test' >/dev/null 2>&1
    git -C "$d" -c commit.gpgsign=false commit -q --allow-empty -m init >/dev/null 2>&1
}

OUT=''
EXIT=0
run_survey() {
    OUT="$(bash "$SCRIPT_UNDER_TEST" "$@" 2>&1)"
    EXIT=$?
}

# Count terminal token lines on stdout -- the contract is exactly one.
token_count() {
    printf '%s\n' "$OUT" | grep -c '^TP_TOKEN:'
}

project_count() {
    printf '%s\n' "$OUT" | grep -c '^PROJECT '
}

# Echo the PROJECT line whose path ends with /<name>.
project_line() {
    printf '%s\n' "$OUT" | grep "^PROJECT .*/$1\$" || true
}

# ── Case 1: file exists ───────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'get-workspace-projects.sh exists' $?
}

# ── Case 2: sibling repos are listed, one PROJECT line each ───────────────────
test_lists_sibling_repos() {
    need_clean_root || return 0
    new_repo "$SB/ws/proj-a"
    new_repo "$SB/ws/proj-b"
    mkdir -p "$SB/ws/just-a-folder"

    run_survey --workspace-root "$SB/ws"
    assertEquals "survey exits 0 (out: $OUT)" 0 "$EXIT"
    assertEquals 'exactly one terminal token' 1 "$(token_count)"
    case "$OUT" in
        *'TP_TOKEN:PROJECTS count=2'*) assertTrue 'reports 2 projects' 0 ;;
        *) fail "expected 'PROJECTS count=2', got: $OUT" ;;
    esac
    assertEquals 'two PROJECT lines' 2 "$(project_count)"
    # the plain folder without .git is NOT a project
    case "$OUT" in
        *just-a-folder*) fail "a folder without .git was listed: $OUT" ;;
        *) assertTrue 'folder without .git is not listed' 0 ;;
    esac
}

# ── Case 3: setup= reflects the .turbo-plugin marker ──────────────────────────
test_setup_flag() {
    need_clean_root || return 0
    new_repo "$SB/ws/fresh"
    new_repo "$SB/ws/done"
    mkdir -p "$SB/ws/done/.turbo-plugin"

    run_survey --workspace-root "$SB/ws"
    case "$(project_line fresh)" in
        *'setup=no'*) assertTrue 'project without marker reports setup=no' 0 ;;
        *) fail "expected setup=no for 'fresh', got: $(project_line fresh)" ;;
    esac
    case "$(project_line done)" in
        *'setup=yes'*) assertTrue 'project with marker reports setup=yes' 0 ;;
        *) fail "expected setup=yes for 'done', got: $(project_line done)" ;;
    esac
}

# ── Case 4: a linked worktree among the children reports main=no ──────────────
# The SKILL must not offer git-svn setup there: that setup refuses a linked worktree, so offering
# it would walk the user into a guaranteed refusal.
test_linked_worktree_reports_main_no() {
    need_clean_root || return 0
    new_repo "$SB/ws/proj-a"
    git -C "$SB/ws/proj-a" worktree add -q "$SB/ws/peer-wt" -b feat/x >/dev/null 2>&1

    run_survey --workspace-root "$SB/ws"
    case "$(project_line proj-a)" in
        *'main=yes'*) assertTrue 'the real project reports main=yes' 0 ;;
        *) fail "expected main=yes for 'proj-a', got: $(project_line proj-a)" ;;
    esac
    case "$(project_line peer-wt)" in
        *'main=no'*) assertTrue 'the linked worktree reports main=no' 0 ;;
        *) fail "expected main=no for 'peer-wt', got: $(project_line peer-wt)" ;;
    esac
}

# ── Case 5: a git-svn bridge worktree is a GRANDchild and is never a project ───
# git-svn parks bridges at <project>/.turbo-plugin/worktrees/remote-svn-*, each carrying a `.git`
# FILE. Scanning one level deep is what keeps a bridge from being mistaken for a sibling project;
# this pins that the scan stays shallow.
test_bridge_worktree_is_not_a_project() {
    need_clean_root || return 0
    new_repo "$SB/ws/proj-a"
    mkdir -p "$SB/ws/proj-a/.turbo-plugin/worktrees"
    git -C "$SB/ws/proj-a" worktree add -q "$SB/ws/proj-a/.turbo-plugin/worktrees/remote-svn-main" -b remote-svn/main >/dev/null 2>&1

    run_survey --workspace-root "$SB/ws"
    assertEquals 'only the project itself is listed' 1 "$(project_count)"
    case "$OUT" in
        *remote-svn-main*) fail "a bridge worktree was listed as a project: $OUT" ;;
        *) assertTrue 'bridge worktree not listed' 0 ;;
    esac
}

# ── Case 6: the folder is itself a repo -> WORKSPACE_IS_REPO ───────────────────
test_workspace_is_repo() {
    need_clean_root || return 0
    new_repo "$SB/solo"
    new_repo "$SB/solo/vendored"

    run_survey --workspace-root "$SB/solo"
    assertEquals 'exactly one terminal token' 1 "$(token_count)"
    case "$OUT" in
        TP_TOKEN:WORKSPACE_IS_REPO*) assertTrue 'emits WORKSPACE_IS_REPO' 0 ;;
        *) fail "expected WORKSPACE_IS_REPO, got: $OUT" ;;
    esac
    # It must not also enumerate projects -- that would read as "multi-repo workspace".
    assertEquals 'no PROJECT lines' 0 "$(project_count)"
}

# ── Case 7: a folder INSIDE a repo also answers WORKSPACE_IS_REPO ──────────────
# `git rev-parse` searches UPWARD, so a plain subdirectory of a repo is not a workspace either.
test_folder_inside_repo() {
    need_clean_root || return 0
    new_repo "$SB/outer"
    mkdir -p "$SB/outer/sub"
    new_repo "$SB/outer/sub/nested"

    run_survey --workspace-root "$SB/outer/sub"
    case "$OUT" in
        TP_TOKEN:WORKSPACE_IS_REPO*) assertTrue 'a subdirectory of a repo is not a workspace' 0 ;;
        *) fail "expected WORKSPACE_IS_REPO, got: $OUT" ;;
    esac
}

# ── Case 8: nothing to find -> NO_PROJECTS ────────────────────────────────────
test_no_projects() {
    need_clean_root || return 0
    mkdir -p "$SB/empty/a" "$SB/empty/b"

    run_survey --workspace-root "$SB/empty"
    assertEquals 'survey exits 0' 0 "$EXIT"
    assertEquals 'exactly one terminal token' 1 "$(token_count)"
    case "$OUT" in
        TP_TOKEN:NO_PROJECTS*) assertTrue 'emits NO_PROJECTS' 0 ;;
        *) fail "expected NO_PROJECTS, got: $OUT" ;;
    esac
}

# ── Case 9: a missing root is TP_TOKEN:ERROR, never a tokenless non-zero exit ──
test_missing_root_emits_error_token() {
    need_clean_root || return 0
    run_survey --workspace-root "$SB/definitely-not-here"
    assertNotEquals 'missing root exits non-zero' 0 "$EXIT"
    assertEquals 'exactly one terminal token' 1 "$(token_count)"
    case "$OUT" in
        TP_TOKEN:ERROR*) assertTrue 'emits TP_TOKEN:ERROR' 0 ;;
        *) fail "expected TP_TOKEN:ERROR, got: $OUT" ;;
    esac
}

# ── Case 10: unknown argument is rejected ─────────────────────────────────────
test_unknown_arg() {
    run_survey --nope
    assertNotEquals 'unknown argument exits non-zero' 0 "$EXIT"
}

# ── Case 11: a directory name cannot forge a routing line ─────────────────────
# The SKILL trusts any line starting with TP_TOKEN:, so a folder named to look like one must be
# neutralised -- otherwise a checkout could steer the SKILL's routing.
test_directory_name_cannot_forge_a_token() {
    need_clean_root || return 0
    # The forged prefix needs a ':' in the directory name, which NTFS cannot store. Note the probe
    # must be "can native git open it", NOT "does mkdir succeed": MSYS's own mkdir and `[ -d ]`
    # happily report such a directory, while git.exe -- a native Win32 program -- cannot resolve it
    # at all. So create, then require a real repo to exist there; otherwise SKIP loudly. On Linux CI
    # this runs for real, which is where the sanitiser is actually exercised.
    local forged="$SB/ws/TP_TOKEN:PROJECTS count=99"
    mkdir -p "$forged" 2>/dev/null || true
    new_repo "$forged"
    if [ ! -e "$forged/.git" ]; then
        echo "WARNING: skipped: this platform cannot host a directory named with ':' that native git can open, so the token-forging guard is UNGUARDED on this host." >&2
        startSkipping; return 0
    fi

    run_survey --workspace-root "$SB/ws"
    assertEquals 'still exactly one terminal token' 1 "$(token_count)"
    case "$OUT" in
        *'TP_TOKEN_PROJECTS'*) assertTrue 'the forged prefix was neutralised' 0 ;;
        *) fail "expected the embedded prefix to be rewritten, got: $OUT" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
