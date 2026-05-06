---
name: cleanup-remote-test
description: 'Permanently retire a test-<n> slot by removing the local test-<n> branch, the remote/test-<n> branch, the remote-test-<n> worktree, and the matching code-workspace folder entry. SVN content is preserved. Use when the user wants to retire a test environment, delete a test slot, or remove a test-<n>.'
argument-hint: 'Required: --n <number>'
user-invocable: true
---

# cleanup-remote-test

## Purpose

Decommission a `test-<n>` slot when it is no longer needed:

1. Remove the local `test-<n>` git branch
2. Remove the local `remote/test-<n>` git branch
3. Remove the `remote-test-<n>` git worktree
4. Remove the matching folder entry from `<proj>.code-workspace`

The SVN path (`branches/test-<n>`) is **deliberately preserved** as history.
The next `/tgs:create-remote-test` invocation chooses a fresh number based on
the remaining `<proj>.worktrees/remote-test-*` directories, so leaving the SVN
URL alone never blocks future test slots.

For the more common case of "test cycle ended, keep the slot but realign with
main", use `/tgs:reset-remote-test` instead — that one keeps the slot alive.

## Tool Preference

Read / Write / Edit / Glob / Grep / LSP for any file inspection or change.
Avoid Bash / PowerShell / Python / Node.js for filesystem operations. Bash /
PowerShell are only for invoking the cleanup script.

## Procedure

### Step 1: Validate input

If `--n` is not given, list the existing `remote-test-*` worktrees (read the
`<proj>.worktrees/` directory) and use `AskUserQuestion` to ask which test
number to retire. Reject any value that is not a positive integer.

### Step 2: Show the cleanup plan and confirm

Format the summary like this (translate labels to user's language):

```
即將永久刪除以下項目（test-<n>）：

  - 本地 branch: test-<n>
  - 本地 branch: remote/test-<n>
  - worktree:   <proj>.worktrees/remote-test-<n>/
  - workspace 條目: remote-test-<n>（在 <proj>.code-workspace）

SVN 上的 branches/test-<n> URL 不會被刪除（作為歷史保留）。
下次 /tgs:create-remote-test 會自動使用新編號，不會撞到。
```

Skip any line whose target does not actually exist (e.g. `test-<n>` already
deleted) — but still include them in the summary if they are partially
present so the user understands the final state.

Then ask via `AskUserQuestion`:
- Option A: Proceed (delete everything listed)
- Option B: Cancel (default)

If the user cancels, exit without touching anything.

### Step 3: Run the cleanup script

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-remote-test.ps1" -N "1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-remote-test.sh" --n "1"
```

The script removes everything in a fixed order (worktree → test-<n> →
remote/test-<n> → workspace entry) and skips items that are already missing.

### Step 4: Report

Report the script output verbatim. The final `Cleanup complete for test-<n>`
line confirms success. If the script exits non-zero, surface the error to the
user; the most common cause is a non-clean main or remote worktree.

## Decision Rules

- Only `test-<n>` (where n is a positive integer) is a valid argument.
- The main worktree must not currently be on `test-<n>` itself; if it is, the
  script aborts and the user must `git checkout main` first.
- The main worktree and (if present) `remote-test-<n>` worktree must be clean
  (no uncommitted changes, no half-finished SVN merges) — the script enforces
  this. Tell the user to commit / stash / push / pull as appropriate before
  retrying.
- This skill never removes:
  - The SVN test branch URL
  - Any `dev-<m>` worktree or its branches
  - Any `<proj>.code-workspace` folder entries other than the named
    `remote-test-<n>`
- Can be called from any worktree in the project.

## Completion Checks

- `git branch --list test-<n>` returns nothing.
- `git branch --list remote/test-<n>` returns nothing.
- `git worktree list` does not contain `<proj>.worktrees/remote-test-<n>`.
- The directory `<proj>.worktrees/remote-test-<n>` does not exist on disk.
- `<proj>.code-workspace` `folders` array no longer contains an entry whose
  `name` equals `remote-test-<n>`.
- `svn ls <branches root>` still shows `test-<n>` (verifying SVN was not
  touched).
