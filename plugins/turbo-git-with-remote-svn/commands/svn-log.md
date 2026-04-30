---
description: 'Show SVN log history of the remote worktree for a given branch'
argument-hint: 'Optional: --branch <main|test-<n>> --limit <n> --verbose'
allowed-tools: Bash, PowerShell
---

Runs `svn log` inside the `remote-<branch>` worktree (e.g. `remote-main` or `remote-test-<n>`) and prints the SVN history. This is a read-only operation: the script does not run `svn update`, does not touch the main worktree, and does not switch git branches.

Run this command from any worktree belonging to the tgs project.

## Arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--branch` / `-Branch` | No | `TGS_SVN_LOG_DEFAULT_BRANCH` if set, otherwise `main` | Target branch. Accepts `main` or `test-<n>` |
| `--limit` / `-Limit` | No | `TGS_SVN_LOG_DEFAULT_LIMIT` if set, otherwise `50` | Number of revisions to show. Passed through as `svn log --limit <n>`. To see all revisions, pass a sufficiently large number (svn does not treat `0` as unlimited) |
| `--verbose` / `-Verbose` | No | on when `TGS_SVN_LOG_DEFAULT_VERBOSE` is `1` or `true`, otherwise off | When set, passes `-v` to `svn log` so each revision lists its changed paths |

## Config

Set the following keys in the `env` block of `.claude/settings.local.json`. All keys are optional — omit them to use the built-in defaults.

```json
{
  "env": {
    "TGS_SVN_LOG_DEFAULT_BRANCH": "main",
    "TGS_SVN_LOG_DEFAULT_LIMIT": "50",
    "TGS_SVN_LOG_DEFAULT_VERBOSE": ""
  }
}
```

`TGS_SVN_LOG_DEFAULT_BRANCH` must be `main` or `test-<n>`. `TGS_SVN_LOG_DEFAULT_LIMIT` must be a positive integer. `TGS_SVN_LOG_DEFAULT_VERBOSE` accepts `1` or `true` (case-insensitive) to enable verbose output by default, or leave empty to disable. All three can be overridden per-invocation via command arguments.

Run `/tgs:setup` to configure these interactively.

## Execution

Run from any worktree of the tgs project.

Default (branch `main`, limit `50`):

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.sh"
```

Specific branch:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.ps1" -Branch test-2
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.sh" --branch test-2
```

Larger limit and changed paths:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.ps1" -Branch main -Limit 200 -Verbose
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.sh" --branch main --limit 200 --verbose
```
