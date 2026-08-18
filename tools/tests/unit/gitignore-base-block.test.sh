#!/usr/bin/env bash
# gitignore-base-block.test.sh (shUnit2)
#
# Under test: the `.gitignore` base block that `tp-setup` injects into every project, as written
# in the shared asset `skills/tp-setup/assets/setup-base.md` (item 3).
#
# Why this suite exists: that block is PROSE in a SKILL asset -- no script emits it, so nothing
# else in the repo can catch a mistake in it. And its failure modes are silent in both directions:
#
#   * a rule that is too broad hides a file the user meant to commit (the `!*.example.local.*`
#     escape exists precisely because `.turbo-plugin/**/*.local.*` swallowed the template that is
#     supposed to reach colleagues -- and nothing reports "your template was never committed");
#   * a rule that is too narrow lets a whole worktree checkout into version control on the next
#     `git add -A`, which on the SVN side is permanent.
#
# So the block is extracted from the asset VERBATIM and its real behaviour is asserted with
# `git check-ignore`. The asset itself says "改動這三行時務必兩邊都驗" -- this is that check,
# mechanised.
#
# Both shared copies (git-svn, three-environment-db) are byte-identical by
# tools/verify-core-identical.sh, so exercising the canonical one covers both.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$TOOLS_DIR/.." && pwd)"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"
SETUP_BASE="$REPO_ROOT/plugins/turbo-plugin-git-svn/skills/tp-setup/assets/setup-base.md"

SANDBOX=''

oneTimeSetUp() {
    SANDBOX="$(mktemp -d -t turbo-gitignore-base-XXXXXX)"
    git -C "$SANDBOX" init -q -b main >/dev/null 2>&1 || git init -q -b main "$SANDBOX" >/dev/null 2>&1

    # Pull the block out of the markdown fence, markers included, and strip the 3-space indent the
    # list item adds. Taking it verbatim is the point: a test that restated the rules would pass
    # while the asset said something else.
    awk '/# >>> turbo-plugin:base >>>/{f=1} f{print} /# <<< turbo-plugin:base <<</{if(f)exit}' \
        "$SETUP_BASE" | sed 's/^   //' > "$SANDBOX/.gitignore"

    mkdir -p "$SANDBOX/.turbo-plugin" "$SANDBOX/docs" "$SANDBOX/.claude/worktrees/wt"
    : > "$SANDBOX/.turbo-plugin/dbhub.example.local.toml"
    : > "$SANDBOX/.turbo-plugin/dbhub.local.toml"
    : > "$SANDBOX/TODO.md"
    : > "$SANDBOX/docs/TODO.md"
    : > "$SANDBOX/.claude/worktrees/wt/file.txt"
    : > "$SANDBOX/.claude/settings.local.json"
}

oneTimeTearDown() {
    [ -n "$SANDBOX" ] && rm -rf "$SANDBOX" 2>/dev/null
    return 0
}

# 0 = git ignores it. Named for readability at the call site.
is_ignored() {
    git -C "$SANDBOX" check-ignore -q "$1"
}

test_block_was_actually_extracted() {
    # Guards the fixture: if the markers ever change shape, every assertion below would otherwise
    # run against an empty .gitignore and pass by ignoring nothing.
    local n
    n="$(grep -c '^[^#]' "$SANDBOX/.gitignore" 2>/dev/null || echo 0)"
    assertTrue "extracted at least 4 rules from $SETUP_BASE (got $n)" "[ '$n' -ge 4 ]"
    grep -q '# >>> turbo-plugin:base >>>' "$SANDBOX/.gitignore"
    assertTrue 'begin marker present in the extracted block' $?
    grep -q '# <<< turbo-plugin:base <<<' "$SANDBOX/.gitignore"
    assertTrue 'end marker present in the extracted block' $?
}

# The escape hatch. Without it the template that shows colleagues which fields to fill is silently
# never committed, and "ship an example alongside the real thing" stops working.
test_example_template_is_not_ignored() {
    if is_ignored '.turbo-plugin/dbhub.example.local.toml'; then
        fail 'the *.example.local.* template is ignored; colleagues would never receive it'
    fi
}

# The other half of the same pair: the real file carries credentials and must stay out.
test_real_local_file_is_ignored() {
    is_ignored '.turbo-plugin/dbhub.local.toml'
    assertTrue 'the real *.local.* file (credentials) must be ignored' $?
}

test_claude_local_settings_are_ignored() {
    is_ignored '.claude/settings.local.json'
    assertTrue '.claude local settings must be ignored' $?
}

# `.claude/**/*.local.*` does NOT cover this: a worktree is a full checkout whose files do not
# contain ".local.". Ignoring the DIRECTORY also stops the later `!` rule from re-including
# anything underneath it, which is what we want.
test_claude_worktrees_directory_is_ignored() {
    is_ignored '.claude/worktrees/wt/file.txt'
    assertTrue 'a checkout under .claude/worktrees/ must be ignored' $?
}

# The base block used to carry `/TODO.md`, because the "not versioned, but part of the handover"
# slot lived in a project-root TODO.md. That slot is gone: it had no tool support at all (git
# ignores the file, an isolated working copy carries it IN but never back OUT, and two copies that
# each added a line cannot be merged by anything). Current-only knowledge now lives in agent
# memory, and turbo-plugin-knowledge-placement's /tp-export-handover is what makes it survive a
# handover.
#
# This is the assertion in the OPPOSITE direction, and it earns its place: nothing else would
# notice the line being quietly reinstated. Re-adding it would silently start hiding a file that
# some project legitimately versions, and would put this repo back to claiming a slot it no longer
# implements.
test_base_block_no_longer_claims_the_root_todo() {
    if is_ignored 'TODO.md'; then
        fail 'the base block still ignores a project-root TODO.md; that slot was deliberately removed'
    fi
    # Nested ones were never in scope and must stay out of scope.
    if is_ignored 'docs/TODO.md'; then
        fail 'the base block hides nested TODO.md files, which it must never do'
    fi
}

# shellcheck source=/dev/null
. "$SHUNIT2"
