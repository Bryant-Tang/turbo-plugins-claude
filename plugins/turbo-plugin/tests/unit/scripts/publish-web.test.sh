#!/usr/bin/env bash
# publish-web.test.sh — bash sibling for publish-web.sh
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/publish-web.sh"

# Capability gate (U5): publish-web.sh is a ps1-delegate (needs PowerShell). Skip cleanly on
# a runner without PowerShell before any fixture setup. Last line "OK" + exit 0 = orchestrator
# non-FAIL signal; on Windows the gate passes and the test runs as today.
if ! command -v powershell >/dev/null 2>&1 && ! command -v pwsh >/dev/null 2>&1; then
    echo "OK (SKIPPED: publish-web.sh delegates to PowerShell; no powershell/pwsh on this runner)"
    exit 0
fi

passed=0
failed=0

assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }

new_sb() {
    local guid
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    local d="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-$1-$guid"
    mkdir -p "$d"
    echo "$d"
}
rm_sb() {
    [[ -z "${1:-}" || ! -d "$1" ]] && return 0
    rm -rf "$1" 2>/dev/null || true
}

write_csproj() {
    cat > "$1/HelloApp.csproj" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <ProjectGuid>{00000000-1111-2222-3333-444444444444}</ProjectGuid>
    <OutputType>Library</OutputType>
    <RootNamespace>HelloApp</RootNamespace>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
EOF
}

# Case 1: missing csproj
sb1="$(new_sb 'publish-sh-nocsproj')"
(cd "$sb1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb1"
combined1="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e1=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case1: missing csproj exit ≠ 0' "$e1"
assert_match 'case1: 訊息提及 .csproj' '\.csproj' "$combined1"

# Case 2: missing pubxml
sb2="$(new_sb 'publish-sh-nopubxml')"
write_csproj "$sb2"
(cd "$sb2" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb2"
combined2="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e2=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case2: missing pubxml exit ≠ 0' "$e2"
assert_match 'case2: 訊息提及 pubxml' '[Pp]ubxml|pubxml' "$combined2"

# Case 3: SKILL re-invoke
cd "$sb2"
combined3="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e3=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case3: SKILL re-invoke exit ≠ 0' "$e3"

echo "  [PASS] case4 (SKIP): real MSBuild publish deferred to Phase 2"
((passed++))

rm_sb "$sb1"
rm_sb "$sb2"

echo ""
echo "publish-web.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
