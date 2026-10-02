#!/usr/bin/env bash
# start-dbhub-install.test.sh (shUnit2)
#
# Script under test: scripts/start-dbhub.js -- the part AFTER config resolution: installing the
# pinned dbhub into the plugin's data directory and starting it from there. npm is replaced by
# assets/fake-npm-cli.js (via TP_DBHUB_NPM_CLI), so nothing is downloaded.
#
# The defect this locks down (issue #200, 2026-10-02): the launcher used `npx`, whose first start
# of a new version takes about a minute. Claude Code gave up on the server before that, the install
# was cut off, and npm left a cache directory with node_modules/ but no package.json. Every later
# start died on reading that package.json; the server stayed CONNECTION_CLOSED until someone found
# the directory and deleted it by hand. What must hold now:
#   - an install that did not finish is never mistaken for one that did;
#   - the install survives the launcher being killed, so the next connect just works;
#   - nothing npm prints reaches stdout, which is the MCP protocol channel.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/start-dbhub.js"
FAKE_NPM="$SCRIPT_DIR/assets/fake-npm-cli.js"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

VERSION_RE='[0-9]+\.[0-9]+\.[0-9]+'

setUp() {
    WS="$(mktemp -d -t turbo-dbhub-inst-XXXXXX)"
    if ! command -v node >/dev/null 2>&1; then
        startSkipping
        return
    fi
    mkdir -p "$WS/proj/.turbo-plugin"
    printf 'dsn = "sqlserver://example"\n' > "$WS/proj/.turbo-plugin/dbhub.local.toml"
    export CLAUDE_PLUGIN_DATA="$WS/data"
    export TP_DBHUB_NPM_CLI="$FAKE_NPM"
    export FAKE_NPM_CALLS="$WS/npm-calls"
    unset FAKE_NPM_MODE FAKE_NPM_DELAY_MS
    VERSION="$(grep -oE "@bytebase/dbhub@${VERSION_RE}" "$SCRIPT_UNDER_TEST" | head -1 | sed 's|.*@||')"
    INSTALL_DIR="$WS/data/dbhub/$VERSION"
}

tearDown() {
    unset CLAUDE_PLUGIN_DATA TP_DBHUB_NPM_CLI FAKE_NPM_CALLS FAKE_NPM_MODE FAKE_NPM_DELAY_MS
    [ -n "${WS:-}" ] && rm -rf "$WS" 2>/dev/null || true
}

launch() {   # stdout -> $WS/out, stderr -> $WS/err, returns the exit code
    node "$SCRIPT_UNDER_TEST" "$WS" </dev/null >"$WS/out" 2>"$WS/err"
}

npm_calls() { [ -f "$FAKE_NPM_CALLS" ] && wc -l <"$FAKE_NPM_CALLS" | tr -d ' ' || echo 0; }

test_first_start_installs_then_runs_dbhub() {
    launch; local rc=$?
    assertEquals 'exit code is dbhub'"'"'s' 0 "$rc"
    assertEquals 'npm ran once' 1 "$(npm_calls)"
    grep -q '^FAKE-DBHUB --transport stdio --config .*proj' "$WS/out"
    assertTrue 'dbhub was started with the resolved config' $?
    grep -q 'added 1 package' "$WS/out"
    assertFalse 'npm output did not reach stdout (the MCP channel)' $?
    assertEquals 'stdout holds only what dbhub wrote' 1 "$(wc -l <"$WS/out" | tr -d ' ')"
    [ -f "$INSTALL_DIR/.tp-installed" ]; assertTrue 'marked as installed' $?
    [ -e "$INSTALL_DIR.lock" ]; assertFalse 'lock released' $?
    ls -d "$INSTALL_DIR".staging-* >/dev/null 2>&1; assertFalse 'no staging directory left' $?
}

test_second_start_does_not_touch_npm() {
    launch
    export FAKE_NPM_MODE=fail
    launch
    assertEquals 'npm ran only for the first start' 1 "$(npm_calls)"
    grep -q '^FAKE-DBHUB ' "$WS/out"; assertTrue 'dbhub started from the existing install' $?
}

# The exact #200 shape: packages present, but the install never finished. Must not be used as-is.
test_half_finished_install_is_redone() {
    mkdir -p "$INSTALL_DIR/node_modules/@bytebase/dbhub/dist"
    printf 'process.stdout.write("STALE\\n")\n' >"$INSTALL_DIR/node_modules/@bytebase/dbhub/dist/index.js"
    launch
    assertEquals 'reinstalled' 1 "$(npm_calls)"
    grep -q 'STALE' "$WS/out"; assertFalse 'the unfinished install was not run' $?
    grep -q '^FAKE-DBHUB ' "$WS/out"; assertTrue 'the fresh install was run' $?
}

test_failed_install_explains_and_keeps_nothing() {
    export FAKE_NPM_MODE=fail
    launch; local rc=$?
    assertEquals 'exit 0 so the MCP server is not reported as crashed' 0 "$rc"
    assertEquals 'nothing on stdout' 0 "$(wc -c <"$WS/out" | tr -d ' ')"
    grep -q 'did not finish' "$WS/err"; assertTrue 'says the install did not finish' $?
    grep -q 'E404' "$WS/err"; assertTrue 'shows the npm error from the log' $?
    [ -e "$INSTALL_DIR" ]; assertFalse 'no install directory' $?
    [ -e "$INSTALL_DIR.lock" ]; assertFalse 'lock released, so a reconnect retries' $?
    ls -d "$INSTALL_DIR".staging-* >/dev/null 2>&1; assertFalse 'no staging directory left' $?
}

# Claude Code gives up on a slow server and kills it. The install must carry on regardless, so the
# next connect is a normal start instead of a permanently broken one.
test_install_survives_the_launcher_being_killed() {
    export FAKE_NPM_MODE=slow FAKE_NPM_DELAY_MS=3000
    node "$SCRIPT_UNDER_TEST" "$WS" </dev/null >"$WS/out" 2>"$WS/err" &
    local pid=$!
    sleep 1
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    [ -f "$INSTALL_DIR/.tp-installed" ]; assertFalse 'not installed yet when the launcher died' $?

    local i
    for i in $(seq 1 40); do
        [ -f "$INSTALL_DIR/.tp-installed" ] && [ ! -e "$INSTALL_DIR.lock" ] && break
        sleep 0.25
    done
    [ -f "$INSTALL_DIR/.tp-installed" ]; assertTrue 'the detached install finished on its own' $?

    unset FAKE_NPM_MODE
    launch
    assertEquals 'the next start did not install again' 1 "$(npm_calls)"
    grep -q '^FAKE-DBHUB ' "$WS/out"; assertTrue 'the next start runs dbhub' $?
}

# A lock left by an installer that is gone must not make every later start wait forever.
test_lock_of_a_dead_installer_is_taken_over() {
    mkdir -p "$INSTALL_DIR.lock"
    printf '999999\n' >"$INSTALL_DIR.lock/pid"
    launch
    grep -q '^FAKE-DBHUB ' "$WS/out"; assertTrue 'installed and ran despite the stale lock' $?
    assertEquals 'installed once' 1 "$(npm_calls)"
}

# Two sessions opening together must download once, and both must end up running dbhub.
test_two_launchers_at_once_install_once() {
    export FAKE_NPM_MODE=slow FAKE_NPM_DELAY_MS=1500
    node "$SCRIPT_UNDER_TEST" "$WS" </dev/null >"$WS/out1" 2>"$WS/err1" &
    local p1=$!
    node "$SCRIPT_UNDER_TEST" "$WS" </dev/null >"$WS/out2" 2>"$WS/err2" &
    local p2=$!
    wait "$p1" "$p2"
    assertEquals 'npm ran once for both' 1 "$(npm_calls)"
    grep -q '^FAKE-DBHUB ' "$WS/out1"; assertTrue 'first launcher runs dbhub' $?
    grep -q '^FAKE-DBHUB ' "$WS/out2"; assertTrue 'second launcher runs dbhub' $?
}

# The installer a launcher is WAITING on dies (the session that started it was closed). The waiter
# must install by itself, not report "did not finish" and leave the user to reconnect.
test_waiter_takes_over_when_the_installer_dies() {
    # The holder is a node process reporting its OWN pid: under Git Bash, $! of a background job is
    # an MSYS pid that node (a native Windows program) does not know, so it would read as dead.
    node -e 'process.stdout.write(String(process.pid)); setTimeout(function () {}, 2000)' >"$WS/holder-pid" &
    local holder=$!
    local i
    for i in $(seq 1 40); do [ -s "$WS/holder-pid" ] && break; sleep 0.05; done
    mkdir -p "$INSTALL_DIR.lock"
    cp "$WS/holder-pid" "$INSTALL_DIR.lock/pid"
    launch
    wait "$holder" 2>/dev/null
    grep -q 'waiting' "$WS/err"; assertTrue 'it waited for the live installer first' $?
    grep -q '^FAKE-DBHUB ' "$WS/out"; assertTrue 'then installed and ran dbhub itself' $?
    assertEquals 'installed once' 1 "$(npm_calls)"
}

# A version bump leaves the previous version's few hundred packages behind; nothing runs them again.
test_other_versions_are_removed_after_install() {
    local old="$WS/data/dbhub/0.0.1"
    mkdir -p "$old/node_modules"
    printf 'x\n' >"$WS/data/dbhub/0.0.1.install.log"
    launch
    [ -f "$INSTALL_DIR/.tp-installed" ]; assertTrue 'current version installed' $?
    [ -e "$old" ]; assertFalse 'old version removed' $?
    [ -e "$WS/data/dbhub/0.0.1.install.log" ]; assertFalse 'old install log removed' $?
}

# Without CLAUDE_PLUGIN_DATA the install falls back to the temp directory. On a shared host that
# directory could have been created by someone else and pre-filled; running from it would run their
# code as us. A fallback directory others can write to is refused.
test_temp_fallback_writable_by_others_is_refused() {
    if [ "$(uname -s 2>/dev/null | cut -c1-5)" != 'Linux' ] && [ "$(uname -s)" != 'Darwin' ]; then
        startSkipping
    fi
    unset CLAUDE_PLUGIN_DATA
    export TMPDIR="$WS/tmp"
    mkdir -p "$TMPDIR"
    local user root
    user="$(node -e 'process.stdout.write(require("os").userInfo().username.replace(/[^A-Za-z0-9._-]/g,"_"))')"
    root="$TMPDIR/turbo-plugin-three-environment-db-$user"
    mkdir -p "$root"
    chmod 777 "$root"
    launch; local rc=$?
    unset TMPDIR
    assertEquals 'exit 0' 0 "$rc"
    grep -q 'refusing' "$WS/err"; assertTrue 'refuses the shared directory' $?
    assertEquals 'npm never ran' 0 "$(npm_calls)"
    assertEquals 'nothing on stdout' 0 "$(wc -c <"$WS/out" | tr -d ' ')"
}

# The same fallback, created fresh, is private to us and works.
test_temp_fallback_is_created_private() {
    if [ "$(uname -s 2>/dev/null | cut -c1-5)" != 'Linux' ] && [ "$(uname -s)" != 'Darwin' ]; then
        startSkipping
    fi
    unset CLAUDE_PLUGIN_DATA
    export TMPDIR="$WS/tmp"
    mkdir -p "$TMPDIR"
    launch
    unset TMPDIR
    grep -q '^FAKE-DBHUB ' "$WS/out"; assertTrue 'installed and ran from the fallback' $?
    local root
    root="$(ls -d "$WS/tmp"/turbo-plugin-three-environment-db-* 2>/dev/null | head -1)"
    [ -n "$root" ]; assertTrue 'fallback directory is per user' $?
    [ -n "$(find "$root" -maxdepth 0 -perm -o+w 2>/dev/null)" ]; assertFalse 'not writable by others' $?
}

# shellcheck disable=SC1090
. "$SHUNIT2"
