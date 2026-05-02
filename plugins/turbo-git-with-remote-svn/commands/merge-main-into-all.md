---
description: 'Merge the latest main branch into every non-remote/* branch in this tgs project'
argument-hint: 'No arguments'
allowed-tools: Bash, PowerShell
---

Merges `main` into every local branch that is not `main` itself and not a `remote/*` branch. This is the recommended follow-up after a successful `pull-from-svn --branch main` to propagate SVN updates to all working branches (`test-<n>`, `dev-<n>`, etc.).

Run this command from any worktree belonging to the tgs project.

## Execution

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/merge-main-into-all.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-main-into-all.sh"
```

## Output Interpretation

The script prints one line per branch:

| Line | Meaning |
|---|---|
| `OK <branch>` | `main` was merged into `<branch>` successfully (including "Already up to date") |
| `SKIP <branch> (<reason>)` | Branch was skipped — either its worktree has uncommitted changes, or the main worktree is dirty and is needed for the checkout |
| `CONFLICT <branch> (merge aborted)` | A merge conflict was detected; the merge was automatically aborted, leaving `<branch>` unchanged |

Exit code is `0` if all branches were either merged successfully or skipped. Exit code is `1` if any branch had a merge conflict or if a fatal error occurred.

## After the Script

- **SKIP**: Ask the user to commit or stash the dirty changes in the indicated worktree, then re-run the command.
- **CONFLICT**: The branch was not modified (merge aborted). Guide the user to check out the branch manually, run `git merge main`, resolve the conflicts, and commit.
