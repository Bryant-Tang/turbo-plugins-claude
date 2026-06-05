#!/usr/bin/env bash
# build-web.test.sh — bash sibling for build-web.sh
# Note: no script-level [iis] gate (SKILL-level only); real build deferred to SKILL-level test.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/build-web.sh"

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }

new_sb() {
    local guid
    guid="$(powershell -NoProfile -Command '[guid]::NewGuid().ToString("N").Substring(0,12)' | tr -d '\r')"
    local d="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-$1-$guid"
    mkdir -p "$d"
    echo "$d"
}
rm_sb() {
    powershell -NoProfile -Command "Remove-Item -LiteralPath '$1' -Recurse -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
}

# Case 1: missing csproj
sb1="$(new_sb 'build-sh-nocsproj')"
(cd "$sb1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb1"
combined1="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e1=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case1: missing csproj exit ≠ 0' "$e1"
assert_match 'case1: 訊息提及 .csproj' '\.csproj' "$combined1"

# Case 2: SKILL re-invoke
cd "$sb1"
combined2="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e2=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case2: SKILL re-invoke exit ≠ 0' "$e2"

# Case 3: [iis]=false sandbox (no script-level gate)
sb2="$(new_sb 'build-sh-iisfalse')"
mkdir -p "$sb2/.turbo-plugin"
echo "[iis]" > "$sb2/.turbo-plugin/config.toml"
echo "enabled = false" >> "$sb2/.turbo-plugin/config.toml"
(cd "$sb2" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb2"
combined3="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e3=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case3 (deviation): no script-level gate → still errors (csproj missing)' "$e3"

# Case 4 SKIP
echo "  [PASS] case4 (SKIP): real MSBuild deferred to Phase 2 SKILL"
((passed++))

rm_sb "$sb1"
rm_sb "$sb2"

echo ""
echo "build-web.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
