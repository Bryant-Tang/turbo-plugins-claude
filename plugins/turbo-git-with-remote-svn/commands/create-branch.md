---
description: 'Create a git branch with a fully-qualified name from a specified base branch. Pre-flight checks the target name does not already exist, the base exists, and the main worktree is clean. Use when a higher-level workflow needs to create a branch by name without assuming any project-specific naming convention.'
argument-hint: 'Required: --name <full-branch-name> --base <base-branch>'
allowed-tools: Bash, PowerShell
---

# create-branch

Creates the named git branch from the specified base branch in the main worktree, then switches the main worktree to it. The command does not know about any project-specific naming convention — callers (e.g. `/tdp:start-dev`) are responsible for constructing the full branch name (`feature/<slug>`, `bugfix/<slug>`, etc.).

Run this command from any worktree belonging to the tgs project; the script auto-locates the main worktree.

## Arguments

| Argument | Required | Description |
|---|---|---|
| `--name` / `-Name` | Yes | Fully-qualified branch name (e.g. `feature/user-login`, `bugfix/issue-42`) |
| `--base` / `-Base` | Yes | Existing branch to use as the base (typically `main`) |

## Pre-flight Checks

The script verifies before making any changes:

1. `--name` does not already exist as a local branch.
2. `--base` exists as a local branch.
3. The main worktree is clean (no uncommitted changes).
4. `--name` matches a safe character set (`[A-Za-z0-9._/-]+`).

If any check fails, the script exits non-zero with a clear message and modifies no state.

## Execution

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-branch.ps1" -Name "feature/user-login" -Base "main"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-branch.sh" --name "feature/user-login" --base "main"
```

## Output

On success, prints `Created branch '<name>' from '<base>' in main worktree.` and exits 0.

On failure, prints the error to stderr and exits 1. State is unchanged.

## Caller Conventions

Callers are expected to compose names that fit the project's branch namespaces:

- `/tdp:start-dev` builds `feature/<slug>` or `bugfix/<slug>` depending on the work type.
- `/tdp:finish-dev` does **not** call this command; it uses `/tgs:archive` to rename branches into the `archives/` namespace.
- `/tgs:create-dev-worktree` and `/tgs:create-remote-test` manage their own `dev-<n>` / `test-<n>` namespaces directly without this command.

This command is a primitive — it has no opinion about which namespace a name belongs to.
