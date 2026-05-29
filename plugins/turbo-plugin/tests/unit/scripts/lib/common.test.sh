#!/usr/bin/env bash
# common.test.sh
#
# Unit tests for plugins/turbo-plugin/scripts/lib/common.sh.
# Covers 4 functions:
#   1. probe_git_version          — happy (git on PATH ≥ 2.31)
#   2. get_normalized_absolute_path — /c/foo Git-Bash style → C:/foo or lowercased drive
#   3. get_main_worktree          — inside a fresh git init reports the worktree's top-level
#   4. test_is_submodule          — fresh git init is NOT a submodule (returns non-zero)
#
# Conventions:
#   - last non-empty line is "OK" (pass) or "FAIL: <reason>" (fail)
#   - exit 0 if all pass, 1 otherwise

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
COMMON_SH="$PLUGIN_ROOT/scripts/lib/common.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

if [[ ! -f "$COMMON_SH" ]]; then
    echo "FAIL: common.sh not found at $COMMON_SH"
    exit 1
fi

# Source under a subshell where set -e is relaxed; common.sh's `set -euo pipefail` is OK in test.
# shellcheck source=/dev/null
source "$COMMON_SH"

# Case 1: probe_git_version — happy
if probe_git_version 2>/dev/null; then
    record_pass "probe_git_version succeeds when git is present and >= 2.31"
else
    record_fail "probe_git_version" "returned non-zero; git likely missing or < 2.31"
fi

# Case 2: get_normalized_absolute_path — Git Bash /c/foo → c:/foo (lowercased)
norm="$(get_normalized_absolute_path '/c/Turbo' 2>/dev/null || true)"
case "$norm" in
    c:/Turbo|c:/turbo)
        record_pass "get_normalized_absolute_path converts /c/Turbo to lowercased-drive form (got: $norm)"
        ;;
    *)
        # realpath -m may resolve /c/Turbo differently on some Git Bash builds; accept
        # any path that starts with the lowercased drive c:.
        if [[ "$norm" =~ ^c:.* ]]; then
            record_pass "get_normalized_absolute_path lowercases drive letter (got: $norm)"
        else
            record_fail "get_normalized_absolute_path" "expected c:/... form, got '$norm'"
        fi
        ;;
esac

# Case 3: get_main_worktree — inside a fresh git init dir, returns its top-level
TMPDIR_GMW="$(mktemp -d -t turbo-common-gmw-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" 2>/dev/null || true' EXIT
(
    cd "$TMPDIR_GMW" || exit 99
    git init -q -b main >/dev/null 2>&1
    git config user.email 'test@turbo-plugin'
    git config user.name 'turbo-plugin-test'
    git commit -q --allow-empty -m 'init' >/dev/null 2>&1

    mw="$(get_main_worktree 2>/dev/null || true)"
    expected="$(get_normalized_absolute_path "$TMPDIR_GMW")"
    if [[ -n "$mw" && "$mw" == "$expected" ]]; then
        echo "  [PASS] get_main_worktree returns normalized top-level inside git repo (got: $mw)"
        exit 0
    fi
    echo "  [FAIL] get_main_worktree: expected '$expected', got '$mw'"
    exit 1
)
case3_rc=$?
if [[ "$case3_rc" -eq 0 ]]; then
    passed=$((passed + 1))
else
    failed=$((failed + 1))
    fail_msgs+=("get_main_worktree: see [FAIL] above")
fi

# Case 4: test_is_submodule — fresh git init is NOT a submodule (returns non-zero)
TMPDIR_TIS="$(mktemp -d -t turbo-common-tis-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" 2>/dev/null || true' EXIT
(
    cd "$TMPDIR_TIS" || exit 99
    git init -q -b main >/dev/null 2>&1
    if test_is_submodule; then
        echo "  [FAIL] test_is_submodule returned 0 (true) inside a non-submodule fresh git init"
        exit 1
    fi
    echo "  [PASS] test_is_submodule returns non-zero (not a submodule) in fresh git init"
    exit 0
)
case4_rc=$?
if [[ "$case4_rc" -eq 0 ]]; then
    passed=$((passed + 1))
else
    failed=$((failed + 1))
    fail_msgs+=("test_is_submodule: see [FAIL] above")
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "common.test: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
