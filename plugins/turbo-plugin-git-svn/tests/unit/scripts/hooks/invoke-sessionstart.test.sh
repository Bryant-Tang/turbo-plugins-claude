#!/usr/bin/env bash
# invoke-sessionstart.test.sh (shUnit2) — bash sibling for invoke-sessionstart.sh (advisory hook)
#
# Behavior on Windows / Git Bash: delegate to .ps1 native impl。
# 在 Linux / macOS:跑 .sh native impl(marker-missing setup prompt)。
#
# Cases (bash entry smoke):
#   1. non-git cwd:     非 git repo → exit 0 + stdout = `{}`
#   2. 沒 marker(main worktree):git repo + 沒 .turbo-plugin/ → exit 0 + stdout 含 /tp-setup

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/invoke-sessionstart.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

mk_sandbox() {
    local tag="$1" stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)"
    local dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-hook-${tag}-${stamp}"
    mkdir -p "$dir"
    echo "$dir"
}
rm_sandbox() {
    local dir="$1"
    [ -z "$dir" ] || [ ! -d "$dir" ] && return 0
    rm -rf "$dir" 2>/dev/null || true
}

# The non-git case MUST run from a dir OUTSIDE any git work tree. The repo-relative
# tests/.sandbox/ lives INSIDE this repo, so a sandbox there would inherit the outer repo and
# the hook would no longer see a non-git cwd. Use OS temp (outside the repo) for that case only.
mk_nongit_sandbox() {
    local tag="$1" stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)"
    local base="${TMPDIR:-/tmp}"
    [ -d "$base" ] || base="/tmp"
    local dir="$base/turbo-plugin-test-hook-${tag}-${stamp}"
    mkdir -p "$dir"
    echo "$dir"
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

# Case 2: 沒 marker(main worktree)→ setup prompt
test_no_marker_setup_prompt() {
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
    echo "$out" | grep -Eq 'systemMessage'; assertTrue 'case3: stdout 含 systemMessage' $?
    echo "$out" | grep -Eq '/tp-setup'; assertTrue 'case3: 訊息提到 /tp-setup' $?
    rm_sandbox "$sb"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
