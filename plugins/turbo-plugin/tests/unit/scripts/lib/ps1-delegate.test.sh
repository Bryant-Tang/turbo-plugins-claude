#!/usr/bin/env bash
# ps1-delegate.test.sh
#
# Unit tests for plugins/turbo-plugin/scripts/lib/ps1-delegate.sh.
# ps1-delegate dispatches `bash <script>` to `powershell -File <SCRIPTS_DIR>/<script>.ps1 <args...>`.
#
# Cases (≥ 3):
#   1. happy dispatch: a temp scripts/lib/ps1-delegate.sh sibling fake.ps1 that writes a sentinel
#      and exits 0 → delegate invocation prints sentinel, exit code 0.
#   2. missing .ps1: delegate to a non-existent script → powershell -File errors, non-zero exit.
#   3. passthrough exit code: fake.ps1 exits with code 42 → delegate exits 42 (PS error codes pass).
#
# Conventions:
#   - last non-empty line is "OK" (pass) or "FAIL: <reason>" (fail)
#   - exit 0 if all pass, 1 otherwise

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
DELEGATE="$PLUGIN_ROOT/scripts/lib/ps1-delegate.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

if [[ ! -f "$DELEGATE" ]]; then
    echo "FAIL: ps1-delegate.sh not found at $DELEGATE"
    exit 1
fi

# Build a sandbox mirroring scripts/<name>.ps1 + scripts/lib/ps1-delegate.sh layout.
# delegate computes SCRIPTS_DIR as `dirname(__file__)/..`, so we put delegate at
# <sb>/scripts/lib/ps1-delegate.sh and the target ps1 at <sb>/scripts/<name>.ps1.
TMPDIR_RT="$(mktemp -d -t turbo-ps1delegate-XXXXXX)"
trap 'rm -rf "$TMPDIR_RT" 2>/dev/null || true' EXIT

mkdir -p "$TMPDIR_RT/scripts/lib"
cp "$DELEGATE" "$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
chmod +x "$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
DELEGATE_FAKE="$TMPDIR_RT/scripts/lib/ps1-delegate.sh"

# Case 1: happy dispatch
cat > "$TMPDIR_RT/scripts/fake-happy.ps1" <<'PS1'
[Console]::Out.WriteLine('SENTINEL_TURBO_DELEGATE_OK')
exit 0
PS1

out_c1="$("$DELEGATE_FAKE" fake-happy 2>&1)"
rc_c1=$?
if [[ "$rc_c1" -eq 0 && "$out_c1" == *"SENTINEL_TURBO_DELEGATE_OK"* ]]; then
    record_pass "Case 1: happy dispatch — fake.ps1 stdout sentinel observed, exit 0"
else
    record_fail "Case 1: happy dispatch" "rc=$rc_c1, out='${out_c1:0:200}'"
fi

# Case 2: missing .ps1 — delegate to a script that does not exist
out_c2="$("$DELEGATE_FAKE" no-such-script-here 2>&1 || true)"
rc_c2=$?
# powershell -File on a missing path exits non-zero; rc must NOT be 0.
if [[ "$rc_c2" -ne 0 ]]; then
    record_pass "Case 2: missing .ps1 — delegate exits non-zero (rc=$rc_c2)"
else
    record_fail "Case 2: missing .ps1 — expected non-zero exit" "rc=0, out='${out_c2:0:200}'"
fi

# Case 3: passthrough exit code (fake.ps1 exits 42)
cat > "$TMPDIR_RT/scripts/fake-exit42.ps1" <<'PS1'
exit 42
PS1

"$DELEGATE_FAKE" fake-exit42 >/dev/null 2>&1
rc_c3=$?
if [[ "$rc_c3" -eq 42 ]]; then
    record_pass "Case 3: passthrough exit code — got 42"
else
    record_fail "Case 3: passthrough exit code" "expected 42, got $rc_c3"
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "ps1-delegate.test: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
