#!/usr/bin/env bash
# tests-passed-gate.test.sh (shUnit2)
#
# Under test: the `tests-passed` job in .github/workflows/tests.yml -- the single check branch
# protection points at.
#
# Why this exists: wiring a new job into that gate takes FOUR coordinated edits -- add it to
# `needs:`, bind its result to an env var, echo it, and add that var to the `for r in ...` loop.
# Only the last one actually gates. Miss it and the job still runs, still reports, still shows in
# the log... and its failure no longer blocks a merge. Nothing announces that; the check stays
# green because the loop it is missing from never looks at it.
#
# This was very nearly shipped while adding `inert-files-are-inert`: needs, env and echo were all
# in place and the loop was not. A rule that CLAUDE.md already states in words is worth having a
# machine enforce, because the failure is invisible in exactly the direction that matters.
#
# Reading the workflow file here is fine: `.github/` is NOT on the inert list -- any change under
# it widens to ALL.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$TOOLS_DIR/.." && pwd)"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"
WF="$REPO_ROOT/.github/workflows/tests.yml"

# The `needs: [...]` list of the gate job. The matrix jobs use the scalar form (`needs: discover`),
# so the bracketed form appears once and belongs to `tests-passed`.
gate_needs() {
    grep -E '^[[:space:]]+needs: \[' "$WF" \
        | head -1 \
        | sed 's/.*\[//; s/\].*//' \
        | tr ',' '\n' \
        | tr -d ' '
}

# Env bindings of the shape `NAME: ${{ needs.<job>.result }}`.
gate_env_pairs() {
    grep -oE '[A-Z_]+: \$\{\{ needs\.[a-z-]+\.result \}\}' "$WF"
}

gate_loop_line() {
    grep -E 'for r in ' "$WF" | head -1
}

test_the_workflow_and_the_gate_are_where_this_expects() {
    local needs loop
    [ -f "$WF" ]
    assertTrue 'tests.yml exists' $?
    local pairs
    needs="$(gate_needs | grep -c .)" || needs=0
    loop="$(gate_loop_line | grep -c .)" || loop=0
    pairs="$(gate_env_pairs | grep -c .)" || pairs=0
    # Fixture guard, and it earns its place: while this file was being written, the env-pair
    # extraction silently matched nothing, and the most important assertion below -- "every bound
    # result is in the loop" -- passed against an empty list. A check that cannot fail is worse
    # than no check, because it reads as coverage.
    assertTrue 'found a bracketed needs list' "[ $needs -ge 3 ]"
    assertEquals 'found the aggregation loop' 1 "$loop"
    assertTrue 'found the result bindings' "[ $pairs -ge 3 ]"
}

# Every job the gate depends on must have its result bound to a variable. A job in `needs:` with no
# binding is a dependency that only delays the gate -- it never influences the verdict.
test_every_needed_job_has_its_result_bound() {
    local job missing=''
    while IFS= read -r job; do
        [ -n "$job" ] || continue
        if ! grep -q "needs\.${job}\.result" "$WF"; then
            missing="$missing $job"
        fi
    done < <(gate_needs)
    assertEquals "jobs in needs: with no \${{ needs.<job>.result }} binding:$missing" '' "$missing"
}

# THE one. A variable that is bound and echoed but absent from the loop reads as wired up in every
# way a human would check, and gates nothing.
test_every_bound_result_is_actually_checked_by_the_loop() {
    local pair var loop missing=''
    loop="$(gate_loop_line)"
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        var="${pair%%:*}"
        case "$loop" in
            *"\"\$$var\""*) ;;
            *) missing="$missing $var" ;;
        esac
    done < <(gate_env_pairs)
    assertEquals "results bound but NOT in the for-loop (their failure would not block merge):$missing" \
        '' "$missing"
}

# The other direction is loud rather than silent -- an undefined variable is empty, which is not
# "success", so the gate goes red and stays red. Asserted anyway: red-for-a-typo wastes a whole
# CI round to diagnose, and this costs nothing.
test_the_loop_references_nothing_that_is_not_bound() {
    local loop var bound stray=''
    loop="$(gate_loop_line)"
    # `tr` to spaces on purpose: the membership test below is a space-padded `case`, and a
    # newline-separated list never matches it -- every name would look unbound.
    bound="$(gate_env_pairs | sed 's/:.*//' | tr '\n' ' ')"
    for var in $(printf '%s' "$loop" | grep -oE '\$[A-Z_]+' | tr -d '$'); do
        case " $bound " in
            *" $var "*) ;;
            *) stray="$stray $var" ;;
        esac
    done
    assertEquals "variables in the loop with no binding above them:$stray" '' "$stray"
}

# The four checks above all reason INSIDE the `needs:` list -- they verify that whatever is listed
# there is bound, echoed and looped. None of them notices a job that was never added to the list at
# all, and that is the easier mistake to make: you write a job, it runs, it reports, it goes green,
# and nothing anywhere says it is not gating. Found while adding `commit-messages-parseable`: the
# whole suite stayed green with the new job wired into nothing.
#
# Top-level job names: two-space indent, then `name:` and nothing else on the line -- but ONLY
# inside the `jobs:` block. Without that restriction the `on:` block's `push:` is picked up as a
# job name, and the check fails on something that does not exist. Measured, while writing this.
all_job_names() {
    awk '
        /^jobs:[[:space:]]*$/ { injobs = 1; next }
        injobs && /^[a-z]/    { injobs = 0 }
        injobs && /^  [a-z][a-z0-9-]*:[[:space:]]*$/ { gsub(/[ :]/, "", $0); print }
    ' "$WF"
}

test_every_job_in_the_workflow_is_gated() {
    local needs jobs job missing=''
    needs="$(gate_needs | tr '\n' ' ')"
    jobs="$(all_job_names)"

    # Floor: if the name pattern stops matching, this test would pass while checking nothing --
    # the exact shape of failure it exists to prevent.
    assertTrue "expected to find several jobs, found $(printf '%s' "$jobs" | grep -c .)" \
        "[ $(printf '%s' "$jobs" | grep -c .) -ge 5 ]"

    for job in $jobs; do
        # The gate cannot depend on itself.
        [ "$job" = 'tests-passed' ] && continue
        case " $needs " in
            *" $job "*) ;;
            *) missing="$missing $job" ;;
        esac
    done
    assertEquals "jobs defined in the workflow but not in the tests-passed gate:$missing" '' "$missing"
}

# shellcheck source=/dev/null
. "$SHUNIT2"
