#!/usr/bin/env bash
# get-target-url.test.sh — bash sibling for get-target-url.sh
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/get-target-url.sh"

# Capability gate (U5): get-target-url.sh is a ps1-delegate (needs PowerShell). Skip cleanly on
# a runner without PowerShell before any fixture setup. Last line "OK" + exit 0 = orchestrator
# non-FAIL signal; on Windows the gate passes and the test runs as today.
if ! command -v powershell >/dev/null 2>&1 && ! command -v pwsh >/dev/null 2>&1; then
    echo "OK (SKIPPED: get-target-url.sh delegates to PowerShell; no powershell/pwsh on this runner)"
    exit 0
fi

passed=0
failed=0

new_sandbox() {
    local purpose="$1"
    local guid
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    local dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-${purpose}-${guid}"
    mkdir -p "$dir"
    echo "$dir"
}

remove_sandbox() {
    local dir="$1"
    [[ -z "$dir" ]] && return
    [[ -d "$dir" ]] || return
    rm -rf "$dir" 2>/dev/null || true
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
  <ProjectExtensions>
    <VisualStudio>
      <FlavorProperties GUID="{349c5851-65df-11da-9384-00065b846f21}">
        <WebProjectProperties>
          <IISUrl>http://localhost:5000/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
EOF
}

init_git_repo() {
    (cd "$1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m 'init') >/dev/null 2>&1
}

assert_match() {
    local name="$1" pattern="$2" text="$3"
    if echo "$text" | grep -Eq "$pattern"; then
        echo "  [PASS] $name"
        ((passed++))
    else
        echo "  [FAIL] $name (pattern='$pattern' got='${text:0:200}')"
        ((failed++))
    fi
}
assert_neq0() {
    local name="$1" actual="$2"
    if [[ "$actual" != "0" ]]; then echo "  [PASS] $name"; ((passed++));
    else echo "  [FAIL] $name (got 0)"; ((failed++)); fi
}
assert_eq0() {
    local name="$1" actual="$2"
    if [[ "$actual" == "0" ]]; then echo "  [PASS] $name"; ((passed++));
    else echo "  [FAIL] $name (got $actual)"; ((failed++)); fi
}

# Case 1: happy
sb1="$(new_sandbox 'gtu-sh-happy')"
write_csproj "$sb1"
init_git_repo "$sb1"
cd "$sb1"
out1="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
exit1=$?
cd "$PLUGIN_ROOT"
assert_eq0 'case1: exit 0' "$exit1"
assert_match 'case1: stdout 含 IIS URL: http://localhost:5000/' 'IIS URL: http://localhost:5000/' "$out1"

# Case 2: SKILL re-invoke
cd "$sb1"
out2="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
exit2=$?
cd "$PLUGIN_ROOT"
assert_eq0 'case2: SKILL-entry exit 0' "$exit2"
assert_match 'case2: 結果一致' 'IIS URL: http://localhost:5000/' "$out2"

# Case 3: missing csproj
sb2="$(new_sandbox 'gtu-sh-nocsproj')"
(cd "$sb2" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
cd "$sb2"
combined3="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"
exit3=$?
cd "$PLUGIN_ROOT"
assert_neq0 'case3: missing csproj exit ≠ 0' "$exit3"
assert_match 'case3: 訊息提及 .csproj' '\.csproj' "$combined3"

remove_sandbox "$sb1"
remove_sandbox "$sb2"

echo ""
echo "get-target-url.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then echo "FAIL"; exit 1; fi
echo "OK"
exit 0
