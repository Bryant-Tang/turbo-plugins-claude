#!/usr/bin/env bash
# install-svn.test.sh (shUnit2)
#
# Under test: tools/install-svn.sh, the retry wrapper both `Install Subversion` steps call.
#
# Why this suite exists: the thing it protects fails SILENTLY. A loop that retries zero times, or
# that drops the `Acquire::*::Timeout` options, behaves identically to a working one on every run
# where the network happens to be fine -- and the only signal on the runs where it is not is the
# thing this script was written to remove (a human noticing and pressing rerun). So the retry COUNT
# and the presence of the timeout options are asserted directly, against fake package managers, and
# never inferred from "the step went green".
#
# The fakes record every invocation and fail the first N attempts, which is what makes "did it
# actually retry?" a question with an answer.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"
SCRIPT_UNDER_TEST="$TOOLS_DIR/install-svn.sh"

SHIM=''
LOG=''

oneTimeSetUp() {
    SHIM="$(mktemp -d 2>/dev/null || mktemp -d -t svninst)"

    # `sudo` is not available on every machine that runs this suite, and asking for real privilege
    # escalation in a unit test would be absurd. The fake makes `sudo apt-get ...` collapse to
    # `apt-get ...`, which is exactly the part under test.
    cat > "$SHIM/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

    # Fails the first $SVN_TEST_FAIL_FIRST attempts, where an attempt is one `update` call.
    cat > "$SHIM/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$SVN_TEST_LOG"
case "$*" in
  *update)
    n="$(grep -c 'update$' "$SVN_TEST_LOG")"
    if [ "$n" -le "${SVN_TEST_FAIL_FIRST:-0}" ]; then exit 100; fi
    ;;
esac
exit 0
EOF

    cat > "$SHIM/choco" <<'EOF'
#!/usr/bin/env bash
printf 'choco %s\n' "$*" >> "$SVN_TEST_LOG"
n="$(grep -c '^choco ' "$SVN_TEST_LOG")"
if [ "$n" -le "${SVN_TEST_FAIL_FIRST:-0}" ]; then exit 1; fi
exit 0
EOF

    chmod +x "$SHIM/sudo" "$SHIM/apt-get" "$SHIM/choco"
    LOG="$SHIM/invocations.log"
    # Needed by the empty-PATH case below: with PATH stripped, `bash` itself is unreachable by
    # name, so the interpreter has to be named outright.
    BASH_BIN="$(command -v bash)"
}

oneTimeTearDown() {
    [ -n "$SHIM" ] && rm -rf "$SHIM" 2>/dev/null
    return 0
}

setUp() {
    : > "$LOG"
}

# Run the script with the fakes in front of the real tools. BACKOFF=0 so the retries do not sleep;
# the sleep is not what is being tested and a real one would make this suite take a minute.
run_it() {
    local platform="$1" fail_first="${2:-0}" attempts="${3:-3}"
    PATH="$SHIM:$PATH" \
    SVN_TEST_LOG="$LOG" \
    SVN_TEST_FAIL_FIRST="$fail_first" \
    SVN_INSTALL_ATTEMPTS="$attempts" \
    SVN_INSTALL_BACKOFF=0 \
        bash "$SCRIPT_UNDER_TEST" "$platform" 2>>"$LOG.err"
}

# `grep -c` prints 0 AND exits 1 when there is no match, so the obvious `grep -c ... || echo 0`
# emits TWO lines and every count comparison against it fails with "expected 0 but was 0\n0".
count_in_log() {
    local n
    n="$(grep -c "$1" "$LOG" 2>/dev/null)" || n=0
    printf '%s' "$n"
}

test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'tools/install-svn.sh exists' $?
}

test_linux_installs_without_retrying_when_apt_is_healthy() {
    local rc updates installs
    run_it linux 0; rc=$?
    updates="$(count_in_log 'update$')"
    installs="$(count_in_log 'install -y subversion')"
    assertEquals 'exit 0 on a clean install' 0 "$rc"
    assertEquals 'exactly one apt-get update' 1 "$updates"
    assertEquals 'exactly one apt-get install' 1 "$installs"
}

# The point of the whole script. A wrapper that silently gave up after one go would still pass the
# test above.
test_linux_retries_until_apt_succeeds() {
    local rc updates
    run_it linux 2; rc=$?
    updates="$(count_in_log 'update$')"
    assertEquals 'exit 0 once a later attempt succeeds' 0 "$rc"
    assertEquals 'took three attempts (two failures, then success)' 3 "$updates"
}

# The other half: it must stop, and it must say so. Exhausting the attempts is a real failure --
# the workflow's `Verify Subversion is usable` step is what turns it red, and it can only do that
# if this script does not pretend to have succeeded.
test_linux_gives_up_after_the_configured_attempts() {
    local rc updates err
    run_it linux 99 3; rc=$?
    updates="$(count_in_log 'update$')"
    assertNotEquals 'a non-zero exit when every attempt failed' 0 "$rc"
    assertEquals 'stopped at exactly the configured attempt count' 3 "$updates"
    err="$(grep -c 'could not install subversion' "$LOG.err" 2>/dev/null)" || err=0
    assertEquals 'said why, on stderr' 1 "$err"
}

# Without these, the retry loop is decoration: apt hangs instead of failing, so the second
# iteration never happens. This is the assertion that pins the actual 2026-08-18/19 fix.
test_linux_bounds_apt_with_acquire_timeouts() {
    local http https retries
    run_it linux 0
    http="$(count_in_log 'Acquire::http::Timeout')"
    https="$(count_in_log 'Acquire::https::Timeout')"
    retries="$(count_in_log 'Acquire::Retries')"
    assertTrue 'passes an http timeout to apt' "[ $http -ge 1 ]"
    assertTrue 'passes an https timeout to apt' "[ $https -ge 1 ]"
    assertTrue 'passes a fetch-level retry count to apt' "[ $retries -ge 1 ]"
}

test_windows_retries_choco() {
    local rc chocos apts
    run_it windows 1; rc=$?
    chocos="$(count_in_log '^choco ')"
    apts="$(count_in_log '^apt-get ')"
    assertEquals 'exit 0 once choco succeeds' 0 "$rc"
    assertEquals 'took two attempts (one 503, then success)' 2 "$chocos"
    assertEquals 'never touched apt on windows' 0 "$apts"
}

test_windows_installs_sliksvn_not_the_svn_package() {
    # choco's `svn` is win32svn, pinned at 1.8.15 -- older than `svn info --show-item`, which these
    # scripts use throughout. Installing it would run the suite and fail ~40 cases with "invalid
    # option", which reads as a product bug and is not one.
    local slik
    run_it windows 0
    slik="$(count_in_log 'choco install sliksvn')"
    assertEquals 'installs sliksvn' 1 "$slik"
}

test_linux_never_calls_choco() {
    local chocos
    run_it linux 0
    chocos="$(count_in_log '^choco ')"
    assertEquals 'linux does not reach for choco' 0 "$chocos"
}

test_unknown_platform_is_rejected() {
    local rc
    run_it solaris 0; rc=$?
    assertEquals 'an unrecognised platform is a usage error, not a silent no-op' 2 "$rc"
}

# A package manager missing from PATH used to surface one step later as the generic "svn is not
# installed", which sends the reader looking at the wrong thing entirely.
test_missing_package_manager_is_its_own_error() {
    local rc out
    out="$(PATH="$SHIM/nonexistent" SVN_TEST_LOG="$LOG" SVN_INSTALL_BACKOFF=0 \
            "$BASH_BIN" "$SCRIPT_UNDER_TEST" linux 2>&1)"
    rc=$?
    assertEquals 'exits 2, distinct from "tried and failed"' 2 "$rc"
    case "$out" in
        *'no package manager on PATH'*) : ;;
        *) fail "expected a package-manager-specific message, got: $out" ;;
    esac
}

# shellcheck source=/dev/null
. "$SHUNIT2"
