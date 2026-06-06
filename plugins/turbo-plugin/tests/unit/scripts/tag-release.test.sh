#!/usr/bin/env bash
# tag-release.test.sh
#
# Bash coverage for tag-release.sh (git-only — no SVN needed for the tag):
#   1. file exists
#   2. missing --branch → exit non-zero + stderr mentions branch
#   3. happy: --branch test-1 → tag test-1-release-<date>-001 == remote-svn/test-1
#   4. serial increment: run twice same day → -001 then -002
#   5. ref naming: tag points at remote-svn/test-1, and remote/test-1 does NOT exist
#
# No hardcoded paths (AE6): work dirs come from mktemp.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/tag-release.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

TODAY="$(date +%Y-%m-%d)"

# Build a main repo + a remote-svn/test-N branch ref (tip = main + 1 extra commit).
# Echoes the project root path. The tag only needs the branch ref to exist.
make_repo_with_remote_svn_test() {
  local sandbox="$1" n="${2:-1}"
  local root="$sandbox/test-turbo-plugin"
  mkdir -p "$root"
  git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
  git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
  git -C "$root" config user.name  'turbo' >/dev/null 2>&1
  echo init > "$root/init.txt"
  mkdir -p "$root/.turbo-plugin/worktrees"
  printf '/.turbo-plugin/worktrees/\n' > "$root/.gitignore"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -m initial --allow-empty >/dev/null 2>&1
  git -C "$root" checkout -b "remote-svn/test-$n" >/dev/null 2>&1
  echo "remote-svn/test-$n tip" > "$root/remote-svn-test-$n.txt"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -m "feat: remote-svn/test-$n tip" >/dev/null 2>&1
  git -C "$root" checkout main >/dev/null 2>&1
  printf '%s' "$root"
}

# Case 1: file exists
if [[ -f "$SCRIPT" ]]; then
    record_pass "tag-release.sh exists"
else
    record_fail "tag-release.sh exists" "not found"
fi

# Case 2: missing --branch → non-zero + stderr
SB2="$(mktemp -d -t turbo-tagrel2-XXXXXX)"
trap 'rm -rf "$SB2" 2>/dev/null || true' EXIT
ROOT2="$(make_repo_with_remote_svn_test "$SB2" 1)"
out2=$(cd "$ROOT2" && bash "$SCRIPT" 2>&1)
rc2=$?
if [[ $rc2 -ne 0 ]]; then
    record_pass "missing --branch exits non-zero (rc=$rc2)"
else
    record_fail "missing --branch" "expected non-zero exit, got 0"
fi
if [[ "$out2" == *"branch"* || "$out2" == *"Branch"* ]]; then
    record_pass "missing --branch stderr mentions branch"
else
    record_fail "missing --branch stderr" "unexpected: $out2"
fi
rm -rf "$SB2" 2>/dev/null || true

# Case 3: happy — tag == remote-svn/test-1
SB3="$(mktemp -d -t turbo-tagrel3-XXXXXX)"
ROOT3="$(make_repo_with_remote_svn_test "$SB3" 1)"
out3=$(cd "$ROOT3" && bash "$SCRIPT" --branch test-1 2>&1)
rc3=$?
EXPECTED_TAG="test-1-release-${TODAY}-001"
if [[ $rc3 -eq 0 && "$out3" == *"Created tag: $EXPECTED_TAG"* ]]; then
    record_pass "happy: created $EXPECTED_TAG (rc=$rc3)"
else
    record_fail "happy create tag" "rc=$rc3 out=$out3"
fi
tag_sha="$(git -C "$ROOT3" rev-parse "$EXPECTED_TAG" 2>/dev/null)"
remote_sha="$(git -C "$ROOT3" rev-parse 'remote-svn/test-1' 2>/dev/null)"
if [[ -n "$tag_sha" && "$tag_sha" == "$remote_sha" ]]; then
    record_pass "tag SHA == remote-svn/test-1 SHA"
else
    record_fail "tag points at remote-svn/test-1" "tag=$tag_sha remote=$remote_sha"
fi
rm -rf "$SB3" 2>/dev/null || true

# Case 4: serial increment — two runs same day
SB4="$(mktemp -d -t turbo-tagrel4-XXXXXX)"
ROOT4="$(make_repo_with_remote_svn_test "$SB4" 1)"
o4a=$(cd "$ROOT4" && bash "$SCRIPT" --branch test-1 2>&1)
o4b=$(cd "$ROOT4" && bash "$SCRIPT" --branch test-1 2>&1)
if [[ "$o4a" == *"test-1-release-${TODAY}-001"* ]]; then
    record_pass "first run -001"
else
    record_fail "first run -001" "out=$o4a"
fi
if [[ "$o4b" == *"test-1-release-${TODAY}-002"* ]]; then
    record_pass "second run -002"
else
    record_fail "second run -002" "out=$o4b"
fi
rm -rf "$SB4" 2>/dev/null || true

# Case 5: ref naming — remote/test-1 must NOT exist; tag resolves to remote-svn/test-1
SB5="$(mktemp -d -t turbo-tagrel5-XXXXXX)"
ROOT5="$(make_repo_with_remote_svn_test "$SB5" 1)"
out5=$(cd "$ROOT5" && bash "$SCRIPT" --branch test-1 2>&1)
TAG5="test-1-release-${TODAY}-001"
if git -C "$ROOT5" rev-parse --verify 'remote/test-1' >/dev/null 2>&1; then
    record_fail "old naming absent" "remote/test-1 unexpectedly exists"
else
    record_pass "remote/test-1 does NOT exist (old naming absent)"
fi
tag5_sha="$(git -C "$ROOT5" rev-parse "$TAG5" 2>/dev/null)"
remote5_sha="$(git -C "$ROOT5" rev-parse 'remote-svn/test-1' 2>/dev/null)"
if [[ -n "$tag5_sha" && "$tag5_sha" == "$remote5_sha" ]]; then
    record_pass "tag points at remote-svn/test-1 (new naming)"
else
    record_fail "tag points at remote-svn/test-1 (new naming)" "tag=$tag5_sha remote=$remote5_sha out=$out5"
fi
rm -rf "$SB5" 2>/dev/null || true

# ─── Summary ────────────────────────────────────────────────────────────────

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "tag-release.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
