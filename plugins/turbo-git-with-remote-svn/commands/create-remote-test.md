---
description: 'Create a test-<n> git branch and a remote-test-<n> SVN sync worktree for a new release candidate environment'
argument-hint: '--svn-url <url> [--n <number>]'
allowed-tools: Bash, PowerShell
---

Creates the `test-<n>` and `remote/test-<n>` git branches, adds the `remote-test-<n>` worktree for SVN synchronisation, and updates the `.code-workspace` file. The `test-<n>` branch is checked out in the main worktree alongside `main` — no separate worktree is created for it. `--svn-url` is required; if the URL does not yet exist on the server it will be created automatically via `svn copy`.

Run this command from any worktree belonging to the tgs project.

## Arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--n` / `-N` | No | auto-increment | Numeric index for the test environment |
| `--svn-url` / `-SvnUrl` | Yes | — | SVN URL for the test branch. If the URL does not yet exist on the server it will be created via `svn copy` from the main SVN URL |

## Execution

Run from any worktree of the tgs project.

With auto-increment index:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-remote-test.ps1" -SvnUrl "https://svn.example.com/repo/branches/test-1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-remote-test.sh" --svn-url "https://svn.example.com/repo/branches/test-1"
```

With explicit index and SVN URL:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-remote-test.ps1" -N 2 -SvnUrl "https://svn.example.com/repo/branches/test-2"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-remote-test.sh" --n 2 --svn-url "https://svn.example.com/repo/branches/test-2"
```

After the script completes, run `/tgs:pull-from-svn --branch test-<n>` to complete the initial SVN sync.

If you have not already done so, run `/tgs:setup` in your main worktree to configure tgs environment variable defaults.
