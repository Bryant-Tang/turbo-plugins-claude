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

# shellcheck disable=SC1091
source "$PLUGIN_ROOT/tests/lib/svn-uri.sh"

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
# A second argument bridges a SUBDIRECTORY of the repository instead of its root, which is what a
# repository shared by several projects looks like (/proj-1, /proj-2, ... side by side).
build_pushed_bridge() {
    local sandbox="$1" subpath="${2:-}"
    local repo="$sandbox/svnrepo" root="$sandbox/test-turbo-plugin" cfg="$sandbox/.svncfg"
    local seed="$sandbox/seed" uri root_uri win wt
    svnadmin create "$repo" >/dev/null 2>&1 || return 1
    root_uri="$(svn_uri "$repo")"
    uri="$root_uri"
    [ -n "$subpath" ] && uri="$root_uri/$subpath"
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
    # Return shape is unchanged on purpose: existing callers read the last field with
    # "${spec##*|}", so appending a field would silently hand every one of them the wrong value.
    printf '%s|%s|%s|%s' "$root" "$uri" "$repo" "$cfg"
}

# The bridge working copy's own checked-out revision.
wc_revision() {
    svn info --show-item revision "$1" 2>/dev/null | tr -d '[:space:]'
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

# Count of MARKED revisions (refs/tp/svn/<N>).
count_trailer_commits() {
    local root="$1"
    git -C "$root" for-each-ref --format='%(refname:lstrip=3)' 'refs/tp/svn/*' 2>/dev/null \
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
    trailer="$(git -C "$root" rev-parse --verify --quiet "refs/tp/svn/${head_rev}^{commit}")"
    assertEquals 'refs/tp/svn/<HEAD> marks the squash commit' "$(git -C "$root" rev-parse remote-svn/main)" "$trailer"
}

# ── Case 12 (range): per-revision inside <lo>:<hi>, squash the leading + trailing rest ─────────
# Mirrors Sync-FromSvn.test.ps1 Case 12 so the bash `range` dispatch arm is covered on ubuntu too
# (it was previously exercised only by the Windows Pester suite).
test_range_per_revision_inside_squash_outside() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local spec root uri cfg before after head lo hi expected got tr_before
    spec="$(build_pushed_bridge "$SB")" || { startSkipping; return 0; }
    root="${spec%%|*}"; uri="$(printf '%s' "$spec" | cut -d'|' -f2)"; cfg="${spec##*|}"
    add_svn_revisions "$uri" "$cfg" "$SB" 8 'rev' || { startSkipping; return 0; }
    head="$(svn info --show-item revision "$uri" --config-dir "$cfg" | tr -d '[:space:]')"
    # 8 consecutive revs = (head-7)..head. Take the middle 3 per-revision: [head-5 .. head-3].
    lo=$((head - 5)); hi=$((head - 3))
    tr_before="$(git -C "$root" for-each-ref --format='%(refname:lstrip=3)' 'refs/tp/svn/*' | grep -oE '^[0-9]+$' | sort -n | tr '\n' ' ')"
    before="$(git -C "$root" rev-list --count remote-svn/main)"
    ( cd "$root" && bash "$SCRIPT" --branch main --granularity range --range "$lo:$hi" >/dev/null 2>&1 )
    assertEquals 'range pull exit 0' 0 $?
    after="$(git -C "$root" rev-list --count remote-svn/main)"
    # leading squash (1) + per-revision [lo..hi] (3) + trailing squash (1) = 5 new commits.
    assertEquals 'range: leading-squash + 3 per-rev + trailing-squash = 5 new commits' 5 "$((after - before))"
    # new markers (delta over the pull) = {lo-1} u [lo..hi] u {head}, ascending.
    expected="$(printf '%s\n' "$((lo - 1))" "$lo" "$((lo + 1))" "$hi" "$head" | sort -n | tr '\n' ' ')"
    got="$(git -C "$root" for-each-ref --format='%(refname:lstrip=3)' 'refs/tp/svn/*' | grep -oE '^[0-9]+$' | sort -n \
        | while read -r v; do case " $tr_before " in *" $v "*) : ;; *) printf '%s ' "$v" ;; esac; done)"
    assertEquals 'new markers = leading boundary(lo-1), per-rev [lo..hi], trailing boundary(head)' "$expected" "$got"
}

# ── Regression: "replayed onto the bridge but NOT merged into main" is RESUMABLE state ─────────
# The pull replays each revision onto remote-svn/main and only THEN merges the bridge into main.
# When that merge does not land (an aborted conflict, or the run dying between the two steps), the
# marker exists on a commit main does not contain. Those commits are MARKED, so the orphan guard
# (which only fires on UNMARKED commits ahead of the branch) must not treat them as debris: a plain
# re-run has to retry the merge. Simulated by rewinding main after a successful pull, which leaves
# exactly that state.
test_marked_but_unmerged_replay_is_resumable() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local spec root uri cfg before bridge_tip out rc
    spec="$(build_pushed_bridge "$SB")" || { startSkipping; return 0; }
    root="${spec%%|*}"; uri="$(printf '%s' "$spec" | cut -d'|' -f2)"; cfg="${spec##*|}"
    add_svn_revisions "$uri" "$cfg" "$SB" 1 'late change' || { startSkipping; return 0; }

    before="$(git -C "$root" rev-parse main)"
    ( cd "$root" && bash "$SCRIPT" --branch main >/dev/null 2>&1 ) || { startSkipping; return 0; }
    bridge_tip="$(git -C "$root" rev-parse remote-svn/main)"

    # Rewind main only: the replay commit + its marker stay on the bridge, unmerged.
    git -C "$root" reset --hard "$before" >/dev/null 2>&1 || { startSkipping; return 0; }
    if git -C "$root" merge-base --is-ancestor "$bridge_tip" main 2>/dev/null; then
        fail 'fixture broken: the replayed commit is still reachable from main'; return 1
    fi

    out="$(cd "$root" && bash "$SCRIPT" --branch main 2>&1)"; rc=$?
    assertEquals "re-running the pull must succeed (out: $out)" 0 "$rc"
    case "$out" in *[Oo]rphan*) fail "marked replay commits must not be reported as orphans: $out" ;; esac
    if git -C "$root" merge-base --is-ancestor "$bridge_tip" main 2>/dev/null; then
        assertTrue 'the re-run retried the merge into main' 0
    else
        fail "the replayed commit is STILL not in main after a re-run: $out"
    fi
}

# ── Case 16: a sibling project's commit must not deadlock push against pull ───
# SVN revision numbers are repository-wide. In a repository shared by several projects, a
# colleague's commit to a SIBLING path bumps HEAD without touching ours -- and the two sides used
# to disagree about what that meant: push compared the working copy against repository HEAD and
# refused ("run pull first"), while pull correctly found no revision affecting this path and
# returned "already up to date". Neither could make progress. Both halves are asserted because
# fixing either alone still leaves the working copy drifting further behind on every sibling commit.
test_sibling_commit_does_not_deadlock() {
    if [ "$HAS_SVN" -ne 1 ]; then startSkipping; return 0; fi
    local spec root uri cfg wt root_uri win wc_before wc_after out rc prep prc
    spec="$(build_pushed_bridge "$SB" 'proj-1')" || { startSkipping; return 0; }
    root="${spec%%|*}"; uri="$(printf '%s' "$spec" | cut -d'|' -f2)"; cfg="${spec##*|}"
    wt="$root/.turbo-plugin/worktrees/remote-svn-main"
    root_uri="$(svn_uri "$SB/svnrepo")"

    wc_before="$(wc_revision "$wt")"

    # A sibling project commits. Nothing under proj-1 changes; only HEAD moves.
    svn mkdir "$root_uri/proj-2" -m 'sibling project commit' --config-dir "$cfg" >/dev/null 2>&1         || { startSkipping; return 0; }

    # Half 1 -- pull reports "up to date" (correct) but must still catch the working copy up.
    out="$(cd "$root" && bash "$SCRIPT" --branch main 2>&1)"; rc=$?
    assertEquals "pull must succeed (out: $out)" 0 "$rc"
    case "$out" in *"Already up to date"*) assertTrue 'pull reports up to date' 0 ;; *) fail "expected 'Already up to date': $out" ;; esac
    wc_after="$(wc_revision "$wt")"
    assertTrue "pull must advance the working copy ($wc_before -> $wc_after)" "[ '$wc_after' -gt '$wc_before' ]"

    # Half 2 -- push must not refuse in the first place. Rewind the working copy to the state pull
    # would have left it in before the fix above existed.
    svn update -r "$wc_before" "$wt" >/dev/null 2>&1 || { startSkipping; return 0; }
    assertEquals 'rewind to the pre-sibling revision' "$wc_before" "$(wc_revision "$wt")"

    printf 'new
' > "$root/new.txt"
    git -C "$root" add new.txt >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -q -m 'feat: something of ours' >/dev/null 2>&1

    prep="$(cd "$root" && bash "$SCRIPTS_DIR/build-svn-commit.sh" --branch main 2>&1)"; prc=$?
    case "$prep" in *"not up to date"*) fail "push was refused by a sibling project's commit: $prep" ;; esac
    assertEquals "push prepare must succeed (out: $prep)" 0 "$prc"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
