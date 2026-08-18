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
    # The workspace root's own file, carrying the marker tp-multi-repo-workspace-setup writes.
    # Both halves matter: the marker is what the hook now keys the workspace shape on, and the file
    # itself is what an isolated session has to be able to edit (issue #86).
    {
        printf '<!-- turbo-plugin:begin multi-repo-workspace -->\n'
        printf 'generated workspace guidance\n'
        printf '<!-- turbo-plugin:end multi-repo-workspace -->\n'
        printf "the user's own cross-project rule\n"
    } > "$WS/CLAUDE.md"
}

# A workspace root that somebody ran `git init` in -- the exact accident the setup skill warns
# about. Returns the path of a fresh one; the caller removes its parent.
mk_root_repo_workspace() {
    local tag="$1" with_marker="$2" ws
    ws="$(mktemp -d -t "turbo-wt-$tag-XXXXXX")/ws"
    mkdir -p "$ws"
    mk_repo "$ws/proj-a" no-origin
    git init -q -b main "$ws" >/dev/null 2>&1
    git -C "$ws" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$ws" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    echo root > "$ws/root.txt"
    git -C "$ws" add -A >/dev/null 2>&1
    git -C "$ws" -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    if [ "$with_marker" = with-marker ]; then
        printf '<!-- turbo-plugin:begin multi-repo-workspace -->\nx\n<!-- turbo-plugin:end multi-repo-workspace -->\n' > "$ws/CLAUDE.md"
    fi
    printf '%s' "$ws"
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

# ── issue #87: removal is asymmetric unless the BRANCHES come down too ───────────────────────
# create-worktree.sh opens one branch per project, so a workspace of N projects leaves N branches
# behind per session, named after a slug nobody can attribute afterwards. The registration being
# clean is not enough -- that was already true while the branches piled up.
#
# This case also exercises BOTH deletion paths at once, which is why it asserts on both projects:
#   proj-1 has an origin AND its local HEAD deliberately sits on `stray`, so the branch (cut from
#          origin/main) is NOT merged into HEAD and `git branch -d` refuses it -- only the
#          "is this tip already contained in another ref?" fallback can remove it.
#   proj-2 has no origin, so the branch is cut from HEAD and the plain safe delete handles it.
test_remove_deletes_the_branches_it_created() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-l | bash "$CREATE" 2>/dev/null)"
    assertTrue 'precondition: the mirror exists' "[ -d '$out' ]"
    assertTrue 'precondition: proj-1 has the branch' "git -C '$WS/proj-1' rev-parse --verify --quiet refs/heads/wt-l >/dev/null"
    assertTrue 'precondition: proj-2 has the branch' "git -C '$WS/proj-2' rev-parse --verify --quiet refs/heads/wt-l >/dev/null"

    payload_for "$WS" WorktreeRemove wt-l | bash "$REMOVE" >/dev/null 2>&1

    assertFalse 'proj-1 branch deleted (via the contained-elsewhere fallback)' \
        "git -C '$WS/proj-1' rev-parse --verify --quiet refs/heads/wt-l >/dev/null"
    assertFalse 'proj-2 branch deleted (via the plain safe delete)' \
        "git -C '$WS/proj-2' rev-parse --verify --quiet refs/heads/wt-l >/dev/null"
    assertFalse 'mirror removed' "[ -d '$out' ]"
}

# The other half of the same rule: a branch that carries work of its own is NEVER deleted. The
# worktree is clean (the work is committed), so removal proceeds -- but the commit exists nowhere
# else, so the branch has to survive or the commit is gone for good.
test_remove_keeps_a_branch_that_carries_its_own_commits() {
    skip_without_git
    local out
    out="$(payload_for "$WS" WorktreeCreate wt-m | bash "$CREATE" 2>/dev/null)"
    echo work > "$out/proj-2/new-work.txt"
    git -C "$out/proj-2" add -A >/dev/null 2>&1
    git -C "$out/proj-2" -c commit.gpgsign=false commit -q -m 'work that exists nowhere else' >/dev/null 2>&1

    payload_for "$WS" WorktreeRemove wt-m | bash "$REMOVE" >/dev/null 2>&1

    assertTrue 'the branch holding unique commits is kept' \
        "git -C '$WS/proj-2' rev-parse --verify --quiet refs/heads/wt-m >/dev/null"
    # ...and the commit is still reachable through it, which is the point of keeping it.
    assertTrue 'the unique commit is still reachable' \
        "git -C '$WS/proj-2' cat-file -e refs/heads/wt-m:new-work.txt"
    # The branch with no work of its own is still cleaned up in the same run.
    assertFalse 'the untouched project'\''s branch is still deleted' \
        "git -C '$WS/proj-1' rev-parse --verify --quiet refs/heads/wt-m >/dev/null"
}

# The ordinary-repo path creates a branch too (this hook replaces the built-in everywhere), so it
# has to clean one up as well.
test_remove_deletes_the_branch_in_an_ordinary_repo() {
    skip_without_git
    local out
    out="$(payload_for "$WS/proj-2" WorktreeCreate wt-n | bash "$CREATE" 2>/dev/null)"
    assertTrue 'precondition: the branch exists' "git -C '$WS/proj-2' rev-parse --verify --quiet refs/heads/wt-n >/dev/null"
    payload_for "$WS/proj-2" WorktreeRemove wt-n | bash "$REMOVE" >/dev/null 2>&1
    assertFalse 'ordinary-repo branch deleted' \
        "git -C '$WS/proj-2' rev-parse --verify --quiet refs/heads/wt-n >/dev/null"
    assertFalse 'ordinary-repo worktree removed' "[ -d '$out' ]"
}

# ── issue #86: the workspace root's own files stay OUT of the mirror ─────────
# Claude Code loads CLAUDE.md by walking UP from the session's working directory, and the mirror is
# <workspace>/.worktrees/<name>, so <workspace>/CLAUDE.md is an ancestor and loads on its own. A
# copy in the mirror would put the same guidance in context twice, and an edit to the copy would
# leave two versions loaded at once. Nothing from the workspace root belongs in there.
test_workspace_root_files_are_not_copied_into_the_mirror() {
    skip_without_git
    local out
    printf 'loose\n' > "$WS/NOTES.md"
    out="$(payload_for "$WS" WorktreeCreate wt-o | bash "$CREATE" 2>/dev/null)"
    assertFalse 'the root CLAUDE.md is NOT duplicated into the mirror' "[ -e '$out/CLAUDE.md' ]"
    assertFalse 'no other root file is duplicated either' "[ -e '$out/NOTES.md' ]"
    # The mirror holds projects and nothing else.
    assertTrue 'the projects are still there' "[ -d '$out/proj-1' ] && [ -d '$out/proj-2' ]"
    payload_for "$WS" WorktreeRemove wt-o | bash "$REMOVE" >/dev/null 2>&1
    assertTrue 'the workspace file is untouched by removal' "[ -f '$WS/NOTES.md' ]"
    rm -f "$WS/NOTES.md"
}

# ── issue #86: the workspace shape is DECLARED, not inferred ─────────────────
# It used to be inferred from "the root is not a git repository", so one `git init` at the workspace
# root silently disabled the whole mirror and isolated the outer repo alone. Nothing failed; the
# feature just stopped existing.
test_marker_wins_over_the_root_being_a_repo() {
    skip_without_git
    local ws out
    ws="$(mk_root_repo_workspace marker with-marker)"
    out="$(payload_for "$ws" WorktreeCreate wt-r | bash "$CREATE" 2>/dev/null)"
    case "$out" in
        */.worktrees/wt-r) assertTrue 'the mirror shape is still used' 0 ;;
        *) fail "the marker did not win; got: $out" ;;
    esac
    assertTrue 'the project is in the mirror' "[ -d '$out/proj-a' ]"
    rm -rf "$(dirname "$ws")" 2>/dev/null
}

# Without the marker we still do the ordinary thing -- guessing the other way could isolate the
# wrong tree -- but the user has to be told why the projects are missing.
test_root_repo_without_marker_says_why_the_projects_are_missing() {
    skip_without_git
    local ws err
    ws="$(mk_root_repo_workspace nomarker no-marker)"
    err="$(payload_for "$ws" WorktreeCreate wt-s | bash "$CREATE" 2>&1 >/dev/null)"
    case "$err" in
        *'holds git repositories directly inside it'*) assertTrue 'the accident is reported' 0 ;;
        *) fail "no warning about the nested projects: $err" ;;
    esac
    rm -rf "$(dirname "$ws")" 2>/dev/null
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

# ── .worktreeinclude, implemented by this hook ───────────────────────────────
# Declaring a WorktreeCreate hook turns Claude Code's own .worktreeinclude handling OFF for every
# repository the user owns ("Because the hook replaces the default git behavior, .worktreeinclude
# is not processed"), so this plugin implements it. These cases pin the OFFICIAL semantics, whose
# discriminating half is the second one: a file must be matched by the patterns AND ignored by git.
#
# Set up in its own workspace rather than in $WS: the shared fixture is reused by many cases, and
# leaving .worktreeinclude files in it would change what every later case copies.
mk_include_workspace() {
    local ws
    ws="$(mktemp -d -t turbo-wt-inc-XXXXXX)/ws"
    mkdir -p "$ws"
    mk_repo "$ws/proj-a" no-origin
    printf '<!-- turbo-plugin:begin multi-repo-workspace -->\nx\n<!-- turbo-plugin:end multi-repo-workspace -->\n' > "$ws/CLAUDE.md"

    local p="$ws/proj-a"
    mkdir -p "$p/cfg" "$p/node_modules/pkg"
    printf 'SECRET\n'  > "$p/.env"
    printf 'MACHINE\n' > "$p/cfg/machine.json"
    printf 'dep\n'     > "$p/node_modules/pkg/index.js"
    printf 'IGNORED\n' > "$p/other.local"
    # Matched by .worktreeinclude but NOT gitignored. A "copy whatever the patterns match"
    # implementation would carry this one in; the official rule says it must stay out, because git
    # already brings tracked/plain files along and a copy would overwrite them.
    printf 'PLAIN\n'   > "$p/matched-not-ignored.txt"
    {
        printf '.env\n'
        printf 'cfg/\n'
        printf 'node_modules/\n'
        printf '*.local\n'
    } > "$p/.gitignore"
    {
        printf '.env\n'
        printf 'cfg/\n'
        printf 'matched-not-ignored.txt\n'
    } > "$p/.worktreeinclude"
    git -C "$p" add .gitignore >/dev/null 2>&1
    git -C "$p" -c commit.gpgsign=false commit -q -m 'chore: ignores' >/dev/null 2>&1
    printf '%s' "$ws"
}

test_worktreeinclude_copies_matched_and_ignored_files() {
    skip_without_git
    local ws out
    ws="$(mk_include_workspace)"
    out="$(payload_for "$ws" WorktreeCreate wt-inc | bash "$CREATE" 2>/dev/null)"
    assertTrue 'a listed, gitignored file is carried in' "[ -f '$out/proj-a/.env' ]"
    assertEquals 'its CONTENT comes across, not just the name' 'SECRET' "$(cat "$out/proj-a/.env" 2>/dev/null)"
    # A directory pattern must arrive expanded, with its relative path rebuilt under the worktree.
    assertTrue 'a listed ignored directory is carried in, path preserved' "[ -f '$out/proj-a/cfg/machine.json' ]"
    rm -rf "$(dirname "$ws")"
}

test_worktreeinclude_skips_files_it_does_not_match_or_git_does_not_ignore() {
    skip_without_git
    local ws out
    ws="$(mk_include_workspace)"
    out="$(payload_for "$ws" WorktreeCreate wt-inc2 | bash "$CREATE" 2>/dev/null)"
    # THE case that separates the official rule from "copy what the patterns match".
    assertFalse 'matched but NOT gitignored stays out' "[ -e '$out/proj-a/matched-not-ignored.txt' ]"
    # Ignored, but nobody asked for it.
    assertFalse 'gitignored but unlisted stays out' "[ -e '$out/proj-a/other.local' ]"
    # The pattern set never mentions node_modules, so the hook must not have walked into it either.
    assertFalse 'an unlisted dependency directory stays out' "[ -e '$out/proj-a/node_modules' ]"
    rm -rf "$(dirname "$ws")"
}

# The ordinary-repo branch is the one that fires for EVERY repository the plugin's owner opens, so
# the feature has to work there too -- that is where the built-in used to do it.
test_worktreeinclude_applies_to_an_ordinary_repo_too() {
    skip_without_git
    local root out
    root="$(mktemp -d -t turbo-wt-inc1-XXXXXX)/r"
    mk_repo "$root" no-origin
    printf 'SECRET\n' > "$root/.env"
    printf '.env\n' > "$root/.gitignore"
    printf '.env\n' > "$root/.worktreeinclude"
    git -C "$root" add .gitignore >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -q -m 'chore: ignore' >/dev/null 2>&1
    out="$(payload_for "$root" WorktreeCreate wt-inc3 | bash "$CREATE" 2>/dev/null)"
    assertTrue 'the ordinary-repo path honours .worktreeinclude' "[ -f '$out/.env' ]"
    rm -rf "$(dirname "$root")"
}

# A spec that matches an unreasonable number of files is a pattern accident, and a bulk copy would
# stall session creation itself. The guard must copy NOTHING and say so -- and it must say so on
# stderr, because stdout carries the path and any extra line there breaks the hook contract.
test_worktreeinclude_refuses_an_implausibly_large_match_set() {
    skip_without_git
    local ws out err
    ws="$(mk_include_workspace)"
    err="$(mktemp -t turbo-wt-inc-err-XXXXXX)"
    # The override belongs on the SCRIPT's side of the pipe; putting it in front of payload_for
    # would set it for the payload generator and leave the hook running with the default.
    out="$(payload_for "$ws" WorktreeCreate wt-inc4 | TP_WORKTREE_INCLUDE_MAX=1 bash "$CREATE" 2>"$err")"
    # Guard against the test passing for the wrong reason: the run itself must still succeed.
    assertTrue 'the worktree is still created' "[ -d '$out/proj-a' ]"
    assertFalse 'nothing is copied when the guard trips' "[ -e '$out/proj-a/.env' ]"
    # 3 candidates: .env, cfg/machine.json and matched-not-ignored.txt. The guard counts what the
    # PATTERNS matched, before the gitignore filter -- it exists to avoid the work, so it has to
    # decide before doing any.
    # `rc` is captured BEFORE building the message. Writing `assertTrue "...$(cat "$err")" $?`
    # instead makes the assertion unfailable: the command substitution in the message runs first,
    # so `$?` carries `cat`'s status (always 0) rather than grep's. Found by mutation-testing this
    # very case -- it stayed green with the whole feature stubbed out.
    local rc=0
    grep -q 'matches 3 files (limit 1)' "$err" || rc=$?
    assertEquals "the refusal names the counts (stderr: $(cat "$err"))" 0 "$rc"
    rm -f "$err"
    rm -rf "$(dirname "$ws")"
}

# A symlink matched by the spec must NOT be followed. Every bash file test except -h/-L follows
# symlinks, and `cp` without -P follows too, so the obvious `[[ -f ]]` guard would let a symlink
# through and copy its TARGET'S CONTENT into the worktree -- including a target outside the repo.
#
# SKIPPED where symlinks cannot be created (Windows without Developer Mode, which is where this was
# written -- so this case never ran locally and is covered by the ubuntu CI leg). The skip is on
# the ACTUAL capability, not on the OS name: a Windows host with Developer Mode on runs it fine.
test_worktreeinclude_does_not_follow_a_symlink_out_of_the_repo() {
    skip_without_git
    local ws p outside out
    ws="$(mk_include_workspace)"
    p="$ws/proj-a"
    outside="$(dirname "$ws")/outside"
    mkdir -p "$outside"
    printf 'TOP-SECRET\n' > "$outside/secret.txt"
    if ! ln -s "$outside/secret.txt" "$p/linked.secret" 2>/dev/null || [ ! -L "$p/linked.secret" ]; then
        rm -rf "$(dirname "$ws")"
        startSkipping
        # Register one assertion WHILE skipping, so the run reports a skip instead of a silent
        # pass. Returning straight after startSkipping executes zero assertions, and a test that
        # asserts nothing looks exactly like a test that passed.
        assertTrue 'symlinks cannot be created on this host; case not exercised here' "${SHUNIT_TRUE}"
        return 0
    fi
    # Ignored AND listed, so it reaches the copy loop; only the symlink guard can stop it.
    printf '*.secret\n' >> "$p/.gitignore"
    printf '*.secret\n' >> "$p/.worktreeinclude"
    git -C "$p" add .gitignore >/dev/null 2>&1
    git -C "$p" -c commit.gpgsign=false commit -q -m 'chore: ignore secrets' >/dev/null 2>&1

    out="$(payload_for "$ws" WorktreeCreate wt-inc5 | bash "$CREATE" 2>/dev/null)"
    # Guard against passing for the wrong reason: the run must still have done its job.
    assertTrue 'the ordinary include still came across' "[ -f '$out/proj-a/.env' ]"
    assertFalse 'the symlink is not materialised in the worktree' "[ -e '$out/proj-a/linked.secret' ]"
    if [ -f "$out/proj-a/linked.secret" ] && grep -q 'TOP-SECRET' "$out/proj-a/linked.secret" 2>/dev/null; then
        fail 'the symlink was FOLLOWED: the target file contents were copied into the worktree'
    fi
    rm -rf "$(dirname "$ws")"
}

# shellcheck source=/dev/null
. "$SHUNIT2"
