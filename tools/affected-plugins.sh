#!/usr/bin/env bash
# affected-plugins.sh
#
# Given a list of changed file paths, decide WHICH plugin test suites are worth running.
#
#   stdin  : one repo-relative path per line (blank lines ignored)
#   stdout : ONE line -- either `ALL`, or a space-separated list of `plugins/<name>` entries
#   exit   : 0 on success; 2 on usage error (unexpected argument)
#
# This is deliberately a PURE function of its input: no git, no network, no filesystem probing.
# That is what makes it testable, and the reason it was pulled out of .github/workflows/tests.yml
# in the first place -- logic living only inside a `run:` block can only be verified by pushing.
#
# FAILURE MODE IS "RUN EVERYTHING". `ALL` is the answer whenever anything is unclear, because the
# two directions are not symmetric: over-testing costs runner minutes, under-testing means a
# broken plugin ships with a green checkmark. This repo has been bitten by "quiet enough to look
# green" more than once, so every uncertain case widens rather than narrows.
#
# Any path outside `plugins/<name>/` therefore forces ALL: tools/ (shared by every suite),
# .github/ (the CI definition itself), and root config (marketplace.json, release-please) can each
# affect every plugin. A path directly under plugins/ with no second segment (`plugins/README.md`)
# belongs to no single plugin, so it forces ALL too.
#
# The CALLER is responsible for the other fail-open cases, because they need API/event context
# this script deliberately does not have: no comparable base (a branch's first push), a failed
# compare call, or a response that may have been truncated. Callers signal those by emitting ALL
# themselves -- see the `Compute affected plugins` step in .github/workflows/tests.yml.
#
# Bash-only, on purpose. Its ONLY consumer is a GitHub Actions `shell: bash` step, and bash is
# present on every runner this repo uses (git-bash on windows-latest). A .ps1 sibling would be a
# second copy of the same branching with no caller -- precisely the drift this script exists to
# make testable.

set -uo pipefail

if [ "$#" -gt 0 ]; then
  echo "usage: affected-plugins.sh < <newline-separated-paths>" >&2
  exit 2
fi

# Diagnostics go to stderr, never stdout: stdout is the result and the caller writes it straight
# into GITHUB_OUTPUT, so a second line there would corrupt the step output. They exist because
# `ALL` on its own does not say WHY everything is about to run -- reading that back out of a CI
# log is how anyone diagnoses a suite that ran when it did not need to.
note() { printf '%s\n' "affected-plugins: $*" >&2; }

input="$(cat)"

# No paths at all means we learned nothing about the change, not that nothing changed.
if [ -z "$input" ]; then
  note 'no paths on stdin; widening to ALL'
  echo 'ALL'
  exit 0
fi

touched=''
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    plugins/*/*)
      p="${f#plugins/}"
      p="plugins/${p%%/*}"
      # Membership test on a space-padded string: several files in one plugin, and a rename
      # inside one plugin (which arrives as two paths), must collapse to a single entry.
      case " $touched " in
        *" $p "*) ;;
        *) touched="$touched $p" ;;
      esac
      ;;
    .release-please-manifest.json)
      # The one root path that does NOT widen. The distinction is release-please's CONFIG versus
      # its STATE:
      #
      #   release-please-config.json     decides behaviour (changelog-sections, tag-separator,
      #                                  which packages exist) -> still widens, see the `*` branch
      #   .release-please-manifest.json  is a map of package path -> version string, nothing else
      #
      # A version number cannot change how any plugin behaves or how any test runs, so this file
      # carries no information that justifies running anything.
      #
      # Why it is worth an exception at all: a Release PR's diff is exactly three files -- this
      # manifest, plus the releasing plugin's CHANGELOG.md and .claude-plugin/plugin.json, both
      # already under plugins/<name>/ and attributed correctly. This single path was therefore
      # dragging the full five-plugin x two-OS matrix onto a diff containing no code whatsoever
      # (~26 minutes), and charging it again on every "Update branch" after a sibling Release PR
      # merged. Four plugins release together whenever Core.ps1 changes, so that compounds.
      #
      # Skipping is not the same as answering "nothing is affected": if this were somehow the only
      # changed path, `$touched` stays empty and the guard below still widens to ALL.
      note "'$f' is release-please state (version numbers only); not widening"
      ;;
    *)
      note "'$f' is not under plugins/<name>/; widening to ALL"
      echo 'ALL'
      exit 0
      ;;
  esac
done <<< "$input"

# Reachable when every input line was blank -- treat it like empty input, not like "no plugin
# is affected", which would skip every suite.
if [ -z "$touched" ]; then
  note 'no attributable paths on stdin; widening to ALL'
  echo 'ALL'
  exit 0
fi

echo "${touched# }"
exit 0
