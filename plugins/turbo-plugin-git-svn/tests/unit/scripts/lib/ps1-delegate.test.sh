#!/usr/bin/env bash
# ps1-delegate.test.sh (shUnit2)
#
# Unit tests for plugins/turbo-plugin-git-svn/scripts/lib/ps1-delegate.sh.
# ps1-delegate dispatches `bash <script>` to `powershell -File <SCRIPTS_DIR>/<script>.ps1 <args...>`.
#
# Cases:
#   1. happy dispatch: a temp scripts/lib/ps1-delegate.sh sibling fake.ps1 that writes a sentinel
#      and exits 0 → delegate invocation prints sentinel, exit code 0.
#   2. missing .ps1: delegate to a non-existent script → powershell -File errors, non-zero exit.
#   3. passthrough exit code: fake.ps1 exits with code 42 → delegate exits 42 (PS error codes pass).
#
# ps1-delegate invokes real powershell; on a runner without it the cases SKIP cleanly.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
DELEGATE="$PLUGIN_ROOT/scripts/lib/ps1-delegate.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    # `powershell` specifically, NOT "powershell or pwsh". ps1-delegate.sh runs
    # `exec powershell ...` literally, so pwsh being installed does not make the delegate work --
    # and ubuntu runners DO have pwsh (Pester needs it), which made this gate report "PowerShell is
    # available" and then fail with `powershell: not found`, exit 127.
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1; then HAS_PS=1; fi
}

setUp() {
    [ "$HAS_PS" -eq 1 ] || return 0
    TMPDIR_RT="$(mktemp -d -t turbo-ps1delegate-XXXXXX)"
    mkdir -p "$TMPDIR_RT/scripts/lib"
    cp "$DELEGATE" "$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
    chmod +x "$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
    DELEGATE_FAKE="$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
}

tearDown() {
    [ -n "${TMPDIR_RT:-}" ] && rm -rf "$TMPDIR_RT" 2>/dev/null || true
}

test_delegate_exists() {
    [ -f "$DELEGATE" ]
    assertTrue 'ps1-delegate.sh exists' $?
}

test_happy_dispatch() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-happy.ps1" <<'PS1'
[Console]::Out.WriteLine('SENTINEL_TURBO_DELEGATE_OK')
exit 0
PS1
    local out rc
    out="$("$DELEGATE_FAKE" fake-happy 2>&1)"; rc=$?
    assertEquals "Case 1: happy dispatch exit 0 (out=${out:0:200})" 0 "$rc"
    case "$out" in
        *SENTINEL_TURBO_DELEGATE_OK*) assertTrue 'Case 1: sentinel observed' 0 ;;
        *) fail "Case 1: sentinel missing, out='${out:0:200}'" ;;
    esac
}

test_missing_ps1_nonzero() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local rc
    "$DELEGATE_FAKE" no-such-script-here >/dev/null 2>&1; rc=$?
    assertNotEquals 'Case 2: missing .ps1 — delegate exits non-zero' 0 "$rc"
}

test_passthrough_exit_code() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-exit42.ps1" <<'PS1'
exit 42
PS1
    local rc
    "$DELEGATE_FAKE" fake-exit42 >/dev/null 2>&1; rc=$?
    assertEquals 'Case 3: passthrough exit code 42' 42 "$rc"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
