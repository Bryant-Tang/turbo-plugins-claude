---
description: 'Create a new tgs project structure with a main git worktree, a remote-main SVN sync worktree, and a .code-workspace file'
argument-hint: 'Required: --svn-url <url>  Optional: --path <dir> --name <name>'
allowed-tools: Bash, PowerShell
---

Build the initial project structure at the specified location. The project will have a `main` git branch, a `remote/main` sync branch, and a `remote-main` worktree where SVN content is checked out.

## Arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--svn-url` / `-SvnUrl` | Yes | — | SVN URL to check out into the remote-main worktree |
| `--path` / `-Path` | No | current directory | Directory that will contain the project folder |
| `--name` / `-Name` | No | basename of `--path` | Project name (also the folder name) |

## Execution

Run from any directory. Do not chain with other commands using `&&`.

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-project.ps1" -SvnUrl "https://svn.example.com/repo/trunk"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --svn-url "https://svn.example.com/repo/trunk"
```

With all arguments:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-project.ps1" -SvnUrl "https://svn.example.com/repo/trunk" -Path "C:/Projects" -Name "myproject"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --svn-url "https://svn.example.com/repo/trunk" --path "/c/Projects" --name "myproject"
```

After the script completes, run `/tgs:pull-from-svn --branch main` to commit the checked-out SVN files into the `remote/main` branch and merge them into `main`.

Then open Claude Code in the new project directory and run `/tgs:setup` to configure tgs environment variable defaults for that working directory.
