---
description: 'Create a dev-<n> worktree for isolated personal development on a specified or new git branch'
argument-hint: 'Required: --branch <branch>  Optional: --n <number>'
allowed-tools: Bash, PowerShell
---

Creates a `dev-<n>` worktree for the specified git branch (creating the branch if it does not exist) and adds it to the `.code-workspace` file. The worktree is local-only — it has no corresponding SVN URL or `remote/*` branch.

Run this command from any worktree belonging to the tgs project.

## Arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--branch` / `-Branch` | Yes | — | Git branch to check out in the dev worktree. Created from the current HEAD of main if it does not exist |
| `--n` / `-N` | No | auto-increment | Numeric index for the dev worktree |

## Execution

Run from any worktree of the tgs project.

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-dev-worktree.ps1" -Branch "feature/my-feature"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-dev-worktree.sh" --branch "feature/my-feature"
```

With explicit index:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-dev-worktree.ps1" -Branch "feature/my-feature" -N 3
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-dev-worktree.sh" --branch "feature/my-feature" --n 3
```

After the script completes, open Claude Code in the new `dev-<n>` directory and run `/tgs:setup` to configure tgs environment variable defaults for that working directory.
