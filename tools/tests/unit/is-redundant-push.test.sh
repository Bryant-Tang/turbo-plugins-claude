#!/usr/bin/env bash
# is-redundant-push.test.sh (shUnit2)
#
# Script under test: tools/is-redundant-push.sh
# Output contract: exactly `true` or `false`; exit 0 for every answer, 2 for a usage error.
#
# Getting this wrong in the `true` direction is INVISIBLE: the run is suppressed, no job reports,
# and a commit ships with nothing behind it. Getting it wrong in the `false` direction costs runner
# minutes and nothing else. So most of the cases below pin the fail-open side -- every form of "we
# could not tell" must answer `false`.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$TOOLS_DIR/is-redundant-push.sh"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"

RC=0
ask() {
    local out
    out="$(bash "$SCRIPT_UNDER_TEST" "$@" 2>/dev/null)"
    RC=$?
    printf '%s' "$out"
}

test_script_exists() {
    assertTrue 'the script under test exists' "[ -f '$SCRIPT_UNDER_TEST' ]"
}

# The one case that suppresses a run: a push whose branch already has an open PR, so the
# pull_request run is testing this exact commit anyway.
test_push_with_an_open_pr_is_redundant() {
    assertEquals 'true' "$(ask push 1)"
    assertEquals 'exit 0' 0 "$RC"
    assertEquals 'more than one open PR is still redundant' 'true' "$(ask push 3)"
}

test_push_without_an_open_pr_runs() {
    assertEquals 'false' "$(ask push 0)"
}

# A pull_request run is the one being deferred TO; suppressing it would leave nothing at all.
test_pull_request_is_never_redundant() {
    assertEquals 'false' "$(ask pull_request 1)"
}

# Someone asking for a run by hand means they want it, regardless of what else exists.
test_workflow_dispatch_is_never_redundant() {
    assertEquals 'false' "$(ask workflow_dispatch 1)"
}

# ── the fail-open guarantees ────────────────────────────────────────────────
# Each of these is a way the API call can come back useless. All of them must run the tests: a
# suppressed run leaves NO check behind, so the mistake is invisible in exactly the direction this
# repo has been bitten by before.
test_unknown_count_runs_rather_than_skips() {
    assertEquals 'an empty count (call failed or never made)' 'false' "$(ask push '')"
    assertEquals 'a null from --jq on an error body' 'false' "$(ask push null)"
    assertEquals 'an error message where a number was expected' 'false' "$(ask push 'gh: not found')"
    assertEquals 'a negative number is not a count' 'false' "$(ask push -1)"
    assertEquals 'a decimal is not a count' 'false' "$(ask push 1.0)"
    assertEquals 'leading whitespace is not silently trimmed into a number' 'false' "$(ask push ' 1')"
}

# The count argument may legitimately be absent (the workflow only queries on push events), and
# that must behave like "unknown", not crash the step.
test_missing_count_is_not_a_usage_error() {
    assertEquals 'false' "$(ask push)"
    assertEquals 'exit 0' 0 "$RC"
}

test_missing_event_is_a_usage_error() {
    ask
    assertEquals 2 "$RC"
}

# shellcheck source=/dev/null
. "$SHUNIT2"
