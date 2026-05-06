---
name: reset-remote-test
description: 'Reset a test-<n> branch back to main, discarding all test-only commits, then publish to SVN. Use when one test cycle has ended and the slot will be reused for the next round, when the user wants to clear test-only data, or when "reset test branch" / "align test to main" is requested.'
argument-hint: 'Required: --n <number>'
user-invocable: true
---

# reset-remote-test

## Purpose

Re-align a `test-<n>` branch with `main` between testing cycles, keeping the
SVN test branch URL alive (so any deployment pipeline pointing at it stays
valid):

1. Show the user every commit in `test-<n>` that is **not** in `main` — these
   will be permanently discarded
2. After confirmation, hard-reset `test-<n>` to `main` in the main worktree
3. Push the reset content up to SVN via `push-to-svn`

This skill never touches the SVN URL itself nor the local worktree / branch
metadata — only the contents of `test-<n>` and the SVN test branch are
realigned.

## Tool Preference

Read / Write / Edit / Glob / Grep / LSP for any file inspection or change.
Avoid using Bash / PowerShell / Python / Node.js for filesystem operations.
Bash / PowerShell are only for invoking the scripts that this SKILL delegates
to.

## Procedure

### Step 1: Validate input

If `--n` is not given, use `AskUserQuestion` to ask which test number to reset.
Reject any value that is not a positive integer.

### Step 2: Compute the diff (read-only)

Run the script in **diff-only** mode to get a preview of what will change:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.ps1" -N "1" -DiffOnly
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.sh" --n "1" --diff-only
```

The script's stdout has two sections separated by an empty line:

```
LOSE
<hash> <subject>     ← commits in test-<n> not in main, will be discarded
...

GAIN
<hash> <subject>     ← commits in main not yet in test-<n>, will be brought in
...
```

If the script exits non-zero (worktree not clean, branch missing, etc.), report
the error to the user and stop.

### Step 3: Show preview and confirm

Format the summary like this (translate labels to the user's language):

```
即將 reset test-<n> 為 main：

將被丟棄（test-<n> 上不在 main 的 commit，N 個）：
- <hash> <subject>
- ...

將被帶進來（main 上不在 test-<n> 的 commit，M 個）：
- <hash> <subject>
- ...
```

If the LOSE list is empty AND the GAIN list is empty, tell the user
`test-<n> already equals main, nothing to reset` and stop.

Then ask via `AskUserQuestion`:
- Option A: Proceed (reset and push to SVN)
- Option B: Cancel (default)

If the user chooses **Cancel**, exit without touching anything.

### Step 4: Run the actual reset

Re-invoke the script without `--diff-only`:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.ps1" -N "1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.sh" --n "1"
```

The script will switch the main worktree to `test-<n>`, hard-reset to `main`,
and switch back. Report any output to the user.

### Step 5: Push to SVN

Delegate to the existing `push-to-svn` SKILL to publish the reset content.
Suggest a commit message such as `reset test-<n> to main after release`:

```
/tgs:push-to-svn --branch test-<n>
```

Let `push-to-svn` handle its own confirmation, file listing, and optional tag
prompt. Decline the optional release tag unless the user opts in — a reset is
typically not a tagging point.

### Step 6: Report

Print a final summary listing:
- The number of commits discarded
- The number of commits brought in from main
- The new SVN revision (from push-to-svn output)

## Decision Rules

- Only `test-<n>` (where n is a positive integer) is a valid argument. Reject
  `main`, `dev-<m>`, `feature/x`, etc.
- Pre-flight requires both the main worktree and `remote-test-<n>` worktree to
  be clean (no uncommitted changes, no half-finished SVN merges); otherwise
  fail with a clear instruction to run `/tgs:push-to-svn` or `/tgs:pull-from-svn`
  first.
- Hard reset is destructive: do not skip the explicit confirmation step even
  when the LOSE list looks small.
- Do **not** delete `remote/test-<n>`, the worktree, or the SVN URL — that is
  `cleanup-remote-test`'s job. This skill keeps the slot alive and ready for
  the next testing cycle.
- Can be called from any worktree in the project.

## Completion Checks

- `git -C <main-worktree> rev-parse test-<n>` equals `git -C <main-worktree> rev-parse main`.
- `push-to-svn` reported `Pushed to SVN r<rev>` (or `No changes to commit` if
  the branch was already aligned at the SVN level).
- The main worktree HEAD is on the same branch it started on (unless it was
  on `test-<n>`, in which case it stays).
