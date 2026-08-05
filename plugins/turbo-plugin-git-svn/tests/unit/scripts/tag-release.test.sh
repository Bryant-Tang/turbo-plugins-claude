#!/usr/bin/env bash
# tag-release.test.sh (shUnit2)
#
# Bash coverage for tag-release.sh (git-only — no SVN needed for the tag):
#   1. file exists
#   2. missing --branch → exit non-zero + stderr mentions branch
#   3. happy: --branch test-1 → tag test-1-release-<date>-001 == remote-svn/test-1
#   4. serial increment: run twice same day → -001 then -002
#   5. ref naming: tag points at remote-svn/test-1, and remote/test-1 does NOT exist
#
# No hardcoded paths (AE6): work dirs come from mktemp.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/tag-release.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    TODAY="$(date +%Y-%m-%d)"
}

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

test_script_exists() {
    [ -f "$SCRIPT" ]
    assertTrue 'tag-release.sh exists' $?
}

test_missing_branch_exits_nonzero_and_mentions_branch() {
    local sb root out rc
    sb="$(mktemp -d -t turbo-tagrel2-XXXXXX)"
    root="$(make_repo_with_remote_svn_test "$sb" 1)"
    out=$(cd "$root" && bash "$SCRIPT" 2>&1); rc=$?
    assertNotEquals 'missing --branch exits non-zero' 0 "$rc"
    case "$out" in
        *branch*|*Branch*) assertTrue 'missing --branch stderr mentions branch' 0 ;;
        *) fail "missing --branch stderr unexpected: $out" ;;
    esac
    rm -rf "$sb" 2>/dev/null || true
}

test_happy_tag_equals_remote_svn() {
    local sb root out rc expected_tag tag_sha remote_sha
    sb="$(mktemp -d -t turbo-tagrel3-XXXXXX)"
    root="$(make_repo_with_remote_svn_test "$sb" 1)"
    out=$(cd "$root" && bash "$SCRIPT" --branch test-1 2>&1); rc=$?
    expected_tag="test-1-release-${TODAY}-001"
    assertEquals "happy: rc 0 (out=$out)" 0 "$rc"
    case "$out" in
        *"Created tag: $expected_tag"*) assertTrue "happy: created $expected_tag" 0 ;;
        *) fail "happy create tag: out=$out" ;;
    esac
    tag_sha="$(git -C "$root" rev-parse "$expected_tag" 2>/dev/null)"
    remote_sha="$(git -C "$root" rev-parse 'remote-svn/test-1' 2>/dev/null)"
    assertNotNull 'tag SHA resolves' "$tag_sha"
    assertEquals 'tag SHA == remote-svn/test-1 SHA' "$remote_sha" "$tag_sha"
    rm -rf "$sb" 2>/dev/null || true
}

test_serial_increment() {
    local sb root o4a o4b
    sb="$(mktemp -d -t turbo-tagrel4-XXXXXX)"
    root="$(make_repo_with_remote_svn_test "$sb" 1)"
    o4a=$(cd "$root" && bash "$SCRIPT" --branch test-1 2>&1)
    o4b=$(cd "$root" && bash "$SCRIPT" --branch test-1 2>&1)
    case "$o4a" in
        *"test-1-release-${TODAY}-001"*) assertTrue 'first run -001' 0 ;;
        *) fail "first run -001: out=$o4a" ;;
    esac
    case "$o4b" in
        *"test-1-release-${TODAY}-002"*) assertTrue 'second run -002' 0 ;;
        *) fail "second run -002: out=$o4b" ;;
    esac
    rm -rf "$sb" 2>/dev/null || true
}

test_ref_naming_new_scheme() {
    local sb root out tag tag_sha remote_sha
    sb="$(mktemp -d -t turbo-tagrel5-XXXXXX)"
    root="$(make_repo_with_remote_svn_test "$sb" 1)"
    out=$(cd "$root" && bash "$SCRIPT" --branch test-1 2>&1)
    tag="test-1-release-${TODAY}-001"
    if git -C "$root" rev-parse --verify 'remote/test-1' >/dev/null 2>&1; then
        fail 'old naming absent: remote/test-1 unexpectedly exists'
    else
        assertTrue 'remote/test-1 does NOT exist (old naming absent)' 0
    fi
    tag_sha="$(git -C "$root" rev-parse "$tag" 2>/dev/null)"
    remote_sha="$(git -C "$root" rev-parse 'remote-svn/test-1' 2>/dev/null)"
    assertNotNull "tag resolves (out=$out)" "$tag_sha"
    assertEquals 'tag points at remote-svn/test-1 (new naming)' "$remote_sha" "$tag_sha"
    rm -rf "$sb" 2>/dev/null || true
}

# shellcheck disable=SC1090
. "$SHUNIT2"
