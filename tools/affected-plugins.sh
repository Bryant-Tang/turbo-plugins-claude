#!/usr/bin/env bash
# affected-plugins.sh
#
# Given a list of changed file paths, decide WHICH plugin test suites are worth running.
#
#   stdin  : one repo-relative path per line (blank lines ignored)
#   stdout : ONE line -- `ALL`, `NONE`, or a space-separated list of `plugins/<name>` entries
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
# INERT PATHS AND THE `NONE` ANSWER. A small, closed list of files provably cannot change how any
# script behaves or how any test runs -- see INERT below for the list and the argument for each.
# They contribute nothing, and a change made up ENTIRELY of them answers `NONE`: run no plugin
# suite at all.
#
# `NONE` is a distinct word rather than empty output, and that distinction is load-bearing. Empty
# output already means "I did not run" to the caller, which fails open to ALL (see the
# `Compute affected plugins` step). If "nothing is affected" were also spelled as nothing, a
# crashed classifier and a genuinely inert diff would be indistinguishable, and the safe reading of
# one is the wrong reading of the other.
#
# Two properties keep `NONE` from being the silent-green hazard it looks like:
#
#   * it requires POSITIVE evidence. At least one path must have been seen AND classified inert.
#     No paths at all, or paths that attribute to nothing, still widen to ALL.
#   * ONE widening path beats any number of inert ones, in any order, because widening exits
#     immediately.
#
# And `NONE` never means "this commit went untested": verify-core-identical and tools-tests carry
# no `needs: discover` and run on every event regardless of what this script answers.
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

# INERT -- the closed list of paths that contribute nothing.
#
# Membership is not a judgement call about how "important" a file feels. The test is narrow and
# mechanical: NO script reads it, and NO test opens it. Each entry below states its own argument,
# and tools/tests/unit/affected-plugins.test.sh carries a repository-level check that fails if any
# test file ever starts reading one of them.
#
#   .release-please-manifest.json         release-please's STATE, as opposed to its CONFIG:
#                                         release-please-config.json decides behaviour
#                                         (changelog-sections, tag-separator, the package list) and
#                                         still widens via the `*` branch, while the manifest is a
#                                         map of package path -> version string and nothing else.
#
#   CLAUDE.md / README.md / LICENSE       Repo ROOT only, and prose only: written for humans and
#   (at the repo root)                    for the agent, never parsed. `plugins/<name>/README.md`
#                                         is deliberately NOT inert -- a plugin's README is its
#                                         specification, and this repo requires a README edit to
#                                         accompany a plugin.json-only change so the release
#                                         actually ships. `docs/README.md` is not inert either: the
#                                         match is on the whole path, not the basename.
#
#   plugins/<name>/CHANGELOG.md           Both are release-please's output, rewritten on every
#   plugins/<name>/.claude-plugin/        Release PR. Neither is read by that plugin's suite. The
#     plugin.json                         one thing that does read plugin.json -- marketplace
#                                         installability, in tools/verify-core-identical.sh --
#                                         lives in a job with no `needs: discover`, so it runs
#                                         whatever this script answers.
#
# The last two are why this exists at all. A Release PR's diff is exactly those three shapes: the
# root manifest plus, per releasing plugin, its CHANGELOG.md and plugin.json. Attributing them
# dragged the full suite onto a diff containing no code whatsoever -- measured at 26, 27 and 26
# minutes across three consecutive Release PRs -- and charged it again on every "Update branch".
# Several plugins release together whenever a shared file changes, so it compounds.
#
# The plugin-relative matching below is EXACT on purpose. A `case` glob's `*` matches slashes, so
# the obvious spelling `plugins/*/CHANGELOG.md` would also swallow
# `plugins/<name>/tests/fixtures/CHANGELOG.md` -- a real test fixture, silently reclassified as
# inert. Splitting the plugin name off first and comparing the remainder exactly cannot do that.
touched=''
saw_inert=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    plugins/*/*)
      rest="${f#plugins/}"
      name="${rest%%/*}"
      sub="${rest#*/}"
      case "$sub" in
        CHANGELOG.md|.claude-plugin/plugin.json)
          note "'$f' is release-please output (changelog / version); not attributing"
          saw_inert=1
          continue
          ;;
      esac
      p="plugins/$name"
      # Membership test on a space-padded string: several files in one plugin, and a rename
      # inside one plugin (which arrives as two paths), must collapse to a single entry.
      case " $touched " in
        *" $p "*) ;;
        *) touched="$touched $p" ;;
      esac
      ;;
    .release-please-manifest.json)
      note "'$f' is release-please state (version numbers only); not widening"
      saw_inert=1
      ;;
    CLAUDE.md|README.md|LICENSE)
      note "'$f' is repo-root prose (nothing reads it); not widening"
      saw_inert=1
      ;;
    *)
      note "'$f' is not under plugins/<name>/; widening to ALL"
      echo 'ALL'
      exit 0
      ;;
  esac
done <<< "$input"

if [ -z "$touched" ]; then
  # Nothing was attributed. The two ways to get here are NOT the same answer.
  if [ "$saw_inert" -eq 1 ]; then
    # Every path seen was on the inert list, so there is genuinely nothing for a plugin suite to
    # exercise. This is the only branch that may narrow all the way to nothing, and it needs the
    # positive evidence of `saw_inert` to be reached.
    note 'every changed path is inert; no plugin suite can be affected'
    echo 'NONE'
    exit 0
  fi
  # Nothing was seen at all, or nothing that could be classified: no stdin, only blank lines. That
  # is an absence of information, not a finding that nothing is affected, so it widens.
  #
  # There used to be a separate early return for empty stdin, above the loop. Removing it is what
  # makes `saw_inert` DO something: with the early return in place this branch was unreachable
  # (command substitution strips trailing newlines, so blank-only input arrives here as empty and
  # left before the loop), and an unreachable guard is one no test can hold in place. Mutation
  # confirmed exactly that -- deleting the `saw_inert` condition changed no observable answer and
  # the whole suite stayed green. Now empty input reaches this branch, and that same mutation
  # turns it into NONE, which test_empty_input_is_all_not_none catches.
  note 'no attributable paths on stdin; widening to ALL'
  echo 'ALL'
  exit 0
fi

echo "${touched# }"
exit 0
