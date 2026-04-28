---
description: 'Start the ASP.NET web project in detached IIS Express and confirm the port is listening'
argument-hint: 'Optional: start-only | restart'
allowed-tools: Bash, PowerShell
---

Start the configured web project under IIS Express in the background and verify the port is listening.

Run `build-web` first when the latest web binaries may not exist or may be stale.

## Config

Set the following keys in the `env` block of `.claude/settings.local.json`. `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` is required when the target `IISUrl` uses `https`. The browser URL and port are derived from the `IISUrl` entry in the web csproj referenced by `BUILD_PROJECT_PATH`.

```json
{
  "env": {
    "BUILD_PROJECT_PATH": "relative/path/to/web-project.csproj",
    "RUN_IIS_EXPRESS_PATH": "C:/Program Files/IIS Express/iisexpress.exe",
    "RUN_IIS_APPLICATIONHOST_CONFIG_PATH": "relative/path/to/.vs/YourSolution/config/applicationhost.config"
  }
}
```

If the config file is missing or either required key is empty, stop and report the configuration problem before attempting startup.

## Execution

Run each script as a separate step from the workspace root. Do not chain them with `&&`.

### Default / `restart` (stop any existing instance first, then start)

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.ps1"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/start-iis-detached.ps1"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/check-iis-listening.ps1"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-iis-detached.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-iis-listening.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.sh"
```

### `start-only` (skip stop, start directly — use when IIS is known to not be running)

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/start-iis-detached.ps1"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/check-iis-listening.ps1"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-iis-detached.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-iis-listening.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.sh"
```

If `stop-iis` reports no existing process, continue. Once `check-iis-listening` shows the configured port in `LISTENING` state, `get-target-url` will output the site URL — report this URL to the user so they can open it in a browser.
