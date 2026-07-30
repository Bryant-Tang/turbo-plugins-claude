#!/usr/bin/env bash
# build-web.test.sh (shUnit2) — bash sibling for build-web.sh
# build-web.sh is a ps1-delegate; on a runner without PowerShell the per-test gate SKIPs.
# Note: no script-level [iis] gate (SKILL-level only); real build deferred to SKILL-level test.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/build-web.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_PS=0
    # `powershell` specifically, NOT "powershell or pwsh". These scripts reach PowerShell through
    # ps1-delegate.sh, which runs `exec powershell ...` literally, so pwsh being installed does not
    # make them work -- and ubuntu runners DO have pwsh (Pester needs it), which made this gate
    # report "available" and then fail with `powershell: not found`.
    if command -v powershell >/dev/null 2>&1; then HAS_PS=1; fi
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

# Case 1 + 2: missing csproj — first invoke errors and mentions .csproj; re-invoke still errors.
test_missing_csproj_and_reinvoke() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb out e
    sb="$(new_sb 'build-sh-nocsproj')"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && echo placeholder > README.txt && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1

    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    assertTrue 'case1: missing csproj exit != 0' "[ $e -ne 0 ]"
    echo "$out" | grep -Eq '\.csproj'; assertTrue 'case1: 訊息提及 .csproj' $?

    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    assertTrue 'case2: SKILL re-invoke exit != 0' "[ $e -ne 0 ]"

    rm_sb "$sb"
}

# Case 3: [iis]=false sandbox — no script-level gate → still errors (csproj missing).
test_iis_false_no_script_gate() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb e
    sb="$(new_sb 'build-sh-iisfalse')"
    mkdir -p "$sb/.turbo-plugin"
    echo "[iis]" > "$sb/.turbo-plugin/config.toml"
    echo "enabled = false" >> "$sb/.turbo-plugin/config.toml"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1

    ( cd "$sb" && bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1 ); e=$?
    assertTrue 'case3 (deviation): no script-level gate → still errors (csproj missing)' "[ $e -ne 0 ]"

    rm_sb "$sb"
}

# Case 4 (U3): arg construction via a stub MSBuild — config OMITTED when unspecified (VS-aligned),
# and BUILD_OUTPUT template emitted. Proves the .sh delegator drives the new .ps1 behavior end-to-end.
test_arg_omit_config_stub() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local sb out e
    sb="$(new_sb 'build-sh-argomit')"
    cat > "$sb/HelloApp.csproj" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <Configuration Condition=" '$(Configuration)' == '' ">Debug</Configuration>
    <OutputType>Library</OutputType>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
EOF
    mkdir -p "$sb/.turbo-plugin"
    printf '[build]\nproject = "HelloApp.csproj"\n' > "$sb/.turbo-plugin/config.toml"
    printf '[tools]\nmsbuild_path = "msbuild-stub.bat"\n' > "$sb/.turbo-plugin/config.local.toml"
    printf '@echo off\r\necho MSBUILD_ARGS: %%*\r\n' > "$sb/msbuild-stub.bat"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1

    out="$(cd "$sb" && bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    rm_sb "$sb"
    assertEquals 'case4: stub build exit 0' 0 "$e"
    echo "$out" | grep -q '/p:Configuration'; assertFalse 'case4: /p:Configuration OMITTED when unspecified' $?
    echo "$out" | grep -q 'BUILD_OUTPUT'; assertTrue 'case4: BUILD_OUTPUT template emitted' $?
}

# Case 5: real MSBuild deferred to Phase 2 SKILL-level test (always skipped here).
test_real_msbuild_deferred() {
    startSkipping
    assertTrue 'case5 (SKIP): real MSBuild deferred to Phase 2 SKILL' true
}

# shellcheck disable=SC1090
. "$SHUNIT2"
