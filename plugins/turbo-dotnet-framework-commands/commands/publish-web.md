---
description: 'Publish the ASP.NET web project with MSBuild using a publish profile (.pubxml)'
argument-hint: 'Optional: --profile <absolute-or-relative-path-to.pubxml>'
allowed-tools: Bash, PowerShell
---

Publish the configured web project using MSBuild and a publish profile (.pubxml).

## Config

Set the following keys in the `env` block of `.claude/settings.local.json`. `BUILD_PROJECT_PATH` and `BUILD_MSBUILD_PATH` are required. `PUBLISH_PUBXML_PATH` is required unless the path is supplied via `--profile` at invocation time.

```json
{
  "env": {
    "BUILD_PROJECT_PATH": "relative/path/to/web-project.csproj",
    "BUILD_MSBUILD_PATH": "C:/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe",
    "PUBLISH_PUBXML_PATH": "relative/or/absolute/path/to/PublishProfile.pubxml"
  }
}
```

If any required key is missing or empty and no `--profile` argument is provided, stop and report the configuration problem before attempting the publish.

## Execution

Run from the workspace root. Do not chain with other commands using `&&`.

Default (uses `PUBLISH_PUBXML_PATH` env var):

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.sh"
```

Override the publish profile for this invocation only:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.ps1" -Profile "C:/path/to/PublishProfile.pubxml"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.sh" --profile "C:/path/to/PublishProfile.pubxml"
```

`--profile` / `-Profile` is optional. When supplied, it takes precedence over `PUBLISH_PUBXML_PATH`. The path may be absolute or relative to the workspace root; Windows and Unix path formats are both accepted.

Internally the script invokes MSBuild with `/p:PublishProfile=<basename>` plus `/p:PublishProfileRootFolder=<dir>` derived from the supplied path, instead of `/p:PublishProfileFullPath`. The former is imported by `Microsoft.WebApplication.targets` before the deploy default targets are computed, so `WebPublishMethod` and `PublishUrl` declared in the `.pubxml` are honored (e.g. a `FileSystem` profile actually deploys to `PublishUrl` rather than being overridden into a `Package`/zip output).
