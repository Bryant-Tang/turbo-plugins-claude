#!/usr/bin/env bash
# db-assets.test.sh (shUnit2)
#
# The SQL landing root is implemented in SKILL.md and config.toml, not in a script -- nothing
# under scripts/ ever mentions it -- so the ordinary script tests cannot see any of this. What
# CAN be checked mechanically is the shape of the assets the skills read, and every case below
# is a failure that produces no error at the time it happens:
#
#   * a mismatched marker pair means tp-setup's "replace my block" path never matches, so every
#     run APPENDS another copy instead of replacing the old one;
#   * a shipped template with an ACTIVE sql_root would silently redirect every new project's SQL
#     somewhere its author never chose;
#   * losing the documented default from the SKILL would break the one promise this feature
#     makes to existing projects -- that not setting the key changes nothing.
#
# .sh only, no .ps1 twin: these are pure text assertions over files, so a second implementation
# would be a translation with no added coverage, and this file runs on BOTH runners (the Windows
# orchestrator drives .sh through Git Bash). Contrast the script tests next door, where the two
# halves are genuinely different implementations.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_TEMPLATE="$PLUGIN_ROOT/default-files/.turbo-plugin/config.toml"
DB_SKILL="$PLUGIN_ROOT/skills/tp-db-management/SKILL.md"
SETUP_BASE="$PLUGIN_ROOT/skills/tp-setup/assets/setup-base.md"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

test_config_template_exists_and_is_not_empty() {
    assertTrue "tp-setup copies this when config.toml is absent: $CONFIG_TEMPLATE" \
        "[ -s '$CONFIG_TEMPLATE' ]"
}

# One marker missing, or two of the same, and tp-setup's replace path silently degrades into
# "append another copy" -- config.toml then carries two [db] sections and the reader takes
# whichever it merges last.
test_db_marker_is_exactly_one_matched_pair() {
    assertEquals 'exactly one begin marker' 1 \
        "$(grep -c '# >>> turbo-plugin:db >>>' "$CONFIG_TEMPLATE")"
    assertEquals 'exactly one end marker' 1 \
        "$(grep -c '# <<< turbo-plugin:db <<<' "$CONFIG_TEMPLATE")"
    local b e
    b="$(grep -n '# >>> turbo-plugin:db >>>' "$CONFIG_TEMPLATE" | cut -d: -f1)"
    e="$(grep -n '# <<< turbo-plugin:db <<<' "$CONFIG_TEMPLATE" | cut -d: -f1)"
    assertTrue "begin ($b) comes before end ($e)" "[ '$b' -lt '$e' ]"
}

# The marker name is load-bearing in BOTH directions: db must replace only its own block, and
# must never touch the git-svn / dotnet blocks their own setups maintain. Shipping a template
# that claims someone else's marker would make each setup silently overwrite the other's section.
test_template_does_not_claim_another_concerns_marker() {
    local other
    for other in git-svn dotnet base; do
        if grep -q "turbo-plugin:$other" "$CONFIG_TEMPLATE"; then
            fail "the db template claims the '$other' marker, which another setup owns"
        fi
    done
}

# Outside the markers the section would survive tp-setup, but tp-setup would also never create
# or maintain it -- the key would exist only for projects that happened to get this exact file.
test_db_section_header_is_inside_the_markers() {
    local b e s
    b="$(grep -n '# >>> turbo-plugin:db >>>' "$CONFIG_TEMPLATE" | cut -d: -f1)"
    e="$(grep -n '# <<< turbo-plugin:db <<<' "$CONFIG_TEMPLATE" | cut -d: -f1)"
    s="$(grep -n '^\[db\]' "$CONFIG_TEMPLATE" | cut -d: -f1)"
    assertNotEquals 'template has a [db] section header' '' "$s"
    assertTrue "[db] (line $s) sits between the markers ($b..$e)" \
        "[ '$s' -gt '$b' ] && [ '$s' -lt '$e' ]"
}

# An active sql_root in the SHIPPED template would apply to every project that ever runs setup,
# and nothing would say so -- the SQL would simply appear somewhere nobody chose. The example
# must stay commented out; the default lives in the SKILL, not in the file.
test_template_ships_sql_root_commented_out() {
    if grep -qE '^[[:space:]]*sql_root[[:space:]]*=' "$CONFIG_TEMPLATE"; then
        fail 'the shipped template has an ACTIVE sql_root; the example must stay commented out'
    fi
    grep -q 'sql_root' "$CONFIG_TEMPLATE"
    assertTrue 'the template still documents the key (commented example present)' $?
}

# The whole backwards-compatibility promise: a project that never sets the key must behave
# exactly as before. If the default disappears from the SKILL, the agent has nothing to fall
# back to and the promise is gone -- silently, for every existing project.
test_skill_documents_the_key_and_the_default() {
    grep -q 'sql_root' "$DB_SKILL"
    assertTrue 'tp-db-management names the config key' $?
    grep -q '\.turbo-plugin/sql' "$DB_SKILL"
    assertTrue 'tp-db-management still names the default root' $?
}

# tp-setup only writes blocks the shared base段 says it owns. If db is not listed there, the
# block this plugin now depends on has no authority to exist.
test_setup_base_lists_db_as_a_config_concern() {
    local line
    line="$(grep '`.turbo-plugin/config.toml`' "$SETUP_BASE" | head -n 1)"
    assertNotEquals 'setup-base names config.toml in the marker table' '' "$line"
    printf '%s' "$line" | grep -q 'db'
    assertTrue 'db is listed among the config.toml concerns' $?
}

# shellcheck source=/dev/null
. "$SHUNIT2"
