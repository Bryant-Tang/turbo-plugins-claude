#!/usr/bin/env bash
# turbo-plugin PreToolUse hook (matcher: Bash) — reminder for tp-commit-msg.
#
# Why this exists: `tp-commit-msg` is marked "use proactively", but nothing GUARANTEES it is ever
# loaded. An agent can call `git commit -m ...` directly and the whole skill -- imperative mood,
# what+why, the `<type>: ` subject format, "follow this repo's existing convention" -- simply never
# happens, with no signal that it was skipped (issue #56). That failure lands *before* the agent
# has any reason to suspect it missed something, which is why memory entries and CLAUDE.md notes
# cannot fix it: all of those must be read first, and not thinking to read is the failure itself.
# A hook fires whether or not anyone remembered.
#
# Advisory only (issue #56, strength 1): it prints a reminder and lets the command run.
#
# ── why this hook has NO .ps1 sibling, unlike invoke-sessionstart ────────────
#
# The pairing rule in CLAUDE.md is real, and the sibling SessionStart hook follows it by delegating
# to Invoke-SessionStart.ps1 on Windows. This hook deliberately does not, because the trigger rates
# are nothing alike: SessionStart runs ONCE per session, while this is PreToolUse on the Bash
# matcher -- it runs before EVERY Bash tool call. Spawning a PowerShell process each time would put
# a process launch in front of every command the agent runs. A .ps1 that the hook never calls would
# be dead code instead. So: one bash implementation, and the work is pure text handling that Git
# Bash does natively on Windows. See CLAUDE.md, "Script" section.
#
# ── two more constraints worth knowing before editing ───────────────────────
#
# 1. NO `jq`. This runs on the developer's machine, not a CI runner, and Git for Windows does not
#    ship jq. All this needs to decide is "is a git commit about to run", which does not require
#    faithfully decoding JSON -- so it pattern-matches the raw payload. A false positive costs one
#    advisory line, which is a fair price for having no dependency.
#
# 2. NEVER emit `permissionDecision`. Returning `"allow"` would suppress the user's own permission
#    prompt for EVERY git commit -- a hook that quietly grants permission is far worse than no
#    hook. Emitting only `systemMessage` leaves the normal permission flow untouched. Plain text is
#    not an option either: for PreToolUse, non-JSON stdout goes to the debug log only.
#
# Contract: reads the PreToolUse payload (JSON) on stdin; prints `{}` when it has nothing to say,
# otherwise one JSON object whose only key is `systemMessage`; always exits 0.

set -uo pipefail

# A hook must never take the tool call down with it. Any unexpected failure falls through to empty
# JSON + exit 0, same guard the sibling SessionStart hook uses.
trap 'printf "{}"; exit 0' ERR

payload="$(cat)"

emit_nothing() {
    printf '{}'
    exit 0
}

# Is a `git commit` about to run? Global options are allowed in between, so `git -C <path> commit`
# and `git -c key=value commit` match too -- those are the ordinary forms in a multi-repo
# workspace, which is exactly the setting issue #56 came out of.
if ! printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_-])git([[:space:]]+-[cC][[:space:]]*[^[:space:]]+)*[[:space:]]+commit([^A-Za-z0-9_-]|$)'; then
    emit_nothing
fi

# `--no-edit` means no message is being authored (typically `--amend --no-edit`, or concluding a
# merge). There is nothing for tp-commit-msg to do, so silence is correct rather than merely polite.
if printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_-])--no-edit([^A-Za-z0-9_-]|$)'; then
    emit_nothing
fi

# One line on purpose: the value is a JSON string, so every newline has to be a literal \n escape.
# A heredoc with real newlines would produce invalid JSON.
printf '%s' '{"systemMessage":"turbo-plugin-git-svn:偵測到即將執行 `git commit`。\n\n`tp-commit-msg` 標了 proactive,但沒有任何機制保證它被載入——請先套用它再提交(這段提醒不會擋下指令)。\n\n最常被跳過的一步是「沿用這個 repo 既有的 type 慣例」,先看過再決定:\n    git log --no-merges --format=%s -n 20\n\nsubject 格式是 `<type>: <祈使描述>`;skill 不限制用哪個 type,而是要求跟著 repo 現有慣例走。\n\n另外檢查:不要寫 git SHA、不要寫只有本地才有意義的識別碼(需求 / 計畫 / 任務代號),整條訊息語言一致,動機不明顯時在 body 交代為什麼。"}'
exit 0
