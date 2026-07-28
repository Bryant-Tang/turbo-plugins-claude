#!/usr/bin/env bash
# approve-iis-express-cert.test.sh (shUnit2)
#
# approve-iis-express-cert.sh is a thin delegate to Approve-IisExpressCert.ps1 (lib/ps1-delegate.sh).
# Bash coverage focuses on:
#   1. delegate dispatch: the script exists and forwards to the matching .ps1.
#   2. -CheckOnly through the bash entry stays READ-ONLY and reports a state cleanly.
#
# This test NEVER trusts or untrusts a certificate: that is a real change to the machine's security
# configuration and the repo requires tests to leave global state alone. Only -CheckOnly is run.
# The exhaustive matrix lives in Approve-IisExpressCert.test.ps1.
#
# ps1-delegate needs PowerShell; on a runner without it the per-test gate SKIPs. A runner without
# IIS Express has no certificate at all, which the script reports as a loud failure -- also a pass
# here, since the point is that it says something intelligible either way.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
CERT="$PLUGIN_ROOT/scripts/approve-iis-express-cert.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi
}

# Case 1: the delegate exists and points at the matching .ps1 (no PowerShell needed).
test_script_exists() {
    assertTrue "approve-iis-express-cert.sh exists at $CERT" "[ -f '$CERT' ]"
    if grep -q 'Approve-IisExpressCert' "$CERT"; then
        assertTrue 'delegates to Approve-IisExpressCert' 0
    else
        fail "delegate does not reference Approve-IisExpressCert: $(cat "$CERT")"
    fi
}

# Case 2: -CheckOnly reports a state and never mutates anything.
test_checkonly_reports_a_state() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local out rc
    out="$(bash "$CERT" -CheckOnly 2>&1)"; rc=$?
    case "$out" in
        *CERT_OUTPUT*)
            assertEquals "有憑證時應 exit 0 (out: $out)" 0 "$rc"
            ;;
        *"IIS Express"*)
            # No certificate on this machine -> loud, explained failure is the contract.
            assertNotEquals "無憑證時應 fail loudly (out: $out)" 0 "$rc"
            ;;
        *)
            fail "unrecognised output from -CheckOnly (rc=$rc): $out"
            ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
