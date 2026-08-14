#!/usr/bin/env bash
# create-worktree.test.sh / remove-worktree.test.sh (shUnit2)
#
# Scripts under test: scripts/hooks/create-worktree.sh + scripts/hooks/remove-worktree.sh
# Contract (observed from a real Claude Code run, 2026-08-14, not only from the docs):
#   stdin  {"cwd":"C:\\…","hook_event_name":"WorktreeCreate","name":"<slug>"}
#   stdout the ABSOLUTE PATH of the created working copy, and nothing else
#   exit   non-zero fails worktree creation outright
#
# Why this suite matters more than most: a WorktreeCreate hook REPLACES the built-in for every
# repository, not just for multi-repo workspaces. A mistake here does not degrade one feature --
# it degrades isolated sessions everywhere the plugin is installed. And the worst failure mode is
# silent: a worktree branched from the wrong base is a perfectly valid worktree, so nothing
# complains. test_base_ref_is_origin_default_not_local_head is the assertion that covers it, and
# the fixture deliberately moves the local checkout off origin/main so the two answers differ --
# without that the case would pass no matter which base the hook picked.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
CREATE="$PLUGIN_ROOT/scripts/hooks/create-worktree.sh"
REMOVE="$PLUGIN_ROOT/scripts/hooks/remove-worktree.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

HAS_GIT=0
WS=''

mk_repo() {
    local d="$1" want_origin="$2"
    mkdir -p "$d"
    git init -q -b main "$d" >/dev/null 2>&1
    git -C "$d" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$d" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    echo x > "$d/f.txt"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    if [ "$want_origin" = with-origin ]; then
        git init -q --bare "$d.origin.git" >/dev/null 2>&1
        git -C "$d" remote add origin "$d.origin.git" >/dev/null 2>&1
        git -C "$d" push -q origin main >/dev/null 2>&1
        git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1
    fi
}

# JSON payload with the path escaped the way Claude Code sends it.
payload_for() {
    printf '{"cwd":"%s","hook_event_name":"%s","name":"%s"}' \
        "$(printf '%s' "$1" | sed 's/\\/\\\\/g')" "$2" "$3"
}

oneTimeSetUp() {
    command -v git >/dev/null 2>&1 && HAS_GIT=1
    [ "$HAS_GIT" -eq 1 ] || return 0
    WS="$(mktemp -d -t turbo-wt-hook-XXXXXX)/ws"
    mkdir -p "$WS"
    mk_repo "$WS/proj-1" with-origin
    mk_repo "$WS/proj-2" no-origin
    # Move proj-1's local checkout off origin/main so "branched from origin/main" and "branched
    # from HEAD" are distinguishable.
    git -C "$WS/proj-1" checkout -q -b stray >/dev/null 2>&1
    echo local-only >> "$WS/proj-1/f.txt"
    git -C "$WS/proj-1" commit -q -am 'local-only commit' >/dev/null 2>&1
}

oneTimeTearDown() {
    [ -n "$WS" ] && rm -rf "$(dirname "$WS")" 2>/dev/null
    return 0
}

skip_without_git() {
    if [ "$HAS_GIT" -ne 1 ]; then startSkipping; return 0; fi
}

# ── multi-repo workspace ─────────────────────────────────────────────────────

test_workspace_returns_a_mirror_with_one_worktree_per_project() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-a | bash "$CREATE" 2>/dev/null)"
    # Compared by suffix, not against a reconstructed absolute path: on Git Bash `mktemp -d`
    # answers /tmp/... while git answers C:/Users/.../Temp/... for the very same directory, so an
    # equality check on the full string tests the spelling of the fixture, not the hook.
    case "$out" in
        */.worktrees/wt-a) assertTrue 'mirror path is <workspace>/.worktrees/<name>' 0 ;;
        *) fail "unexpected mirror path: $out" ;;
    esac
    assertTrue 'proj-1 worktree exists'  "[ -d '$out/proj-1' ]"
    assertTrue 'proj-2 worktree exists'  "[ -d '$out/proj-2' ]"
    # Each child must be a worktree in its OWN right, otherwise `git -C <project>` from the mirror
    # would reach the wrong repository.
    # git answers with the Windows spelling of the same directory, so match the tail: what matters
    # is that the child resolves to ITSELF and not up to the project's main checkout.
    case "$(git -C "$out/proj-1" rev-parse --show-toplevel 2>/dev/null)" in
        */.worktrees/wt-a/proj-1) assertTrue 'proj-1 child resolves to itself' 0 ;;
        *) fail "proj-1 resolves elsewhere: $(git -C "$out/proj-1" rev-parse --show-toplevel 2>/dev/null)" ;;
    esac
    assertEquals 'both children share the session branch name' 'wt-a' \
        "$(git -C "$out/proj-2" branch --show-current 2>/dev/null)"
}

# Claude Code refuses a returned path whose working tree git resolves to an enclosing checkout.
# The mirror sits in a non-repo parent, so git must resolve nothing for it.
test_mirror_itself_is_not_inside_any_checkout() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-b | bash "$CREATE" 2>/dev/null)"
    if git -C "$out" rev-parse --show-toplevel >/dev/null 2>&1; then
        fail "git resolves a working tree for the mirror; Claude Code would refuse it: $out"
    fi
}

# The silent one. `fresh` (origin/<default>) is Claude Code's own default, and inheriting whatever
# branch the checkout happens to sit on is precisely the class of mistake this suite exists for.
test_base_ref_is_origin_default_not_local_head() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-c | bash "$CREATE" 2>/dev/null)"
    assertEquals 'branched from origin/main' \
        "$(git -C "$WS/proj-1" rev-parse origin/main)" "$(git -C "$WS/proj-1" rev-parse wt-c)"
    # Fixture guard: if these two ever coincide the assertion above proves nothing.
    if [ "$(git -C "$WS/proj-1" rev-parse origin/main)" = "$(git -C "$WS/proj-1" rev-parse HEAD)" ]; then
        fail 'fixture is not discriminating: origin/main == local HEAD'
    fi
}

test_base_ref_falls_back_to_head_without_an_origin() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-d | bash "$CREATE" 2>/dev/null)"
    assertEquals 'no origin -> HEAD' \
        "$(git -C "$WS/proj-2" rev-parse HEAD)" "$(git -C "$WS/proj-2" rev-parse wt-d)"
}

# A local bare mirror sitting next to the projects is not a project: `worktree add` on it is
# meaningless, and surveying it produced an alarming log line about a project that never was.
test_bare_repo_sibling_is_not_treated_as_a_project() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-e | bash "$CREATE" 2>/dev/null)"
    assertFalse 'bare mirror must not appear in the mirror dir' "[ -e '$out/proj-1.origin.git' ]"
}

test_recreating_the_same_name_is_idempotent() {
    skip_without_git
    local first second
    first="$(payload_for "$WS" WorktreeCreate wt-f | bash "$CREATE" 2>/dev/null)"
    second="$(payload_for "$WS" WorktreeCreate wt-f | bash "$CREATE" 2>/dev/null)"
    assertEquals 'same path returned' "$first" "$second"
    assertTrue 'worktrees still intact' "[ -d '$first/proj-1' ]"
}

# ── ordinary git repository ──────────────────────────────────────────────────
# NOT a hypothetical branch: verified that the hook fires inside ordinary repos too.

test_ordinary_repo_gets_the_builtin_layout() {
    skip_without_git
    local out
    out="$(payload_for "$WS/proj-2" WorktreeCreate wt-g | bash "$CREATE" 2>/dev/null)"
    case "$out" in
        */proj-2/.claude/worktrees/wt-g) assertTrue 'path matches the built-in convention' 0 ;;
        *) fail "unexpected worktree path: $out" ;;
    esac
    assertEquals 'is a worktree of that repo' "$out" \
        "$(git -C "$out" rev-parse --show-toplevel 2>/dev/null)"
    assertEquals 'on its own branch' 'wt-g' "$(git -C "$out" branch --show-current 2>/dev/null)"
}

test_plain_folder_fails_loudly() {
    skip_without_git
    local dir rc=0
    dir="$(mktemp -d -t turbo-wt-plain-XXXXXX)"
    payload_for "$dir" WorktreeCreate wt-h | bash "$CREATE" >/dev/null 2>&1 || rc=$?
    rm -rf "$dir" 2>/dev/null
    assertNotEquals 'nothing to isolate must fail creation, not return a bogus path' 0 "$rc"
}

# ── removal ──────────────────────────────────────────────────────────────────

test_remove_takes_the_whole_mirror_down() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-i | bash "$CREATE" 2>/dev/null)"
    payload_for "$WS" WorktreeRemove wt-i | bash "$REMOVE" >/dev/null 2>&1
    assertFalse 'mirror removed' "[ -d '$out' ]"
    if git -C "$WS/proj-1" worktree list 2>/dev/null | grep -q 'wt-i'; then
        fail 'proj-1 still registers the removed worktree'
    fi
}

# Removal must never be able to lose an edit. git refuses without --force, and we do not force.
test_remove_keeps_a_worktree_with_uncommitted_work() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-j | bash "$CREATE" 2>/dev/null)"
    echo uncommitted >> "$out/proj-2/f.txt"
    payload_for "$WS" WorktreeRemove wt-j | bash "$REMOVE" >/dev/null 2>&1
    assertTrue  'the dirty worktree is kept'    "[ -d '$out/proj-2' ]"
    assertFalse 'the clean one is still removed' "[ -d '$out/proj-1' ]"
    assertTrue  'the mirror is kept because something is left' "[ -d '$out' ]"
}

# The ordinary-repo removal path. Worth its own case because the payload may carry no path field,
# and reconstructing only the workspace mirror would leave every ordinary-repo worktree behind
# forever -- and the ordinary repo is the COMMON case, since this hook replaces the built-in
# everywhere, not only in workspaces.
test_remove_finds_an_ordinary_repo_worktree_without_a_path_field() {
    skip_without_git
    local out
    out="$(payload_for "$WS/proj-2" WorktreeCreate wt-k | bash "$CREATE" 2>/dev/null)"
    assertTrue 'precondition: the worktree exists' "[ -d '$out' ]"
    # Deliberately only cwd + name, no path field.
    payload_for "$WS/proj-2" WorktreeRemove wt-k | bash "$REMOVE" >/dev/null 2>&1
    assertFalse 'ordinary-repo worktree removed' "[ -d '$out' ]"
    if git -C "$WS/proj-2" worktree list 2>/dev/null | grep -q 'wt-k'; then
        fail 'proj-2 still registers the removed worktree'
    fi
}

# A name is pasted into a path and a branch name. It is a Claude Code slug today, but a separator
# or a `..` would place the worktree somewhere else entirely -- and the remove hook deletes things.
test_implausible_name_is_refused_rather_than_escaping_the_directory() {
    skip_without_git
    local rc=0
    payload_for "$WS" WorktreeCreate '../escaped' | bash "$CREATE" >/dev/null 2>&1 || rc=$?
    assertNotEquals 'a traversing name must fail creation' 0 "$rc"
    assertFalse 'nothing was created outside the workspace' "[ -d '$(dirname "$WS")/escaped' ]"
}

# shellcheck source=/dev/null
. "$SHUNIT2"
