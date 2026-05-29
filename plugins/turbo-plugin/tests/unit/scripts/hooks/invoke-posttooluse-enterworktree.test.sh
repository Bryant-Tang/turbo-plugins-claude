#!/usr/bin/env bash
# invoke-posttooluse-enterworktree.test.sh — bash sibling for posttooluse-enterworktree.sh (v1.0 no-op hook)
#
# Behavior: 在 Windows / Git Bash 把 stdin pipe 給 .ps1 native impl;非 Windows
# 直接印 `{}` exit 0。兩條路徑 always exit 0(hook 是 advisory,不可 block session)。
#
# Cases (per shell):
#   1. happy no-op: empty stdin → exit 0、stdout = `{}`、不在 cwd 留檔
#   2. 中文 cwd:   切到含中文的 cwd → exit 0、stdout = `{}`
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/posttooluse-enterworktree.sh"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }

mk_sandbox() {
    local tag="$1"
    local stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)"
    local dir="/c/Turbo/turbo-plugin-test-hook-${tag}-${stamp}"
    mkdir -p "$dir"
    echo "$dir"
}
rm_sandbox() {
    local dir="$1"
    [[ -z "$dir" || ! -d "$dir" ]] && return 0
    rm -rf "$dir" 2>/dev/null || true
}

# Case 1: happy no-op
sb1="$(mk_sandbox 'happy')"
cd "$sb1"
out1="$(printf '' | bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: exit 0' '0' "$e1"
assert_match 'case1: stdout empty JSON {}' '^\{[[:space:]]*\}[[:space:]]*$' "$out1"
# sandbox 沒被汙染
created1="$(find "$sb1" -mindepth 1 2>/dev/null | wc -l | tr -d ' \r\n')"
assert_eq 'case1: sandbox 沒有任何 hook 副作用 file' '0' "$created1"
rm_sandbox "$sb1"

# Case 2: 中文 cwd
sb2="$(mk_sandbox '中文')"
cd "$sb2"
out2="$(printf '' | bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
cd "$PLUGIN_ROOT"
assert_eq 'case2: 中文 cwd exit 0' '0' "$e2"
assert_match 'case2: 中文 cwd stdout empty JSON' '^\{[[:space:]]*\}[[:space:]]*$' "$out2"
rm_sandbox "$sb2"

echo ""
echo "posttooluse-enterworktree.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
