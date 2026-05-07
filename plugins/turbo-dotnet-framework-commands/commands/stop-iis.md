---
description: 'Stop the IIS Express process that matches the current repo and site configuration'
allowed-tools: Bash, PowerShell
---

Stop the IIS Express process associated with the current repository and site. Only the process whose executable path and command-line arguments match the configured settings is stopped — processes from other repositories or sites are left untouched.

## Config

Set the following keys in the `env` block of `.claude/settings.local.json`. `BUILD_PROJECT_PATH` and `RUN_IIS_EXPRESS_PATH` are required — the former is needed to resolve the site root and port that identify the matching IIS Express process. `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` is required when the target `IISUrl` uses `https`.

```json
{
  "env": {
    "BUILD_PROJECT_PATH": "relative/path/to/web-project.csproj",
    "RUN_IIS_EXPRESS_PATH": "C:/Program Files/IIS Express/iisexpress.exe",
    "RUN_IIS_APPLICATIONHOST_CONFIG_PATH": "relative/path/to/.vs/YourSolution/config/applicationhost.config"
  }
}
```

If `BUILD_PROJECT_PATH` or `RUN_IIS_EXPRESS_PATH` is missing or empty, stop and report the configuration problem before attempting to stop the process.

## Execution

Run from the workspace root. Do not chain with other commands using `&&`.

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.sh"
```

If no matching process is found, the script exits normally with a message indicating that no repo-specific IIS Express process was found. This is not an error — it means IIS Express was not running for this repo/site.
