#!/usr/bin/env bash
# remove-orphan-iis.test.sh (shUnit2)
# Script under test: scripts/remove-orphan-iis.sh (ps1-delegate -> needs PowerShell + IIS Express).
# Note: script has NO [iis] gate at script level (by design — gate is SKILL-level).
#
# U5 / R5 — delegate-smoke only: remove-orphan-iis.sh forwards to Remove-OrphanIis.ps1 via
#   lib/ps1-delegate.sh (no independent regex logic). The canonical regex-escape "誤殺防護"
#   assertions live in Remove-OrphanIis.test.ps1. Here we only verify the delegate dispatches
#   and surfaces the No-orphan happy path / exit codes.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/remove-orphan-iis.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

TEST_ROOT="$PLUGIN_ROOT/tests/.sandbox/test-turbo-plugin"
CFG="$TEST_ROOT/.turbo-plugin/config.toml"

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

    # The PROCESS half of "no orphan" cannot be sandboxed: the script scans machine-wide for
    # iisexpress, and the fixture's csproj stem (HelloApp) is a plausible real project name, so a
    # developer's own running HelloApp-<hash> would legitimately be reported as an orphan. Detect
    # it and SKIP loudly rather than fail on someone else's running server.
    FOREIGN_IIS=0
    if command -v powershell >/dev/null 2>&1; then
        if powershell -NoProfile -Command '$p=@(Get-CimInstance Win32_Process -Filter "Name = ''iisexpress.exe''" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "/site:HelloApp-[0-9a-f]{8}" }); if ($p.Count -gt 0) { exit 9 } else { exit 0 }' >/dev/null 2>&1; then
            FOREIGN_IIS=0
        else
            FOREIGN_IIS=1
        fi
    fi
}

set_iis_enabled() {
    sed -i.bak -E "s/^enabled = (true|false)$/enabled = $1/" "$CFG" 2>/dev/null
    rm -f "${CFG}.bak" 2>/dev/null || true
}

# Guard for the machine-state-dependent cases: needs PowerShell, the fixture, and no foreign
# HelloApp IIS Express. Returns non-zero (after arming shUnit2's skip) when any is missing.
need_clean_machine() {
    [ "$HAS_PS" -eq 1 ] || { startSkipping; return 1; }
    if [ "$FOREIGN_IIS" -eq 1 ]; then
        echo "WARNING: skipped: an iisexpress running a HelloApp-<hash> site is already on this machine, so 'no orphan' cannot hold; the Remove-OrphanIis no-orphan guard is UNGUARDED this run." >&2
        startSkipping; return 1
    fi
    [ -d "$TEST_ROOT" ] || { fail "fixture $TEST_ROOT missing"; return 1; }
    return 0
}

# Give the script under test its OWN empty %TEMP%. It scans GetTempPath() for stale
# turbo-plugin-iis-<hash>.{config,out.log,err.log} sets, so against the real temp dir these
# assertions depend on whatever any earlier IIS Express run left on the machine -- a leftover from
# a developer's own /tp-run turned these cases red once already. GetTempPath() reads TMP then TEMP,
# so both must be set, and the value must be in WINDOWS form for the PowerShell child (`pwd -W`).
ISO_TEMP=''
run_with_isolated_temp() {
    ISO_TEMP="$PLUGIN_ROOT/tests/.sandbox/sandboxes/iis-temp-$$-$RANDOM"
    mkdir -p "$ISO_TEMP"
    local win
    win="$(cd "$ISO_TEMP" && pwd -W 2>/dev/null || printf '%s' "$ISO_TEMP")"
    TMP="$win" TEMP="$win" bash "$SCRIPT_UNDER_TEST" "$@"
    local rc=$?
    rm -rf "$ISO_TEMP" 2>/dev/null || true
    return $rc
}

# Case 1: no orphan -> exit 0 + "No orphan IIS Express"
test_no_orphan() {
    need_clean_machine || return 0
    local out e
    cd "$TEST_ROOT"
    out="$(run_with_isolated_temp 2>/dev/null)"; e=$?
    cd "$PLUGIN_ROOT"
    assertEquals 'case1: no-orphan exit 0' 0 "$e"
    echo "$out" | grep -Eq 'No orphan IIS Express'; assertTrue 'case1: No orphan message' $?
}

# Case 2: SKILL re-invoke -> exit 0
test_skill_reinvoke() {
    need_clean_machine || return 0
    local e
    cd "$TEST_ROOT"
    run_with_isolated_temp >/dev/null 2>&1; e=$?
    cd "$PLUGIN_ROOT"
    assertEquals 'case2: SKILL re-invoke exit 0' 0 "$e"
}

# Case 3: [iis]=false — script has no gate by design, still exits 0 with No-orphan message.
test_no_script_level_gate() {
    need_clean_machine || return 0
    local out e
    set_iis_enabled false
    cd "$TEST_ROOT"
    out="$(run_with_isolated_temp 2>/dev/null)"; e=$?
    cd "$PLUGIN_ROOT"
    set_iis_enabled true
    assertEquals 'case3 (deviation): no script-level gate, still exits 0' 0 "$e"
    echo "$out" | grep -Eq 'No orphan IIS Express'; assertTrue 'case3: 訊息仍是 No orphan' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
