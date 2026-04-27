---
description: 'Build the ASP.NET web project with MSBuild and optionally package frontend assets'
argument-hint: 'Optional: --configuration <Debug|Release|...> --platform <AnyCPU|x86|x64|...>'
allowed-tools: Bash, PowerShell
---

Build the configured web project using the repository-standard MSBuild workflow.

## Config

Set the following keys in the `env` block of `.claude/settings.local.json`. Only `BUILD_PROJECT_PATH` and `BUILD_MSBUILD_PATH` are required; omit the frontend keys when the project has no Node-based asset packaging step.

```json
{
  "env": {
    "BUILD_PROJECT_PATH": "relative/path/to/web-project.csproj",
    "BUILD_MSBUILD_PATH": "C:/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe",
    "BUILD_DEFAULT_CONFIGURATION": "Debug",
    "BUILD_DEFAULT_PLATFORM": "AnyCPU",
    "BUILD_FRONTEND_DIR_PATH": "relative/path/to/frontend-or-web-project-dir/",
    "BUILD_NODE_VERSION": "v24.14.0",
    "BUILD_FRONTEND_INSTALL_COMMAND": "npm install",
    "BUILD_FRONTEND_BUILD_COMMAND": "npm run build"
  }
}
```

`BUILD_DEFAULT_CONFIGURATION` and `BUILD_DEFAULT_PLATFORM` are optional. When omitted, the build defaults to `Debug` and `AnyCPU`. These can be overridden per-invocation via command arguments.

If any required key is missing or empty, stop and report the configuration problem before attempting the build.

## Execution

Run from the workspace root. Do not chain with other commands using `&&`.

Default (uses `BUILD_DEFAULT_CONFIGURATION` / `BUILD_DEFAULT_PLATFORM` env vars, or `Debug` / `AnyCPU` when unset):

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/build-web.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/build-web.sh"
```

Custom configuration and/or platform:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/build-web.ps1" -Configuration Release -Platform x64
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/build-web.sh" --configuration Release --platform x64
```

Both `--configuration` / `-Configuration` and `--platform` / `-Platform` are optional and independent. Any valid MSBuild value is accepted (e.g. `Debug`, `Release`, `AnyCPU`, `x86`, `x64`). Per-invocation arguments take precedence over env var defaults.

If `BUILD_FRONTEND_DIR_PATH` is configured, the script runs the frontend install and build commands after MSBuild succeeds. If `BUILD_NODE_VERSION` is configured, validate the active Node version matches it before running frontend commands. Report build warnings separately from errors — warnings alone do not constitute build failure.
