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
SKILL_ASSETS="$PLUGIN_ROOT/skills/tp-db-management/assets"
MODULE_TEMPLATE="$SKILL_ASSETS/module-script-template.sql"

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

# --- _modules/ fixed-filename half -------------------------------------------------------------
#
# Everything below guards a failure that produces NO error when it happens. The whole point of
# the fixed-filename landing is to convert a silent database-level overwrite into a loud git
# conflict; each of these checks protects one of the pieces that makes that trade pay off.

# A dangling asset link is silent in the worst way: the agent follows it, finds nothing, and
# invents its own layout for a file whose whole value is that the layout is fixed.
test_every_skill_asset_link_resolves() {
    local link count=0
    for link in $(grep -oE '\(\./assets/[A-Za-z0-9._-]+\)' "$DB_SKILL" | tr -d '()' ); do
        count=$((count + 1))
        assertTrue "SKILL links ./assets/${link#./assets/} but the file is missing" \
            "[ -f '$SKILL_ASSETS/${link#./assets/}' ]"
    done
    # A scan that silently matched nothing would pass the loop above without asserting anything.
    assertTrue "expected at least the two SQL templates to be linked, found $count" \
        "[ '$count' -ge 2 ]"
}

test_module_template_exists_and_is_not_empty() {
    assertTrue "the _modules/ half has its own template: $MODULE_TEMPLATE" \
        "[ -s '$MODULE_TEMPLATE' ]"
}

# These two SET options persist WITH the object. A template that omits them produces files that
# run fine and leave the object behaving differently (index views, computed-column indexes) --
# nothing errors, and the difference is invisible until something much later depends on it.
test_module_template_carries_both_persisted_set_options() {
    grep -q 'SET ANSI_NULLS' "$MODULE_TEMPLATE"
    assertTrue 'module template sets ANSI_NULLS (persists with the object)' $?
    grep -q 'SET QUOTED_IDENTIFIER' "$MODULE_TEMPLATE"
    assertTrue 'module template sets QUOTED_IDENTIFIER (persists with the object)' $?
}

# ...and they must stay PLACEHOLDERS. Pre-filling ON is the tempting "helpful" edit, and it is
# wrong in the one direction that matters: an object scripted with ANSI_NULLS OFF gets silently
# flipped to ON by whoever copies the template without re-reading the baseline. Nothing errors --
# the object simply starts behaving differently. Almost every object is ON, which is precisely
# what makes the rare OFF so easy to lose.
test_module_template_does_not_prefill_the_set_option_values() {
    local opt
    for opt in ANSI_NULLS QUOTED_IDENTIFIER; do
        if grep -qE "^[[:space:]]*SET[[:space:]]+$opt[[:space:]]+(ON|OFF)" "$MODULE_TEMPLATE"; then
            fail "module template pre-fills SET $opt; it must stay a placeholder so the baseline is re-read"
        fi
    done
}

# DROP + CREATE silently strips every GRANT on the object, and if the CREATE half fails the
# object is simply gone -- for a trigger that means auditing stops from that moment with no
# error anywhere. CREATE OR ALTER is the entire reason this landing can exist.
test_module_template_uses_create_or_alter_and_never_drops() {
    grep -q 'CREATE OR ALTER' "$MODULE_TEMPLATE"
    assertTrue 'module template uses CREATE OR ALTER' $?
    local obj
    for obj in PROCEDURE VIEW FUNCTION TRIGGER; do
        if grep -qE "^[[:space:]]*DROP[[:space:]]+$obj" "$MODULE_TEMPLATE"; then
            fail "module template has an active DROP $obj; that strips GRANTs and can lose the object"
        fi
    done
}

# CREATE OR ALTER must be the first statement in its batch, so it cannot sit inside TRY/CATCH or
# an explicit transaction -- which is exactly why this template is separate from the <slug> one.
# If someone "unifies" them by pasting the transaction wrapper back in, the separation is gone.
test_module_template_is_not_wrapped_in_a_transaction() {
    local forbidden
    for forbidden in 'BEGIN TRANSACTION' 'BEGIN TRY'; do
        if grep -qE "^[[:space:]]*$forbidden" "$MODULE_TEMPLATE"; then
            fail "module template opens '$forbidden'; CREATE OR ALTER must be first in its batch"
        fi
    done
}

# The baseline for main-db MUST come from production, and OBJECT_DEFINITION is the tempting
# shortcut that ruins it twice over: it drops the two SET lines above, and SSMS truncates the
# result silently (65535 in the grid, 8192 in text mode) so a long procedure arrives cut in half.
test_skill_rules_out_object_definition_as_the_baseline_source() {
    grep -q 'OBJECT_DEFINITION' "$DB_SKILL"
    assertTrue 'tp-db-management warns against OBJECT_DEFINITION for the baseline' $?
}

# _modules/ sits alongside the <slug> folders, so it lands in the "pick an existing folder"
# candidate list unless something filters it out. Picking it is silent: one-shot scripts then
# get written into the reserved folder and nothing objects.
test_skill_keeps_the_reserved_folder_out_of_slug_candidates() {
    grep -q '_modules' "$DB_SKILL"
    assertTrue 'tp-db-management names the reserved _modules folder' $?
    grep -q '底線開頭' "$DB_SKILL"
    assertTrue 'tp-db-management states the leading-underscore rule for slug candidates' $?
}

# shellcheck source=/dev/null
. "$SHUNIT2"
