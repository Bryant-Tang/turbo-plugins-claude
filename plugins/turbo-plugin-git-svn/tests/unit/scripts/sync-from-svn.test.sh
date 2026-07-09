#!/usr/bin/env bash
# sync-from-svn.test.sh (shUnit2)
#
# Bash entry coverage for sync-from-svn.sh:
#   Arg-parse (always-run, git only):
#     1. file exists
#     2. missing --branch -> exit non-zero + stderr mentions branch required
#     3. unknown argument -> exit non-zero
#     4. --granularity / --range with no value -> exit non-zero + "requires a value"
#     5. --granularity <value> is ACCEPTED (parsed, not "Unknown argument")
#   Behavioral (svn-gated, SKIP when svn/svnadmin absent):
#     6. AE1 -- 3 new trunk revs, per-revision auto -> 3 replay commits (trailer+subject each)
#     7. >5 new revs, no --granularity -> TP_TOKEN:GRANULARITY_REQUIRED, ZERO commits, exit 0
#     8. --granularity squash -> ONE `sync: svn r<HEAD>` commit carrying the svn-revision trailer
#
# The richer matrix (empty-delta skip, interrupted-rerun resume, range mode, CJK round-trip,
# guards) lives in Sync-FromSvn.test.ps1 (windows runner). ubuntu runs this portable subset.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/scripts/sync-from-svn.sh"
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    if svn_available; then HAS_SVN=1; fi
    TMPDIR_CASE="$(mktemp -d -t turbo-pfs-XXXXXX)"
    git -C "$TMPDIR_CASE" init -b main >/dev/null 2>&1 || git -C "$TMPDIR_CASE" init >/dev/null 2>&1
    git -C "$TMPDIR_CASE" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$TMPDIR_CASE" config user.name  'turbo' >/dev/null 2>&1
    echo init > "$TMPDIR_CASE/init.txt"
    git -C "$TMPDIR_CASE" add -A >/dev/null 2>&1
    git -C "$TMPDIR_CASE" commit -m initial --allow-empty >/dev/null 2>&1
}

oneTimeTearDown() {
    [ -n "${TMPDIR_CASE:-}" ] && rm -rf "$TMPDIR_CASE" 2>/dev/null || true
}

setUp() { SB="$(mktemp -d -t turbo-pfs-sb-XXXXXX)"; }
tearDown() { [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true; }

# Build a real pushed bridge (svn import -> initialize -> build+submit push), matching the PS
# New-PushedBridge. Echoes "root|uri|repo|cfg"; returns non-zero when any step fails.
build_pushed_bridge() {
    local sandbox="$1"
    local repo="$sandbox/svnrepo" root="$sandbox/test-turbo-plugin" cfg="$sandbox/.svncfg"
    local seed="$sandbox/seed" uri win wt
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    win="$(cygpath -m "$repo" 2>/dev/null || printf '%s' "$repo")"
    uri="file:///$win"
    mkdir -p "$seed"
    printf 'app\n' > "$seed/app.txt"
    printf '*.log\n' > "$seed/.gitignore"
    svn import "$seed" "$uri" -m seed --config-dir "$cfg" >/dev/null 2>&1 || return 1
    mkdir -p "$root"
    git -C "$root" init -q -b main >/dev/null 2>&1 || return 1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    git -C "$root" config core.autocrlf false >/dev/null 2>&1
    ( cd "$root" && bash "$SCRIPTS_DIR/initialize-git-svn-bridge.sh" --svn-url "$uri" >/dev/null 2>&1 ) || return 1
    printf '%s\n' '*.log' '/.turbo-plugin/worktrees/' '.svn/' > "$root/.gitignore"
    git -C "$root" add .gitignore >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -q -m 'chore: skeleton gitignore' >/dev/null 2>&1
    ( cd "$root" && bash "$SCRIPTS_DIR/build-svn-commit.sh" --branch main >/dev/null 2>&1 ) || return 1
    ( cd "$root" && bash "$SCRIPTS_DIR/submit-svn-commit.sh" --branch main --title 'sync main to svn' >/dev/null 2>&1 ) || return 1
    wt="$root/.turbo-plugin/worktrees/remote-svn-main"
    ( cd "$wt" && svn update >/dev/null 2>&1 ) || return 1
    printf '%s|%s|%s|%s' "$root" "$uri" "$repo" "$cfg"
}

# Commit <count> new real trunk revisions to <uri> via a scratch WC. Each revision adds one file
# and uses "<prefix> <n>" as the commit message. Returns non-zero on failure.
add_svn_revisions() {
    local uri="$1" cfg="$2" sandbox="$3" count="$4" prefix="${5:-rev change}"
    local co="$sandbox/co-$RANDOM" n
    svn checkout "$uri" "$co" --config-dir "$cfg" >/dev/null 2>&1 || return 1
    for ((n = 1; n <= count; n++)); do
        printf 'content %s\n' "$n" > "$co/file$n.txt"
        svn add "$co/file$n.txt" --config-dir "$cfg" >/dev/null 2>&1 || return 1
        ( cd "$co" && svn commit -m "$prefix $n" --config-dir "$cfg" >/dev/null 2>&1 ) || return 1
    done
    return 0
}

# Count commits on remote-svn/main carrying a numeric svn-revision trailer.
count_trailer_commits() {
    local root="$1"
    git -C "$root" log remote-svn/main --format='%(trailers:key=svn-revision,valueonly)' 2>/dev/null \
        | grep -cE '^[0-9]+$' || true
}

# ── Case 1: file exists ────────────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT" ]
    assertTrue 'sync-from-svn.sh exists' $?
}

# ── Case 2: missing --branch ───────────────────────────────────────────────────
test_missing_branch_exits_nonzero_and_mentions_branch() {
    local out rc
    out=$(cd "$TMPDIR_CASE" && bash "$SCRIPT" 2>&1); rc=$?
    assertNotEquals 'missing --branch exits non-zero' 0 "$rc"
    case "$out" in
        *--branch*|*required*) assertTrue 'missing --branch stderr mentions branch' 0 ;;
        *) fail "missing --branch stderr unexpected: $out" ;;
    esac
}

# ── Case 3: unknown argument ───────────────────────────────────────────────────
test_unknown_arg_exits_nonzero() {
    local rc
    (cd "$TMPDIR_CASE" && bash "$SCRIPT" --bogus >/dev/null 2>&1); rc=$?
    assertNotEquals 'unknown arg exits non-zero' 0 "$rc"
}

# ── Case 4: --granularity / --range with no value → "requires a value" ──────────
test_granularity_missing_value_fails() {
    local out rc
    out=$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --branch main --granularity 2>&1); rc=$?
    assertNotEquals '--granularity with no value exits non-zero' 0 "$rc"
    case "$out" in
        *"requires a value"*) assertTrue '--granularity reports requires a value' 0 ;;
        *) fail "expected 'requires a value', got: $out" ;;
    esac
}

test_range_missing_value_fails() {
    local out rc
    out=$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --branch main --range 2>&1); rc=$?
    assertNotEquals '--range with no value exits non-zero' 0 "$rc"
    case "$out" in
        *"requires a value"*) assertTrue '--range reports requires a value' 0 ;;
        *) fail "expected 'requires a value', got: $out" ;;
    esac
}

# ── Case 5: --granularity <value> is ACCEPTED (parsed, not "Unknown argument") ──
test_granularity_value_accepted() {
    local out rc
    # No bridge here, so it fails later ("not found") — the point is the arg PARSES, never
    # tripping the "Unknown argument" arm.
    out=$(cd "$TMPDIR_CASE" && bash "$SCRIPT" --branch main --granularity per-revision 2>&1); rc=$?
    assertNotEquals 'still non-zero (no bridge)' 0 "$rc"
    case "$out" in
        *"Unknown argument"*) fail "--granularity value was not parsed: $out" ;;
        *) assertTrue '--granularity value accepted (no Unknown argument)' 0 ;;
    esac
}

# ── Case 6: AE1 — 3 new revs, per-revision auto → 3 replay commits ──────────────
test_ae1_per_revision_three_commits() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local spec root uri repo cfg before after rc out before_tr after_tr
    spec="$(build_pushed_bridge "$SB")" || { startSkipping; return 0; }
    root="${spec%%|*}"; uri="$(printf '%s' "$spec" | cut -d'|' -f2)"; cfg="${spec##*|}"
    add_svn_revisions "$uri" "$cfg" "$SB" 3 'change number' || { startSkipping; return 0; }
    before="$(git -C "$root" rev-list --count remote-svn/main)"
    before_tr="$(count_trailer_commits "$root")"
    out="$(cd "$root" && bash "$SCRIPT" --branch main 2>&1)"; rc=$?
    assertEquals "per-revision pull exit 0 ($out)" 0 "$rc"
    after="$(git -C "$root" rev-list --count remote-svn/main)"
    assertEquals '3 new commits on remote-svn/main' 3 "$((after - before))"
    # No granularity signal on a <=5 pull.
    case "$out" in
        *TP_TOKEN:GRANULARITY_REQUIRED*) fail "unexpected granularity signal on a 3-rev pull" ;;
        *) assertTrue 'no granularity signal' 0 ;;
    esac
    # Three distinct subjects present (not one squashed 'sync:' commit).
    local subj
    subj="$(git -C "$root" log main --format='%s' | grep -cE 'change number [123]$' || true)"
    assertEquals 'three per-revision subjects on main' 3 "$subj"
    # Three svn-revision trailers NEWLY present (delta -- the bootstrap import commit already carries
    # its own trailer now, so count the increase rather than the absolute total).
    after_tr="$(count_trailer_commits "$root")"
    assertEquals 'three new trailer-bearing replay commits' 3 "$((after_tr - before_tr))"
}

# ── Case 7: >5 new revs, no --granularity → structured signal, zero commits ─────
test_over5_needs_choice_no_commits() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local spec root uri cfg before after rc out
    spec="$(build_pushed_bridge "$SB")" || { startSkipping; return 0; }
    root="${spec%%|*}"; uri="$(printf '%s' "$spec" | cut -d'|' -f2)"; cfg="${spec##*|}"
    add_svn_revisions "$uri" "$cfg" "$SB" 6 'rev' || { startSkipping; return 0; }
    before="$(git -C "$root" rev-list --count remote-svn/main)"
    out="$(cd "$root" && bash "$SCRIPT" --branch main 2>&1)"; rc=$?
    assertEquals 'needs-choice exits 0 (not a failure)' 0 "$rc"
    case "$out" in
        *"TP_TOKEN:GRANULARITY_REQUIRED count=6"*) assertTrue 'emits granularity signal with count=6' 0 ;;
        *) fail "expected TP_TOKEN:GRANULARITY_REQUIRED count=6, got: $out" ;;
    esac
    after="$(git -C "$root" rev-list --count remote-svn/main)"
    assertEquals 'NO commits created on a needs-choice pull' 0 "$((after - before))"
}

# ── Case 8: --granularity squash → single boundary commit with HEAD trailer ─────
test_squash_single_boundary_commit() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local spec root uri cfg before after head_rev subj trailer
    spec="$(build_pushed_bridge "$SB")" || { startSkipping; return 0; }
    root="${spec%%|*}"; uri="$(printf '%s' "$spec" | cut -d'|' -f2)"; cfg="${spec##*|}"
    add_svn_revisions "$uri" "$cfg" "$SB" 6 'rev' || { startSkipping; return 0; }
    head_rev="$(svn info --show-item revision "$uri" --config-dir "$cfg" | tr -d '[:space:]')"
    before="$(git -C "$root" rev-list --count remote-svn/main)"
    ( cd "$root" && bash "$SCRIPT" --branch main --granularity squash >/dev/null 2>&1 )
    assertEquals 'squash pull exit 0' 0 $?
    after="$(git -C "$root" rev-list --count remote-svn/main)"
    assertEquals 'squash creates exactly ONE new commit' 1 "$((after - before))"
    subj="$(git -C "$root" log remote-svn/main -1 --format='%s')"
    assertEquals 'squash subject is sync: svn r<HEAD>' "sync: svn r$head_rev" "$subj"
    trailer="$(git -C "$root" log remote-svn/main -1 --format='%(trailers:key=svn-revision,valueonly)' | tr -d '[:space:]')"
    assertEquals 'squash commit carries the HEAD svn-revision trailer' "$head_rev" "$trailer"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
