---
name: setup
description: 'Set up or update .NET Framework build, run, and publish configuration in .claude/settings.local.json. Use when installing the tnf plugin for the first time or when adjusting MSBuild path, IIS Express path, publish profile, or csproj settings.'
argument-hint: 'Optional: build | run | publish | all'
user-invocable: true
---

# Setup

## Purpose

Configure `.claude/settings.local.json` with the environment variables required by the `build-web`, `run-web`, and `publish-web` commands so they can run in the current workspace.

## What This Skill Configures

| Area | Env Vars | Companion File | Required For |
|---|---|---|---|
| Build | `BUILD_PROJECT_PATH`, `BUILD_MSBUILD_PATH` | — | `build-web` command |
| Build defaults | `BUILD_DEFAULT_CONFIGURATION`, `BUILD_DEFAULT_PLATFORM` | — | `build-web` (optional) |
| Build frontend | `BUILD_FRONTEND_DIR_PATH`, `BUILD_NODE_VERSION`, `BUILD_FRONTEND_INSTALL_COMMAND`, `BUILD_FRONTEND_BUILD_COMMAND` | — | `build-web` (optional) |
| Run | `RUN_IIS_EXPRESS_PATH`, `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` | — | `run-web` command |
| Publish | `PUBLISH_PUBXML_PATH` | — | `publish-web` command |
| Publish defaults | `PUBLISH_DEFAULT_CONFIGURATION`, `PUBLISH_DEFAULT_PLATFORM` | — | `publish-web` (optional) |

## Procedure

1. Read `.claude/settings.local.json` if it exists and extract the current `env` block. Note which keys already have real values versus placeholder values.
2. Identify which areas to configure based on the skill argument. If no argument is given, ask the user which commands they plan to use before collecting values.
3. For each area to configure, use the `AskUserQuestion` tool to ask the user about each env var. Ask one question per variable — do not batch all variables into a single summary table and ask for bulk confirmation. For each variable:
   - If missing or still a placeholder (contains all-caps segments like `ABSOLUTE`, `RELATIVE`, `YOUR`, or obvious template text), ask the user for the real value via `AskUserQuestion`.
   - If already set to a real value, ask the user via `AskUserQuestion` whether to keep or replace it. If the user chooses to keep it, skip to the next variable.
4. Write the updated `env` block back to `.claude/settings.local.json`, merging into any existing content so settings outside the `env` block are preserved.
5. Report what was updated.

## Decision Rules

- If `.claude/settings.local.json` already exists, merge into the `env` block only. Do not overwrite or remove any keys that are not part of this plugin's configuration.
- If a plugin-managed key already has a real value (not a placeholder), confirm with the user before replacing it. If the user chooses to keep the existing value, leave it unchanged.
- If `.claude/settings.json` also exists with an `env` block, keep this plugin's local values in `settings.local.json` so they stay out of version control.
- If the user passes `all`, configure every area in the table above.
- `BUILD_PROJECT_PATH` is a relative path from the workspace root to the `.csproj` file.
- `PUBLISH_PUBXML_PATH` is the path to a `.pubxml` publish profile file. It may be absolute or relative to the workspace root. This variable is optional when `--profile` is supplied at invocation time.
- `BUILD_MSBUILD_PATH` and `RUN_IIS_EXPRESS_PATH` are absolute paths to executable files on the machine.
- `BUILD_DEFAULT_CONFIGURATION` and `BUILD_DEFAULT_PLATFORM` are optional. If omitted, builds use `Debug` and `AnyCPU` by default. Accepted values are any valid MSBuild configuration or platform string (e.g. `Debug`, `Release`, `AnyCPU`, `x86`, `x64`). These defaults can always be overridden at invocation time by passing `--configuration` / `--platform` arguments to the build command.
- `PUBLISH_DEFAULT_CONFIGURATION` and `PUBLISH_DEFAULT_PLATFORM` are optional. If omitted, publishes use `Release` and `AnyCPU` by default (deliberately different from the build defaults). Accepted values follow the same rules as the build defaults. These can be overridden at invocation time by passing `--configuration` / `--platform` arguments to the `publish-web` command.
- When collecting `RUN_IIS_APPLICATIONHOST_CONFIG_PATH`:
  1. **Detect solution name**: scan the workspace root for `.sln` files. If exactly one is found, let `solutionName` = that file's base name (without the `.sln` extension). If there are multiple or none, `solutionName = null`.
  2. **Ask the user** via `AskUserQuestion` (single select) which config to use:
     - If `solutionName != null`: present `.vs/<solutionName>/config/applicationhost.config` as the first option (Recommended), plus the user-level path (`%USERPROFILE%\Documents\IISExpress\config\applicationhost.config`) as a second option, plus "Other…" for free-form input.
     - If `solutionName == null`: present the VS project-level option (description only, no specific path pre-filled) as the first option (Recommended), the user-level path as a second option, and "Other…" for free-form input.
  3. **Check if the file exists** (resolve the chosen path to an absolute path first):
     - If **not found**: run `git worktree list --porcelain` and scan each worktree for the same relative path.
       - **Found in another worktree**: create parent directories (as a separate step, not chained with `&&`), then copy the file. Announce "Copied applicationhost.config from `<source-worktree-basename>`."
       - **Not found anywhere**: inform the user that the file does not exist yet and Visual Studio will generate it on the first build or run; advise re-running `/tnf:setup` afterwards to verify physicalPath. Write the path value and skip physicalPath correction.
  4. **physicalPath correction** (run when the file exists):
     - Read `BUILD_PROJECT_PATH` from the current `env` block. If not yet set, inform the user and skip this step.
     - Compute `expectedPhysicalPath` = absolute path of `dirname(BUILD_PROJECT_PATH)` relative to the workspace root, in Windows backslash format (e.g. `C:\Projects\MyProject\src\Web`).
     - Read the applicationhost.config XML. Locate the matching site: first try `<site name="<X>">` where X equals `basename(dirname(BUILD_PROJECT_PATH))`; if not found, try a site whose `<binding bindingInformation="...">` has a port matching the `<IISUrl>` port from the `.csproj` file.
     - If no site can be matched, warn the user and skip physicalPath correction.
     - Compare the `physicalPath` attribute of that site's `<virtualDirectory path="/">` element (case-insensitive, treating backslash and forward-slash as equivalent):
       - If correct: announce "physicalPath is correct — no changes needed."
       - If different: use the Edit tool to update only that attribute value to `expectedPhysicalPath` (preserve all other XML content). Announce "physicalPath updated from `<old>` to `<expectedPhysicalPath>`."
- Never overwrite existing keys set by other plugins. Only manage the `BUILD_*`, `RUN_*`, and `PUBLISH_*` keys listed in the table above.
- When creating files as separate shell steps, do not chain commands with `&&`.
- Path variables (`BUILD_PROJECT_PATH`, `BUILD_MSBUILD_PATH`, `BUILD_FRONTEND_DIR_PATH`, `RUN_IIS_EXPRESS_PATH`, `RUN_IIS_APPLICATIONHOST_CONFIG_PATH`, `PUBLISH_PUBXML_PATH`) accept any path format the user provides — Windows absolute with backslash (`C:\...`) or forward slash (`C:/...`), Unix absolute (`/path/...`), Git Bash drive format (`/c/...`), or relative with or without `./` prefix. Write the value as-is to `settings.local.json`; the underlying scripts (both bash and PowerShell) normalize all these formats automatically.
- Do not accept or suggest paths using the `.\` prefix (Windows-style dot-backslash relative, e.g. `.\src\Web.csproj`). The bash script's path resolver does not strip `.\`. Prefer `relative/path` or `./relative/path` format for relative paths.

## Completion Checks

- `.claude/settings.local.json` exists and the `env` block contains all configured `BUILD_*`, `RUN_*`, and `PUBLISH_*` keys with real, non-placeholder values.
- No credentials or secrets were written into `.claude/settings.local.json`.
- If `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` was configured and the corresponding file exists: the applicationhost.config's matching site has a `physicalPath` equal to the workspace root's web project directory in Windows backslash format.
