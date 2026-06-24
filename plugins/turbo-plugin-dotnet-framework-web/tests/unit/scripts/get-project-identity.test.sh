#!/usr/bin/env bash
# get-project-identity.test.sh (shUnit2) — bash sibling for get-project-identity.sh
# 1-line delegate to .ps1; exercises the .sh entry under a sandboxed workspace.
# ps1-delegate needs PowerShell; on a runner without it the per-test gate SKIPs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/get-project-identity.sh"
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
        chmod -R u+w "$d" 2>/dev/null || true
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
    # Explicit target via config (no auto-detect): get-project-identity resolves [build].project
    # (run section falls back to it). Script is invoked with no -Project.
    mkdir -p "$1/.turbo-plugin"
    printf '[build]\nproject = "HelloApp.csproj"\n' > "$1/.turbo-plugin/config.toml"
}

init_git_repo() {
    (cd "$1" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m 'fixture init') >/dev/null 2>&1
}

hash_of() {
    echo "$1" | grep -Eo 'IDENTITY_HASH=[0-9a-f]{8}' | head -1 | sed 's/IDENTITY_HASH=//'
}

# Case 1 + 2: happy path then deterministic re-invoke on same dir.
test_happy_and_deterministic() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb out1 e1 out2 e2 h1 h2
    sb="$(new_sandbox 'cpi-sh-happy')"
    write_csproj "$sb"
    init_git_repo "$sb"

    out1="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e1=$?
    assertEquals 'case1: exit 0' 0 "$e1"
    echo "$out1" | grep -Eq 'PROJECT='; assertTrue 'case1: stdout has PROJECT' $?
    echo "$out1" | grep -Eq 'IDENTITY_HASH=[0-9a-f]{8}'; assertTrue 'case1: IDENTITY_HASH 8-hex' $?
    echo "$out1" | grep -Eq 'SITE_NAME=HelloApp-[0-9a-f]{8}'; assertTrue 'case1: SITE_NAME shape' $?
    h1="$(hash_of "$out1")"

    out2="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e2=$?
    h2="$(hash_of "$out2")"
    assertEquals 'case2: SKILL-entry exit 0' 0 "$e2"
    assertEquals 'case2: hash deterministic' "$h1" "$h2"

    # stash h1 for the 中文 comparison
    HASH_ASCII="$h1"
}

# Case 3: 中文 path — exits 0, hash present, and differs from the ASCII-path hash.
test_chinese_path() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb zh out e h ascii
    sb="$(new_sandbox 'cpi-sh-zh')"
    zh="$sb/中文資料夾"
    mkdir -p "$zh"
    write_csproj "$zh"
    init_git_repo "$zh"

    out="$(cd "$zh" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"; e=$?
    assertEquals 'case3: 中文 path exit 0' 0 "$e"
    echo "$out" | grep -Eq 'IDENTITY_HASH=[0-9a-f]{8}'; assertTrue 'case3: 中文 path IDENTITY_HASH 8-hex' $?
    h="$(hash_of "$out")"

    # Derive the ASCII baseline independently so this test does not depend on run order.
    ascii="${HASH_ASCII:-}"
    if [ -z "$ascii" ]; then
        local sba outa
        sba="$(new_sandbox 'cpi-sh-ascii-ref')"
        write_csproj "$sba"
        init_git_repo "$sba"
        outa="$(cd "$sba" && bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
        ascii="$(hash_of "$outa")"
    fi
    assertTrue 'case3: 中文 path hash present' "[ -n '$h' ]"
    assertTrue 'case3: 中文 path hash differs from ASCII' "[ '$h' != '$ascii' ]"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
