#!/usr/bin/env bash
# test-iis-listening.test.sh (shUnit2) — bash sibling for test-iis-listening.sh
#
# test-iis-listening.sh is a ps1-delegate (needs PowerShell). On a runner without
# PowerShell the cases SKIP cleanly (Unix x Windows-only-tool); on Windows they run.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/test-iis-listening.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

PORT=51928

oneTimeSetUp() {
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi
}

new_sandbox() {
    local guid
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    local dir="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-$1-${guid}"
    mkdir -p "$dir"
    echo "$dir"
}
remove_sandbox() {
    [ -z "${1:-}" ] || [ ! -d "$1" ] && return 0
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
          <IISUrl>http://localhost:${PORT}/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
EOF
    # Explicit target via config (no auto-detect): test-iis-listening → Resolve-IisSettings reads
    # [run].project, falling back to [build].project. Script is invoked with no -Project.
    mkdir -p "$1/.turbo-plugin"
    printf '[build]\nproject = "HelloApp.csproj"\n' > "$1/.turbo-plugin/config.toml"
}
init_git() {
    (cd "$1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
}

# Case 1: not listening — exit 1, stdout 含 port:
test_not_listening() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local sb out e
    sb="$(new_sandbox 'cil-sh-notlisten')"
    write_csproj "$sb"
    init_git "$sb"
    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case1: exit 1' 1 "$e"
    echo "$out" | grep -Eq "port: $PORT"; assertTrue 'case1: stdout 含 port:' $?
    remove_sandbox "$sb"
}

# Case 2: SKILL re-invoke — still exit 1
test_reinvoke_consistent() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local sb e
    sb="$(new_sandbox 'cil-sh-reinvoke')"
    write_csproj "$sb"
    init_git "$sb"
    (cd "$sb" && bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1)
    (cd "$sb" && bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1); e=$?
    assertEquals 'case2: exit 1' 1 "$e"
    remove_sandbox "$sb"
}

# Case 3: missing csproj — exit != 0
test_missing_csproj() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local sb e
    sb="$(new_sandbox 'cil-sh-nocsproj')"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
    (cd "$sb" && bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1); e=$?
    assertNotEquals 'case3: missing csproj exit != 0' 0 "$e"
    remove_sandbox "$sb"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
