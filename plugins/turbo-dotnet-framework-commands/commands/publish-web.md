---
description: 'Publish the ASP.NET web project with MSBuild using a publish profile (.pubxml). On success the resolved output path is reported via a final PUBLISH_OUTPUT_PATH=<path> line.'
argument-hint: 'Optional: --profile <absolute-or-relative-path-to.pubxml> --configuration <Debug|Release|...> --platform <AnyCPU|x86|x64|...>'
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
    "PUBLISH_PUBXML_PATH": "relative/or/absolute/path/to/PublishProfile.pubxml",
    "PUBLISH_DEFAULT_CONFIGURATION": "Release",
    "PUBLISH_DEFAULT_PLATFORM": "AnyCPU"
  }
}
```

`PUBLISH_DEFAULT_CONFIGURATION` and `PUBLISH_DEFAULT_PLATFORM` are optional. When omitted, publish defaults to `Release` and `AnyCPU`. These can be overridden per-invocation via command arguments.

If any required key is missing or empty and no `--profile` argument is provided, stop and report the configuration problem before attempting the publish.

## Execution

Run from the workspace root. Do not chain with other commands using `&&`.

Default (uses `PUBLISH_PUBXML_PATH` env var, plus `PUBLISH_DEFAULT_CONFIGURATION` / `PUBLISH_DEFAULT_PLATFORM` when set, or `Release` / `AnyCPU` when unset):

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

Custom configuration and/or platform:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.ps1" -Configuration Release -Platform x64
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.sh" --configuration Release --platform x64
```

`--profile` / `-Profile` is optional. When supplied, it takes precedence over `PUBLISH_PUBXML_PATH`. The path may be absolute or relative to the workspace root; Windows and Unix path formats are both accepted.

`--configuration` / `-Configuration` and `--platform` / `-Platform` are optional and independent. Any valid MSBuild value is accepted (e.g. `Debug`, `Release`, `AnyCPU`, `x86`, `x64`). Per-invocation arguments take precedence over env var defaults.

Internally the script invokes MSBuild with `/p:PublishProfile=<basename>` plus `/p:PublishProfileRootFolder=<dir>` derived from the supplied path, instead of `/p:PublishProfileFullPath`. The former is imported by `Microsoft.WebApplication.targets` before the deploy default targets are computed, so `WebPublishMethod` and `PublishUrl` declared in the `.pubxml` are honored (e.g. a `FileSystem` profile actually deploys to `PublishUrl` rather than being overridden into a `Package`/zip output).

The script also passes `/p:Configuration=<value>` and `/p:Platform=<value>` as MSBuild global properties. These take precedence over any `<Configuration>` / `<Platform>` element in the `.pubxml`, so the resolved CLI / env var value is always the source of truth for build configuration. `WebPublishMethod`, `PublishUrl`, and other publish-specific settings remain driven by the `.pubxml`.

## Output

After MSBuild publishes successfully, the script prints four trailing lines:

```
Publish succeeded.
Method: <FileSystem|Package|MSDeploy|FTP|...>
Published to: <absolute path or PublishUrl value>
PUBLISH_OUTPUT_PATH=<same path as above>
```

The `PUBLISH_OUTPUT_PATH=` line is always the last line of stdout, intended for downstream tooling (e.g. tail-grep) to capture the resolved output path without parsing surrounding text.

The output path is read from the `<PublishUrl>` element of the `.pubxml` (taking the last occurrence when multiple are declared, matching MSBuild's "later wins" semantics). When `WebPublishMethod` is `FileSystem`, relative paths are resolved against the `.csproj` directory (matching MSBuild's `MSBuildProjectDirectory`-based normalization in `Microsoft.WebApplication.targets`) and a trailing backslash is trimmed. For other publish methods the raw `<PublishUrl>` value is reported as-is.

If `<PublishUrl>` is missing, empty, or contains MSBuild properties (e.g. `$(SolutionDir)bin\publish`) that cannot be resolved statically, a warning is written to stderr and the `PUBLISH_OUTPUT_PATH=` line is skipped, but the command still exits 0 because the underlying publish has already succeeded.
