#!/usr/bin/env bash
# invoke-sessionstart.test.sh — bash sibling for invoke-sessionstart.sh (3-branch advisory hook)
#
# Behavior on Windows / Git Bash: delegate to .ps1 native impl(同樣的 3 條 branch)。
# 在 Linux / macOS:跑 .sh native impl(branch i applicationhost.config 跳過,
# branch ii / iii 與 Windows 等價)。
#
# Cases (per shell — Windows 上 .ps1 已被 sessionstart.Tests.ps1 覆蓋,此檔做 bash entry smoke):
#   1. non-git cwd:     非 git repo → exit 0 + stdout = `{}`
#   2. Pattern B 缺 dbhub.local.toml: peer worktree + 有 dbhub.example.local.toml +
#                       無 dbhub.local.toml → exit 0 + stdout 含 dbhub.local.toml
#   3. 沒 marker(main worktree):git repo + 沒 .turbo-plugin/ → exit 0 + stdout 含 /tp-setup
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/invoke-sessionstart.sh"

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

# ─── Case 1: non-git cwd ────────────────────────────────────────────────────
sb1="$(mk_sandbox 'ss-nongit')"
cd "$sb1"
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: non-git exit 0' '0' "$e1"
assert_match 'case1: stdout empty JSON {}' '^\{[[:space:]]*\}[[:space:]]*$' "$out1"
rm_sandbox "$sb1"

# ─── Case 2: Pattern B + 缺 dbhub.local.toml ────────────────────────────────
sb2_main="$(mk_sandbox 'ss-main')"
cd "$sb2_main"
git init -q -b main >/dev/null 2>&1
git config user.email 'test@example.invalid' >/dev/null 2>&1
git config user.name 'Test' >/dev/null 2>&1
echo "init" > init.txt
git add -A >/dev/null 2>&1
git -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
git branch peer-branch >/dev/null 2>&1
# peer worktree 必須在 main 之外的 sibling 目錄
sb2_peer="${sb2_main}.peer-$$"
git worktree add "$sb2_peer" peer-branch >/dev/null 2>&1
cd "$PLUGIN_ROOT"
# 在 peer 放 marker + example,但不放 dbhub.local.toml
mkdir -p "$sb2_peer/.turbo-plugin"
echo "# example" > "$sb2_peer/.turbo-plugin/dbhub.example.local.toml"
cd "$sb2_peer"
out2="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
cd "$PLUGIN_ROOT"
assert_eq 'case2: Pattern B exit 0' '0' "$e2"
assert_match 'case2: stdout 含 systemMessage' 'systemMessage' "$out2"
assert_match 'case2: 訊息提到 dbhub.local.toml' 'dbhub\.local\.toml' "$out2"
# cleanup peer + main
cd "$sb2_main" >/dev/null 2>&1 && git worktree remove --force "$sb2_peer" >/dev/null 2>&1 || true
cd "$PLUGIN_ROOT"
rm_sandbox "$sb2_peer"
rm_sandbox "$sb2_main"

# ─── Case 3: 沒 marker(main worktree)→ setup prompt ───────────────────────
sb3="$(mk_sandbox 'ss-nomarker')"
cd "$sb3"
git init -q -b main >/dev/null 2>&1
git config user.email 'test@example.invalid' >/dev/null 2>&1
git config user.name 'Test' >/dev/null 2>&1
echo "init" > init.txt
git add -A >/dev/null 2>&1
git -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
out3="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e3=$?
cd "$PLUGIN_ROOT"
assert_eq 'case3: no-marker exit 0' '0' "$e3"
assert_match 'case3: stdout 含 systemMessage' 'systemMessage' "$out3"
assert_match 'case3: 訊息提到 /tp-setup' '/tp-setup' "$out3"
rm_sandbox "$sb3"

echo ""
echo "invoke-sessionstart.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
