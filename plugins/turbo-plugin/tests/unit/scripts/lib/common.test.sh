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
    # Match by basename — Windows 8.3 short name (mktemp via $TMPDIR /MELWU~1/) vs
    # git rev-parse --show-toplevel (long /Mel Wu/) make literal-equal comparison
    # unreliable. Verify mw is non-empty, starts with normalized drive, and contains
    # the unique tmpdir basename.
    tmpdir_basename="${TMPDIR_GMW##*/}"
    if [[ -n "$mw" && "$mw" =~ ^[a-z]:.* && "$mw" == *"$tmpdir_basename"* ]]; then
        echo "  [PASS] get_main_worktree returns normalized top-level inside git repo (got: $mw)"
        exit 0
    fi
    echo "  [FAIL] get_main_worktree: expected path containing '$tmpdir_basename' on lowercased drive, got '$mw'"
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

# ─── assert_trusted_svn_url (U1) ─────────────────────────────────────────────
#
# Boundary-safe + case-normalized + traversal-reject trust check anchored on the
# trusted working copy's repos-root-url (NOT trunk url). Uses the seed SVN dump
# loaded into a throwaway repo; trunk/ + branches/test-1/ let us prove a legit
# sibling branch passes (= repos-root). Fail-closed uses an empty non-WC dir.

assert_trusted_ok() {
    # $1=name $2=wc $3=candidate ; expect exit 0
    local name="$1" wc="$2" cand="$3"
    # `set +e` locally so a failing helper never aborts the test under common.sh's set -e.
    set +e
    assert_trusted_svn_url "$wc" "$cand" >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        record_pass "$name"
    else
        record_fail "$name" "expected trusted (exit 0), got non-zero for '$cand'"
    fi
}
assert_trusted_reject() {
    # $1=name $2=wc $3=candidate $4=stderr-substr(optional) ; expect non-zero
    local name="$1" wc="$2" cand="$3" want="${4:-}"
    local err rc
    set +e
    err="$(assert_trusted_svn_url "$wc" "$cand" 2>&1 >/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        record_fail "$name" "expected reject (non-zero), got exit 0 for '$cand'"
    elif [[ -n "$want" && "$err" != *"$want"* ]]; then
        record_fail "$name" "rejected but stderr missing '$want': $err"
    else
        record_pass "$name"
    fi
}

if ! command -v svn >/dev/null 2>&1 || ! command -v svnadmin >/dev/null 2>&1; then
    echo "  [SKIP] svn/svnadmin not on PATH — assert_trusted_svn_url cases skipped."
else
    DUMP_U1="$(cd -- "$PLUGIN_ROOT" && pwd)/tests/fixtures/seed/svn-repo-r1-r20.dump"
    if [[ ! -f "$DUMP_U1" ]]; then
        echo "  [SKIP] seed dump missing at $DUMP_U1 — run build-seed-repo.sh."
    else
        TMPDIR_U1="$(mktemp -d -t turbo-common-trusturl-XXXXXX)"
        trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" "$TMPDIR_U1" 2>/dev/null || true' EXIT
        SVN_REPO="$TMPDIR_U1/repo"
        WC_U1="$TMPDIR_U1/wc"
        EMPTY_NONWC="$TMPDIR_U1/empty-non-wc"
        mkdir -p "$EMPTY_NONWC"

        load_ok=1
        svnadmin create "$SVN_REPO" >/dev/null 2>&1 || load_ok=0
        # The dump is committed as binary (LF preserved — no CRLF mangle), so a native
        # bash stdin redirect loads cleanly without the cmd.exe / cygpath dance.
        if [[ $load_ok -eq 1 ]]; then
            svnadmin load "$SVN_REPO" < "$DUMP_U1" >/dev/null 2>&1 || load_ok=0
        fi

        if [[ $load_ok -eq 0 ]]; then
            echo "  [SKIP] svnadmin create/load failed (likely dump LF→CRLF mangle); cannot build trust fixture."
        else
            # Build a file:// URI with Windows drive form when under Git Bash.
            repo_for_uri="$SVN_REPO"
            if [[ "$repo_for_uri" =~ ^/([a-zA-Z])/(.*)$ ]]; then
                repo_for_uri="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
            fi
            REPO_URI="file:///$repo_for_uri"

            svn checkout "$REPO_URI/trunk" "$WC_U1" >/dev/null 2>&1 || true
            REPOS_ROOT="$(svn info --show-item repos-root-url "$WC_U1" 2>/dev/null | tr -d '\r\n' || true)"

            if [[ -z "$REPOS_ROOT" ]]; then
                echo "  [SKIP] svn checkout of trusted WC failed; cannot build trust fixture."
            else
                echo "  (trusted repos-root-url = $REPOS_ROOT)"

                # Confirm the helper queries repos-root-url (not url): a legit sibling
                # branch under branches/ must be accepted — only repos-root makes that true.
                assert_trusted_ok     "same-repo trunk URL is trusted"                       "$WC_U1" "$REPOS_ROOT/trunk"
                assert_trusted_ok     "legit sibling branches/test-1 is trusted (repos-root)" "$WC_U1" "$REPOS_ROOT/branches/test-1"
                assert_trusted_reject "prefix-confusion <root>-evil/trunk is rejected (R10)"  "$WC_U1" "${REPOS_ROOT}-evil/trunk"

                # Uppercase scheme → normalized, still trusted (R11)
                UPPER_ROOT="${REPOS_ROOT/#file:\/\//FILE://}"
                assert_trusted_ok     "uppercase scheme FILE:// normalizes and is trusted (R11)" "$WC_U1" "$UPPER_ROOT/trunk"

                # Trailing-slash candidate variant → same as no slash
                assert_trusted_ok     "trailing-slash candidate matches no-slash result"     "$WC_U1" "$REPOS_ROOT/branches/test-1/"

                # Out-of-bounds + different scheme/host → reject
                assert_trusted_reject "out-of-bounds file:///C:/Windows/... is rejected"      "$WC_U1" "file:///C:/Windows/System32/"
                assert_trusted_reject "different scheme/host http://attacker/... is rejected" "$WC_U1" "http://attacker.example/repo"

                # Path traversal → reject
                assert_trusted_reject "candidate with '..' traversal is rejected"             "$WC_U1" "$REPOS_ROOT/trunk/../../etc"
                assert_trusted_reject "percent-encoded ..(%2e%2e) traversal rejected after decode" "$WC_U1" "$REPOS_ROOT/trunk/%2e%2e/%2e%2e/etc"

                # Fail-closed: empty non-WC reference → reject, with explanatory stderr
                assert_trusted_reject "fail-closed: non-WC trusted reference rejects"         "$EMPTY_NONWC" "$REPOS_ROOT/trunk" "fail closed"
            fi
        fi
    fi
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
