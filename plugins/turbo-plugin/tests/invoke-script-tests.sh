#!/usr/bin/env bash
# invoke-script-tests.sh
#
# Bash script-tests orchestrator (v0.5.0 U17 — shUnit2 rewrite). Owns the *.test.sh
# suite. On a two-orchestrator CI runner (e.g. ubuntu) the .ps1 suite is run separately
# by the PowerShell orchestrator (pwsh + Pester); this one does NOT run .ps1, so the .sh
# files never double-run.
#
# Pipeline:
#   1. Lint pre-flight (tools/lint-ps-compat.ps1 over scripts/). Skipped by SKIP_PREFLIGHT=1,
#      or when no PowerShell interpreter is present (lint is a PS 5.1/Windows concern, covered
#      by the Windows job). Failure => exit 1.
#   2. Framework gate (ALWAYS, even with SKIP_PREFLIGHT=1): the vendored shUnit2 must exist at
#      tests/lib/shunit2. Missing => exit 1 (R20 "framework missing is FAIL, not SKIP").
#   3. Discover *.test.sh under tests/unit and tests/fixtures.
#   4. Run each via bash (shUnit2), resetting the shared fixture before each (best-effort).
#   5. Summary + exit. 0 = all PASS (shUnit2 counts skipped asserts as non-fatal); 1 = any FAIL.
#
# Exit codes (0/1 contract, U17): 0 = success (incl. legal SKIP); 1 = any failure (lint,
# test FAIL, or framework-missing gate). No exit 2.
#
# Env vars (defaults shown):
#   SKIP_PREFLIGHT=0   set 1 to skip the lint pre-flight (framework gate still runs)
#   SKIP_RESET=0       set 1 to skip the per-file Reset-Fixture call
#   POWERSHELL=        override PS interpreter path (only used by the lint pre-flight)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"
LIB_DIR="$TESTS_DIR/lib"
UNIT_DIR="$TESTS_DIR/unit"
FIXTURES_DIR="$TESTS_DIR/fixtures"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/plugins/turbo-plugin/scripts"
LINT_PS1="$REPO_ROOT/tools/lint-ps-compat.ps1"
RESET_SH="$FIXTURES_DIR/reset/reset-fixture.sh"
SHUNIT2="$LIB_DIR/shunit2"

SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-0}"
SKIP_RESET="${SKIP_RESET:-0}"
POWERSHELL="${POWERSHELL:-}"
if [[ -z "$POWERSHELL" ]]; then
    if command -v powershell.exe >/dev/null 2>&1; then POWERSHELL="powershell.exe"
    elif command -v powershell >/dev/null 2>&1; then POWERSHELL="powershell"
    elif command -v pwsh >/dev/null 2>&1; then POWERSHELL="pwsh"
    else POWERSHELL=""; fi
fi

echo "invoke-script-tests: REPO_ROOT = $REPO_ROOT"
echo "invoke-script-tests: TESTS_DIR = $TESTS_DIR"
echo ""

# ─── Step 1: Lint pre-flight (skippable; PS-only concern) ────────────────────
if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
    echo "─── Pre-flight lint ─────────────────────────────────────────────────"
    if [[ -z "$POWERSHELL" ]]; then
        echo "Pre-flight: no PowerShell interpreter; skipping lint (PS 5.1/Windows concern, covered by the Windows job)."
    else
        "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$LINT_PS1" -Path "$SCRIPTS_DIR"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "Pre-flight FAILED: lint-ps-compat.ps1 returned exit $rc"
            exit 1
        fi
        echo "Pre-flight: PASS"
    fi
    echo ""
else
    echo "Pre-flight lint: SKIPPED (SKIP_PREFLIGHT=1)"
    echo ""
fi

# ─── Step 2: Framework gate (ALWAYS — vendored shUnit2 must be present) ───────
echo "─── Framework gate (vendored shUnit2) ───────────────────────────────"
if [[ ! -f "$SHUNIT2" ]]; then
    echo "Framework gate FAILED: vendored shUnit2 not found at $SHUNIT2"
    echo "  shUnit2 is vendored into the repo; restore tests/lib/shunit2 (see CHANGELOG / KTD-3)."
    exit 1
fi
echo "shUnit2 present: $SHUNIT2"
echo ""

# ─── Step 3: Discover *.test.sh ──────────────────────────────────────────────
sh_tests=()
while IFS= read -r f; do
    [[ -n "$f" ]] && sh_tests+=("$f")
done < <(find "$UNIT_DIR" "$FIXTURES_DIR" -type f -name '*.test.sh' 2>/dev/null | sort)
echo "Discovered ${#sh_tests[@]} *.test.sh"
echo ""

if [[ ${#sh_tests[@]} -eq 0 ]]; then
    echo "No *.test.sh discovered. Lint + framework gate passed. Exiting 0."
    exit 0
fi

# ─── Step 4: Run each *.test.sh (shUnit2) ────────────────────────────────────
run_reset() {
    if [[ "$SKIP_RESET" -eq 1 ]]; then return 0; fi
    # Best-effort: a failure here (e.g. svn absent) is non-fatal — shUnit2 tests self-SKIP
    # the tool-dependent cases and tests that build their own sandbox are unaffected.
    if [[ -f "$RESET_SH" ]]; then bash "$RESET_SH" >/dev/null 2>&1 || true; fi
}

sh_passed=0; sh_failed=0
failed_files=()
for c in "${sh_tests[@]}"; do
    echo "─── SH: $(basename "$c") ──────────────────────────────────"
    run_reset
    bash "$c"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        sh_passed=$((sh_passed+1))
    else
        sh_failed=$((sh_failed+1))
        failed_files+=("$(basename "$c")")
    fi
    echo ""
done

# ─── Step 5: Summary + exit (0/1) ────────────────────────────────────────────
echo "─── Summary ─────────────────────────────────────────────────────────"
echo "  shUnit2 (.sh): $sh_passed file(s) passed / $sh_failed failed  (of ${#sh_tests[@]})"
if [[ $sh_failed -gt 0 ]]; then
    echo ""
    echo "Failed files:"
    for f in "${failed_files[@]}"; do echo "  - $f"; done
    exit 1
fi
echo ""
echo "All .sh test files passed (shUnit2 SKIP counts as green)."
exit 0
