#!/usr/bin/env bash
# test-iis-listening.test.sh — bash sibling for check-iis-listening.sh
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/test-iis-listening.sh"

# Capability gate (U5): test-iis-listening.sh is a ps1-delegate (needs PowerShell). Skip cleanly
# on a runner without PowerShell before any fixture setup. Last line "OK" + exit 0 = orchestrator
# non-FAIL signal; on Windows the gate passes and the test runs as today.
if ! command -v powershell >/dev/null 2>&1 && ! command -v pwsh >/dev/null 2>&1; then
    echo "OK (SKIPPED: test-iis-listening.sh delegates to PowerShell; no powershell/pwsh on this runner)"
    exit 0
fi

passed=0
failed=0
port=51928

new_sandbox() {
    local guid
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    local dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-$1-${guid}"
    mkdir -p "$dir"
    echo "$dir"
}
remove_sandbox() {
    [[ -z "$1" || ! -d "$1" ]] && return
    rm -rf "$1" 2>/dev/null || true
}
write_csproj() {
    cat > "$1/HelloApp.csproj" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <ProjectGuid>{00000000-1111-2222-3333-444444444444}</ProjectGuid>
    <OutputType>Library</OutputType>
    <RootNamespace>HelloApp</RootNamespace>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
  <ProjectExtensions>
    <VisualStudio>
      <FlavorProperties GUID="{349c5851-65df-11da-9384-00065b846f21}">
        <WebProjectProperties>
          <IISUrl>http://localhost:${port}/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
EOF
}
init_git() {
    (cd "$1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
}
assert_match() {
    if echo "$3" | grep -Eq "$2"; then echo "  [PASS] $1"; ((passed++));
    else echo "  [FAIL] $1 pattern='$2' got='${3:0:200}'"; ((failed++)); fi
}
assert_neq0() { if [[ "$2" != "0" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 got 0"; ((failed++)); fi }
assert_eq() { if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; ((passed++)); else echo "  [FAIL] $1 expected '$2' got '$3'"; ((failed++)); fi }

# Case 1: not listening
sb1="$(new_sandbox 'cil-sh-notlisten')"
write_csproj "$sb1"
init_git "$sb1"
cd "$sb1"
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: exit 1' '1' "$e1"
assert_match 'case1: stdout 含 port:' "port: $port" "$out1"

# Case 2: SKILL re-invoke
cd "$sb1"
out2="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
cd "$PLUGIN_ROOT"
assert_eq 'case2: exit 1' '1' "$e2"

# Case 3: missing csproj
sb2="$(new_sandbox 'cil-sh-nocsproj')"
(cd "$sb2" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb2"
combined3="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e3=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case3: missing csproj exit ≠ 0' "$e3"

remove_sandbox "$sb1"
remove_sandbox "$sb2"

echo ""
echo "check-iis-listening.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
