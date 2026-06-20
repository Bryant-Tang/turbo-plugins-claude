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
#   2. db in use + Pattern B:      peer worktree + dbhub.example.local.toml + 無 dbhub.local.toml
#                                  → exit 0 + stdout 含 dbhub.local.toml 警告
#   3. no marker (main worktree):  git repo + 沒 .turbo-plugin/ → exit 0 + `{}`(db 不做 setup 提示)
#   4. db NOT in use + Pattern B:  peer worktree + 無 dbhub.example.local.toml + 無 dbhub.local.toml
#                                  → exit 0 + `{}`(concern-marker gate:no-op)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/invoke-sessionstart.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

mk_sandbox() {
    local tag="$1" stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)"
    local dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/db-test-hook-${tag}-${stamp}"
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
    local tag="$1" stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)"
    local base="${TMPDIR:-/tmp}"
    [ -d "$base" ] || base="/tmp"
    local dir="$base/db-test-hook-${tag}-${stamp}"
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
    sb_peer="${sb_main}.peer-$$"
    (cd "$sb_main" && git worktree add "$sb_peer" peer-branch >/dev/null 2>&1)
    echo "${sb_main}|${sb_peer}"
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

# Case 2: db in use + Pattern B + 缺 dbhub.local.toml → 警示
test_db_in_use_pattern_b_warns() {
    local pair sb_main sb_peer out e
    pair="$(mk_main_and_peer 'ss-warn')"; sb_main="${pair%%|*}"; sb_peer="${pair##*|}"
    mkdir -p "$sb_peer/.turbo-plugin"
    echo "# example" > "$sb_peer/.turbo-plugin/dbhub.example.local.toml"
    out="$(cd "$sb_peer" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case2: Pattern B exit 0' 0 "$e"
    echo "$out" | grep -Eq 'systemMessage'; assertTrue 'case2: stdout 含 systemMessage' $?
    echo "$out" | grep -Eq 'dbhub\.local\.toml'; assertTrue 'case2: 訊息提到 dbhub.local.toml' $?
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
    pair="$(mk_main_and_peer 'ss-gate')"; sb_main="${pair%%|*}"; sb_peer="${pair##*|}"
    mkdir -p "$sb_peer/.turbo-plugin"
    # marker dir exists but NO dbhub.example.local.toml (db not set up) and no dbhub.local.toml
    out="$(cd "$sb_peer" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case4: gate exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case4: stdout empty JSON {} (db not in use)' $?
    cleanup_main_and_peer "$sb_main" "$sb_peer"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
