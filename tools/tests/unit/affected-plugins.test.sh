#!/usr/bin/env bash
# affected-plugins.test.sh (shUnit2)
#
# Script under test: tools/affected-plugins.sh
# Output contract: exactly ONE line -- `ALL`, `NONE`, or space-separated `plugins/<name>` in
# first-seen order. Exit 0 for every input; exit 2 only for a usage error.
#
# What makes this suite worth having: a wrong answer here does NOT turn CI red. It makes some
# plugin's test suite quietly not run while the checkmark stays green. So the cases below are
# weighted toward EVERY path that must widen to ALL -- those are the fail-open guarantees, and
# they are the ones whose breakage is invisible.
#
# `NONE` -- "every changed path is inert, run no suite" -- is the one answer that narrows all the
# way to nothing, so it gets the same weighting from the other side: the cases below pin that it
# needs positive evidence, that a single widening path still beats it in either order, and that
# the inert list matches paths EXACTLY (a `case` glob's `*` spans slashes, which would otherwise
# reclassify a test fixture named CHANGELOG.md as inert).
#
# The script never touches the filesystem, so the plugin names used here are just strings; they
# are real names only to keep the scenarios readable. The one exception is
# test_no_test_reads_an_inert_file, which checks the REPOSITORY rather than the script.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# Only test_no_test_reads_an_inert_file needs this: every other case feeds the script strings.
REPO_ROOT="$(cd -- "$TOOLS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$TOOLS_DIR/affected-plugins.sh"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"

# Feed paths on stdin, capture the single output line. Exit code lands in $RC.
# stderr is deliberately NOT captured here: the diagnostics belong there, and every assertion
# below would break if they ever leaked into stdout.
run_with() {
    RC=0
    OUT="$(printf '%s' "$1" | bash "$SCRIPT_UNDER_TEST" 2>/dev/null)" || RC=$?
}

# Same, but stderr instead of stdout.
err_of() {
    printf '%s' "$1" | bash "$SCRIPT_UNDER_TEST" 2>&1 >/dev/null
}

test_script_exists() {
    assertTrue "affected-plugins.sh should exist at $SCRIPT_UNDER_TEST" "[ -f '$SCRIPT_UNDER_TEST' ]"
}

# ── the narrowing cases: a real subset is returned ───────────────────────────

test_single_plugin() {
    run_with 'plugins/turbo-plugin-git-svn/scripts/lib/common.sh'
    assertEquals 'exit 0' 0 "$RC"
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_several_files_in_one_plugin_dedupe() {
    run_with 'plugins/turbo-plugin-git-svn/scripts/a.sh
plugins/turbo-plugin-git-svn/tests/b.sh
plugins/turbo-plugin-git-svn/README.md'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_two_plugins_both_listed_in_first_seen_order() {
    run_with 'plugins/turbo-plugin-git-svn/scripts/a.sh
plugins/turbo-plugin-dotnet-framework/scripts/b.ps1'
    assertEquals 'plugins/turbo-plugin-git-svn plugins/turbo-plugin-dotnet-framework' "$OUT"
}

test_deeply_nested_path_resolves_to_its_plugin() {
    run_with 'plugins/turbo-plugin-git-svn/skills/tp-push/assets/deep/file.md'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_blank_lines_between_entries_are_ignored() {
    run_with 'plugins/turbo-plugin-git-svn/scripts/a.sh

plugins/turbo-plugin-code-comment/skills/x/SKILL.md
'
    assertEquals 'plugins/turbo-plugin-git-svn plugins/turbo-plugin-code-comment' "$OUT"
}

# ── rename / move: git reports BOTH paths, and both must count ───────────────
# The workflow feeds `.filename` and `.previous_filename` as separate lines, so a move shows up
# here as two ordinary paths. These cases pin what must happen to each shape.

test_move_between_plugins_marks_both() {
    # Source plugin LOST a file -- if only the destination were marked, the source's suite would
    # not run even though its contents changed.
    run_with 'plugins/turbo-plugin-dotnet-framework/scripts/moved.ps1
plugins/turbo-plugin-git-svn/scripts/moved.ps1'
    assertEquals 'plugins/turbo-plugin-dotnet-framework plugins/turbo-plugin-git-svn' "$OUT"
}

test_rename_inside_one_plugin_stays_one_entry() {
    run_with 'plugins/turbo-plugin-git-svn/scripts/new-name.sh
plugins/turbo-plugin-git-svn/scripts/old-name.sh'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_move_out_of_a_plugin_to_repo_root_widens_to_all() {
    # The root path alone forces ALL, which is the right answer twice over: root files affect
    # every plugin, and the source plugin lost a file.
    run_with 'shared-thing.md
plugins/turbo-plugin-git-svn/shared-thing.md'
    assertEquals 'ALL' "$OUT"
}

# ── the widening cases: anything unclear must return ALL ─────────────────────
# These are the ones that fail silently. A regression here shows up as a green run that tested
# less than it claimed, never as a red one.

# (The empty-input and blank-lines cases live with the NONE section below: what they pin is the
# difference between "nothing was affected" and "nothing was learned".)

test_tools_change_widens_to_all() {
    # tools/ holds the shared linters and this very script -- every suite can be affected.
    run_with 'tools/lint-ps-compat.ps1'
    assertEquals 'ALL' "$OUT"
}

test_workflow_change_widens_to_all() {
    run_with '.github/workflows/tests.yml'
    assertEquals 'ALL' "$OUT"
}

test_root_config_change_widens_to_all() {
    run_with 'release-please-config.json'
    assertEquals 'ALL' "$OUT"
}

test_plugin_file_mixed_with_a_root_file_widens_to_all() {
    # The plugin entry must NOT win over the root entry: order does not matter, one unclear
    # path is enough.
    #
    # This mixed case (and the reversed one below) is what actually guards the outside-plugins/
    # branch. Deleting that branch entirely was mutation-tested and the pure-root cases above
    # STAYED GREEN -- with nothing accumulated, the "no plugin attributed" fallback returns ALL
    # anyway, so both bugs and correct code give the same answer. Only an input that mixes an
    # attributable path with an unattributable one can tell them apart. Do not drop these two.
    run_with 'plugins/turbo-plugin-git-svn/scripts/a.sh
release-please-config.json'
    assertEquals 'ALL' "$OUT"
}

test_root_file_listed_first_also_widens_to_all() {
    run_with 'release-please-config.json
plugins/turbo-plugin-git-svn/scripts/a.sh'
    assertEquals 'ALL' "$OUT"
}

test_file_directly_under_plugins_widens_to_all() {
    # plugins/README.md belongs to no single plugin -- there is no second path segment to name
    # an owner, so it cannot be attributed and must not be dropped either.
    run_with 'plugins/README.md'
    assertEquals 'ALL' "$OUT"
}

test_marketplace_manifest_widens_to_all() {
    run_with '.claude-plugin/marketplace.json'
    assertEquals 'ALL' "$OUT"
}

# ── inert paths, and the NONE answer ─────────────────────────────────────────
#
# The inert list is the ONLY thing in this script that can narrow to nothing, so it is the only
# place where a mistake means "ran no suite" rather than "ran too many". Its safety rests on one
# claim -- that nothing reads these files -- which test_no_test_reads_an_inert_file checks against
# the repository itself, and which is not a claim this script can make on its own.
#
# Each inert branch here IS individually discriminating, unlike the widening branches: deleting one
# turns its case from NONE into ALL (root prose, the manifest) or into a plugin name (CHANGELOG.md,
# plugin.json), and either way the assertion fails. That is a change from the previous shape of
# this file, where a lone unattributable path gave ALL through the fallback whether the exception
# existed or not -- the trap still documented on
# test_plugin_file_mixed_with_a_root_file_widens_to_all, which applies to the WIDENING branch only.
#
# (When mutation-testing this file: shUnit2 reports two entries per failing test -- the ASSERT
# line, plus a "returned non-zero return code" line, because a failed assertion makes the test
# function itself return non-zero. Two failing tests read as `failures=4`.)

test_release_pr_shape_is_none() {
    # THE case this list exists for. A Release PR's diff is exactly this: the root manifest, plus
    # each releasing plugin's CHANGELOG.md and plugin.json. It contains no code, and it used to
    # cost a full matrix run (26/27/26 minutes, three consecutive Release PRs).
    run_with '.release-please-manifest.json
plugins/turbo-plugin-dotnet-framework/CHANGELOG.md
plugins/turbo-plugin-dotnet-framework/.claude-plugin/plugin.json'
    assertEquals 'exit 0' 0 "$RC"
    assertEquals 'NONE' "$OUT"
}

test_repo_root_prose_is_none() {
    # This assertion used to read ALL, and reversing it is the one direction change worth pausing
    # on. It is safe because these three are prose at the REPO ROOT: no script parses them and no
    # test opens them. Should that ever stop being true, test_no_test_reads_an_inert_file goes red
    # and this exception has to come back out -- that pairing is the whole basis for reversing it.
    run_with 'README.md
CLAUDE.md
LICENSE'
    assertEquals 'NONE' "$OUT"
}

test_release_manifest_alone_is_none() {
    run_with '.release-please-manifest.json'
    assertEquals 'NONE' "$OUT"
}

test_plugin_changelog_alone_is_none() {
    run_with 'plugins/turbo-plugin-git-svn/CHANGELOG.md'
    assertEquals 'NONE' "$OUT"
}

# ── the inert list must not swallow neighbours ───────────────────────────────

test_nested_changelog_is_not_inert() {
    # A `case` glob's `*` matches slashes, so the obvious `plugins/*/CHANGELOG.md` spelling would
    # also match this real fixture path and silently drop the plugin from the run. The script
    # splits the plugin name off and compares the remainder EXACTLY to stop that.
    run_with 'plugins/turbo-plugin-git-svn/tests/fixtures/base/CHANGELOG.md'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_nested_plugin_json_is_not_inert() {
    # Same trap, second name. Only `<plugin>/.claude-plugin/plugin.json` is the release-managed one.
    run_with 'plugins/turbo-plugin-git-svn/skills/tp-push/assets/plugin.json'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_plugin_readme_is_not_inert() {
    # Only the ROOT README is prose-with-no-reader. A plugin's README is its specification, and
    # this repo requires a README edit to accompany a plugin.json-only change so that the release
    # actually ships -- treating it as inert would make exactly that change test nothing.
    run_with 'plugins/turbo-plugin-git-svn/README.md'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_non_root_readme_still_widens() {
    # The match is on the whole path, not the basename: a README somewhere else is an unattributed
    # root-level path like any other.
    run_with 'docs/README.md'
    assertEquals 'ALL' "$OUT"
}

# ── NONE needs positive evidence, and loses to any widening path ─────────────

test_inert_plus_real_change_runs_that_plugin() {
    # An inert path must not suppress a real one that came with it -- the everyday shape of a
    # feature commit that also updates its changelog.
    run_with 'plugins/turbo-plugin-git-svn/CHANGELOG.md
plugins/turbo-plugin-git-svn/scripts/a.sh'
    assertEquals 'plugins/turbo-plugin-git-svn' "$OUT"
}

test_inert_plus_widening_path_is_all() {
    # One unclear path outweighs any number of inert ones.
    run_with 'CLAUDE.md
release-please-config.json'
    assertEquals 'ALL' "$OUT"
}

test_widening_path_listed_first_still_beats_inert() {
    # Order must not matter here either.
    run_with 'release-please-config.json
CLAUDE.md'
    assertEquals 'ALL' "$OUT"
}

test_release_please_config_still_widens_to_all() {
    # The exception is for the STATE file only. The config decides behaviour (changelog-sections,
    # tag-separator, the package list), so it must keep widening. Same-name-different-file is
    # exactly the sort of thing a later edit could conflate.
    run_with 'release-please-config.json
plugins/turbo-plugin-git-svn/CHANGELOG.md'
    assertEquals 'ALL' "$OUT"
}

test_empty_input_is_all_not_none() {
    # The distinction NONE exists to preserve. "I saw no paths" is not evidence that nothing is
    # affected; only a path seen AND classified inert is.
    run_with ''
    assertEquals 'exit 0' 0 "$RC"
    assertEquals 'ALL' "$OUT"
}

test_only_blank_lines_is_all_not_none() {
    run_with '

'
    assertEquals 'ALL' "$OUT"
}

test_none_is_exactly_one_line() {
    # Same contract as every other answer: the caller writes it straight into GITHUB_OUTPUT.
    local lines
    lines="$(printf 'CLAUDE.md\n' | bash "$SCRIPT_UNDER_TEST" 2>/dev/null | wc -l)"
    assertEquals '1' "$(printf '%s' "$lines" | tr -d '[:space:]')"
}

test_inert_skips_are_announced_on_stderr() {
    # Every other narrowing decision is silent, but these override the documented "root widens"
    # rule and end in running nothing, so they say so -- reading that back out of a CI log is how
    # anyone diagnoses a suite that did not run.
    local err
    err="$(err_of '.release-please-manifest.json
plugins/turbo-plugin-git-svn/CHANGELOG.md')"
    assertNotNull 'the skip should be explained on stderr' "$err"
    case "$err" in
        *release-please\ state*) ;;
        *) fail "stderr should say the manifest was skipped as release-please state; got: $err" ;;
    esac
    case "$err" in
        *inert*) ;;
        *) fail "stderr should say why nothing is affected; got: $err" ;;
    esac
}

# ── output shape ─────────────────────────────────────────────────────────────

test_output_is_exactly_one_line() {
    # The caller writes this straight into GITHUB_OUTPUT as `list=<output>`. A second line there
    # would corrupt the step output rather than merely being ignored.
    local lines
    lines="$(printf 'plugins/turbo-plugin-git-svn/a.sh\nplugins/turbo-plugin-code-comment/b.sh\n' \
        | bash "$SCRIPT_UNDER_TEST" | wc -l)"
    assertEquals '1' "$(printf '%s' "$lines" | tr -d '[:space:]')"
}

test_no_leading_space_in_list() {
    # The accumulator is built by appending " $p", so the leading space must be stripped; a
    # stray one would make the caller's `case " $affected " in *" $plugin "*` still work but
    # would look wrong in logs and break naive equality checks.
    run_with 'plugins/turbo-plugin-git-svn/a.sh'
    assertEquals "$OUT" "${OUT# }"
}

# ── diagnostics: on stderr, and they name the culprit ────────────────────────
# Widening to ALL without saying why leaves whoever reads the CI log with no way to tell a
# correct decision from a bug. But the caller writes stdout straight into GITHUB_OUTPUT, so
# these must never appear there.

test_widening_names_the_offending_path_on_stderr() {
    local e
    e="$(err_of 'plugins/turbo-plugin-git-svn/a.sh
release-please-config.json')"
    assertNotNull 'stderr should not be empty when widening' "$e"
    case "$e" in
        *release-please-config.json*) ;;
        *) fail "stderr should name the path that forced ALL; got: $e" ;;
    esac
}

test_diagnostics_never_reach_stdout() {
    # Same input as above: stdout must still be the single word ALL.
    local o
    o="$(printf 'plugins/turbo-plugin-git-svn/a.sh\nrelease-please-config.json\n' \
        | bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
    assertEquals 'ALL' "$o"
    assertEquals '1' "$(printf '%s\n' "$o" | wc -l | tr -d '[:space:]')"
}

test_empty_input_explains_itself_on_stderr() {
    local e
    e="$(err_of '')"
    assertNotNull 'empty input should still explain why it widened' "$e"
}

test_narrowing_case_stays_quiet() {
    # A clean attribution needs no explanation; noise on every run trains people to ignore it.
    local e
    e="$(err_of 'plugins/turbo-plugin-git-svn/a.sh')"
    assertEquals 'no diagnostics when the answer is a real subset' '' "$e"
}

test_unexpected_argument_is_a_usage_error() {
    # Guards against a caller drifting to `affected-plugins.sh file.txt` and getting ALL
    # silently -- i.e. a caller that thinks it is filtering while it is not.
    RC=0
    printf '' | bash "$SCRIPT_UNDER_TEST" somefile.txt >/dev/null 2>&1 || RC=$?
    assertEquals 'usage error exits 2' 2 "$RC"
}

# ── the repository check, not a script check ────────────────────────────────
#
# The inert list is a claim about the REPOSITORY -- "no test opens these files" -- and the script
# cannot check its own premise. Nothing else would catch it either: the day someone adds a lint
# over CLAUDE.md, or a test that asserts something about a plugin's CHANGELOG.md, that test stops
# running on precisely the changes it exists to police, and the run stays green. This case is the
# reason the exception is allowed to exist at all; issue #96 made adding it a precondition.
#
# WHAT IT LOOKS FOR, and why not something stricter. A test that reaches for the repository's own
# copy has to name a path that leaves its own tests/ directory -- `..`, a repo/plugin-root
# variable, or a literal `plugins/...`. Sandbox uses never do: they build their path from a
# mktemp'd variable the test itself created, which is why the many `$WS/CLAUDE.md` and
# `$out/CLAUDE.md` lines in the multi-repo-workspace suite do not fire here.
#
# The trade is deliberate. Matching on read constructs instead (`cat`, `Get-Content`, `[ -f ... ]`)
# would flag every one of those sandbox lines, and a check that cries wolf gets deleted. This one
# can in principle miss a test that computes the path in one statement and opens it in the next;
# what it cannot miss is the ordinary way anyone writes such a test.
#
# EXCLUSIONS: the vendored shunit2, gitignored sandboxes and fixture trees are not statements about
# what any suite needs. Comment lines are excluded for the same reason as in
# plugin-requires-tool.test.sh -- a mention is not a dependency. And this file excludes ITSELF: the
# script under test is a pure text function that never opens a file, so the inert paths appearing
# throughout the cases above are inputs, not reads.
test_no_test_reads_an_inert_file() {
    # Mirror of INERT in tools/affected-plugins.sh. If a name is added there, add it here.
    local names='(CLAUDE\.md|CHANGELOG\.md|plugin\.json|LICENSE|README\.md)'
    # Markers for a path that leaves the test's own directory.
    local escapes='\.\.|repo_?root|plugin_?(root|dir)|plugins/'
    local self="$SCRIPT_DIR/affected-plugins.test.sh"
    local f hits found='' scanned=0

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f" = "$self" ] && continue
        scanned=$((scanned + 1))
        hits="$(grep -nE "$names" "$f" 2>/dev/null \
            | grep -vE '^[0-9]+:[[:space:]]*#' \
            | grep -iE "$escapes" \
            | head -n 1)"
        [ -n "$hits" ] || continue
        found="$found
  $f:$hits"
    done <<EOF
$(find "$REPO_ROOT"/plugins/*/tests "$REPO_ROOT/tools/tests" -type f \
    \( -name '*.sh' -o -name '*.ps1' \) 2>/dev/null \
    | grep -v '/tests/lib/shunit2' \
    | grep -v '/\.sandbox/' \
    | grep -v '/fixtures/')
EOF

    # A check that scanned nothing reports exactly like a check that found nothing. If the layout
    # moves and those globs stop matching, this has to go red rather than quietly stop guarding the
    # inert list. The floor is far below the real count (96 files at the time of writing) so it
    # trips on "the search broke", never on "someone deleted a test".
    assertTrue "the scan should have covered the test suites, but only reached ${scanned} file(s) -- the find globs above have probably gone stale" \
        "[ $scanned -ge 20 ]"

    if [ -n "$found" ]; then
        fail "a test appears to read a file that affected-plugins.sh treats as inert, so that test would stop running on changes to it. Either narrow the test or remove the entry from INERT:$found"
    fi
}

# shellcheck source=/dev/null
. "$SHUNIT2"
