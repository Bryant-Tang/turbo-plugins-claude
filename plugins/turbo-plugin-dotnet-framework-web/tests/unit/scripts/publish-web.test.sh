#!/usr/bin/env bash
# publish-web.test.sh (shUnit2)
# Script under test: scripts/publish-web.sh (ps1-delegate -> needs PowerShell).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/publish-web.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    # U5: publish-web.sh is a ps1-delegate (needs PowerShell). On a runner without it, SKIP.
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi
}

new_sb() {
    local guid
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    local d="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-$1-$guid"
    mkdir -p "$d"
    echo "$d"
}
rm_sb() {
    [ -z "${1:-}" ] && return 0
    [ -d "$1" ] || return 0
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

# Case 1: missing csproj -> exit != 0 + message mentions .csproj
test_missing_csproj() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb combined e
    sb="$(new_sb 'publish-sh-nocsproj')"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
    cd "$sb"
    combined="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    rm_sb "$sb"
    assertNotEquals 'case1: missing csproj exit != 0' 0 "$e"
    echo "$combined" | grep -Eq '\.csproj'; assertTrue 'case1: message mentions .csproj' $?
}

# Case 2: missing pubxml -> exit != 0 + message mentions pubxml
test_missing_pubxml() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb combined e
    sb="$(new_sb 'publish-sh-nopubxml')"
    write_csproj "$sb"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
    cd "$sb"
    # Explicit -Project (no auto-detect): reaches the pubxml-finding step so the missing-pubxml
    # error fires (the point of this case), not a "no target" error.
    combined="$(bash "$SCRIPT_UNDER_TEST" -Project HelloApp.csproj 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    rm_sb "$sb"
    assertNotEquals 'case2: missing pubxml exit != 0' 0 "$e"
    echo "$combined" | grep -Eq '[Pp]ubxml|pubxml'; assertTrue 'case2: message mentions pubxml' $?
}

# Case 3: SKILL re-invoke (consistency) -> still exit != 0
test_skill_reinvoke() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb e
    sb="$(new_sb 'publish-sh-reinvoke')"
    write_csproj "$sb"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
    cd "$sb"
    bash "$SCRIPT_UNDER_TEST" -Project HelloApp.csproj >/dev/null 2>&1; e=$?
    cd "$PLUGIN_ROOT"
    rm_sb "$sb"
    assertNotEquals 'case3: SKILL re-invoke exit != 0' 0 "$e"
}

# Case 4 (U4): arg construction via stub MSBuild — config OMITTED when unspecified (pubxml
# governs), PUBLISH_OUTPUT preserved. Proves the .sh delegator drives the new .ps1 behavior.
test_arg_omit_config_stub() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb out e
    sb="$(new_sb 'publish-sh-argomit')"
    write_csproj "$sb"
    mkdir -p "$sb/Properties/PublishProfiles"
    cat > "$sb/Properties/PublishProfiles/FolderProfile.pubxml" <<'EOF'
<Project><PropertyGroup><WebPublishMethod>FileSystem</WebPublishMethod><PublishUrl>bin\app.publish\</PublishUrl></PropertyGroup></Project>
EOF
    mkdir -p "$sb/.turbo-plugin"
    printf '[publish]\nproject = "HelloApp.csproj"\n' > "$sb/.turbo-plugin/config.toml"
    printf '[tools]\nmsbuild_path = "msbuild-stub.bat"\n' > "$sb/.turbo-plugin/config.local.toml"
    printf '@echo off\r\necho MSBUILD_ARGS: %%*\r\n' > "$sb/msbuild-stub.bat"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1

    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    rm_sb "$sb"
    assertEquals 'case4: stub publish exit 0' 0 "$e"
    echo "$out" | grep -q '/p:Configuration'; assertFalse 'case4: /p:Configuration OMITTED (pubxml governs)' $?
    echo "$out" | grep -q 'PUBLISH_OUTPUT'; assertTrue 'case4: PUBLISH_OUTPUT preserved' $?
}

# Case 5: real MSBuild publish deferred to Phase 2 (always SKIP).
test_real_publish_deferred() {
    startSkipping
}

# shellcheck disable=SC1090
. "$SHUNIT2"
