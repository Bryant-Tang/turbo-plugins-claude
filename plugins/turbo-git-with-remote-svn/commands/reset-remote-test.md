---
description: 'Reset a test-<n> branch back to main, then publish to SVN. Commits referenced by tags remain reachable. Use when one test cycle has ended and the slot will be reused for the next round, when the user wants to clear test-only data, or when "reset test branch" / "align test to main" is requested.'
argument-hint: 'Required: --n <number>'
allowed-tools: Bash, PowerShell
---

# reset-remote-test

## Purpose

Re-align a `test-<n>` branch with `main` between testing cycles, keeping the
SVN test branch URL alive (so any deployment pipeline pointing at it stays
valid):

1. Show the user every commit currently on `test-<n>` that is **not** in
   `main` — those commits will leave the `test-<n>` branch tip after the
   reset (any commit referenced by a release tag or another ref remains
   reachable in the git object database)
2. After confirmation, hard-reset `test-<n>` to `main` in the main worktree
3. Push the reset content up to SVN via `push-to-svn`

This command never touches the SVN URL itself nor the local worktree / branch
metadata — only the contents of `test-<n>` and the SVN test branch are
realigned.

## Why "leaving" rather than "discarding"

`git reset --hard` only moves the branch pointer; the underlying commit
objects are not deleted from the git object database. As long as a commit is
referenced by **any** ref — a release tag, another branch, or even the
reflog — it remains reachable via `git log <ref>`, `git checkout <hash>`, or
`git show <tag>`. SVN history on `branches/test-<n>` is also untouched: the
push that follows the reset adds a new revision rather than rewriting older
ones.

In this project's workflow, every push to `test-<n>` typically gets a release
tag, so reset is non-destructive in practice — the commits simply stop being
listed under the `test-<n>` branch.

## Tool Preference

Read / Write / Edit / Glob / Grep / LSP for any file inspection or change.
Avoid using Bash / PowerShell / Python / Node.js for filesystem operations.
Bash / PowerShell are only for invoking the scripts that this command
delegates to.

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
<hash> <subject>     ← commits leaving test-<n> after reset (still reachable via tags / refs)
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

將離開 test-<n> 分支（test-<n> 上不在 main 的 commit，N 個——若已被 release tag 或其它 ref 指到，仍可透過該 ref 找回）：
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

Delegate to the existing `push-to-svn` command to publish the reset content.
Suggest a commit message such as `reset test-<n> to main after release`:

```
/tgs:push-to-svn --branch test-<n>
```

Let `push-to-svn` handle its own confirmation, file listing, and optional tag
prompt. Decline the optional release tag unless the user opts in — a reset is
typically not a tagging point.

### Step 6: Report

Print a final summary listing:
- The number of commits that left the `test-<n>` tip
- The number of commits brought in from main
- The new SVN revision (from push-to-svn output)
- A reminder that any tagged commits remain reachable via their tags

## Decision Rules

- Only `test-<n>` (where n is a positive integer) is a valid argument. Reject
  `main`, `dev-<m>`, `feature/x`, etc.
- Pre-flight requires both the main worktree and `remote-test-<n>` worktree to
  be clean (no uncommitted changes, no half-finished SVN merges); otherwise
  fail with a clear instruction to run `/tgs:push-to-svn` or `/tgs:pull-from-svn`
  first.
- Hard reset moves the branch pointer; do not skip the explicit confirmation
  step even when the LOSE list looks small. The confirmation prompt should
  remind the user that release tags preserve history.
- Do **not** delete `remote/test-<n>`, the worktree, or the SVN URL — that is
  `cleanup-remote-test`'s job. This command keeps the slot alive and ready for
  the next testing cycle.
- Can be called from any worktree in the project.

## Completion Checks

- `git -C <main-worktree> rev-parse test-<n>` equals `git -C <main-worktree> rev-parse main`.
- `push-to-svn` reported `Pushed to SVN r<rev>` (or `No changes to commit` if
  the branch was already aligned at the SVN level).
- The main worktree HEAD is on the same branch it started on (unless it was
  on `test-<n>`, in which case it stays).
- Any release tag created on the previous tip of `test-<n>` still resolves
  with `git rev-parse <tag>` and `git show <tag>`.
