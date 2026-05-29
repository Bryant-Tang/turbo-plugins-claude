#!/usr/bin/env bash
# start-iis.test.sh — bash sibling for start-iis.sh (1-line delegate)
#
# Same coverage as Start-Iis.test.ps1: [iis] disabled gate consistency, missing apphost,
# missing csproj. Happy path is SKILL-level territory (real IIS Express launch).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/start-iis.sh"
TEST_ROOT="/c/Turbo/test-turbo-plugin"
CFG="$TEST_ROOT/.turbo-plugin/config.toml"
APPHOST="$TEST_ROOT/.turbo-plugin/applicationhost.config"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }

set_iis_enabled() {
    local val="$1"
    sed -i.bak -E "s/^enabled = (true|false)$/enabled = ${val}/" "$CFG" 2>/dev/null
    rm -f "${CFG}.bak" 2>/dev/null || true
}

# Ensure fixture .git
if [[ -d "$TEST_ROOT" && ! -d "$TEST_ROOT/.git" ]]; then
    (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
fi
if [[ ! -d "$TEST_ROOT" ]]; then
    echo "  [FAIL] setup: $TEST_ROOT not found"
    exit 1
fi

# Case 1: [iis] enabled = false
set_iis_enabled false
cd "$TEST_ROOT"
combined1="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e1=$?
cd "$PLUGIN_ROOT"
set_iis_enabled true
assert_neq0 'case1: [iis]=false exit ≠ 0' "$e1"
assert_match 'case1: stderr 含 IIS 已停用' 'IIS 已停用' "$combined1"

# Case 4: SKILL re-invoke disabled (consistency)
set_iis_enabled false
cd "$TEST_ROOT"
combined4="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e4=$?
cd "$PLUGIN_ROOT"
set_iis_enabled true
assert_neq0 'case4: SKILL-entry [iis]=false exit ≠ 0' "$e4"
assert_match 'case4: 訊息一致' 'IIS 已停用' "$combined4"

# Case 2: missing apphost
if [[ -f "$APPHOST" ]]; then
    cp "$APPHOST" "${APPHOST}.bak"
    rm -f "$APPHOST"
    cd "$TEST_ROOT"
    combined2="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e2=$?
    cd "$PLUGIN_ROOT"
    mv "${APPHOST}.bak" "$APPHOST"
    assert_neq0 'case2: missing apphost exit ≠ 0' "$e2"
    assert_match 'case2: 訊息提及 applicationhost' 'applicationhost' "$combined2"
fi

# Case 3: missing csproj sandbox
guid="$(powershell -NoProfile -Command '[guid]::NewGuid().ToString("N").Substring(0,12)' | tr -d '\r')"
sb="/c/Turbo/turbo-plugin-test-startiis-sh-$guid"
mkdir -p "$sb/.turbo-plugin"
echo "[iis]" > "$sb/.turbo-plugin/config.toml"
echo "enabled = true" >> "$sb/.turbo-plugin/config.toml"
(cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb"
combined3="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e3=$?
cd "$PLUGIN_ROOT"
powershell -NoProfile -Command "Remove-Item -LiteralPath '$sb' -Recurse -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
assert_neq0 'case3: no csproj exit ≠ 0' "$e3"
assert_match 'case3: 訊息提及 .csproj' '\.csproj' "$combined3"

echo ""
echo "start-iis.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
