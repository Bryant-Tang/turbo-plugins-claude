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
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi

    if [ -d "$TEST_ROOT" ] && [ ! -d "$TEST_ROOT/.git" ]; then
        (cd "$TEST_ROOT" && git init -q && git config user.email 'test@example.invalid' && git config user.name 'Test' && git add -A && git -c commit.gpgsign=false commit -q -m init) >/dev/null 2>&1 || true
    fi
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

# Case 2: missing apphost -> exit != 0 + message mentions applicationhost.
# Only runs when the fixture has an applicationhost.config to remove.
test_missing_apphost() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    [ -f "$APPHOST" ] || startSkipping
    local combined e
    cp "$APPHOST" "${APPHOST}.bak"
    rm -f "$APPHOST"
    cd "$TEST_ROOT"
    combined="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; e=$?
    cd "$PLUGIN_ROOT"
    mv "${APPHOST}.bak" "$APPHOST"
    assertNotEquals 'case2: missing apphost exit != 0' 0 "$e"
    echo "$combined" | grep -Eq 'applicationhost'; assertTrue 'case2: 訊息提及 applicationhost' $?
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
