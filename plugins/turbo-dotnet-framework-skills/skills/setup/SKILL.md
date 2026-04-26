---
name: setup
description: 'Set up or update plugin configuration in .claude/settings.local.json and create required companion files. Use when installing the plugin for the first time or when adding or adjusting environment variables and config files for build, run, db-management, memory, or markitdown skills.'
argument-hint: 'Optional: build | run | db | memory | markitdown | all'
user-invocable: true
---

# Setup

## Purpose

Configure `.claude/settings.local.json` and companion files so this plugin's skills and commands can run in the current workspace.

## What This Skill Configures

| Area | Env Vars | Companion File | Required For |
|---|---|---|---|
| Build | `BUILD_PROJECT_PATH`, `BUILD_MSBUILD_PATH` | — | `build-project` command |
| Build frontend | `BUILD_FRONTEND_DIR_PATH`, `BUILD_NODE_VERSION`, `BUILD_FRONTEND_INSTALL_COMMAND`, `BUILD_FRONTEND_BUILD_COMMAND` | — | `build-project` (optional) |
| Run | `RUN_IIS_EXPRESS_PATH`, `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` | — | `run-project` command |
| Test stash | `TEST_LOCAL_STASH_SHA` | — | `testing-and-proof` (optional) |
| DB | `DBHUB_TOML_FILE_PATH` | `.claude/dbhub.local.toml` | `db-management` |
| Memory | `MEMORY_SERVER_JSONL_FILE_PATH` | `.claude/memory-server.local.jsonl` | `memory` |
| MarkItDown | `MARKITDOWN_WORKDIR_PATH` | workdir directory | `markitdown` |

## Procedure

1. Read `.claude/settings.local.json` if it exists and extract the current `env` block. Note which keys already have real values versus placeholder values.
2. Identify which areas to configure based on the skill argument. If no argument is given, ask the user which skills they plan to use before collecting values.
3. For each area to configure, use the `AskUserQuestion` tool to ask the user about each env var. Ask one question per variable — do not batch all variables into a single summary table and ask for bulk confirmation. For each variable:
   - If missing or still a placeholder (contains all-caps segments like `ABSOLUTE`, `RELATIVE`, `YOUR`, or obvious template text), ask the user for the real value via `AskUserQuestion`.
   - If already set to a real value, ask the user via `AskUserQuestion` whether to keep or replace it. If the user chooses to keep it, skip to the next variable.
4. Write the updated `env` block back to `.claude/settings.local.json`, merging into any existing content so settings outside the `env` block are preserved.
5. For each companion file whose path was just configured, check whether that file or directory exists:
   - `DBHUB_TOML_FILE_PATH` — if the file does not exist, copy the template from `${CLAUDE_PLUGIN_ROOT}/default-config-files/.claude/dbhub.example.local.toml` to the configured path, then tell the user to edit the connection strings inside it.
   - `MEMORY_SERVER_JSONL_FILE_PATH` — if the file does not exist, create an empty file at that path.
   - `MARKITDOWN_WORKDIR_PATH` — if the directory does not exist, create it.
   - `.claude/frontend-standard.local.md` — if the file does not exist in the workspace root, copy the template from `${CLAUDE_PLUGIN_ROOT}/default-config-files/.claude/frontend-standard.example.local.md`.
6. Report what was created or updated, and call out any companion files the user still needs to edit manually.

## Decision Rules

- If `.claude/settings.local.json` already exists, merge into the `env` block only. Do not overwrite or remove any keys that are not part of this plugin's configuration.
- If a plugin-managed key already has a real value (not a placeholder), confirm with the user before replacing it. If the user chooses to keep the existing value, leave it unchanged.
- If `.claude/settings.json` also exists with an `env` block, keep this plugin's local values in `settings.local.json` so they stay out of version control.
- If the user passes `all`, configure every area in the table above.
- `BUILD_PROJECT_PATH` is a relative path from the workspace root to the `.csproj` file.
- `BUILD_MSBUILD_PATH` and `RUN_IIS_EXPRESS_PATH` are absolute paths to executable files on the machine.
- When collecting `RUN_IIS_APPLICATIONHOST_CONFIG_PATH`, ask the user which `applicationhost.config` they want to use before prompting for a path:
  - **Visual Studio auto-generated (recommended, project-level)** — located at `.vs\{SolutionName}\config\applicationhost.config` inside the workspace. This file is generated per-solution and keeps site bindings in version control proximity.
  - **User-level** — located at `%USERPROFILE%\Documents\IISExpress\config\applicationhost.config`. This is the global fallback used when no project-level config is present.
- `DBHUB_TOML_FILE_PATH` and `MEMORY_SERVER_JSONL_FILE_PATH` are absolute paths to files that the Docker containers can read via volume mount.
- `MARKITDOWN_WORKDIR_PATH` is an absolute path to a directory that the Docker container mounts as `/workdir`.
- Never overwrite an existing companion file that has been customized. Only create companion files if they are absent.
- Do not store credentials or connection strings in `.claude/settings.local.json`. The DBHub TOML file holds the actual database credentials; only the path to that file goes in the env block.
- When creating directories or files as separate shell steps, do not chain commands with `&&`.

## Completion Checks

- `.claude/settings.local.json` exists and the `env` block contains all configured keys with real, non-placeholder values.
- Every companion file or directory referenced by the configured env vars exists at the specified path.
- The user was told which companion files still require manual editing (DBHub connection strings, frontend standards).
- No credentials or secrets were written into `.claude/settings.local.json`.
