#!/usr/bin/env bash
# merge-main-into-all.test.sh
#
# Bash coverage for merge-main-into-all.sh (git-only — no SVN). NEW semantics:
#   1. file exists
#   2. happy: main advanced + 2 target branches (test-x, feature-y) behind main →
#      after run both contain main tip; main & remote-svn/main NOT targets.
#   3. exclude: main & remote-svn/* never appear as "OK <branch>" lines.
#   4. conflict: conflicting branch reported CONFLICT (aborted clean); non-conflicting
#      branch still merges; original branch restored; worktree clean.
#
# No hardcoded paths (AE6): work dirs come from mktemp.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/merge-main-into-all.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

git_init_main() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -b main >/dev/null 2>&1 || git -C "$root" init >/dev/null 2>&1
  git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
  git -C "$root" config user.name  'turbo' >/dev/null 2>&1
  echo init > "$root/init.txt"
  mkdir -p "$root/.turbo-plugin/worktrees"
  printf '/.turbo-plugin/worktrees/\n' > "$root/.gitignore"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -m initial --allow-empty >/dev/null 2>&1
}

commit_file() {
  local root="$1" name="$2" content="$3" msg="$4"
  printf '%s' "$content" > "$root/$name"
  git -C "$root" add -A >/dev/null 2>&1
  git -C "$root" commit -m "$msg" >/dev/null 2>&1
}

# main advanced + test-x/feature-y behind + remote-svn/main bridge. Echoes root.
make_merge_fixture() {
  local sandbox="$1"
  local root="$sandbox/test-turbo-plugin"
  git_init_main "$root"
  git -C "$root" branch test-x >/dev/null 2>&1
  git -C "$root" branch feature-y >/dev/null 2>&1
  git -C "$root" branch remote-svn/main >/dev/null 2>&1
  commit_file "$root" main-only.txt 'main tip' 'feat: main advances'
  printf '%s' "$root"
}

# Case 1: file exists
if [[ -f "$SCRIPT" ]]; then
  record_pass "merge-main-into-all.sh exists"
else
  record_fail "merge-main-into-all.sh exists" "not found"
fi

# Case 2: happy — both targets contain main tip; main & remote-svn/main untouched
SB2="$(mktemp -d -t turbo-merge2-XXXXXX)"
trap 'rm -rf "$SB2" 2>/dev/null || true' EXIT
ROOT2="$(make_merge_fixture "$SB2")"
main_sha="$(git -C "$ROOT2" rev-parse main)"
remote_before="$(git -C "$ROOT2" rev-parse remote-svn/main)"
out2=$(cd "$ROOT2" && bash "$SCRIPT" 2>&1)
rc2=$?
if [[ $rc2 -eq 0 ]]; then
  record_pass "happy exit 0 (rc=$rc2)"
else
  record_fail "happy exit 0" "rc=$rc2 out=$out2"
fi
if git -C "$ROOT2" merge-base --is-ancestor "$main_sha" test-x; then
  record_pass "test-x contains main tip"
else
  record_fail "test-x contains main tip" "main not ancestor of test-x"
fi
if git -C "$ROOT2" merge-base --is-ancestor "$main_sha" feature-y; then
  record_pass "feature-y contains main tip"
else
  record_fail "feature-y contains main tip" "main not ancestor of feature-y"
fi
main_after="$(git -C "$ROOT2" rev-parse main)"
if [[ "$main_after" == "$main_sha" ]]; then
  record_pass "main tip unchanged"
else
  record_fail "main tip unchanged" "before=$main_sha after=$main_after"
fi
remote_after="$(git -C "$ROOT2" rev-parse remote-svn/main)"
if [[ "$remote_after" == "$remote_before" ]]; then
  record_pass "remote-svn/main untouched"
else
  record_fail "remote-svn/main untouched" "before=$remote_before after=$remote_after"
fi
rm -rf "$SB2" 2>/dev/null || true

# Case 3: exclude — no "OK main" / "OK remote-svn/*" lines
SB3="$(mktemp -d -t turbo-merge3-XXXXXX)"
ROOT3="$(make_merge_fixture "$SB3")"
git -C "$ROOT3" branch remote-svn/test-1 >/dev/null 2>&1
out3=$(cd "$ROOT3" && bash "$SCRIPT" 2>&1)
if echo "$out3" | grep -qE '^OK main$'; then
  record_fail "no OK main line" "found OK main"
else
  record_pass "no OK main line"
fi
if echo "$out3" | grep -qE '^OK remote-svn/'; then
  record_fail "no OK remote-svn/* line" "found OK remote-svn/*"
else
  record_pass "no OK remote-svn/* line"
fi
if echo "$out3" | grep -qE '^OK test-x$'; then
  record_pass "test-x merged"
else
  record_fail "test-x merged" "out=$out3"
fi
if echo "$out3" | grep -qE '^OK feature-y$'; then
  record_pass "feature-y merged"
else
  record_fail "feature-y merged" "out=$out3"
fi
rm -rf "$SB3" 2>/dev/null || true

# Case 4: conflict — conflicting branch CONFLICT+aborted; clean branch merges; restored
SB4="$(mktemp -d -t turbo-merge4-XXXXXX)"
ROOT4="$SB4/test-turbo-plugin"
git_init_main "$ROOT4"
commit_file "$ROOT4" shared.txt 'base' 'feat: add shared'
git -C "$ROOT4" branch clean-branch >/dev/null 2>&1
git -C "$ROOT4" branch conflict-branch >/dev/null 2>&1
git -C "$ROOT4" checkout conflict-branch >/dev/null 2>&1
commit_file "$ROOT4" shared.txt 'branch-version' 'feat: branch edits shared'
git -C "$ROOT4" checkout main >/dev/null 2>&1
commit_file "$ROOT4" shared.txt 'main-version' 'feat: main edits shared'
main4_sha="$(git -C "$ROOT4" rev-parse main)"
git -C "$ROOT4" checkout clean-branch >/dev/null 2>&1
start_branch="$(git -C "$ROOT4" rev-parse --abbrev-ref HEAD)"

out4=$(cd "$ROOT4" && bash "$SCRIPT" 2>&1)
rc4=$?
if [[ $rc4 -eq 1 ]]; then
  record_pass "conflict run exit 1 (rc=$rc4)"
else
  record_fail "conflict run exit 1" "rc=$rc4 out=$out4"
fi
if echo "$out4" | grep -qE '^CONFLICT conflict-branch\b'; then
  record_pass "conflict-branch reported CONFLICT"
else
  record_fail "conflict-branch reported CONFLICT" "out=$out4"
fi
if git -C "$ROOT4" merge-base --is-ancestor "$main4_sha" conflict-branch; then
  record_fail "conflict-branch NOT merged" "main unexpectedly ancestor of conflict-branch"
else
  record_pass "conflict-branch NOT merged"
fi
if git -C "$ROOT4" merge-base --is-ancestor "$main4_sha" clean-branch; then
  record_pass "clean-branch merged"
else
  record_fail "clean-branch merged" "main not ancestor of clean-branch"
fi
status4="$(git -C "$ROOT4" status --porcelain)"
if [[ -z "$status4" ]]; then
  record_pass "worktree clean after run"
else
  record_fail "worktree clean after run" "dirty: $status4"
fi
end_branch="$(git -C "$ROOT4" rev-parse --abbrev-ref HEAD)"
if [[ "$end_branch" == "$start_branch" ]]; then
  record_pass "original branch restored ($end_branch)"
else
  record_fail "original branch restored" "start=$start_branch end=$end_branch"
fi
rm -rf "$SB4" 2>/dev/null || true

# ─── Summary ────────────────────────────────────────────────────────────────

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "merge-main-into-all.sh: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
  for m in "${fail_msgs[@]}"; do echo "  - $m"; done
  echo "FAIL: $failed assertion(s) failed"
  exit 1
fi
echo "OK"
exit 0
