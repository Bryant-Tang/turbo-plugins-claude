---
name: dependency-check
description: 'Check external dependencies for installed turbo-plugins-claude plugins and report recommended global tools. Use to diagnose missing dependencies before they cause errors at runtime.'
user-invocable: true
---

# Dependency-Check

## Purpose

Perform two categories of checks and print a single consolidated report:

1. **Plugin dependencies** — For each installed turbo-plugins-claude plugin, check whether its required or optional external tools are present on the system.
2. **Recommended tools** — Regardless of which plugins are installed, check a fixed set of globally recommended tools and settings.

This skill is read-only: it checks and reports; it does not install anything.

## Discovery

### D1 — Installed plugin list

1. Read `~/.claude/plugins/installed_plugins.json` (Windows: `C:\Users\<username>\.claude\plugins\installed_plugins.json`).
2. Filter keys ending with `@turbo-plugins-claude`. Extract the alias (the part before `@`) for each key.
3. Exclude `tpi` from the list.

### D2 — Plugin dependency table

Use only the entries whose alias is present in the installed list (from D1).

| Plugin alias | Dependency | Type     | Check command           | Install hint |
|---|---|---|---|---|
| `tdp`        | `docker`   | required | `docker --version`      | https://docs.docker.com/get-docker/ |
| `tgs`        | `svn`      | required | `svn --version`         | https://subversion.apache.org |
| `tnf`        | `node`     | optional | `node --version`        | https://nodejs.org |

For `tnf`/`node`: the check applies only when the env var `BUILD_FRONTEND_DIR_PATH` is set in the project's `.claude/settings.local.json`. If the env var is absent, mark the row as `– (not configured)` instead of checking.

### D3 — Build the check list

From D2, collect only rows whose alias is in the installed list. If the installed list is empty (no non-tpi turbo-plugins-claude plugins found), skip Section 1 of the output entirely.

## Procedure

### P1 — Run plugin dependency checks

For each row collected in D3:

1. **If the row is `tnf`/`node` and `BUILD_FRONTEND_DIR_PATH` is not set**: mark status as `– (not configured)` and skip the check command.
2. **Otherwise**: run the check command in a shell.
   - Exit 0 and non-empty stdout → status `✓ installed`
   - Exit non-zero or command not found → status `✗ MISSING`

Record `(alias, dependency, type, status, install_hint)` for each row.

### P2 — Run recommended tool checks

Perform each check below unconditionally:

| Item | Check | Install hint |
|---|---|---|
| `ENABLE_LSP_TOOL=1` (env var) | Read `.claude/settings.local.json` in the current working directory. Check if `env.ENABLE_LSP_TOOL` equals `"1"`. | Add `"ENABLE_LSP_TOOL": "1"` under `env` in `.claude/settings.local.json` |
| `csharp-ls` | `csharp-ls --version` | `dotnet tool install -g csharp-ls` |
| `typescript-language-server` | `typescript-language-server --version` | `npm i -g typescript-language-server typescript` |

Status values:
- `ENABLE_LSP_TOOL=1`: `✓ set` or `✗ NOT SET`
- Commands: `✓ installed` or `✗ NOT FOUND`

### P3 — Print the report

Print the report to the chat in plain text (no markdown table syntax — use aligned columns):

```
Dependency Check

Required / optional dependencies
  plugin  dependency  type      status
  tdp     docker      required  ✓ installed
  tgs     svn         required  ✗ MISSING — install Subversion: https://subversion.apache.org
  tnf     node        optional  ✓ installed

Recommended tools
  item                            status
  ENABLE_LSP_TOOL=1 (env var)    ✗ NOT SET — add "ENABLE_LSP_TOOL": "1" to env in .claude/settings.local.json
  csharp-ls                       ✗ NOT FOUND — dotnet tool install -g csharp-ls
  typescript-language-server      ✓ installed
```

Column alignment rules:
- For Section 1: align all four columns (`plugin`, `dependency`, `type`, `status+hint`) with at least two spaces between columns.
- For Section 2: align `item` and `status+hint` with at least two spaces between columns.
- The install hint is appended inline after the status, preceded by ` — `.

If Section 1 has no rows (no eligible plugins installed), replace it with:

```
Required / optional dependencies
  (no turbo-plugins-claude plugins installed — nothing to check)
```

### P4 — Print missing-required summary

After the report, scan for rows where `type == required` and `status == ✗ MISSING`. For each such row, print a prominent warning block:

```
⚠ Missing required dependencies detected:

  tdp requires docker — the following features will not work:
    • dbhub MCP server
    • memory-server MCP server
    • markitdown MCP server
  Install Docker: https://docs.docker.com/get-docker/

  tgs requires svn — the following features will not work:
    • pull-from-svn
    • push-to-svn
    • svn-log
  Install Subversion: https://subversion.apache.org
```

Use the feature lists below:

| Plugin | Dependency | Affected features |
|---|---|---|
| `tdp` | `docker` | dbhub MCP server, memory-server MCP server, markitdown MCP server |
| `tgs` | `svn` | pull-from-svn, push-to-svn, svn-log |

If no required dependencies are missing, omit the warning block entirely.

## Decision Rules

- **Read `installed_plugins.json` fresh** on every invocation. Do not cache results across runs.
- **No installation**: this skill only reads and reports. Never attempt to install or modify any tool or setting.
- **`tnf`/`node` conditionality**: the `BUILD_FRONTEND_DIR_PATH` check reads `.claude/settings.local.json` in the current working directory only (project scope). If the file does not exist or has no `env` block, treat the env var as not set.
- **Command execution**: run each check command via the Bash tool (or PowerShell on Windows). Capture exit code and stdout; ignore stderr for status determination.
- **Platform**: on Windows, prefix `node --version`, `csharp-ls --version`, and `typescript-language-server --version` with `cmd /c` if the Bash tool is unavailable. `docker --version` and `svn --version` work the same on both platforms.
- **Unknown aliases**: if an installed alias has no entry in the D2 table (e.g. a future plugin), skip it silently — do not add a row for it.
- **`tpi` exclusion**: `tpi` must never appear as a plugin row in the output.

## Completion Checks

- Every alias in the installed list (excluding `tpi`) that has an entry in the D2 table appears exactly once in Section 1.
- The `tnf`/`node` row shows `– (not configured)` when `BUILD_FRONTEND_DIR_PATH` is absent from `.claude/settings.local.json`.
- All three recommended items appear in Section 2.
- The warning block in P4 appears if and only if at least one required dependency is `✗ MISSING`.
- No installation or file modification was performed.
