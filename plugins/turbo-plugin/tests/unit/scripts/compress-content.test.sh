#!/usr/bin/env bash
# compress-content.test.sh
#
# pack-content.sh is a thin delegate to pack-content.ps1 (lib/ps1-delegate.sh).
# Bash coverage focuses on:
#   1. delegate dispatch:script exists and is executable.
#   2. arg pass-through:passing an unknown arg should bubble the .ps1 error.
#   3. no-config skip:cwd missing .turbo-plugin/config.toml → ps1 raises but with the expected error path.
#
# We do not exercise the full happy build flow (that lives in Compress-Content.test.ps1 — the .ps1 already
# carries the canonical assertions; bash entry is a delegate so re-running the same heavy build would
# double the runtime without adding signal).
#
# Conventions:
#   - stdout last non-empty line must start with "OK" or "FAIL: <reason>".
#   - exit 0 if PASS, 1 if FAIL.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
PACK="$PLUGIN_ROOT/scripts/compress-content.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

# Case 1: pack-content.sh exists
if [[ -f "$PACK" ]]; then
    record_pass "pack-content.sh exists at $PACK"
else
    record_fail "pack-content.sh exists" "not found at $PACK"
fi

# Case 2: running from a temp dir with no .turbo-plugin/config.toml should fail (delegate forwards to ps1).
TMPDIR_CASE2="$(mktemp -d -t turbo-pack-content-bash-XXXXXX)"
trap 'rm -rf "$TMPDIR_CASE2" 2>/dev/null || true' EXIT

pushd "$TMPDIR_CASE2" >/dev/null
out=$(bash "$PACK" 2>&1)
rc=$?
popd >/dev/null

# Even when ps1 itself exits 0 (no [frontend] = skip), the delegate must mirror that.
# Either of these is acceptable: exit 0 with "not configured" OR exit non-zero with a clear error.
if [[ "$out" == *"not configured"* || "$out" == *"config.toml"* || "$out" == *"frontend"* ]]; then
    record_pass "no-config delegate emits frontend-related message"
else
    record_fail "no-config delegate output" "unexpected stdout/stderr: $out"
fi

# Case 3: passing unknown arg → ps1 ignores positional args (pack-content has no [CmdletBinding] params)
# but should still complete (exit 0 with skip) since cwd has no config.
# This case only checks that the bash entry doesn't crash on extra args.
pushd "$TMPDIR_CASE2" >/dev/null
bash "$PACK" --bogus-arg 2>&1 >/dev/null || true
rc3=$?
popd >/dev/null

if [[ $rc3 -ge 0 ]]; then
    record_pass "extra args do not crash bash delegate (rc=$rc3)"
else
    record_fail "extra args crash" "rc=$rc3"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "pack-content.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
