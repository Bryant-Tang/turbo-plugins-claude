#!/usr/bin/env bash
# verify-inert-files.test.sh (shUnit2)
#
# Under test: tools/verify-inert-files.sh, the experiment that stands behind `affected-plugins.sh`
# answering NONE.
#
# The experiment's own failure mode is the one worth guarding: a version that forgets to garble
# anything, or that never notices a failing suite, passes every plausible smoke check and reports
# success forever -- while the claim it is supposed to be testing goes unexamined. So the assertions
# below are about the MECHANISM, not about today's answer:
#
#   * the inert list is DERIVED from the classifier, not written down twice
#   * the suite list is GLOBBED, so a new plugin cannot fall out of the experiment silently
#   * the files really do hold garbage while the suites run
#   * a failing suite really does fail the experiment
#   * the files are restored afterwards
#
# The suites themselves are stubbed out via TP_INERT_SUITES: running eight real suites here would
# turn a unit test into a CI job, and what these cases check is the harness around them.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$TOOLS_DIR/.." && pwd)"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"
SCRIPT_UNDER_TEST="$TOOLS_DIR/verify-inert-files.sh"

LIST_OUT=''
INERT_FILES=''

# Derive ONCE for the whole file. The derivation spawns the classifier per tracked file, which is
# ~1s on a Linux runner but slow enough on Windows that doing it in every case turned this
# seven-second suite into a ten-minute one -- and "seven seconds locally" is the property the grep
# guard is documented as providing. The cases below reuse this answer through TP_INERT_FILES;
# the two that are ABOUT the derivation assert against this real output.
oneTimeSetUp() {
    LIST_OUT="$(bash "$SCRIPT_UNDER_TEST" --list 2>/dev/null)"
    INERT_FILES="$(printf '%s\n' "$LIST_OUT" \
        | awk '/^inert files:/{f=1;next} /^suites:/{f=0} f{sub(/^  /,""); print}')"
}

# Run the experiment against the already-derived list.
run_experiment() {
    TP_INERT_FILES="$INERT_FILES" TP_INERT_SUITES="$1" bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
}

# These cases drive the experiment, and the experiment runs the tools suite -- which contains this
# file. Left alone, the whole set re-enters itself: the inner run finds the tree already garbled
# and refuses, so half of these fail; worse, a version that did NOT refuse would restore the files
# mid-experiment and leave the outer run silently testing nothing.
#
# So when the harness is what is running us, skip. shUnit2 counts skips as green, which is right
# here: what these cases check is the harness, and the harness is demonstrably running.
setUp() {
    if [ -n "${TP_INERT_RUNNING:-}" ]; then
        startSkipping
    fi
}

test_script_exists() {
    [ -f "$SCRIPT_UNDER_TEST" ]
    assertTrue 'tools/verify-inert-files.sh exists' $?
}

# The refusal itself, asserted rather than assumed. (Like everything here it is skipped when we
# ARE the nested run; a standalone `bash tools/tests/invoke-script-tests.sh` is where it counts.)
test_refuses_to_re_enter_itself() {
    local rc out
    out="$(TP_INERT_RUNNING=1 TP_INERT_SUITES='true' bash "$SCRIPT_UNDER_TEST" 2>&1)"
    rc=$?
    assertEquals 'a nested run exits 2 instead of un-garbling the outer one' 2 "$rc"
    case "$out" in
        *'refusing to run inside another'*) : ;;
        *) fail "expected the refusal to say why, got: $out" ;;
    esac
}

# --- the inert list is derived, not declared -----------------------------------------------------

test_list_derives_the_inert_set_from_the_classifier() {
    local out manifest changelog
    out="$LIST_OUT"
    manifest="$(printf '%s\n' "$out" | grep -c '^  \.release-please-manifest\.json$')" || manifest=0
    changelog="$(printf '%s\n' "$out" | grep -c '^  plugins/.*/CHANGELOG\.md$')" || changelog=0
    assertEquals 'release-please state is inert' 1 "$manifest"
    assertTrue 'every plugin CHANGELOG is inert' "[ $changelog -ge 1 ]"
}

# The other direction, and the one that would matter if the derivation broke: things that are NOT
# inert must not appear. A derivation that answered "everything" would garble the whole repo and
# every suite would fail -- loud. A derivation that answered "a bit too much" is the quiet one.
test_list_excludes_files_that_are_not_inert() {
    local out readme tools_script
    out="$LIST_OUT"
    readme="$(printf '%s\n' "$out" | grep -c '^  plugins/[^/]*/README\.md$')" || readme=0
    tools_script="$(printf '%s\n' "$out" | grep -c '^  tools/')" || tools_script=0
    assertEquals "a plugin's README is its spec, never inert" 0 "$readme"
    assertEquals 'nothing under tools/ is inert' 0 "$tools_script"
}

# --- the suite list is globbed, not declared -----------------------------------------------------

test_every_plugin_suite_is_included() {
    local out listed on_disk
    out="$LIST_OUT"
    listed="$(printf '%s\n' "$out" | grep -c 'plugins/.*/tests/invoke-script-tests\.sh')" || listed=0
    on_disk="$(find "$REPO_ROOT/plugins" -maxdepth 3 -name invoke-script-tests.sh 2>/dev/null | wc -l)"
    on_disk="$(printf '%s' "$on_disk" | tr -d ' ')"
    assertEquals 'the experiment runs EVERY plugin suite that exists on disk' "$on_disk" "$listed"
    assertTrue 'and there is more than one of them, so the count means something' "[ $on_disk -gt 1 ]"
}

test_the_tools_suite_is_included_too() {
    local out tools
    out="$LIST_OUT"
    tools="$(printf '%s\n' "$out" | grep -c 'bash tools/tests/invoke-script-tests\.sh')" || tools=0
    assertEquals 'tools/ has its own suite and it reads repo-root files the most' 1 "$tools"
}

# --- the experiment itself -----------------------------------------------------------------------

test_a_passing_suite_passes_the_experiment() {
    local rc
    run_experiment 'true'
    rc=$?
    assertEquals 'nothing objected to the garbage, so the inert list holds' 0 "$rc"
}

test_a_failing_suite_fails_the_experiment() {
    local rc
    run_experiment 'false'
    rc=$?
    assertNotEquals 'a suite that failed under garbage must fail the experiment' 0 "$rc"
}

# THE test. Everything above still passes if the script never writes a single byte -- and a version
# that quietly skipped the garbling would report success forever while checking nothing at all.
# The stub suite here fails unless the marker is actually sitting in the file at that moment.
test_the_files_really_hold_garbage_while_the_suites_run() {
    local rc
    run_experiment 'grep -q "replaced by tools/verify-inert-files.sh" CLAUDE.md'
    rc=$?
    assertEquals 'an inert file held the marker while the suite ran' 0 "$rc"
}

test_the_files_are_restored_afterwards() {
    local dirty
    run_experiment 'true'
    dirty="$(cd "$REPO_ROOT" && git status --porcelain -- CLAUDE.md README.md .release-please-manifest.json 2>/dev/null)"
    assertEquals 'the working tree is exactly as it was' '' "$dirty"
}

test_restores_even_when_a_suite_fails() {
    local dirty
    run_experiment 'false'
    dirty="$(cd "$REPO_ROOT" && git status --porcelain -- CLAUDE.md 2>/dev/null)"
    assertEquals 'a red experiment still leaves the checkout clean' '' "$dirty"
}

# --- the guards ----------------------------------------------------------------------------------

# Restoring is `git checkout --`, which discards working-tree changes. Running this on a machine
# with an uncommitted CLAUDE.md edit would destroy it, silently, as a side effect of a check.
test_refuses_to_run_when_an_inert_file_is_dirty() {
    local rc out
    printf '\nlocal edit that must survive\n' >> "$REPO_ROOT/CLAUDE.md"
    out="$(TP_INERT_FILES="$INERT_FILES" TP_INERT_SUITES='true' bash "$SCRIPT_UNDER_TEST" 2>&1)"
    rc=$?
    # Restore BEFORE asserting: a failed assertion must not leave the checkout modified.
    (cd "$REPO_ROOT" && git checkout -- CLAUDE.md 2>/dev/null)
    assertEquals 'refuses rather than clobbering uncommitted work' 2 "$rc"
    case "$out" in
        *'uncommitted changes'*) : ;;
        *) fail "expected the refusal to say why, got: $out" ;;
    esac
}

# A classifier that answers NONE for nothing derives an empty list. Treating that as "nothing to
# check, all good" would retire this experiment without anyone noticing -- the exact shape of
# silent-green this repo keeps getting bitten by.
#
# This is the one case that cannot reuse the shared derivation: the branch it exercises only exists
# INSIDE the derivation loop. It therefore pays the full per-file spawn cost (about a second on a
# Linux runner, closer to a minute on Windows) and is the reason this suite is minutes rather than
# seconds locally on Windows. Worth it -- the alternative is the experiment being able to retire
# itself in silence.
test_an_empty_inert_list_is_an_error_not_a_pass() {
    local rc stub
    stub="$(mktemp)"
    printf '#!/usr/bin/env bash\ncat >/dev/null\necho ALL\n' > "$stub"
    chmod +x "$stub"
    TP_INERT_CLASSIFIER="$stub" TP_INERT_SUITES='true' bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
    rc=$?
    rm -f "$stub"
    assertNotEquals 'deriving nothing is a failure, not a quiet success' 0 "$rc"
}

# A line of spaces is not blank to `[ -n ]`, so before the filter was added it was treated as a
# path and `> "$f"` CREATED a file called "   " in the repo root. Observed, not hypothesised.
# The filter turns such a list into an empty one, which the guard above then catches.
test_a_whitespace_only_list_is_an_error_not_a_pass() {
    local rc
    TP_INERT_FILES='   ' TP_INERT_SUITES='true' bash "$SCRIPT_UNDER_TEST" >/dev/null 2>&1
    rc=$?
    assertNotEquals 'a list of nothing but spaces must fail, not garble a file named "   "' 0 "$rc"
    [ -e "$REPO_ROOT/   " ]
    assertFalse 'and must not have created a file whose name is whitespace' $?
}

# THE silent one, and it was reachable. With the write unchecked, bash printed its own "Is a
# directory" to stderr while this script went on to announce "replaced the contents of 1 inert
# file(s)" and then "the inert list holds", exiting 0 -- a green experiment that garbled nothing.
# A directory is the portable way to make a write fail; chmod is not, on Windows. It has to be a
# directory OUTSIDE the repository, though: an in-repo path would be caught by the dirty check
# first whenever the developer happens to have edits there -- which, while working on this very
# file, is always. git reports an outside path as not-in-repository, so the dirty check sees
# nothing and the write is what fails.
test_a_write_that_fails_stops_the_experiment() {
    local rc out dir
    dir="$(mktemp -d 2>/dev/null || mktemp -d -t inertwrite)"
    out="$(TP_INERT_FILES="$dir" TP_INERT_SUITES='true' bash "$SCRIPT_UNDER_TEST" 2>&1)"
    rc=$?
    rmdir "$dir" 2>/dev/null
    assertNotEquals 'a hollow experiment must not report success' 0 "$rc"
    case "$out" in
        *'could not replace the contents'*) : ;;
        *) fail "expected the failed write to be named, got: $out" ;;
    esac
}

test_unexpected_argument_is_a_usage_error() {
    local rc
    bash "$SCRIPT_UNDER_TEST" --nope >/dev/null 2>&1
    rc=$?
    assertEquals 'an unrecognised flag exits 2' 2 "$rc"
}

# shellcheck source=/dev/null
. "$SHUNIT2"
