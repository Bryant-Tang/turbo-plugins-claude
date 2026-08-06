#!/usr/bin/env bash
# affected-plugins.test.sh (shUnit2)
#
# Script under test: tools/affected-plugins.sh
# Output contract: exactly ONE line -- `ALL`, or space-separated `plugins/<name>` in first-seen
# order. Exit 0 for every input; exit 2 only for a usage error.
#
# What makes this suite worth having: a wrong answer here does NOT turn CI red. It makes some
# plugin's test suite quietly not run while the checkmark stays green. So the cases below are
# weighted toward EVERY path that must widen to ALL -- those are the fail-open guarantees, and
# they are the ones whose breakage is invisible.
#
# The script never touches the filesystem, so the plugin names used here are just strings; they
# are real names only to keep the scenarios readable.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
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

test_empty_input_widens_to_all() {
    run_with ''
    assertEquals 'exit 0' 0 "$RC"
    assertEquals 'ALL' "$OUT"
}

test_only_blank_lines_widens_to_all() {
    run_with '

'
    assertEquals 'ALL' "$OUT"
}

test_repo_root_docs_widen_to_all() {
    run_with 'README.md
CLAUDE.md'
    assertEquals 'ALL' "$OUT"
}

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

# shellcheck source=/dev/null
. "$SHUNIT2"
