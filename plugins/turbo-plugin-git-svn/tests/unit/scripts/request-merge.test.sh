#!/usr/bin/env bash
# request-merge.test.sh (shUnit2)
#
# Script under test: scripts/request-merge.sh (git-only — no SVN, so no SKIP path).
# Contract:
#   request-merge.sh --branch <name> [--base <name>] [--merge] [--repo-root <path>]
#   Emits exactly ONE 'TP_TOKEN:' line. Precedence:
#     ERROR > BRANCH_IS_BASE > BRANCH_NOT_FOUND > BASE_NOT_FOUND > SOURCE_DIRTY
#           > MAIN_DIRTY > MAIN_DETACHED > BASE_ELSEWHERE > NOTHING_TO_MERGE
#           > READY  (report)  |  MERGED / CONFLICT  (--merge)
#
# Every token above has a case here that actually produces it. A guard nothing can reach is
# a guard that will not be there when it is needed, and it looks identical to one that works.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/request-merge.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

setUp() {
    # `startSkipping` is a GLOBAL flag in shUnit2, not a per-test one. One case turning it on
    # (the git-shim case below can) would silently skip every case after it, and a suite that
    # skips everything still reports OK. Clear it at the start of each case.
    endSkipping
    # Short name on purpose: a peer worktree's admin file lands at
    # <main>/.git/worktrees/<peer>/… so every character of the sandbox path is spent twice,
    # and on Windows a long one silently fails to create the worktree at all.
    SB="$(mktemp -d -t tp-rqm-XXXXXX)"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null || true
}

# ── fixture helpers ───────────────────────────────────────────────────────────

commit_file() {
    local root="$1" name="$2" content="$3" msg="$4"
    printf '%s\n' "$content" > "$root/$name"
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -qm "$msg" >/dev/null 2>&1
}

# main + a `feat` branch two commits ahead. Main worktree left on `main`. Echoes the root.
make_fixture() {
    local root="$SB/proj"
    mkdir -p "$root"
    git -C "$root" init -b main -q >/dev/null 2>&1 || git -C "$root" init -q >/dev/null 2>&1
    git -C "$root" config user.email 'test@turbo' >/dev/null 2>&1
    git -C "$root" config user.name  'turbo' >/dev/null 2>&1
    commit_file "$root" init.txt 'init' 'initial'
    git -C "$root" checkout -qb feat >/dev/null 2>&1
    commit_file "$root" b.txt 'b' 'feat: add b'
    commit_file "$root" c.txt 'c' 'feat: add c'
    git -C "$root" checkout -q main >/dev/null 2>&1
    printf '%s' "$root"
}

run_sut() {
    local root="$1"; shift
    ( cd "$root" && bash "$SCRIPT_UNDER_TEST" "$@" 2>&1 )
}

token_of() { printf '%s\n' "$1" | grep '^TP_TOKEN:' || true; }
token_count() { printf '%s\n' "$1" | grep -c '^TP_TOKEN:' || true; }

# A peer worktree that silently failed to be created leaves an ordinary directory behind, and
# every assertion downstream then passes for the wrong reason. Verified, not assumed.
add_peer() {
    local root="$1" path="$2" branch="$3"
    git -C "$root" worktree add "$path" "$branch" >/dev/null 2>&1
    [ -e "$path/.git" ]
    assertTrue "fixture: '$path' is not a linked worktree -- git worktree add failed silently" $?
}

# ── Case 1: the file exists ───────────────────────────────────────────────────
test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'request-merge.sh exists' $?
}

# ── Case 2: report mode is READY, and changes nothing ─────────────────────────
test_report_ready_and_read_only() {
    local root out before after
    root="$(make_fixture)"
    before="$(git -C "$root" rev-parse main)"
    out="$(run_sut "$root" --branch feat)"
    assertEquals 'report exit 0' 0 $?
    assertEquals 'one token' 1 "$(token_count "$out")"
    # The main= path spelling is platform-dependent (git hands back `C:/…` on Windows), so the
    # assertion pins the stable fields and only requires the path to be non-empty.
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:READY branch=feat base=main ahead=2 main=.'
    assertTrue 'READY token carries branch/base/ahead and a non-empty main path' $?
    after="$(git -C "$root" rev-parse main)"
    assertEquals 'report mode did not move main' "$before" "$after"
}

# ── Case 3: the report lists the commits and the diffstat ─────────────────────
test_report_lists_commits_and_diffstat() {
    local root out
    root="$(make_fixture)"
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$out" | grep -q 'feat: add b'; assertTrue 'lists first commit subject'  $?
    printf '%s' "$out" | grep -q 'feat: add c'; assertTrue 'lists second commit subject' $?
    printf '%s' "$out" | grep -q 'ahead  : 2 commit'; assertTrue 'reports ahead count'   $?
    printf '%s' "$out" | grep -q 'behind : 0 commit'; assertTrue 'reports behind count'  $?
    printf '%s' "$out" | grep -q '2 files changed';   assertTrue 'includes the diffstat'  $?
}

# ── Case 4: BRANCH_NOT_FOUND ──────────────────────────────────────────────────
test_branch_not_found() {
    local root out
    root="$(make_fixture)"
    out="$(run_sut "$root" --branch nope)"
    assertEquals 'BRANCH_NOT_FOUND' 'TP_TOKEN:BRANCH_NOT_FOUND branch=nope' "$(token_of "$out")"
}

# ── Case 5: BASE_NOT_FOUND ────────────────────────────────────────────────────
test_base_not_found() {
    local root out
    root="$(make_fixture)"
    out="$(run_sut "$root" --branch feat --base nosuch)"
    assertEquals 'BASE_NOT_FOUND' 'TP_TOKEN:BASE_NOT_FOUND base=nosuch' "$(token_of "$out")"
}

# ── Case 6: BRANCH_IS_BASE ────────────────────────────────────────────────────
test_branch_is_base() {
    local root out
    root="$(make_fixture)"
    out="$(run_sut "$root" --branch main)"
    assertEquals 'BRANCH_IS_BASE' 'TP_TOKEN:BRANCH_IS_BASE branch=main' "$(token_of "$out")"
}

# ── Case 6b: remote-svn/* is refused at BOTH ends ─────────────────────────────
# As base it would merge work INTO the bridge; as branch it does tp-pull-from-svn's job
# without any of its bookkeeping. Refused by name, so it holds even when the bridge exists.
test_bridge_branch_refused_as_base() {
    local root out
    root="$(make_fixture)"
    git -C "$root" branch remote-svn/main >/dev/null 2>&1
    out="$(run_sut "$root" --branch feat --base remote-svn/main)"
    assertEquals 'BRIDGE_BRANCH as base' 'TP_TOKEN:BRIDGE_BRANCH name=remote-svn/main' "$(token_of "$out")"
}

test_bridge_branch_refused_as_source() {
    local root out
    root="$(make_fixture)"
    git -C "$root" branch remote-svn/main >/dev/null 2>&1
    out="$(run_sut "$root" --branch remote-svn/main)"
    assertEquals 'BRIDGE_BRANCH as source' 'TP_TOKEN:BRIDGE_BRANCH name=remote-svn/main' "$(token_of "$out")"
}

# The refusal must not swallow ordinary branches that merely contain the word.
test_similarly_named_branch_is_not_refused() {
    local root out
    root="$(make_fixture)"
    git -C "$root" branch remote-svn-ish feat >/dev/null 2>&1
    out="$(run_sut "$root" --branch remote-svn-ish)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:BRIDGE_BRANCH'
    assertFalse 'a branch merely NAMED like the bridge prefix is not refused' $?
}

# ── Case 7: a malformed ref name is a HARD, TOKENLESS error (anti-forge) ──────
test_malformed_branch_name_is_tokenless() {
    local root out rc
    root="$(make_fixture)"
    out="$(run_sut "$root" --branch 'bad..name')"; rc=$?
    assertEquals 'malformed name exits 1' 1 "$rc"
    assertEquals 'and earns no routing token' 0 "$(token_count "$out")"
    printf '%s' "$out" | grep -q 'not a valid branch name'
    assertTrue 'says why' $?
}

# ── Case 8: MAIN_DIRTY ────────────────────────────────────────────────────────
test_main_dirty() {
    local root out
    root="$(make_fixture)"
    printf 'dirt\n' > "$root/dirt.txt"
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:MAIN_DIRTY path=.'
    assertTrue 'MAIN_DIRTY with a path' $?
}

# ── Case 9: SOURCE_DIRTY — the guard this script exists for ───────────────────
# The branch is checked out in a peer worktree with uncommitted work. Merging now would ship
# less than what was built and tested, and the `remove` that follows would delete the rest.
test_source_worktree_dirty() {
    local root out
    root="$(make_fixture)"
    add_peer "$root" "$SB/wt" feat
    printf 'not committed\n' > "$SB/wt/pending.txt"
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:SOURCE_DIRTY path=.'
    assertTrue 'SOURCE_DIRTY with a path' $?
}

# ── Case 10: a CLEAN peer worktree does not trip SOURCE_DIRTY ─────────────────
# Without this, Case 9 would pass just as happily if the guard fired unconditionally.
test_clean_peer_worktree_is_ready() {
    local root out
    root="$(make_fixture)"
    add_peer "$root" "$SB/wt" feat
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:READY '
    assertTrue 'a clean peer worktree still reports READY' $?
}

# ── Case 11: MAIN_DETACHED ────────────────────────────────────────────────────
test_main_detached() {
    local root out
    root="$(make_fixture)"
    git -C "$root" checkout -q --detach >/dev/null 2>&1
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:MAIN_DETACHED path=.'
    assertTrue 'MAIN_DETACHED with a path' $?
}

# ── Case 12: BASE_ELSEWHERE ───────────────────────────────────────────────────
test_base_checked_out_elsewhere() {
    local root out
    root="$(make_fixture)"
    git -C "$root" checkout -qb parked >/dev/null 2>&1
    add_peer "$root" "$SB/wt" main
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:BASE_ELSEWHERE base=main path=.'
    assertTrue 'BASE_ELSEWHERE names the base and the worktree holding it' $?
}

# ── Case 13: NOTHING_TO_MERGE ─────────────────────────────────────────────────
test_nothing_to_merge_after_merging() {
    local root out
    root="$(make_fixture)"
    run_sut "$root" --branch feat --merge >/dev/null
    out="$(run_sut "$root" --branch feat)"
    assertEquals 'NOTHING_TO_MERGE' 'TP_TOKEN:NOTHING_TO_MERGE branch=feat base=main' "$(token_of "$out")"
}

# ── Case 14: --merge actually merges, and restores where it started ───────────
test_merge_happy() {
    local root out feat_sha
    root="$(make_fixture)"
    feat_sha="$(git -C "$root" rev-parse feat)"
    out="$(run_sut "$root" --branch feat --merge)"
    assertEquals 'merge exit 0' 0 $?
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:MERGED branch=feat base=main commit=.'
    assertTrue 'MERGED token carries the merge commit' $?
    git -C "$root" merge-base --is-ancestor "$feat_sha" main
    assertTrue 'main now contains the feat tip' $?
    # rev-list --parents prints "<sha> <p1> <p2>" for a merge => 3 fields. --no-ff is what
    # makes this a merge commit rather than a fast-forward, so this is the assertion that
    # would notice if --no-ff were ever dropped.
    assertEquals 'merge commit has two parents' 3 \
        "$(git -C "$root" rev-list --parents -n 1 main | wc -w | tr -d ' ')"
    assertEquals 'HEAD is back on main' 'main' "$(git -C "$root" symbolic-ref --short HEAD)"
}

# ── Case 15: the single-worktree everyday shape — standing ON the source branch ─
# It exercises checkout-base -> merge -> checkout-back where "back" is the source branch
# itself, which the third-branch case below does not reach.
test_merge_while_sitting_on_the_source_branch() {
    local root out
    root="$(make_fixture)"
    git -C "$root" checkout -q feat >/dev/null 2>&1
    assertEquals 'precondition: HEAD is on the source branch' 'feat' \
        "$(git -C "$root" symbolic-ref --short HEAD)"
    out="$(run_sut "$root" --branch feat --merge)"
    assertEquals 'merge exit 0' 0 $?
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:MERGED branch=feat base=main commit=.'
    assertTrue 'MERGED' $?
    git -C "$root" merge-base --is-ancestor feat main
    assertTrue 'main got the merge' $?
    assertEquals 'HEAD is back on the source branch' 'feat' \
        "$(git -C "$root" symbolic-ref --short HEAD)"
}

# ── Case 16: the original branch is restored, not just assumed to be base ─────
test_merge_restores_a_non_base_original_branch() {
    local root
    root="$(make_fixture)"
    git -C "$root" checkout -qb parked >/dev/null 2>&1
    run_sut "$root" --branch feat --merge >/dev/null
    assertEquals 'HEAD restored to the branch it started on' 'parked' \
        "$(git -C "$root" symbolic-ref --short HEAD)"
    git -C "$root" merge-base --is-ancestor feat main
    assertTrue 'and main really did get the merge' $?
}

# ── Case 17: CONFLICT leaves base exactly as it was ───────────────────────────
test_conflict_aborts_and_leaves_base_untouched() {
    local root out rc before after
    root="$(make_fixture)"
    git -C "$root" checkout -qb clash main >/dev/null 2>&1
    commit_file "$root" shared.txt 'from-clash' 'clash side'
    git -C "$root" checkout -q main >/dev/null 2>&1
    commit_file "$root" shared.txt 'from-main' 'main side'
    before="$(git -C "$root" rev-parse main)"
    out="$(run_sut "$root" --branch clash --merge)"; rc=$?
    after="$(git -C "$root" rev-parse main)"
    assertEquals 'conflict exits 1' 1 "$rc"
    assertEquals 'CONFLICT token' 'TP_TOKEN:CONFLICT branch=clash base=main' "$(token_of "$out")"
    assertEquals 'main did not move' "$before" "$after"
    [ ! -f "$root/.git/MERGE_HEAD" ]
    assertTrue 'no merge state left behind' $?
    assertEquals 'HEAD still on main' 'main' "$(git -C "$root" symbolic-ref --short HEAD)"
}

# ── Case 18: --merge re-runs the guards; a stale READY does not admit a merge ─
# This is the reason report and merge live in one script. The user sees a report, then the
# source worktree changes while they decide; --merge must refuse rather than merge on the
# strength of what was true a minute ago.
test_merge_rechecks_guards_and_refuses() {
    local root out before after
    root="$(make_fixture)"
    add_peer "$root" "$SB/wt" feat
    out="$(run_sut "$root" --branch feat)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:READY '
    assertTrue 'precondition: the report said READY' $?

    printf 'appeared later\n' > "$SB/wt/late.txt"
    before="$(git -C "$root" rev-parse main)"
    out="$(run_sut "$root" --branch feat --merge)"
    after="$(git -C "$root" rev-parse main)"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:SOURCE_DIRTY '
    assertTrue '--merge re-checked and refused' $?
    assertEquals 'and nothing was merged' "$before" "$after"
}

# ── Case 19: outside a repository routes as ERROR, not a bare crash ───────────
# The sandbox comes from mktemp, so it is outside this repository -- but that is asserted
# rather than assumed. Run the same case from a sandbox that happens to sit INSIDE a git
# repository and the script walks up, finds that repository, and answers about it instead;
# the case then passes or fails for reasons that have nothing to do with what it claims to
# check. (The Pester twin cannot use its usual sandbox for exactly this reason.)
test_outside_a_repo_emits_error_token() {
    local out rc plain
    plain="$SB/not-a-repo"
    mkdir -p "$plain"
    ( cd "$plain" && git rev-parse --git-dir >/dev/null 2>&1 )
    assertFalse 'precondition: the sandbox really is outside any git repository' $?
    out="$( cd "$plain" && bash "$SCRIPT_UNDER_TEST" --branch feat 2>&1 )"; rc=$?
    assertEquals 'exits 1' 1 "$rc"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:ERROR reason=.'
    assertTrue 'ERROR token carries a reason' $?
}

# ── Case 20: a --repo-root that does not exist also routes as ERROR ───────────
test_missing_repo_root_emits_error_token() {
    local out rc
    out="$( cd "$SB" && bash "$SCRIPT_UNDER_TEST" --branch feat --repo-root "$SB/no-such-dir" 2>&1 )"; rc=$?
    assertEquals 'exits 1' 1 "$rc"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:ERROR reason=.'
    assertTrue 'ERROR token carries a reason' $?
}

# ── Case 21: a git that WARNS on stderr but exits 0 must not read as a dirty tree ─
# `detected dubious ownership` is the everyday instance -- a repo owned by another user, which
# is the normal state inside CI images and agent containers. Capturing it into the value (2>&1)
# makes `status --porcelain` non-empty on a perfectly clean tree, and the script would then
# refuse a merge it should have offered. The stderr is discarded and the exit code is what is
# checked; this case is what holds that in place.
test_git_stderr_warning_is_not_mistaken_for_dirt() {
    local root out shim real_git probe
    root="$(make_fixture)"
    real_git="$(command -v git)"
    shim="$SB/shim"
    mkdir -p "$shim"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "warning: detected dubious ownership in repository" >&2\n'
        printf 'exec "%s" "$@"\n' "$real_git"
    } > "$shim/git"
    chmod +x "$shim/git"

    # Prove the shim is actually on the path before trusting anything this case concludes. A
    # shim that never resolves produces a clean pass that means nothing at all.
    probe="$( PATH="$shim:$PATH" git --version 2>&1 )"
    if ! printf '%s' "$probe" | grep -q 'dubious ownership'; then
        echo "SKIP: the git shim did not take effect on this platform"
        startSkipping
        return
    fi

    out="$( cd "$root" && PATH="$shim:$PATH" bash "$SCRIPT_UNDER_TEST" --branch feat 2>&1 )"
    printf '%s' "$(token_of "$out")" | grep -q '^TP_TOKEN:READY '
    assertTrue 'a clean tree stays READY even when git warns on stderr' $?
    printf '%s' "$(token_of "$out")" | grep -q 'DIRTY'
    assertFalse 'and is never reported as dirty' $?
}

# ── Case 22: every mode emits exactly one token ───────────────────────────────
test_exactly_one_token_per_run() {
    local root
    root="$(make_fixture)"
    assertEquals 'report'   1 "$(token_count "$(run_sut "$root" --branch feat)")"
    assertEquals 'missing'  1 "$(token_count "$(run_sut "$root" --branch nope)")"
    assertEquals 'merge'    1 "$(token_count "$(run_sut "$root" --branch feat --merge)")"
    assertEquals 'no-op'    1 "$(token_count "$(run_sut "$root" --branch feat)")"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
