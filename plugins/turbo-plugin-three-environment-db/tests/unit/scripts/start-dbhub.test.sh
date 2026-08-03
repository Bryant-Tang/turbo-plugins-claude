#!/usr/bin/env bash
# start-dbhub.test.sh (shUnit2)
#
# Script under test: scripts/start-dbhub.sh -- the launcher `.mcp.json` runs for the tp-dbhub
# server. Everything is asserted through --print-command, so no container is ever started.
#
# The two defects this locks down (real machine, 2026-07-31):
#   #13 `docker run -v <missing path>` CREATES a directory, so every folder a session opened in
#       collected a stray `.turbo-plugin/dbhub.local.toml/` -- an empty DIRECTORY. It then blocked
#       its own fix (no file of that name can be created) and dbhub got a directory as its config.
#   #14 `${CLAUDE_PROJECT_DIR}` is the session root, so in a multi-project workspace the config --
#       which lives inside a project -- was never found.
#
# Resolution order under test (D1): root config wins > exactly one project match > ambiguous stops
# > nothing found stops. Every stop must exit 0 (a non-zero exit shows up as a crashed MCP server)
# and must leave the filesystem untouched.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/start-dbhub.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

CONFIG_REL='.turbo-plugin/dbhub.local.toml'

setUp() {
    WS="$(mktemp -d -t turbo-dbhub-XXXXXX)"
}

tearDown() {
    [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true
}

add_config() {   # $1 = directory that should own a config
    mkdir -p "$1/.turbo-plugin"
    printf 'dsn = "sqlserver://example"\n' > "$1/$CONFIG_REL"
}

run_it() { bash "$SCRIPT_UNDER_TEST" "$@" --print-command 2>&1; }

test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'start-dbhub.sh exists' $?
}

# Nothing configured: explain where it looked, exit 0, create nothing.
test_no_config_stops_cleanly() {
    local out rc
    out="$(run_it "$WS")"; rc=$?
    assertEquals 'exit 0 so the MCP server is not reported as crashed' 0 "$rc"
    echo "$out" | grep -q 'no database config found'; assertTrue 'says nothing was found' $?
    echo "$out" | grep -q 'docker'; assertFalse 'does not emit a docker command' $?
    [ -e "$WS/.turbo-plugin" ]; assertFalse 'created nothing (the #13 regression)' $?
}

# A config one level down is found -- this is the multi-project workspace case (#14).
test_single_project_config_is_found() {
    add_config "$WS/proj-1"
    local out
    out="$(run_it "$WS")"
    echo "$out" | grep -q "proj-1"; assertTrue 'resolved the project config' $?
    echo "$out" | grep -q ':/dbhub.toml'; assertTrue 'mounted it at /dbhub.toml' $?
    echo "$out" | grep -q 'bytebase/dbhub:latest'; assertTrue 'runs the dbhub image' $?
}

# Ambiguity is not resolved by guessing: which database you connect to is not a recoverable slip.
test_multiple_project_configs_stop_and_list() {
    add_config "$WS/proj-1"
    add_config "$WS/proj-2"
    local out rc
    out="$(run_it "$WS")"; rc=$?
    assertEquals 'exit 0' 0 "$rc"
    echo "$out" | grep -q 'ambiguous'; assertTrue 'says it is ambiguous' $?
    echo "$out" | grep -q 'proj-1'; assertTrue 'lists the first candidate' $?
    echo "$out" | grep -q 'proj-2'; assertTrue 'lists the second candidate' $?
    echo "$out" | grep -q '^docker$'; assertFalse 'emits no docker command' $?
}

# A workspace-root config is how the user settles that ambiguity, so it must win outright.
test_root_config_wins_over_projects() {
    add_config "$WS/proj-1"
    add_config "$WS/proj-2"
    add_config "$WS"
    local out
    out="$(run_it "$WS")"
    echo "$out" | grep -q 'ambiguous'; assertFalse 'no longer ambiguous' $?
    echo "$out" | grep -q 'proj-'; assertFalse 'did not pick a project config' $?
    echo "$out" | grep -q "$CONFIG_REL"; assertTrue 'mounted the root config' $?
}

# A DIRECTORY named like the config must not be treated as one -- that is exactly the state #13
# left behind, and mounting it would hand dbhub a directory.
test_directory_named_like_config_is_not_used() {
    mkdir -p "$WS/.turbo-plugin/dbhub.local.toml"
    local out rc
    out="$(run_it "$WS")"; rc=$?
    assertEquals 'exit 0' 0 "$rc"
    echo "$out" | grep -q 'no database config found'; assertTrue 'treated the directory as "not a config"' $?
}

# Deeper nesting is deliberately NOT searched: which database you connect to must not depend on
# how far down someone buried a file.
test_does_not_search_deeper_than_one_level() {
    add_config "$WS/group/proj-1"
    local out
    out="$(run_it "$WS")"
    echo "$out" | grep -q 'no database config found'; assertTrue 'two levels down is not searched' $?
}

test_missing_session_root_stops_cleanly() {
    local out rc
    out="$(bash "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertEquals 'exit 0 with no argument' 0 "$rc"
    echo "$out" | grep -q 'session root'; assertTrue 'explains the missing argument' $?

    out="$(run_it "$WS/does-not-exist")"; rc=$?
    assertEquals 'exit 0 for a non-directory root' 0 "$rc"
    echo "$out" | grep -q 'not a directory'; assertTrue 'explains the bad root' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
