#!/usr/bin/env bash
# remind-commit-msg.test.sh (shUnit2) — PreToolUse advisory hook for tp-commit-msg (issue #56)
#
# Script under test: scripts/hooks/remind-commit-msg.sh
# Contract:
#   stdin  : the PreToolUse payload (JSON)
#   stdout : `{}` when it has nothing to say, else ONE JSON object whose only key is systemMessage
#   exit   : always 0
#
# The assertion that matters most is test_never_emits_a_permission_decision. The rest are about
# noise; that one is about safety. A hook answering `"permissionDecision":"allow"` would approve
# EVERY git commit on the user's behalf -- turning a reminder into a hole in their permission
# settings, and looking like it was working the whole time.
#
# Pure stdin -> stdout: no git, no filesystem, no sandbox, nothing to SKIP.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/hooks/remind-commit-msg.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

# Only the payload shape matters: the script pattern-matches the raw JSON rather than decoding it
# (no jq on Git for Windows -- see the script's header).
payload_for() {
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}

run_hook() {
    RC=0
    OUT="$(payload_for "$1" | bash "$SCRIPT_UNDER_TEST")" || RC=$?
}

# Pick a python that actually WORKS, not merely one that exists.
#
# On Windows `python3` usually resolves to the Microsoft Store stub under
# %LOCALAPPDATA%\Microsoft\WindowsApps. It is a real file, so `command -v` finds it, and it exits
# 0 -- but it runs nothing and prints nothing, so probing with `-c 'pass'` "passes" against a
# binary that cannot execute anything. Measured here: python3 -> the stub, python -> the real one.
# Hence the probe checks for expected OUTPUT. Exit 0 is not evidence that it ran.
pick_python() {
    local candidate
    for candidate in python3 python; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        [ "$("$candidate" -c 'print(42)' 2>/dev/null)" = "42" ] || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

test_script_and_config_exist() {
    assertTrue "hook script should exist at $SCRIPT_UNDER_TEST" "[ -f '$SCRIPT_UNDER_TEST' ]"
    assertTrue "hooks.json should exist at $HOOKS_JSON" "[ -f '$HOOKS_JSON' ]"
}

# ── quiet unless a commit is actually happening ──────────────────────────────

test_unrelated_command_is_quiet() {
    run_hook 'ls -la'
    assertEquals 'exit 0' 0 "$RC"
    assertEquals 'empty JSON for an unrelated command' '{}' "$OUT"
}

test_other_git_subcommands_are_quiet() {
    # `git log` neither creates a commit nor authors a message. Reminding here would train the
    # reader to ignore the reminder, which costs more than it saves.
    run_hook 'git log --oneline -5'
    assertEquals '{}' "$OUT"
    run_hook 'git status --porcelain'
    assertEquals '{}' "$OUT"
}

test_no_edit_is_quiet() {
    # --amend --no-edit authors no message, so tp-commit-msg has nothing to contribute.
    run_hook 'git commit --amend --no-edit'
    assertEquals '{}' "$OUT"
}

# ── speaks up on the forms that actually occur ───────────────────────────────

test_plain_commit_triggers() {
    run_hook 'git commit -m \"fix: something\"'
    assertEquals 'exit 0' 0 "$RC"
    case "$OUT" in
        *tp-commit-msg*) ;;
        *) fail "reminder should name the skill; got: $OUT" ;;
    esac
}

test_git_dash_capital_c_triggers() {
    # `git -C <path> commit` is the ordinary form in a multi-repo workspace -- the very setting
    # issue #56 came out of. Missing it would leave the reported case uncovered.
    run_hook 'git -C /some/repo commit -m \"fix: x\"'
    case "$OUT" in
        *tp-commit-msg*) ;;
        *) fail "git -C ... commit should trigger; got: $OUT" ;;
    esac
}

test_git_dash_lowercase_c_triggers() {
    run_hook 'git -c commit.gpgsign=false commit -m \"fix: x\"'
    case "$OUT" in
        *tp-commit-msg*) ;;
        *) fail "git -c ... commit should trigger; got: $OUT" ;;
    esac
}

# Found in review of PR #64, and it reproduced: the --no-edit test used to look at the whole
# payload, so an unrelated --no-edit anywhere in a chain silenced a commit that WAS authoring a
# message. That is the same silent skip issue #56 exists to catch, occurring inside the hook meant
# to catch it -- and `&&`-chained one-liners are an ordinary shape for agent-issued Bash calls.
test_no_edit_from_another_command_does_not_silence_the_commit() {
    run_hook 'git merge --no-edit && git commit -m \"fix: x\"'
    case "$OUT" in
        *tp-commit-msg*) ;;
        *) fail "another command's --no-edit must not suppress the reminder; got: $OUT" ;;
    esac
}

test_no_edit_on_the_commit_itself_still_silences_in_a_chain() {
    # The other direction: scoping must not break the case --no-edit was added for.
    run_hook 'git add -A && git commit --amend --no-edit'
    assertEquals '{}' "$OUT"
}

test_commit_later_in_a_chain_still_triggers() {
    run_hook 'npm run build && git add -A && git commit -m \"fix: x\"'
    case "$OUT" in
        *tp-commit-msg*) ;;
        *) fail "a commit later in a chain should trigger; got: $OUT" ;;
    esac
}

test_heredoc_form_triggers() {
    # Issue #56 called `git commit -F -` with a heredoc the hard case to intercept. It is not hard
    # here: the whole heredoc arrives inside the same command string.
    run_hook 'git commit -F - <<EOF\nfix: x\nEOF'
    case "$OUT" in
        *tp-commit-msg*) ;;
        *) fail "heredoc commit should trigger; got: $OUT" ;;
    esac
}

# ── output contract ──────────────────────────────────────────────────────────

test_never_emits_a_permission_decision() {
    # THE safety assertion. `allow` would bypass the user's own permission prompt on every git
    # commit; `deny` would silently turn an advisory hook into a blocking one. Both would be
    # invisible until the damage was done.
    run_hook 'git commit -m \"fix: x\"'
    case "$OUT" in
        *permissionDecision*) fail "advisory hook must not emit permissionDecision; got: $OUT" ;;
        *) ;;
    esac
}

test_output_is_one_line_with_only_system_message() {
    run_hook 'git commit -m \"fix: x\"'
    local lines
    lines="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
    assertEquals 'exactly one line' '1' "$lines"
    case "$OUT" in
        '{"systemMessage":"'*'"}') ;;
        *) fail "output should be one {\"systemMessage\":\"...\"} object; got: $OUT" ;;
    esac
}

test_output_parses_as_json() {
    # A real parse, not shape-matching. Self-SKIPs where no working python exists, per the repo's
    # "run what can run" rule -- the shape assertion above still covers those machines.
    local py
    if ! py="$(pick_python)"; then
        startSkipping
        assertTrue 'no working python; JSON parse check skipped' true
        return 0
    fi
    run_hook 'git commit -m \"fix: x\"'
    printf '%s' "$OUT" | "$py" -c 'import json,sys; d=json.load(sys.stdin); assert list(d.keys())==["systemMessage"], d.keys()'
    assertEquals 'output should parse as JSON with only systemMessage' 0 $?
}

test_quiet_output_also_parses_as_json() {
    local py
    if ! py="$(pick_python)"; then
        startSkipping
        assertTrue 'no working python; JSON parse check skipped' true
        return 0
    fi
    run_hook 'ls -la'
    printf '%s' "$OUT" | "$py" -c 'import json,sys; assert json.load(sys.stdin) == {}'
    assertEquals 'the quiet path should emit valid empty JSON' 0 $?
}

test_reminder_points_at_the_convention_check() {
    # Issue #56 identified "follow this repo's existing convention" as the step that gets skipped,
    # so the message carries the command that answers it. A reminder that only says "be careful"
    # would reproduce the problem it exists to solve.
    run_hook 'git commit -m \"fix: x\"'
    case "$OUT" in
        *'git log --no-merges'*) ;;
        *) fail "reminder should include the convention-checking command; got: $OUT" ;;
    esac
}

# ── declaration ──────────────────────────────────────────────────────────────

test_hooks_json_keeps_both_hooks() {
    # This plugin already shipped a SessionStart hook; adding PreToolUse must not displace it.
    # (It once did, during development -- a Write over the whole file rather than an edit.)
    grep -q '"SessionStart"' "$HOOKS_JSON" || fail 'hooks.json must still declare SessionStart'
    grep -q '"PreToolUse"' "$HOOKS_JSON" || fail 'hooks.json should declare PreToolUse'
    grep -q 'invoke-sessionstart.sh' "$HOOKS_JSON" || fail 'SessionStart command should be intact'
    grep -q 'remind-commit-msg.sh' "$HOOKS_JSON" || fail 'PreToolUse should point at this hook'
}

test_hooks_json_uses_the_plugin_wrapper_and_bash_matcher() {
    # The plugin form nests events under a top-level "hooks" key. Getting that wrong does not
    # error -- the hooks just never load, silently.
    grep -q '"hooks"' "$HOOKS_JSON" || fail 'hooks.json needs the top-level "hooks" wrapper'
    grep -q '"matcher": *"Bash"' "$HOOKS_JSON" || fail 'PreToolUse should match the Bash tool'
    grep -q 'CLAUDE_PLUGIN_ROOT' "$HOOKS_JSON" || fail 'commands should use ${CLAUDE_PLUGIN_ROOT}'
}

# shellcheck source=/dev/null
. "$SHUNIT2"
