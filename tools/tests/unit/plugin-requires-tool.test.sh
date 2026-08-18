#!/usr/bin/env bash
# plugin-requires-tool.test.sh (shUnit2)
#
# Script under test: tools/plugin-requires-tool.sh
# Output contract: exactly `true` or `false` on stdout; exit 0 for every answer, 2 for usage error.
#
# What makes this suite worth having is the same thing as affected-plugins.test.sh: a wrong answer
# here does NOT turn CI red. Answering `false` when a tool IS needed makes that plugin's tests
# self-SKIP, and a SKIP counts as green -- so the suite reports success while having tested almost
# nothing. The cases are therefore weighted toward the fail-open guarantees.
#
# The last case is different in kind: it checks the REPOSITORY, not the script -- that no plugin
# whose tests actually reach for svn has forgotten to declare it. That is the mistake the
# declaration file makes possible, and nothing else would catch it.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$TOOLS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$TOOLS_DIR/plugin-requires-tool.sh"
SHUNIT2="$TOOLS_DIR/tests/lib/shunit2"

RC=0
ask() {
    local out
    out="$(bash "$SCRIPT_UNDER_TEST" "$@" 2>/dev/null)"
    RC=$?
    printf '%s' "$out"
}

setUp() {
    SB="$(mktemp -d -t turbo-prt-XXXXXX)"
    mkdir -p "$SB/plug/tests"
}

tearDown() {
    [ -n "${SB:-}" ] && rm -rf "$SB" 2>/dev/null
    return 0
}

test_script_exists() {
    assertTrue 'the script under test exists' "[ -f '$SCRIPT_UNDER_TEST' ]"
}

# Absence is a DEFINITE answer, not an uncertain one -- five of six plugins need nothing, and this
# is the case that actually removes the install.
test_no_declaration_means_needs_nothing() {
    assertEquals 'false' "$(ask "$SB/plug" svn)"
    assertEquals 'exit 0' 0 "$RC"
}

test_declared_tool_is_required() {
    printf 'svn\n' > "$SB/plug/tests/required-tools"
    assertEquals 'true' "$(ask "$SB/plug" svn)"
}

test_undeclared_tool_is_not_required() {
    printf 'svn\n' > "$SB/plug/tests/required-tools"
    assertEquals 'false' "$(ask "$SB/plug" dotnet)"
}

# A substring must not count: a plugin declaring `svnadmin` has not declared `svn`, and vice versa.
# Written because the obvious `grep -q "$TOOL"` implementation gets this wrong in both directions.
test_matching_is_whole_line_not_substring() {
    printf 'svnadmin\n' > "$SB/plug/tests/required-tools"
    assertEquals 'false' "$(ask "$SB/plug" svn)"
    printf 'svn\n' > "$SB/plug/tests/required-tools"
    assertEquals 'false' "$(ask "$SB/plug" svnadmin)"
}

test_comments_blanks_and_padding_are_ignored() {
    {
        printf '# a comment naming svn should not count\n'
        printf '\n'
        printf '   \n'
        printf '  dotnet   \n'
    } > "$SB/plug/tests/required-tools"
    assertEquals 'a commented-out name is not a declaration' 'false' "$(ask "$SB/plug" svn)"
    assertEquals 'surrounding whitespace is trimmed' 'true' "$(ask "$SB/plug" dotnet)"
}

# A file whose last line has no newline is what a hand-edit often produces.
test_last_line_without_trailing_newline_still_counts() {
    printf 'dotnet\nsvn' > "$SB/plug/tests/required-tools"
    assertEquals 'true' "$(ask "$SB/plug" svn)"
}

# THE fail-open guarantee: we cannot inspect it, so we install. Answering `false` here would make
# a typo'd matrix entry silently skip an install and turn its whole suite into green SKIPs.
test_unknown_path_answers_true_rather_than_false() {
    assertEquals 'true' "$(ask "$SB/does-not-exist" svn)"
    assertEquals 'still exit 0, because this is an answer and not a crash' 0 "$RC"
}

test_usage_error_exits_2() {
    ask "$SB/plug"
    assertEquals 'a missing tool argument is a usage error' 2 "$RC"
    ask
    assertEquals 'no arguments at all is a usage error' 2 "$RC"
}

# ── the repository check, not a script check ────────────────────────────────
# The declaration file introduces exactly one new way to be wrong: a plugin's tests use a tool and
# nobody declared it. CI then skips the install, those cases self-SKIP, and the suite is green
# while testing nothing -- invisible in every direction. So: if a plugin's own test files reach
# for svn, that plugin must declare it.
#
# Comment lines are excluded because one plugin legitimately MENTIONS svnadmin in a comment about
# quoting (turbo-plugin-dotnet-framework/tests/lib/ScriptsCommon.ps1) without depending on it. The
# vendored shunit2 and the gitignored sandboxes are excluded for the same reason: neither is a
# statement about what this plugin needs.
test_every_plugin_using_svn_declares_it() {
    local d name hits
    for d in "$REPO_ROOT"/plugins/*/; do
        name="$(basename "$d")"
        [ -d "$d/tests" ] || continue
        hits="$(grep -rlE '(command -v|which) svn|Get-Command +svn|svnadmin +create|svn_available' \
            "$d/tests" 2>/dev/null \
            | grep -v '/tests/lib/shunit2' \
            | grep -v '/\.sandbox/' \
            | head -n 1)"
        [ -n "$hits" ] || continue
        if [ "$(bash "$SCRIPT_UNDER_TEST" "$d" svn 2>/dev/null)" != 'true' ]; then
            fail "$name's tests use svn (e.g. $hits) but it does not declare svn in tests/required-tools"
        fi
    done
}

# shellcheck source=/dev/null
. "$SHUNIT2"
