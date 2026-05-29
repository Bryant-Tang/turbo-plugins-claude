#!/usr/bin/env bash
# invoke-script-tests.sh
#
# Bash sibling of Invoke-ScriptTests.ps1 (turbo-plugin v1.0 script tests orchestrator).
# Functional parity with the .ps1 entry — same five steps:
#   1. Pre-flight lint    (tools/lint-ps-compat.sh on plugins/turbo-plugin/scripts/)
#   2. Infra gate         (AssertHelpers FIRST, full halt on FAIL; then fixture meta-tests)
#   3. Discovery          (recursive find -name '*.test.ps1' -o -name '*.test.sh'; brace
#                          expansion *.test.{ps1,sh} is NOT used with find primaries — must
#                          use -o between two -name primaries per R12)
#   4. Path-based routing (tests/lib/* + tests/fixtures/* -> infra; tests/unit/** -> prod)
#   5. Run prod tests + decide exit code
#
# Exit codes (KD-14):
#   0 = all PASS or all non-PASS are acknowledged (FAIL-known / SKIP / BLOCKED-BY)
#   1 = at least one raw FAIL, or infra gate AssertHelpers FAIL
#   2 = lint pre-flight FAIL
#
# Usage (from repo root):
#   bash plugins/turbo-plugin/tests/invoke-script-tests.sh
#
# Optional env vars (defaults shown):
#   SKIP_PREFLIGHT=0       set 1 to skip lint pre-flight
#   SKIP_INFRA_GATE=0      set 1 to skip infra gate
#   SKIP_RESET=0           set 1 to skip per-case Reset-Fixture
#   POWERSHELL=powershell  override PS interpreter path
#
# NOTE: .ps1 tests are run by delegating to powershell.exe (or PS 7 `pwsh`); on Linux
# this requires PowerShell 7+. The harness only fails on the .ps1 cases if PowerShell
# is unavailable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"
LIB_DIR="$TESTS_DIR/lib"
UNIT_DIR="$TESTS_DIR/unit"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Walk up 3 levels: tests -> turbo-plugin -> plugins -> repo
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/plugins/turbo-plugin/scripts"
LINT_PS1="$REPO_ROOT/tools/lint-ps-compat.ps1"
LINT_SH="$REPO_ROOT/tools/lint-ps-compat.sh"

RESET_PS1="$FIXTURES_DIR/reset/Reset-Fixture.ps1"
RESET_SH="$FIXTURES_DIR/reset/reset-fixture.sh"
ASSERT_META="$LIB_DIR/AssertHelpers.test.ps1"

SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-0}"
SKIP_INFRA_GATE="${SKIP_INFRA_GATE:-0}"
SKIP_RESET="${SKIP_RESET:-0}"
POWERSHELL="${POWERSHELL:-}"

# Resolve PowerShell interpreter (prefer PS 5.1 on Windows, fallback pwsh).
if [[ -z "$POWERSHELL" ]]; then
    if command -v powershell.exe >/dev/null 2>&1; then
        POWERSHELL="powershell.exe"
    elif command -v powershell >/dev/null 2>&1; then
        POWERSHELL="powershell"
    elif command -v pwsh >/dev/null 2>&1; then
        POWERSHELL="pwsh"
    else
        POWERSHELL=""
    fi
fi

echo "invoke-script-tests: REPO_ROOT  = $REPO_ROOT"
echo "invoke-script-tests: TESTS_DIR  = $TESTS_DIR"
echo "invoke-script-tests: POWERSHELL = ${POWERSHELL:-<none>}"
echo ""

# ─── Step 1: Pre-flight lint ─────────────────────────────────────────────────

if [[ "$SKIP_PREFLIGHT" -eq 0 ]]; then
    echo "─── Pre-flight lint ─────────────────────────────────────────────────"
    echo "Target: $SCRIPTS_DIR"

    if [[ -z "$POWERSHELL" ]]; then
        echo "Pre-flight: WARN — no PowerShell interpreter found; cannot run lint-ps-compat.ps1." >&2
        echo "Pre-flight: skipping (treat as PASS for non-Windows smoke run)." >&2
    else
        echo "[1a] lint-ps-compat.ps1 ..."
        "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$LINT_PS1" -Path "$SCRIPTS_DIR"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo ""
            echo "Pre-flight FAILED: lint-ps-compat.ps1 returned exit $rc"
            exit 2
        fi
        echo "[1a] OK"

        if [[ -f "$LINT_SH" ]]; then
            echo "[1b] lint-ps-compat.sh ..."
            bash "$LINT_SH" -Path "$SCRIPTS_DIR" >/dev/null
            rc=$?
            if [[ $rc -ne 0 ]]; then
                echo ""
                echo "Pre-flight FAILED: lint-ps-compat.sh returned exit $rc"
                exit 2
            fi
            echo "[1b] OK"
        else
            echo "[1b] WARN: lint-ps-compat.sh not found at $LINT_SH — skipping"
        fi
    fi
    echo ""
    echo "Pre-flight: PASS"
    echo ""
else
    echo "Pre-flight: SKIPPED (SKIP_PREFLIGHT=1)"
    echo ""
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

run_ps_test() {
    local file="$1"
    if [[ -z "$POWERSHELL" ]]; then
        echo "    (no PowerShell — SKIP)"
        return 255
    fi
    "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$file"
    return $?
}

run_sh_test() {
    local file="$1"
    bash "$file"
    return $?
}

# ─── Step 2: Infra gate ──────────────────────────────────────────────────────

FIXTURE_GATE_OK=1
SKIPPED_FIXTURE_REASON=""

if [[ "$SKIP_INFRA_GATE" -eq 0 ]]; then
    echo "─── Infra gate ──────────────────────────────────────────────────────"

    # 3a. AssertHelpers FIRST — full halt on FAIL
    if [[ ! -f "$ASSERT_META" ]]; then
        echo "Infra gate ABORT: AssertHelpers meta-test not found: $ASSERT_META"
        exit 1
    fi
    echo ""
    echo "[3a] AssertHelpers.test.ps1 ..."
    run_ps_test "$ASSERT_META"
    rc=$?
    if [[ $rc -ne 0 && $rc -ne 255 ]]; then
        echo ""
        echo "infra gate failed: AssertHelpers (exit $rc)"
        echo "Full halt — assertion library cannot be trusted; downstream results would be meaningless."
        exit 1
    fi
    if [[ $rc -eq 255 ]]; then
        echo "[3a] SKIPPED (no PowerShell available)"
    else
        echo "[3a] AssertHelpers OK"
    fi

    # 3b. Fixture meta-tests — FAIL only causes fixture-dependent skip
    echo ""
    echo "[3b] fixture meta-tests ..."
    # R12: find with -o between two -name primaries (brace expansion does NOT work here).
    fixture_metas=()
    while IFS= read -r f; do
        fixture_metas+=("$f")
    done < <(find "$FIXTURES_DIR" -type f \( -name '*.test.ps1' -o -name '*.test.sh' \) 2>/dev/null)

    echo "    fixture meta-tests found: ${#fixture_metas[@]}"
    for meta in "${fixture_metas[@]}"; do
        echo ""
        bn=$(basename "$meta")
        echo "    [fixture] $bn"
        case "$meta" in
            *.test.ps1)
                run_ps_test "$meta"
                mrc=$?
                ;;
            *.test.sh)
                run_sh_test "$meta"
                mrc=$?
                ;;
            *)
                mrc=99
                ;;
        esac
        if [[ $mrc -eq 255 ]]; then
            echo "    [fixture] SKIPPED $bn (no PowerShell)"
            continue
        fi
        if [[ $mrc -ne 0 ]]; then
            FIXTURE_GATE_OK=0
            SKIPPED_FIXTURE_REASON="fixture meta-test $bn FAILED (exit $mrc)"
            echo "    [fixture] FAIL: $bn — fixture-dependent prod tests will SKIP"
        else
            echo "    [fixture] PASS: $bn"
        fi
    done

    echo ""
    if [[ $FIXTURE_GATE_OK -eq 1 ]]; then
        echo "Infra gate: PASS"
    else
        echo "Infra gate: PARTIAL — $SKIPPED_FIXTURE_REASON"
    fi
    echo ""
else
    echo "Infra gate: SKIPPED (SKIP_INFRA_GATE=1)"
    echo ""
fi

# ─── Step 3: Discovery (recursive *.test.ps1 + *.test.sh) ────────────────────

echo "─── Discovery ───────────────────────────────────────────────────────"
all_ps_tests=()
all_sh_tests=()
while IFS= read -r f; do
    [[ -n "$f" ]] && all_ps_tests+=("$f")
done < <(find "$TESTS_DIR" -type f -name '*.test.ps1' 2>/dev/null)
while IFS= read -r f; do
    [[ -n "$f" ]] && all_sh_tests+=("$f")
done < <(find "$TESTS_DIR" -type f -name '*.test.sh' 2>/dev/null)

# ─── Step 4: Path-based routing ──────────────────────────────────────────────

prod_ps=()
prod_sh=()
infra_ps=()
infra_sh=()
unrecognized=()

is_infra_path() {
    local p="$1"
    case "$p" in
        "$LIB_DIR"/*|"$FIXTURES_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

is_prod_path() {
    local p="$1"
    case "$p" in
        "$UNIT_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

for t in "${all_ps_tests[@]+"${all_ps_tests[@]}"}"; do
    if is_infra_path "$t"; then
        infra_ps+=("$t")
    elif is_prod_path "$t"; then
        prod_ps+=("$t")
    else
        unrecognized+=("$t")
    fi
done
for t in "${all_sh_tests[@]+"${all_sh_tests[@]}"}"; do
    if is_infra_path "$t"; then
        infra_sh+=("$t")
    elif is_prod_path "$t"; then
        prod_sh+=("$t")
    else
        unrecognized+=("$t")
    fi
done

echo "  Total .test.ps1 discovered: ${#all_ps_tests[@]}  (infra=${#infra_ps[@]}, prod=${#prod_ps[@]})"
echo "  Total .test.sh  discovered: ${#all_sh_tests[@]}  (infra=${#infra_sh[@]}, prod=${#prod_sh[@]})"

if [[ ${#unrecognized[@]} -gt 0 ]]; then
    echo ""
    echo "ERROR: unrecognized test location(s) (must be under tests/lib/, tests/fixtures/, or tests/unit/):"
    for u in "${unrecognized[@]}"; do echo "  - $u"; done
    exit 1
fi
echo ""

if [[ ${#prod_ps[@]} -eq 0 && ${#prod_sh[@]} -eq 0 ]]; then
    echo "─── Summary ─────────────────────────────────────────────────────────"
    echo "No prod test cases discovered (tests/unit/ empty or no *.test.{ps1,sh})."
    echo "Lint pre-flight passed and infra gate completed. Exiting 0."
    exit 0
fi

# ─── Step 5: Run prod tests ──────────────────────────────────────────────────

ps_passed=0; ps_failed=0; ps_skipped=0
sh_passed=0; sh_failed=0; sh_skipped=0

run_reset() {
    if [[ "$SKIP_RESET" -eq 1 ]]; then return 0; fi
    if [[ -f "$RESET_SH" ]]; then
        bash "$RESET_SH" >/dev/null
        return $?
    fi
    # Fallback to PS Reset-Fixture if .sh missing
    if [[ -n "$POWERSHELL" && -f "$RESET_PS1" ]]; then
        "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$RESET_PS1" >/dev/null
        return $?
    fi
    return 99
}

for c in "${prod_ps[@]+"${prod_ps[@]}"}"; do
    echo ""
    echo "─── PS prod case: $(basename "$c") ─────────────────────────────────"
    if [[ $FIXTURE_GATE_OK -eq 0 ]]; then
        echo "  SKIP — $SKIPPED_FIXTURE_REASON"
        ps_skipped=$((ps_skipped+1))
        continue
    fi
    run_reset
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "  Reset-Fixture FAILED with exit $rc"
        ps_failed=$((ps_failed+1))
        continue
    fi
    run_ps_test "$c"
    rc=$?
    if [[ $rc -eq 255 ]]; then
        echo "  SKIP — no PowerShell"
        ps_skipped=$((ps_skipped+1))
    elif [[ $rc -eq 0 ]]; then
        ps_passed=$((ps_passed+1))
    else
        ps_failed=$((ps_failed+1))
    fi
done

for c in "${prod_sh[@]+"${prod_sh[@]}"}"; do
    echo ""
    echo "─── SH prod case: $(basename "$c") ─────────────────────────────────"
    if [[ $FIXTURE_GATE_OK -eq 0 ]]; then
        echo "  SKIP — $SKIPPED_FIXTURE_REASON"
        sh_skipped=$((sh_skipped+1))
        continue
    fi
    run_reset
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "  Reset-Fixture FAILED with exit $rc"
        sh_failed=$((sh_failed+1))
        continue
    fi
    run_sh_test "$c"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        sh_passed=$((sh_passed+1))
    else
        sh_failed=$((sh_failed+1))
    fi
done

# ─── Step 6: Summary ─────────────────────────────────────────────────────────

echo ""
echo "─── Summary ─────────────────────────────────────────────────────────"
echo "  PS:    $ps_passed PASS / $ps_failed FAIL / $ps_skipped SKIP  (of ${#prod_ps[@]})"
echo "  Bash:  $sh_passed PASS / $sh_failed FAIL / $sh_skipped SKIP  (of ${#prod_sh[@]})"
echo ""

if [[ $ps_failed -gt 0 || $sh_failed -gt 0 ]]; then
    exit 1
fi
exit 0
