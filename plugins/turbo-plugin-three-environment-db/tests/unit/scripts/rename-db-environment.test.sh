#!/usr/bin/env bash
# rename-db-environment.test.sh (shUnit2)
#
# Script under test: scripts/rename-db-environment.sh -- the migration that renames one database
# environment folder AND rewrites the environment name inside every .sql header under it.
#
# Why the header rewrite is part of the contract, not a nicety: a .sql file records which
# environment it targets, and (for a _modules/ baseline) which environment the baseline was taken
# from. Renaming only the directory leaves every one of those files asserting something false --
# and those fields are the only way to tell a trustworthy baseline from a dangerous one. There is
# no symptom; the SQL still runs.
#
# The behaviours locked down here:
#   - DRY RUN IS THE DEFAULT. Anything else would make a mistyped argument rewrite hundreds of
#     files with no warning.
#   - WORD BOUNDARIES. Renaming `test` to `test-db` must not turn an existing `test-db` into
#     `test-db-db`. A naive substring replace does exactly that, and the corruption is silent.
#   - REFUSES TO MERGE. If the target folder already exists the run stops and changes nothing;
#     merging two environments is not recoverable by re-running anything.
#   - COMMENTED-OUT CONFIG LINES ARE NOT CONFIG. Only an uncommented `environments =` is updated.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/rename-db-environment.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

setUp() {
    WS="$(mktemp -d -t tp-ren-XXXXXX)"
}

tearDown() {
    [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true
}

# Build a workspace: sql tree with $1 as the environment folder, plus one one-off script and one
# _modules baseline, both carrying the environment name in their header.
make_ws() {   # $1 = environment folder name
    local env="$1"
    mkdir -p "$WS/.turbo-plugin/sql/$env/feat-x"
    mkdir -p "$WS/.turbo-plugin/sql/$env/_modules/AppDb/Procedures"
    {
        printf '/*\n'
        printf '目標環境: %s\n' "$env"
        printf -- '- <sql_root>/%s/feat-x/01.sql\n' "$env"
        printf '*/\nSELECT 1;\n'
    } > "$WS/.turbo-plugin/sql/$env/feat-x/01-AppDb-fill.sql"
    {
        printf '/*\n'
        printf '目標環境: %s\n' "$env"
        printf '基線來源環境: %s\n' "$env"
        printf '*/\nCREATE OR ALTER PROCEDURE dbo.X AS BEGIN SET NOCOUNT ON; END;\n'
    } > "$WS/.turbo-plugin/sql/$env/_modules/AppDb/Procedures/dbo.X.sql"
}

write_config() {   # $1 = the environments line body, e.g. '["local-db", "test-db"]'
    mkdir -p "$WS/.turbo-plugin"
    {
        printf '# >>> turbo-plugin:db >>>\n'
        printf '[db]\n'
        printf '# environments = ["commented-local-db"]\n'
        printf 'environments = %s\n' "$1"
        printf '# <<< turbo-plugin:db <<<\n'
    } > "$WS/.turbo-plugin/config.toml"
}

run_it() { bash "$SCRIPT_UNDER_TEST" "$@" --root "$WS" 2>&1; }

test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'rename-db-environment.sh exists' $?
}

# The default must be harmless: report what would change, touch nothing.
test_dry_run_changes_nothing() {
    make_ws local-db
    local out rc
    out="$(run_it local-db dev-db)"; rc=$?
    assertEquals 'dry run exits 0' 0 "$rc"

    echo "$out" | grep -q 'dry run'
    assertTrue 'says it was a dry run' $?

    [ -d "$WS/.turbo-plugin/sql/local-db" ]
    assertTrue 'source folder still there' $?
    [ ! -e "$WS/.turbo-plugin/sql/dev-db" ]
    assertTrue 'target folder was not created' $?

    grep -q 'local-db' "$WS/.turbo-plugin/sql/local-db/feat-x/01-AppDb-fill.sql"
    assertTrue 'file contents untouched' $?
}

test_apply_renames_folder_and_rewrites_headers() {
    make_ws local-db
    local rc
    run_it local-db dev-db --apply >/dev/null 2>&1; rc=$?
    assertEquals 'apply exits 0' 0 "$rc"

    [ -d "$WS/.turbo-plugin/sql/dev-db" ]
    assertTrue 'folder was renamed' $?
    [ ! -e "$WS/.turbo-plugin/sql/local-db" ]
    assertTrue 'old folder is gone' $?

    # The _modules baseline is deliberately the one asserted: it carries TWO header fields
    # (target + baseline source), and the baseline-source field is the one that matters most.
    local mod="$WS/.turbo-plugin/sql/dev-db/_modules/AppDb/Procedures/dbo.X.sql"
    grep -q '目標環境: dev-db' "$mod"
    assertTrue 'target-environment header rewritten' $?
    grep -q '基線來源環境: dev-db' "$mod"
    assertTrue 'baseline-source header rewritten' $?
    grep -q 'local-db' "$mod"
    assertFalse 'no stale environment name left behind' $?

    grep -q '<sql_root>/dev-db/feat-x/01.sql' "$WS/.turbo-plugin/sql/dev-db/feat-x/01-AppDb-fill.sql"
    assertTrue 'path list in the one-off header rewritten' $?
}

# A substring replace turns the existing `test-db` into `test-db-db`, silently. This is the reason
# the replacement is boundary-anchored.
test_rename_does_not_corrupt_a_longer_name_sharing_the_prefix() {
    mkdir -p "$WS/.turbo-plugin/sql/test/feat-x"
    {
        printf '目標環境: test\n'
        printf -- '- <sql_root>/test/feat-x/01.sql\n'
        printf -- '- <sql_root>/test-db/feat-x/01.sql\n'
    } > "$WS/.turbo-plugin/sql/test/feat-x/01-AppDb-fill.sql"

    run_it test test-db --apply >/dev/null 2>&1

    local f="$WS/.turbo-plugin/sql/test-db/feat-x/01-AppDb-fill.sql"
    grep -q '目標環境: test-db' "$f"
    assertTrue 'the standalone name was renamed' $?
    grep -q 'test-db-db' "$f"
    assertFalse 'the longer name that shares the prefix was NOT touched' $?
}

test_refuses_when_target_already_exists() {
    make_ws local-db
    mkdir -p "$WS/.turbo-plugin/sql/dev-db"
    local out rc
    out="$(run_it local-db dev-db --apply)"; rc=$?
    assertNotEquals 'exits non-zero' 0 "$rc"
    echo "$out" | grep -q 'already exists'
    assertTrue 'explains that the target exists' $?
    [ -d "$WS/.turbo-plugin/sql/local-db" ]
    assertTrue 'source folder untouched after the refusal' $?
}

test_refuses_unknown_source_environment() {
    make_ws local-db
    local rc
    run_it nope dev-db --apply >/dev/null 2>&1; rc=$?
    assertNotEquals 'exits non-zero for a source that does not exist' 0 "$rc"
}

test_refuses_a_name_that_is_not_a_single_folder_name() {
    make_ws local-db
    local rc
    run_it local-db 'a/b' --apply >/dev/null 2>&1; rc=$?
    assertNotEquals 'exits non-zero for a name containing a path separator' 0 "$rc"
    [ -d "$WS/.turbo-plugin/sql/local-db" ]
    assertTrue 'nothing was renamed' $?
}

test_updates_the_uncommented_environments_line_only() {
    make_ws local-db
    write_config '["local-db", "test-db", "main-db"]'
    run_it local-db dev-db --apply >/dev/null 2>&1

    grep -q 'environments = \["dev-db", "test-db", "main-db"\]' "$WS/.turbo-plugin/config.toml"
    assertTrue 'the live environments line was updated' $?
    grep -q '# environments = \["commented-local-db"\]' "$WS/.turbo-plugin/config.toml"
    assertTrue 'the commented-out line was left exactly as it was' $?
}

# Two matches separated by exactly ONE character: the first match consumes that character as its
# right boundary, so a single pass leaves the second unmatched. This is why the substitution runs
# twice, in the file contents AND in the config line.
#
# `local-db/local-db` is the shape that does it -- reachable for real when sql_root itself ends in
# the environment name, which makes the expanded path in a "檔案落點" header read
# `.../local-db/local-db/_modules/...`. Note that a TOML array does NOT produce this: between
# `"local-db","local-db"` there are three characters, so the comma still serves as the second
# match's left boundary and one pass is enough.
test_replaces_two_names_separated_by_a_single_character() {
    make_ws local-db
    printf '檔案落點: <sql_root>/local-db/local-db/_modules/AppDb/X.sql\n' \
        > "$WS/.turbo-plugin/sql/local-db/feat-x/02-adjacent.sql"
    write_config '["local-db/local-db"]'

    run_it local-db dev-db --apply >/dev/null 2>&1

    grep -q 'dev-db/dev-db' "$WS/.turbo-plugin/sql/dev-db/feat-x/02-adjacent.sql"
    assertTrue 'both names in the file content were replaced, not just the first' $?
    grep -q 'local-db' "$WS/.turbo-plugin/sql/dev-db/feat-x/02-adjacent.sql"
    assertFalse 'no half-renamed path left in the file' $?

    grep -q 'environments = \["dev-db/dev-db"\]' "$WS/.turbo-plugin/config.toml"
    assertTrue 'both names in the config line were replaced' $?
    # Exactly one mention of the old name may survive: the commented-out sample line, which is
    # not config and must not be touched.
    assertEquals 'the sole surviving mention is the commented-out sample' 1 \
        "$(grep -c 'local-db' "$WS/.turbo-plugin/config.toml")"
}

# Without an environments key the rename still happens, but the skill would then see a folder that
# is not in its list and stop -- so the script has to say what to add.
test_says_what_to_add_when_there_is_no_environments_key() {
    make_ws local-db
    local out
    out="$(run_it local-db dev-db)"
    echo "$out" | grep -q 'environments = \["dev-db"'
    assertTrue 'suggests the line to add' $?
}

# sql_root is read from config, so a project that moved its SQL tree is still migratable.
test_honours_a_custom_sql_root_from_config() {
    mkdir -p "$WS/.turbo-plugin" "$WS/db/scripts/local-db/feat-x"
    printf '[db]\nsql_root = "db/scripts"\n' > "$WS/.turbo-plugin/config.toml"
    printf '目標環境: local-db\n' > "$WS/db/scripts/local-db/feat-x/01.sql"

    run_it local-db dev-db --apply >/dev/null 2>&1

    [ -d "$WS/db/scripts/dev-db" ]
    assertTrue 'renamed inside the configured sql_root' $?
    grep -q '目標環境: dev-db' "$WS/db/scripts/dev-db/feat-x/01.sql"
    assertTrue 'header rewritten inside the configured sql_root' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
