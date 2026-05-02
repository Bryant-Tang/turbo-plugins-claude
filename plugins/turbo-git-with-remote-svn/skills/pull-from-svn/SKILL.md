---
name: pull-from-svn
description: 'Pull the latest SVN changes into the corresponding remote-* worktree, commit them to the remote/* git branch, and merge into the specified git working branch. Use when the user wants to sync SVN updates into git, update from SVN, or pull SVN changes.'
argument-hint: 'Required: --branch <main|test-<n>>'
user-invocable: true
---

# pull-from-svn

## Purpose

Synchronise SVN changes into git:
1. Run `svn update` in the remote-* worktree
2. Commit the updated files to the `remote/*` branch
3. Merge `remote/*` into the specified git working branch

## Branch Mapping

| Working branch | Remote worktree | Remote git branch |
|---|---|---|
| `main` | `remote-main` | `remote/main` |
| `test-<n>` | `remote-test-<n>` | `remote/test-<n>` |

## Procedure

1. If `--branch` is not given, check the `TGS_DEFAULT_WORKING_BRANCH` environment variable. If it is set and valid (`main` or `test-<n>`), use that value. Otherwise, list the existing remote-* worktrees and use `AskUserQuestion` to ask which branch to pull into.
2. Call the script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/pull-from-svn.ps1" -Branch "main"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pull-from-svn.sh" --branch "main"
```

3. Interpret the script output:
   - **"Already up to date at SVN r\<rev\>"** → Report to the user and stop.
   - **"Pulled SVN r\<rev\> into \<branch\>"** → Report success, including the SVN revision and whether the main worktree was switched back to its original branch.
   - **Non-zero exit (merge conflict)** → The script will have printed the conflicting files. Guide the user to open the main worktree, resolve each conflict, stage the resolutions with `git add <file>`, run `git -C <main-worktree> merge --continue`, and if they were on a different branch before, switch back with `git checkout <original-branch>`.

## Decision Rules

- Only `main` and `test-<n>` (where n is a positive integer) are valid branch names. Reject any other branch (e.g., `dev-1`, `feature/x`) with a clear error.
- The script automatically switches the main worktree to `<branch>` before merging and switches back afterwards. The main worktree must be clean (no uncommitted changes) before calling the script; if it is not, ask the user to commit or stash first.
- Can be called from any worktree in the project — the script resolves all paths from the shared git directory.

## Completion Checks

- The `remote/*` branch contains a new "sync: svn r\<rev\>" commit.
- The working branch (`main` or `test-<n>`) contains a merge commit "Merge branch 'remote/\<branch\>' into \<branch\>".
- The main worktree is on the same branch it was on before the command ran (or on `<branch>` if a merge conflict occurred).

## Post-Pull Suggestion

If the pull succeeded (not "Already up to date") and the target branch was `main`, suggest:

> "All other working branches are now behind main. Run `/tgs:merge-main-into-all` to merge the update into every test-\<n\> and dev-\<n\> branch at once."
