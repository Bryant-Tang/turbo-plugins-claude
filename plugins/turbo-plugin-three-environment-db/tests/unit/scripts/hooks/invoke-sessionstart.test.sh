#!/usr/bin/env bash
# invoke-sessionstart.test.sh (shUnit2) — bash sibling for the db SessionStart hook
# (advisory, dbhub branch only).
#
# Behavior on Windows / Git Bash: delegate to the .ps1 native impl. On Linux / macOS:
# run the .sh native impl. db hook only ever emits the dbhub Pattern-B warning; it does
# NOT emit the marker-missing /tp-setup prompt (that belongs to turbo-plugin-git-svn).
#
# Cases:
#   1. non-git cwd:                非 git repo → exit 0 + stdout = `{}`
#   2. db in use + Pattern B:      peer worktree + dbhub.example.toml + 無 dbhub.local.toml
#                                  → exit 0 + stdout 含 dbhub.local.toml 警告
#   3. no marker (main worktree):  git repo + 沒 .turbo-plugin/ → exit 0 + `{}`(db 不做 setup 提示)
#   4. db NOT in use + Pattern B:  peer worktree + 無任何 example 範本 + 無 dbhub.local.toml
#                                  → exit 0 + `{}`(concern-marker gate:no-op)
#   7/8. 改名前的舊範本名(dbhub.example.local.toml)一樣要 gate 得到 —— cwd 與下一層各一個。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/invoke-sessionstart.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

# Keep sandbox names SHORT, and do not lengthen them casually.
#
# `git worktree add` writes an admin file at `<main>/.git/worktrees/<peer-basename>/HEAD`, and on
# Windows that whole path must fit in MAX_PATH (260). The old naming
# (`db-test-hook-<tag>-<19-digit nanosecond stamp>`, twice over, since the peer basename is derived
# from the main one) pushed it over on a checkout that was itself a few directories deep, and
# `git worktree add` failed with `error: couldn't set 'HEAD'`. Uniqueness comes from the caller's
# tag plus the shell PID, which is plenty here and costs ~24 characters less per name.
mk_sandbox() {
    local tag="$1"
    local dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/db-$$-${tag}"
    mkdir -p "$dir"
    echo "$dir"
}
rm_sandbox() {
    local dir="$1"
    [ -z "$dir" ] || [ ! -d "$dir" ] && return 0
    rm -rf "$dir" 2>/dev/null || true
}

# The non-git case MUST run from a dir OUTSIDE any git work tree. The repo-relative
# tests/.sandbox/ lives INSIDE this repo, so a sandbox there would inherit the outer repo.
# Use OS temp (outside the repo) for that case only.
mk_nongit_sandbox() {
    local tag="$1"
    local base="${TMPDIR:-/tmp}"
    [ -d "$base" ] || base="/tmp"
    local dir="$base/db-$$-${tag}"
    mkdir -p "$dir"
    echo "$dir"
}

# Build a main + linked peer worktree; echo "<main>|<peer>".
mk_main_and_peer() {
    local tag="$1" sb_main sb_peer
    sb_main="$(mk_sandbox "$tag-main")"
    (
        cd "$sb_main"
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@example.invalid' >/dev/null 2>&1
        git config user.name 'Test' >/dev/null 2>&1
        echo "init" > init.txt
        git add -A >/dev/null 2>&1
        git -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
        git branch peer-branch >/dev/null 2>&1
    )
    sb_peer="${sb_main}-p"
    (cd "$sb_main" && git worktree add "$sb_peer" peer-branch >/dev/null 2>&1)
    echo "${sb_main}|${sb_peer}"
}

# Every peer-worktree test MUST call this first.
#
# `git worktree add` above is silenced, so when it fails the caller still gets a path -- and the
# very next `mkdir -p "$sb_peer/..."` creates that path as an ORDINARY directory. The hook then
# runs inside whatever repository happens to contain the sandbox, and the answer it gives depends
# on whether THAT checkout is a main or a linked worktree. Both outcomes are wrong, and neither
# looks wrong: on 2026-08-21 all four peer tests reported green on a machine whose checkout was a
# linked worktree, while CI (a main worktree) failed one of them -- the real cause being a sandbox
# path long enough to push git's admin file past Windows MAX_PATH.
assert_peer_is_linked_worktree() {
    local peer="$1"
    [ -e "$peer/.git" ]
    assertTrue "fixture: '$peer' is not a linked worktree -- git worktree add failed silently" $?
}
cleanup_main_and_peer() {
    local sb_main="$1" sb_peer="$2"
    (cd "$sb_main" >/dev/null 2>&1 && git worktree remove --force "$sb_peer" >/dev/null 2>&1) || true
    rm_sandbox "$sb_peer"
    rm_sandbox "$sb_main"
}

# Case 1: non-git cwd
test_non_git_cwd() {
    local sb out e
    sb="$(mk_nongit_sandbox 'ss-nongit')"
    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case1: non-git exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case1: stdout empty JSON {}' $?
    rm_sandbox "$sb"
}

# Case 5: multi-project workspace root -- NOT a git repo, marker lives one level down.
#
# This is the shape the db plugin's multi-project support exists for, and the hook could not fire
# in it: two separate gates each assumed "the session root IS the project". It bailed on
# `git rev-parse --is-inside-work-tree` (a workspace root is never a repo), and even past that its
# concern gate looked for the marker in the cwd rather than in the projects. Observed on a real
# machine 2026-08-03: a session with no node on PATH said nothing at all, and the user had to ask
# why the MCP server was red.
#
# Do NOT strip PATH to simulate a missing `node` here: on Windows this .sh is only a delegator to
# the .ps1, so a stripped PATH loses `powershell` and tests the wrapper instead of the logic. The
# node branch is asserted in the Pester twin, which runs the native implementation and can control
# the child's PATH cleanly. What this pair locks down is the GATE: the hook must get past
# "not a git repository" and find the marker one level down.
test_multiproject_root_reaches_the_gate() {
    local sb out e
    sb="$(mk_nongit_sandbox 'ss-multiproj')"
    mkdir -p "$sb/proj-2/.turbo-plugin" "$sb/proj-1"
    : > "$sb/proj-2/.turbo-plugin/dbhub.example.toml"

    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case5: exit 0 (a hook must never break the session)' 0 "$e"
    echo "$out" | grep -q '^{'; assertTrue 'case5: emitted JSON from a NON-repo workspace root' $?
    # The old code printed git's "fatal: not a git repository" on this path; it is meant to be silent.
    echo "$out" | grep -qi 'fatal'; assertFalse 'case5: no git error leaked into stdout' $?
    rm_sandbox "$sb"
}

# Case 6: same shape, but NO project uses db -> still a silent no-op.
test_multiproject_root_without_db_is_silent() {
    local sb out e
    sb="$(mk_nongit_sandbox 'ss-multiproj-nodb')"
    mkdir -p "$sb/proj-1" "$sb/proj-2/.turbo-plugin"
    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case6: exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case6: stdout empty JSON {}' $?
    rm_sandbox "$sb"
}

# Case 2: db in use + Pattern B + 缺 dbhub.local.toml → 警示
test_db_in_use_pattern_b_warns() {
    local pair sb_main sb_peer out e
    pair="$(mk_main_and_peer 'warn')"; sb_main="${pair%%|*}"; sb_peer="${pair##*|}"
    assert_peer_is_linked_worktree "$sb_peer"
    mkdir -p "$sb_peer/.turbo-plugin"
    echo "# example" > "$sb_peer/.turbo-plugin/dbhub.example.toml"
    out="$(cd "$sb_peer" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case2: Pattern B exit 0' 0 "$e"
    echo "$out" | grep -Eq 'systemMessage'; assertTrue 'case2: stdout 含 systemMessage' $?
    echo "$out" | grep -Eq 'dbhub\.local\.toml'; assertTrue 'case2: 訊息提到 dbhub.local.toml' $?
    cleanup_main_and_peer "$sb_main" "$sb_peer"
}

# Case 7 + 8: the PRE-RENAME template name must keep gating.
#
# `dbhub.example.local.toml` is what every project set up before the rename has committed. If the
# gate stopped recognising it, those projects would silently stop getting the warning -- the hook
# would decide they do not use a database at all. Nothing would look broken, which is why this is
# tested rather than trusted: the failure has no symptom other than the absence of a message the
# user never knew to expect. Both call sites are covered because the cwd and the one-level-down
# scan are separate lookups.
test_legacy_marker_name_still_gates_at_cwd() {
    local pair sb_main sb_peer out e
    pair="$(mk_main_and_peer 'lgc')"; sb_main="${pair%%|*}"; sb_peer="${pair##*|}"
    assert_peer_is_linked_worktree "$sb_peer"
    mkdir -p "$sb_peer/.turbo-plugin"
    echo "# example" > "$sb_peer/.turbo-plugin/dbhub.example.local.toml"
    out="$(cd "$sb_peer" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case7: exit 0' 0 "$e"
    echo "$out" | grep -Eq 'systemMessage'
    # `$out` is interpolated from a variable, never a command substitution: `$(...)` inside an
    # assert message runs first and overwrites `$?`, leaving an assertion that can never fail.
    assertTrue "case7: 舊檔名一樣觸發警示 [out=$out]" $?
    cleanup_main_and_peer "$sb_main" "$sb_peer"
}

#
# The one-level-down half is deliberately NOT written as the case-5 workspace-root shape. There,
# passing the gate and failing it produce the same `{}`: outside a repo there is no peer-worktree
# branch to speak, so the assertion could not tell the two apart and the test would pass even with
# the legacy name removed. A peer worktree whose sub-project carries the marker is the smallest
# shape where the scan's result is actually observable -- a message is emitted only if the gate let
# it through.
test_legacy_marker_name_still_gates_one_level_down() {
    local pair sb_main sb_peer out e
    pair="$(mk_main_and_peer 'lgcd')"; sb_main="${pair%%|*}"; sb_peer="${pair##*|}"
    assert_peer_is_linked_worktree "$sb_peer"
    mkdir -p "$sb_peer/sub/.turbo-plugin"
    echo "# example" > "$sb_peer/sub/.turbo-plugin/dbhub.example.local.toml"
    out="$(cd "$sb_peer" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case8: exit 0' 0 "$e"
    echo "$out" | grep -Eq 'systemMessage'
    assertTrue "case8: 舊檔名在下一層也 gate 得到 [out=$out]" $?
    cleanup_main_and_peer "$sb_main" "$sb_peer"
}

# Case 3: no marker (main worktree) → {} (db 不做 setup 提示)
test_no_marker_silent() {
    local sb out e
    sb="$(mk_sandbox 'ss-nomarker')"
    (
        cd "$sb"
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@example.invalid' >/dev/null 2>&1
        git config user.name 'Test' >/dev/null 2>&1
        echo "init" > init.txt
        git add -A >/dev/null 2>&1
        git -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    )
    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case3: no-marker exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case3: stdout empty JSON {} (no setup prompt)' $?
    rm_sandbox "$sb"
}

# Case 4: db NOT in use (no dbhub.example.local.toml) + Pattern B → {} (gate no-op)
test_db_not_in_use_gate_noop() {
    local pair sb_main sb_peer out e
    pair="$(mk_main_and_peer 'gate')"; sb_main="${pair%%|*}"; sb_peer="${pair##*|}"
    assert_peer_is_linked_worktree "$sb_peer"
    mkdir -p "$sb_peer/.turbo-plugin"
    # marker dir exists but NO dbhub.example.local.toml (db not set up) and no dbhub.local.toml
    out="$(cd "$sb_peer" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case4: gate exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case4: stdout empty JSON {} (db not in use)' $?
    cleanup_main_and_peer "$sb_main" "$sb_peer"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
