#!/usr/bin/env bash
# is-redundant-push.sh
#
# Answer "is this workflow run redundant, because the very same commit is already being tested by
# a pull_request run?"
#
#   usage  : is-redundant-push.sh <event-name> <open-pr-count>
#   stdout : `true` or `false` -- shaped for `$GITHUB_OUTPUT`
#   exit   : 0 on an answer; 2 on usage error (missing event name)
#
# WHY. tests.yml runs on BOTH `push` and `pull_request`, so every commit on a PR branch is tested
# twice -- measured at ~28 minutes per run on #88 and #92, i.e. ~55 minutes of runner time per push
# for one commit's worth of information. The `push` trigger cannot simply be dropped: without it a
# long-lived branch that has not opened a PR gets ZERO runs, which is exactly how feat/turbo-plugin
# accumulated hundreds of commits with a broken shared-copy invariant and no CI to notice. The
# thing to remove is the DUPLICATE, not the push trigger.
#
# WHY NOT `concurrency`. Tried and measured on PR #93, then reverted. Putting both events in one
# concurrency group does collapse them -- but the cancelled one leaves a FAILURE `tests-passed` on
# that SHA, and GitHub aggregates EVERY check-run for a SHA rather than taking the newest, so the
# PR ends up permanently BLOCKED. That property was already documented in tests.yml's own header
# (PR #54 / 12eb846, four `tests-passed` check-runs on one SHA); the experiment only confirmed it.
#
# FAILURE DIRECTION IS "NOT REDUNDANT" -- i.e. run the tests. Everything uncertain answers `false`:
# an empty count (the API call failed, or was never made), a non-numeric count, a negative number.
# Skipping a run that was actually needed means a commit ships with no CI behind it, which is the
# invisible direction; running one that was not needed costs runner minutes, which is not.
set -uo pipefail

EVENT="${1-}"
COUNT="${2-}"

if [[ -z "$EVENT" ]]; then
  printf 'usage: %s <event-name> <open-pr-count>\n' "${0##*/}" >&2
  exit 2
fi

# Only a `push` run can ever be the redundant one. A pull_request run is the one being deferred to,
# and workflow_dispatch is someone asking for a run on purpose.
if [[ "$EVENT" != 'push' ]]; then
  printf 'false\n'
  exit 0
fi

# Digits only. An empty string, `null`, an error message, or anything else means we do not know --
# and not knowing must never suppress a run.
if [[ ! "$COUNT" =~ ^[0-9]+$ ]]; then
  printf 'false\n'
  exit 0
fi

if (( COUNT > 0 )); then
  printf 'true\n'
else
  printf 'false\n'
fi
exit 0
