#!/usr/bin/env bash
# start-iis.test.sh (shUnit2)
# Script under test: scripts/start-iis.sh (ps1-delegate -> needs PowerShell + IIS Express).
#
# Same coverage as Start-Iis.test.ps1: [iis] disabled gate consistency, missing apphost,
# missing csproj. Happy path is SKILL-level territory (real IIS Express launch).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/start-iis.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

TEST_ROOT="$PLUGIN_ROOT/tests/.sandbox/test-turbo-plugin"
CFG="$TEST_ROOT/.turbo-plugin/config.toml"
APPHOST="$TEST_ROOT/.turbo-plugin/applicationhost.config"

oneTimeSetUp() {
    # U5: ps1-delegate (needs PowerShell + IIS Express). On a runner without PowerShell, SKIP.
    HAS_PS=0
    # `powershell` specifically, NOT "powershell or pwsh". These scripts reach PowerShell through
    # ps1-delegate.sh, which runs `exec powershell ...` literally, so pwsh being installed does not
    # make them work -- and ubuntu runners DO have pwsh (Pester needs it), which made this gate
    # report "available" and then fail with `powershell: not found`.
    if command -v powershell >/dev/null 2>&1; then HAS_PS=1; fi

    if [ -d "$TEST_ROOT" ] && [ ! -d "$TEST_ROOT/.git" ]; then
        (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
    fi

    # applicationhost.config is generated FROM IIS Express's own shipped template, so the
    # lazy-bootstrap case needs it present. Empty when IIS Express is not installed -> SKIP.
    IIS_TEMPLATE=""
    for _root in "$(cygpath -u "${PROGRAMFILES:-C:\\Program Files}" 2>/dev/null)" \
                 "$(cygpath -u "$(printenv 'ProgramFiles(x86)' 2>/dev/null || echo 'C:\\Program Files (x86)')" 2>/dev/null)"; do
        [ -n "$_root" ] || continue
        if [ -f "$_root/IIS Express/AppServer/applicationhost.config" ]; then
            IIS_TEMPLATE="$_root/IIS Express/AppServer/applicationhost.config"
            break
        fi
    done
}

set_iis_enabled() {
    sed -i.bak -E "s/^enabled = (true|false)$/enabled = $1/" "$CFG" 2>/dev/null
    rm -f "${CFG}.bak" 2>/dev/null || true
}

# Case 1: [iis] enabled = false -> exit != 0 + "IIS 已停用"
test_iis_disabled() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local combined e
    set_iis_enabled false
    cd "$TEST_ROOT"
    combined="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    set_iis_enabled true
    assertNotEquals 'case1: [iis]=false exit != 0' 0 "$e"
    echo "$combined" | grep -Eq 'IIS 已停用'; assertTrue 'case1: stderr 含 IIS 已停用' $?
}

# Case 4: SKILL re-invoke disabled (consistency) -> exit != 0 + same message
test_skill_reinvoke_disabled() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -d "$TEST_ROOT" ] || fail "fixture $TEST_ROOT missing"
    local combined e
    set_iis_enabled false
    cd "$TEST_ROOT"
    combined="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    set_iis_enabled true
    assertNotEquals 'case4: SKILL-entry [iis]=false exit != 0' 0 "$e"
    echo "$combined" | grep -Eq 'IIS 已停用'; assertTrue 'case4: 訊息一致' $?
}

# Case 2: no applicationhost.config -> generated on the spot (lazy bootstrap).
#
# A throwaway repo is used rather than the shared fixture, and its iis_express_path points at a
# file that is NOT a real executable: the whole configuration path runs for real and only the
# launch step fails, so the test suite never spawns an IIS Express process. (Pointing the fixture
# at the machine's real IIS Express would do exactly that, now that a missing config no longer
# stops the script.)
test_lazy_apphost_generated() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -n "$IIS_TEMPLATE" ] || startSkipping
    local guid sb combined generated
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    sb="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-lazy-sh-$guid"
    mkdir -p "$sb/.turbo-plugin" "$sb/AppServer"
    # The production code looks for the template beside iisexpress.exe under AppServer/, so the
    # fake executable gets a real template next to it and the generation path runs for real.
    cp "$IIS_TEMPLATE" "$sb/AppServer/applicationhost.config"
    cat > "$sb/HelloApp.csproj" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>HelloApp</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
    <IISUrl>http://localhost:51793/</IISUrl>
  </PropertyGroup>
</Project>
EOF
    printf '[iis]\nenabled = true\n' > "$sb/.turbo-plugin/config.toml"
    printf 'not an executable' > "$sb/not-really-iisexpress.exe"
    printf '[tools]\niis_express_path = "not-really-iisexpress.exe"\n' > "$sb/.turbo-plugin/config.local.toml"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
    cd "$sb"
    combined="$(bash "$SCRIPT_UNDER_TEST" -Project HelloApp.csproj 2>&1)"
    cd "$PLUGIN_ROOT"

    generated="$sb/.turbo-plugin/applicationhost.config"
    [ -f "$generated" ]; assertTrue 'case2: 設定檔第一次執行就被產生出來' $?
    grep -q 'name="HelloApp"' "$generated"; assertTrue 'case2: 站台以專案名命名' $?
    grep -q '\*:51793:localhost' "$generated"; assertTrue 'case2: binding 取自 csproj 的 IISUrl' $?
    echo "$combined" | grep -q 'tp-setup'; assertFalse 'case2: 不再叫使用者先跑別的設定指令' $?
    rm -rf "$sb" 2>/dev/null || true
}

# Case 3: enabled IIS but missing csproj -> exit != 0 + message mentions .csproj
test_missing_csproj() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local guid sb combined e
    guid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${RANDOM}${RANDOM}${RANDOM}")"
    guid="${guid//-/}"; guid="${guid:0:12}"
    sb="$PLUGIN_ROOT/tests/.sandbox/sandboxes/turbo-plugin-test-startiis-sh-$guid"
    mkdir -p "$sb/.turbo-plugin"
    echo "[iis]" > "$sb/.turbo-plugin/config.toml"
    echo "enabled = true" >> "$sb/.turbo-plugin/config.toml"
    (cd "$sb" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1
    cd "$sb"
    combined="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    rm -rf "$sb" 2>/dev/null || true
    assertNotEquals 'case3: no csproj exit != 0' 0 "$e"
    echo "$combined" | grep -Eq '\.csproj'; assertTrue 'case3: 訊息提及 .csproj' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
