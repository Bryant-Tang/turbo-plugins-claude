#!/usr/bin/env bash
# new-remote-test.test.sh
#
# Bash entry coverage for new-remote-test.sh:
#   1. file exists
#   2. missing --svn-url → exit non-zero + stderr mentions svn-url required
#   3. unknown arg → exit non-zero
#   4. (U2/R1) remote-svn-main absent → fail-closed BEFORE any side effect (no branch/worktree)
#   5. (U2/R1, 002:U17.4b) out-of-trust URL (file:///C:/Windows/...) → reject, no side effect
#   6. (R10) prefix-confusion <repos-root>-evil/... → reject
#   7. (R8/002:U17.5) pre-existing remote-svn/test-N collision → rollback fires (saw "rolling back")
#
# Cases 5-7 need a real remote-svn-main svn working copy built from the seed dump; they SKIP
# (counted as pass) if svn/svnadmin or the dump is unavailable.
# The canonical, exhaustive assertions live in New-RemoteTest.test.ps1; this file mirrors
# the key reject / fail-closed / rollback behaviors for parity.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/new-remote-test.sh"
DUMP_PATH="$PLUGIN_ROOT/tests/fixtures/seed/svn-repo-r1-r20.dump"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

# Build a throwaway git main worktree + worktrees dir. Echoes the project root path.
# Usage: make_main_repo <sandbox_dir>
make_main_repo() {
  local sandbox="$1"
  local root="$sandbox/test-turbo-plugin"
  mkdir -p "$root"
  git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
  git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
  git -C "$root" config user.name  'turbo' >/dev/null 2>&1
  echo init > "$root/init.txt"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -m initial --allow-empty >/dev/null 2>&1
  # v1.0 (U1): container inside the main worktree at <root>/.turbo-plugin/worktrees.
  mkdir -p "$root/.turbo-plugin/worktrees"
  printf '%s' "$root"
}

# Build a real remote-svn-main svn WC from the seed dump under
# <root>/.turbo-plugin/worktrees/remote-svn-main.
# Echoes repos-root-url on success; returns non-zero (empty) on failure.
make_remote_main_wc() {
  local sandbox="$1" root="$2"
  local svnrepo="$sandbox/svnrepo"
  local worktrees="$root/.turbo-plugin/worktrees"
  svnadmin create "$svnrepo" >/dev/null 2>&1 || return 1
  svnadmin load "$svnrepo" < "$DUMP_PATH" >/dev/null 2>&1 || return 1
  # Build a file:// URI from the (possibly Git-Bash) path. Convert /c/... → file:///C:/...
  local uri winpath
  winpath="$(cygpath -m "$svnrepo" 2>/dev/null || printf '%s' "$svnrepo")"
  uri="file:///$winpath"
  svn checkout "$uri/trunk" "$worktrees/remote-svn-main" >/dev/null 2>&1 || return 1
  local reposroot
  reposroot="$(svn info --show-item repos-root-url "$worktrees/remote-svn-main" 2>/dev/null | tr -d '\r\n')"
  [[ -n "$reposroot" ]] || return 1
  printf '%s' "$reposroot"
}

# Case 1: file exists
if [[ -f "$SCRIPT" ]]; then
    record_pass "new-remote-test.sh exists"
else
    record_fail "new-remote-test.sh exists" "not found"
fi

# Case 2: in a git repo, missing --svn-url → non-zero exit
TMPDIR_CASE="$(mktemp -d -t turbo-crt-XXXXXX)"
trap 'rm -rf "$TMPDIR_CASE" 2>/dev/null || true' EXIT
pushd "$TMPDIR_CASE" >/dev/null
git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
git config user.email 'test@turbo' >/dev/null 2>&1
git config user.name  'turbo' >/dev/null 2>&1
echo init > init.txt
git add -A >/dev/null 2>&1
git commit -m initial --allow-empty >/dev/null 2>&1
out=$(bash "$SCRIPT" 2>&1)
rc=$?
popd >/dev/null

if [[ $rc -ne 0 ]]; then
    record_pass "missing --svn-url exits non-zero (rc=$rc)"
else
    record_fail "missing --svn-url" "expected non-zero exit, got 0"
fi
if [[ "$out" == *"svn-url"* || "$out" == *"required"* ]]; then
    record_pass "missing --svn-url stderr mentions svn-url"
else
    record_fail "missing --svn-url stderr" "unexpected: $out"
fi

# Case 3: unknown argument
pushd "$TMPDIR_CASE" >/dev/null
out2=$(bash "$SCRIPT" --bogus-flag 2>&1)
rc2=$?
popd >/dev/null
if [[ $rc2 -ne 0 ]]; then
    record_pass "unknown arg exits non-zero (rc=$rc2)"
else
    record_fail "unknown arg" "expected non-zero exit"
fi
if [[ "$out2" == *"Unknown argument"* || "$out2" == *"bogus"* ]]; then
    record_pass "unknown arg stderr mentions Unknown"
else
    record_fail "unknown arg stderr" "unexpected: $out2"
fi

# Case 4: (U2/R1) remote-svn-main absent → fail-closed before any side effect.
SB4="$(mktemp -d -t turbo-crt4-XXXXXX)"
ROOT4="$(make_main_repo "$SB4")"   # worktrees dir exists but NO remote-svn-main
out4=$(cd "$ROOT4" && bash "$SCRIPT" --n 99 --svn-url 'file:///nonexistent-svn-repo/branches/test-99' 2>&1)
rc4=$?
if [[ $rc4 -ne 0 ]]; then
    record_pass "remote-svn-main absent exits non-zero (fail-closed, rc=$rc4)"
else
    record_fail "remote-svn-main absent fail-closed" "expected non-zero exit"
fi
# Must not have entered rollback nor created branches.
if [[ "$out4" != *"rolling back"* ]]; then
    record_pass "fail-closed did NOT enter rollback"
else
    record_fail "fail-closed rollback" "unexpectedly saw 'rolling back': $out4"
fi
if git -C "$ROOT4" branch --list 'test-99' | grep -q .; then
    record_fail "fail-closed orphan test-99" "test-99 branch should not exist"
else
    record_pass "fail-closed left no orphan test-99 branch"
fi
rm -rf "$SB4" 2>/dev/null || true

# Cases 5-7: trust-validation behaviors needing a real remote-svn-main svn WC.
if ! svn_available; then
    echo "  [SKIP] svn/svnadmin not on PATH — trust-validation cases 5-7 skipped (counted pass)."
    passed=$((passed + 3))
elif [[ ! -f "$DUMP_PATH" ]]; then
    echo "  [SKIP] seed dump missing at $DUMP_PATH — cases 5-7 skipped (counted pass)."
    passed=$((passed + 3))
else
    # Case 5: out-of-trust file:///C:/Windows/... → reject, no side effect (002:U17.4b)
    SB5="$(mktemp -d -t turbo-crt5-XXXXXX)"
    ROOT5="$(make_main_repo "$SB5")"
    if REPOSROOT5="$(make_remote_main_wc "$SB5" "$ROOT5")"; then
        out5=$(cd "$ROOT5" && bash "$SCRIPT" --n 5 --svn-url 'file:///C:/Windows/System32/' 2>&1)
        rc5=$?
        if [[ $rc5 -ne 0 && "$out5" != *"Creating test environment"* ]]; then
            record_pass "out-of-trust file:// rejected before side effects (002:U17.4b)"
        else
            record_fail "out-of-trust file:// reject" "rc=$rc5 out=$out5"
        fi
    else
        echo "  [SKIP] case 5: could not build remote-svn-main WC (counted pass)."
        passed=$((passed + 1))
    fi
    rm -rf "$SB5" 2>/dev/null || true

    # Case 6: prefix-confusion <repos-root>-evil/... → reject (R10)
    SB6="$(mktemp -d -t turbo-crt6-XXXXXX)"
    ROOT6="$(make_main_repo "$SB6")"
    if REPOSROOT6="$(make_remote_main_wc "$SB6" "$ROOT6")"; then
        out6=$(cd "$ROOT6" && bash "$SCRIPT" --n 6 --svn-url "${REPOSROOT6}-evil/branches/test-1" 2>&1)
        rc6=$?
        if [[ $rc6 -ne 0 && "$out6" != *"Creating test environment"* ]]; then
            record_pass "prefix-confusion <root>-evil rejected (R10)"
        else
            record_fail "prefix-confusion reject" "rc=$rc6 out=$out6"
        fi
    else
        echo "  [SKIP] case 6: could not build remote-svn-main WC (counted pass)."
        passed=$((passed + 1))
    fi
    rm -rf "$SB6" 2>/dev/null || true

    # Case 7: pre-existing remote-svn/test-7 collision → rollback fires (R8/002:U17.5)
    SB7="$(mktemp -d -t turbo-crt7-XXXXXX)"
    ROOT7="$(make_main_repo "$SB7")"
    if REPOSROOT7="$(make_remote_main_wc "$SB7" "$ROOT7")"; then
        # Collide remote-svn/test-7 (the FIRST inner git mutation), not test-7 (caught by
        # the pre-check outside the rollback trap).
        git -C "$ROOT7" branch 'remote-svn/test-7' 'main' >/dev/null 2>&1
        out7=$(cd "$ROOT7" && bash "$SCRIPT" --n 7 --svn-url "${REPOSROOT7}/branches/test-7" 2>&1)
        rc7=$?
        # Passed trust gate (entered "Creating") AND rollback fired — not a rejection.
        if [[ "$out7" == *"Creating test environment"* && "$out7" == *"rolling back"* ]]; then
            record_pass "git-mutation collision triggered rollback (R8)"
        else
            record_fail "rollback regression" "rc=$rc7 out=$out7"
        fi
    else
        echo "  [SKIP] case 7: could not build remote-svn-main WC (counted pass)."
        passed=$((passed + 1))
    fi
    rm -rf "$SB7" 2>/dev/null || true
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "new-remote-test.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
