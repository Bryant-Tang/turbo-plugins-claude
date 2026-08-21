#!/usr/bin/env bash
# start-dbhub.test.sh (shUnit2)
#
# Script under test: scripts/start-dbhub.js -- the launcher `.mcp.json` runs for the tp-dbhub
# server. Everything is asserted through --print-command, so dbhub is never actually started.
#
# There is ONE launcher (a .js) rather than the usual .ps1 + .sh pair, because a plugin's
# `.mcp.json` takes a literal command with no per-platform branch and Claude Code spawns it RAW
# against the OS PATH -- where, on Windows, `bash` is the WSL relay and `sh` does not exist.
# `node` is the only interpreter on PATH under the same name everywhere. This suite and its Pester
# twin drive that single launcher from both harnesses, so the pair rule's real goal -- the two
# platforms cannot drift -- is still enforced.
#
# The two defects this locks down (real machine, 2026-07-31):
#   #13 `docker run -v <missing path>` CREATES a directory, so every folder a session opened in
#       collected a stray `.turbo-plugin/dbhub.local.toml/` -- an empty DIRECTORY. It then blocked
#       its own fix (no file of that name can be created) and dbhub got a directory as its config.
#       Running the npm package takes no mount at all, so the whole class is now impossible; the
#       "creates nothing" assertions stay as the regression lock.
#   #14 `${CLAUDE_PROJECT_DIR}` is the session root, so in a multi-project workspace the config --
#       which lives inside a project -- was never found.
#
# Resolution order under test (D1): root config wins > exactly one project match > ambiguous stops
# > nothing found stops. Every stop must exit 0 (a non-zero exit shows up as a crashed MCP server)
# and must leave the filesystem untouched.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/start-dbhub.js"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

CONFIG_REL='.turbo-plugin/dbhub.local.toml'
DBHUB_SPEC='@bytebase/dbhub@1.2.0'

setUp() {
    WS="$(mktemp -d -t turbo-dbhub-XXXXXX)"
    # Gate per-test rather than once: shUnit2 re-enables asserts between tests, so a one-time
    # startSkipping would not hold. Missing tooling SKIPs, it does not FAIL.
    if ! command -v node >/dev/null 2>&1; then
        startSkipping
    fi
}

tearDown() {
    [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true
}

add_config() {   # $1 = directory that should own a config
    mkdir -p "$1/.turbo-plugin"
    printf 'dsn = "sqlserver://example"\n' > "$1/$CONFIG_REL"
}

run_it() { node "$SCRIPT_UNDER_TEST" "$@" --print-command 2>&1; }

test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'start-dbhub.js exists' $?
}

# Nothing configured: explain where it looked, exit 0, create nothing.
test_no_config_stops_cleanly() {
    local out rc
    out="$(run_it "$WS")"; rc=$?
    assertEquals 'exit 0 so the MCP server is not reported as crashed' 0 "$rc"
    echo "$out" | grep -q 'no database config found'; assertTrue 'says nothing was found' $?
    echo "$out" | grep -q 'npx'; assertFalse 'does not emit a run command' $?
    # Both template names, because this branch is reachable for projects on either one: the
    # template is present, only the filled-in config is missing. Naming just the current one sends
    # anyone set up before the rename looking for a file that is not in their directory.
    echo "$out" | grep -qF 'dbhub.example.toml'
    assertTrue 'names the current template' $?
    echo "$out" | grep -qF 'dbhub.example.local.toml'
    assertTrue 'also names the pre-rename template' $?
    [ -e "$WS/.turbo-plugin" ]; assertFalse 'created nothing (the #13 regression)' $?
}

# A config one level down is found -- this is the multi-project workspace case (#14).
test_single_project_config_is_found() {
    add_config "$WS/proj-1"
    local out
    out="$(run_it "$WS")"
    echo "$out" | grep -q "proj-1"; assertTrue 'resolved the project config' $?
    echo "$out" | grep -q -- '--config'; assertTrue 'passed it as --config' $?
    echo "$out" | grep -qF "$DBHUB_SPEC"; assertTrue 'runs the pinned dbhub package' $?
    echo "$out" | grep -qx -- '-v'; assertFalse 'no bind mount, so no path can be created for us' $?
}

# The pin is load-bearing: a floating spec trades "may go stale" for "may break with no diagnosis",
# and only the first of those can be covered by a reminder.
test_dbhub_version_is_pinned() {
    add_config "$WS"
    local out
    out="$(run_it "$WS")"
    echo "$out" | grep -qE '@bytebase/dbhub@[0-9]+\.[0-9]+\.[0-9]+$'; assertTrue 'exact version, not a range or latest' $?
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
    echo "$out" | grep -q '^npx$'; assertFalse 'emits no run command' $?
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
    echo "$out" | grep -q "dbhub.local.toml"; assertTrue 'used the root config' $?
}

# A DIRECTORY named like the config must not be treated as one -- that is exactly the state #13
# left behind, and handing it to dbhub would pass a directory as the config.
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
    out="$(node "$SCRIPT_UNDER_TEST" 2>&1)"; rc=$?
    assertEquals 'exit 0 with no argument' 0 "$rc"
    echo "$out" | grep -q 'session root'; assertTrue 'explains the missing argument' $?

    out="$(run_it "$WS/does-not-exist")"; rc=$?
    assertEquals 'exit 0 for a non-directory root' 0 "$rc"
    echo "$out" | grep -q 'not a directory'; assertTrue 'explains the bad root' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
