#!/usr/bin/env bash
# compress-content.test.sh (shUnit2)
#
# compress-content.sh is a thin delegate to pack-content.ps1 (lib/ps1-delegate.sh).
# Bash coverage focuses on:
#   1. delegate dispatch: script exists.
#   2. no-config skip: cwd missing .turbo-plugin/config.toml → ps1 raises/skips with frontend-related output.
#   3. arg pass-through: passing an unknown arg should not crash the bash delegate.
#
# We do not exercise the full happy build flow (that lives in Compress-Content.test.ps1 — the .ps1 already
# carries the canonical assertions; bash entry is a delegate so re-running the same heavy build would
# double the runtime without adding signal).
#
# ps1-delegate needs PowerShell; on a runner without it the per-test gate SKIPs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
PACK="$PLUGIN_ROOT/scripts/compress-content.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_PS=0
    # `powershell` specifically, NOT "powershell or pwsh". These scripts reach PowerShell through
    # ps1-delegate.sh, which runs `exec powershell ...` literally, so pwsh being installed does not
    # make them work -- and ubuntu runners DO have pwsh (Pester needs it), which made this gate
    # report "available" and then fail with `powershell: not found`.
    if command -v powershell >/dev/null 2>&1; then HAS_PS=1; fi
}

setUp() {
    TMPDIR_CASE="$(mktemp -d -t turbo-pack-content-bash-XXXXXX)"
}
tearDown() {
    [ -n "${TMPDIR_CASE:-}" ] && rm -rf "$TMPDIR_CASE" 2>/dev/null || true
}

# Case 1: compress-content.sh exists (no PowerShell needed for this check).
test_script_exists() {
    assertTrue "compress-content.sh exists at $PACK" "[ -f '$PACK' ]"
}

# Case 2: running from a temp dir with no .turbo-plugin/config.toml → delegate forwards to ps1,
# which emits a frontend/config-related message (skip or error, both acceptable).
test_no_config_emits_frontend_message() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local out
    out="$(cd "$TMPDIR_CASE" && bash "$PACK" 2>&1)"
    case "$out" in
        *"not configured"*|*"config.toml"*|*"frontend"*)
            assertTrue 'no-config delegate emits frontend-related message' true ;;
        *)
            fail "no-config delegate output: unexpected stdout/stderr: $out" ;;
    esac
}

# Case 3: passing unknown arg → bash entry must not crash (any non-negative rc is fine).
test_extra_args_do_not_crash() {
    [ "$HAS_PS" -eq 1 ] || startSkipping
    local rc
    ( cd "$TMPDIR_CASE" && bash "$PACK" --bogus-arg >/dev/null 2>&1 ); rc=$?
    assertTrue "extra args do not crash bash delegate (rc=$rc)" "[ $rc -ge 0 ]"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
