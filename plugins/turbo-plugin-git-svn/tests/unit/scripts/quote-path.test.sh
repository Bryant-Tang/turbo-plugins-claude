#!/usr/bin/env bash
# quote-path.test.sh (shUnit2)
#
# Under test: the rule that git output printed for a HUMAN carries `-c core.quotePath=false`,
# and output parsed by a MACHINE does not (issue #143).
#
# Why it needs a test. git's `core.quotePath` defaults to true, so a non-ASCII filename comes out
# as `"docs/\347\231\274..."`. Nothing errors -- the list is still produced, still non-empty, still
# passes every existing assertion. It is only unreadable, and only to the person who has to act on
# it. A new conflict-list call site added without the flag would therefore be invisible to CI and
# to review, which is exactly the shape of failure this repo keeps getting bitten by.
#
# The rule has TWO directions and both are asserted. Blanket-adding the flag is also wrong:
# `--porcelain` escaping is part of that format (it disambiguates names containing spaces or
# newlines), so turning it off there makes parsing unsafe. If a call site ever really needs to
# parse names, the answer is `--porcelain -z`, not this flag.
#
# .sh only, no .ps1 twin: these are text assertions over both halves' sources plus one behavioural
# probe against git itself, so a second implementation would be a translation with no added
# coverage -- and this file runs on BOTH runners (the Windows orchestrator drives .sh through Git
# Bash). Same reasoning as tests/unit/assets in the db plugin.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
SKILLS_DIR="$PLUGIN_ROOT/skills"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

FLAG='-c core.quotePath=false'

# The shapes whose output a human reads: conflict lists, the tp-request-merge diffstat, and the
# bridge's differing-files list.
HUMAN_SHAPES='diff --name-only --diff-filter=U|diff --stat|diff --cached --name-only'

# Every line in scripts/ that runs one of those shapes, both language halves.
#
# The quote/comma stripping is load-bearing, not tidiness. One call site does not spell the command
# as a bare string at all -- it goes through the Read-Git wrapper as an ARGUMENT ARRAY:
#
#     Read-Git -Cwd $x -GitArgs @('-c', 'core.quotePath=false', 'diff', '--stat', "$a...$b")
#
# A pattern anchored on a literal `git ... diff --stat` misses that line completely. It did: the
# first version of this test stayed GREEN with the flag deleted from exactly that call, and the
# "at least N call sites" floor did not save it -- eleven other sites satisfied the floor while the
# twelfth went unchecked. Normalising first is what makes both spellings one shape.
human_lines() {
    grep -rn -E 'diff' "$SCRIPTS_DIR" --include='*.sh' --include='*.ps1' 2>/dev/null \
        | tr -d "'\"," \
        | grep -E "($HUMAN_SHAPES)"
}

test_every_human_facing_git_call_disables_quotepath() {
    local line missing='' count=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Skip prose: comment lines, and the error-message strings that merely name the command
        # that just ran. Neither invokes anything.
        case "$line" in
            *'Write-ErrorToken'*|*'_die_token'*) continue ;;
            *:[0-9]*:*[!\ ]*) : ;;
        esac
        # Strip "path:lineno:" then test whether what remains starts a comment.
        case "$(printf '%s' "${line#*:*:}" | sed 's/^[[:space:]]*//')" in
            '#'*) continue ;;
        esac
        count=$((count + 1))
        case "$line" in
            *"$FLAG"*) ;;
            *) missing="$missing
  ${line}" ;;
        esac
    done <<EOF
$(human_lines)
EOF
    # Floor: if the shape pattern stops matching, this test would pass while checking nothing.
    assertTrue "expected many human-facing git calls, found $count" "[ '$count' -ge 10 ]"
    assertEquals "human-facing git calls missing '$FLAG':$missing" '' "$missing"
}

# The other direction. Escaping is load-bearing for --porcelain, so the flag must NOT spread there
# just because someone saw it next door.
test_machine_parsed_calls_keep_quoting() {
    local hits
    hits="$(grep -rn -- "$FLAG" "$SCRIPTS_DIR" --include='*.sh' --include='*.ps1' 2>/dev/null \
        | grep -- '--porcelain' || true)"
    assertEquals "the flag must not be applied to --porcelain output:
$hits" '' "$hits"
}

# The SKILL commands the agent runs and then reports from are the same rule, one layer up.
test_skill_source_commands_disable_quotepath() {
    local line missing='' count=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        count=$((count + 1))
        case "$line" in
            *"$FLAG"*) ;;
            *) missing="$missing
  ${line}" ;;
        esac
    done <<EOF
$(grep -rnE '^- Source: .git ' "$SKILLS_DIR" --include='*.md' 2>/dev/null)
EOF
    assertTrue "expected several SKILL 'Source:' git commands, found $count" "[ '$count' -ge 3 ]"
    assertEquals "SKILL 'Source:' git commands missing '$FLAG':$missing" '' "$missing"
}

# Behavioural oracle: prove the flag actually does the job on this machine's git, rather than
# trusting that the string appears in the right places.
test_the_flag_actually_unescapes_a_non_ascii_name() {
    local tmp escaped raw
    tmp="$(mktemp -d -t turbo-quotepath-XXXXXX)"
    git -C "$tmp" init -q
    git -C "$tmp" config user.email 'ci@turbo-plugin'
    git -C "$tmp" config user.name 'turbo-plugin-ci'
    git -C "$tmp" config core.quotePath true   # git's own default, pinned so the test is not ambient
    mkdir -p "$tmp/docs"
    printf 'a\n' > "$tmp/docs/發佈說明.md"
    git -C "$tmp" add -A >/dev/null 2>&1
    git -C "$tmp" commit -qm base >/dev/null 2>&1

    escaped="$(git -C "$tmp" diff --name-only HEAD~0 2>/dev/null; git -C "$tmp" show --name-only --format= HEAD)"
    raw="$(git -C "$tmp" -c core.quotePath=false show --name-only --format= HEAD)"

    # Guard the fixture: without this, a git that stopped escaping would make both sides equal and
    # the assertions below would pass while proving nothing.
    printf '%s' "$escaped" | grep -q '\\3'
    assertTrue "fixture guard: default git should have escaped the name, got: $escaped" $?

    printf '%s' "$raw" | grep -q '發佈說明'
    assertTrue "the flag must yield the real name, got: $raw" $?
    printf '%s' "$raw" | grep -q '\\3'
    assertFalse 'the flagged output must contain no octal escapes' $?

    rm -rf "$tmp"
}

# shellcheck source=/dev/null
. "$SHUNIT2"
