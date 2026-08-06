#!/usr/bin/env bash
# invoke-script-tests.sh  (tools/)
#
# Script-tests orchestrator for the repo-level tools/ scripts. Same shape and same 0/1 exit
# contract as the per-plugin orchestrators (plugins/<name>/tests/invoke-script-tests.sh), so
# there is one convention to learn rather than two:
#
#   1. Framework gate (ALWAYS): the vendored shUnit2 must exist at tests/lib/shunit2.
#      Missing => exit 1. A missing framework is a FAILURE, never a SKIP (R20) -- the whole
#      point of these tests is that they are hard to notice when they silently stop running.
#   2. Discover *.test.sh under tests/unit.
#   3. Run each via bash (shUnit2).
#   4. Summary + exit. 0 = every file passed (shUnit2 counts skipped asserts as non-fatal);
#      1 = any file failed.
#
# Differences from the plugin orchestrators, and why:
#   - No lint pre-flight. lint-ps-compat.ps1 targets a plugin's scripts/ dir; tools/ has no
#     such dir, and pointing the linter at its own source is a different job from testing.
#   - No fixture reset. These tests are pure-function tests that build nothing on disk.
#   - No .ps1 / Pester half. Nothing under tools/ currently has a Pester suite. When one is
#     added, give it a sibling Invoke-ScriptTests.ps1 here and a matching CI job -- do not
#     bolt a PowerShell path onto this file before there is a test for it to run.
#
# Env vars (defaults shown):
#   SKIP_PREFLIGHT=0   accepted and ignored, so this orchestrator is drop-in interchangeable
#                      with the per-plugin ones in scripts that pass it

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"
LIB_DIR="$TESTS_DIR/lib"
UNIT_DIR="$TESTS_DIR/unit"
TOOLS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
SHUNIT2="$LIB_DIR/shunit2"

echo "invoke-script-tests (tools): REPO_ROOT = $REPO_ROOT"
echo "invoke-script-tests (tools): TESTS_DIR = $TESTS_DIR"
echo ""

# ─── Step 1: Framework gate (ALWAYS — vendored shUnit2 must be present) ───────
echo "─── Framework gate (vendored shUnit2) ───────────────────────────────"
if [[ ! -f "$SHUNIT2" ]]; then
    echo "Framework gate FAILED: vendored shUnit2 not found at $SHUNIT2"
    echo "  shUnit2 is vendored into the repo; restore tools/tests/lib/shunit2"
    echo "  (copy it from any plugins/*/tests/lib/shunit2 — all copies are identical)."
    exit 1
fi
echo "shUnit2 present: $SHUNIT2"
echo ""

# ─── Step 2: Discover *.test.sh ──────────────────────────────────────────────
sh_tests=()
while IFS= read -r f; do
    [[ -n "$f" ]] && sh_tests+=("$f")
done < <(find "$UNIT_DIR" -type f -name '*.test.sh' 2>/dev/null | sort)
echo "Discovered ${#sh_tests[@]} *.test.sh"
echo ""

# Not "nothing to do, exit 0". tools/ is only in CI at all because it HAS tests now; an empty
# discovery means they were moved, renamed out of the *.test.sh convention, or deleted -- and
# the job would otherwise go green while testing nothing, which is the exact failure this
# whole suite exists to prevent.
if [[ ${#sh_tests[@]} -eq 0 ]]; then
    echo "Discovery FAILED: no *.test.sh found under $UNIT_DIR"
    exit 1
fi

# ─── Step 3: Run each *.test.sh (shUnit2) ────────────────────────────────────
sh_passed=0; sh_failed=0
failed_files=()
for c in "${sh_tests[@]}"; do
    echo "─── SH: $(basename "$c") ──────────────────────────────────"
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

# ─── Step 4: Summary + exit (0/1) ────────────────────────────────────────────
echo "─── Summary ─────────────────────────────────────────────────────────"
echo "  shUnit2 (.sh): $sh_passed file(s) passed / $sh_failed failed  (of ${#sh_tests[@]})"
if [[ $sh_failed -gt 0 ]]; then
    echo ""
    echo "Failed files:"
    for f in "${failed_files[@]}"; do echo "  - $f"; done
    exit 1
fi
echo ""
echo "All .sh test files passed."
exit 0
