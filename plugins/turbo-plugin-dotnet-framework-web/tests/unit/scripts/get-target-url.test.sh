#!/usr/bin/env bash
# get-target-url.test.sh (shUnit2) — bash sibling for get-target-url.sh
# ps1-delegate needs PowerShell; on a runner without it the per-test gate SKIPs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/get-target-url.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi
    SANDBOXES=()
}

oneTimeTearDown() {
    local d
    for d in "${SANDBOXES[@]:-}"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        rm -rf "$d" 2>/dev/null || true
    done
}

new_sandbox() {
    local purpose="$1" guid dir
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-${purpose}-${guid}"
    mkdir -p "$dir"
    SANDBOXES+=("$dir")
    echo "$dir"
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
    # Explicit target via config (no auto-detect): get-target-url → Resolve-IisSettings reads
    # [run].project, falling back to [build].project. Script is invoked with no -Project.
    mkdir -p "$1/.turbo-plugin"
    printf '[build]\nproject = "HelloApp.csproj"\n' > "$1/.turbo-plugin/config.toml"
}

init_git_repo() {
    (cd "$1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m 'init') >/dev/null 2>&1
}

# Case 1 + 2: happy path, then SKILL re-invoke yields the same IIS URL.
test_happy_and_reinvoke() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb out1 e1 out2 e2
    sb="$(new_sandbox 'gtu-sh-happy')"
    write_csproj "$sb"
    init_git_repo "$sb"

    out1="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
    assertEquals 'case1: exit 0' 0 "$e1"
    echo "$out1" | grep -Eq 'IIS URL: http://localhost:5000/'; assertTrue 'case1: stdout 含 IIS URL' $?

    out2="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
    assertEquals 'case2: SKILL-entry exit 0' 0 "$e2"
    echo "$out2" | grep -Eq 'IIS URL: http://localhost:5000/'; assertTrue 'case2: 結果一致' $?
}

# Case 3: missing csproj → exit != 0 and message mentions .csproj.
test_missing_csproj() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb out e
    sb="$(new_sandbox 'gtu-sh-nocsproj')"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1

    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    assertTrue 'case3: missing csproj exit != 0' "[ $e -ne 0 ]"
    echo "$out" | grep -Eq '\.csproj'; assertTrue 'case3: 訊息提及 .csproj' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
