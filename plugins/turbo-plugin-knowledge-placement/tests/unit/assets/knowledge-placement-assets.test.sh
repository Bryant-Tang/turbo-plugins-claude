#!/usr/bin/env bash
# knowledge-placement-assets.test.sh (shUnit2)
#
# This plugin ships no scripts, so what CAN break is the assets -- and each failure below is one
# that produces no error at the time it happens:
#
#   * a mismatched marker pair means the setup skill's "replace the block" path never matches, so
#     every run APPENDS another copy instead of replacing the old one;
#   * a frontmatter `name` that disagrees with its directory means the skill cannot be invoked by
#     the name its own file claims;
#   * a non-English `description` costs context on EVERY session (descriptions are preloaded for
#     routing, bodies are not) without anything ever going red.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SNIPPET="$PLUGIN_ROOT/skills/tp-knowledge-placement-setup/assets/claudemd-knowledge-placement-snippet.md"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

# Frontmatter value for a key, from the top block of a SKILL.md.
fm_value() {
    sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n 1
}

test_snippet_exists_and_is_not_empty() {
    assertTrue "the injected snippet exists: $SNIPPET" "[ -s '$SNIPPET' ]"
}

# The setup skill replaces everything between the markers. One marker missing, or two of the same,
# and the replace path silently degrades into "append another copy" -- CLAUDE.md then carries the
# guidance twice and an edit to one copy leaves two contradictory versions loaded at once.
test_snippet_markers_are_exactly_one_matched_pair() {
    assertEquals 'exactly one begin marker' 1 \
        "$(grep -c '<!-- turbo-plugin:begin knowledge-placement -->' "$SNIPPET")"
    assertEquals 'exactly one end marker' 1 \
        "$(grep -c '<!-- turbo-plugin:end knowledge-placement -->' "$SNIPPET")"
    local b e
    b="$(grep -n '<!-- turbo-plugin:begin knowledge-placement -->' "$SNIPPET" | cut -d: -f1)"
    e="$(grep -n '<!-- turbo-plugin:end knowledge-placement -->' "$SNIPPET" | cut -d: -f1)"
    assertTrue "begin ($b) comes before end ($e)" "[ '$b' -lt '$e' ]"
}

# The marker name is load-bearing in BOTH directions: this plugin must replace only its own block,
# and must never touch the `base` block that git-svn / three-environment-db maintain. Sharing a
# name would make each setup silently overwrite the other's section.
test_snippet_does_not_reuse_another_plugins_marker_name() {
    if grep -q 'turbo-plugin:begin base' "$SNIPPET"; then
        fail "the snippet claims the 'base' marker, which another plugin's setup owns"
    fi
}

test_every_skill_has_complete_frontmatter() {
    local d skill name desc
    for d in "$PLUGIN_ROOT"/skills/*/; do
        skill="$(basename "$d")"
        assertTrue "$skill has a SKILL.md" "[ -f '$d/SKILL.md' ]"
        [ -f "$d/SKILL.md" ] || continue
        name="$(fm_value "$d/SKILL.md" name)"
        assertEquals "$skill: frontmatter name matches its directory" "$skill" "$name"
        desc="$(fm_value "$d/SKILL.md" description)"
        assertNotEquals "$skill: has a description" '' "$desc"
        assertEquals "$skill: is user-invocable" 'true' "$(fm_value "$d/SKILL.md" user-invocable)"
    done
}

# Descriptions are the only part of a skill that is PRELOADED -- every installed skill's
# description sits in context permanently so the model can route to it, while the body loads only
# when the skill is actually used. A CJK description therefore costs tokens on every session
# forever. Bodies stay in Traditional Chinese on purpose; this checks the description line only.
test_skill_descriptions_are_english() {
    local d skill desc
    for d in "$PLUGIN_ROOT"/skills/*/; do
        skill="$(basename "$d")"
        [ -f "$d/SKILL.md" ] || continue
        desc="$(fm_value "$d/SKILL.md" description)"
        # LC_ALL=C so the class means "byte outside printable ASCII", not "not a letter in the
        # ambient locale" -- under a UTF-8 locale grep would happily call CJK text alphabetic.
        if printf '%s' "$desc" | LC_ALL=C grep -q '[^ -~]'; then
            fail "$skill: description must be English (found a non-ASCII byte): $desc"
        fi
    done
}

# shellcheck source=/dev/null
. "$SHUNIT2"
