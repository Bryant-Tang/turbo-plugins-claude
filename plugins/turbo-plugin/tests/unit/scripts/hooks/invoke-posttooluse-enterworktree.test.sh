#!/usr/bin/env bash
# invoke-posttooluse-enterworktree.test.sh (shUnit2) — bash sibling for invoke-posttooluse-enterworktree.sh (v1.0 no-op hook)
#
# Behavior: 在 Windows / Git Bash 把 stdin pipe 給 .ps1 native impl;非 Windows
# 直接印 `{}` exit 0。兩條路徑 always exit 0(hook 是 advisory,不可 block session)。
#
# Cases:
#   1. happy no-op: empty stdin → exit 0、stdout = `{}`、不在 cwd 留檔
#   2. 中文 cwd:   切到含中文的 cwd → exit 0、stdout = `{}`

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/invoke-posttooluse-enterworktree.sh"
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

# Case 1: happy no-op
test_happy_noop() {
    local sb out e created
    sb="$(mk_sandbox 'happy')"
    out="$(cd "$sb" && printf '' | bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case1: exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case1: stdout empty JSON {}' $?
    created="$(find "$sb" -mindepth 1 2>/dev/null | wc -l | tr -d ' \r\n')"
    assertEquals 'case1: sandbox 沒有任何 hook 副作用 file' 0 "$created"
    rm_sandbox "$sb"
}

# Case 2: 中文 cwd
test_chinese_cwd() {
    local sb out e
    sb="$(mk_sandbox '中文')"
    out="$(cd "$sb" && printf '' | bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case2: 中文 cwd exit 0' 0 "$e"
    echo "$out" | grep -Eq '^\{[[:space:]]*\}[[:space:]]*$'; assertTrue 'case2: 中文 cwd stdout empty JSON' $?
    rm_sandbox "$sb"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
