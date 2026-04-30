---
name: setup
description: 'Set up or update tgs environment variable defaults in .claude/settings.local.json. Use when installing tgs for the first time or adjusting svn-log defaults and working branch defaults.'
argument-hint: ''
user-invocable: true
---

# Setup

## Purpose

Configure `.claude/settings.local.json` with the environment variables used by tgs commands and skills so their default behaviours match your workflow without requiring arguments on every invocation.

## What This Skill Configures

| Area | Env Vars | Companion File | Required For |
|---|---|---|---|
| svn-log defaults | `TGS_SVN_LOG_DEFAULT_BRANCH`, `TGS_SVN_LOG_DEFAULT_LIMIT`, `TGS_SVN_LOG_DEFAULT_VERBOSE` | — | `svn-log` command (all optional) |
| Working branch default | `TGS_DEFAULT_WORKING_BRANCH` | — | `pull-from-svn`, `push-to-svn` skills (optional) |

## Procedure

1. Read `.claude/settings.local.json` if it exists and extract the current `env` block. Note which `TGS_*` keys already have values.
2. For each env var in the table above, use the `AskUserQuestion` tool to ask the user whether to configure it and what value to set. Ask one question per variable — do not batch all variables into a single question. For each variable:
   - If missing or empty, ask whether the user wants to set a custom value (or leave it at the built-in default).
   - If already set to a real value, ask whether to keep or replace it. If the user chooses to keep it, skip to the next variable.
3. Write the updated `env` block back to `.claude/settings.local.json`, merging into any existing content so settings outside the `env` block are preserved.
4. Report what was updated and what each configured variable's built-in default is.

## Decision Rules

- If `.claude/settings.local.json` already exists, merge into the `env` block only. Do not overwrite or remove any keys that are not part of this plugin's configuration.
- Never overwrite existing keys set by other plugins. Only manage the four `TGS_*` keys listed in the table above.
- If `.claude/settings.json` also exists with an `env` block, keep tgs values in `settings.local.json` so they stay out of version control.
- `TGS_SVN_LOG_DEFAULT_BRANCH` must be `main` or `test-<n>` (where n is a positive integer). If left empty, the built-in default is `main`.
- `TGS_SVN_LOG_DEFAULT_LIMIT` must be a positive integer. If left empty, the built-in default is `50`.
- `TGS_SVN_LOG_DEFAULT_VERBOSE` accepts `1` or `true` (case-insensitive) to enable verbose mode by default, or empty string to disable. Built-in default is off (empty string).
- `TGS_DEFAULT_WORKING_BRANCH` must be `main` or `test-<n>` if provided. If left empty, `pull-from-svn` and `push-to-svn` will prompt via `AskUserQuestion` each time — which is the intended behaviour when you regularly switch between branches.
- Each tgs worktree is an independent working directory with its own `.claude/settings.local.json`. Run `/tgs:setup` separately in each worktree where you open Claude Code (typically the main worktree and any dev-<n> worktrees).
- When creating files as separate shell steps, do not chain commands with `&&`.

## Completion Checks

- `.claude/settings.local.json` exists and the `env` block contains all configured `TGS_*` keys.
- `TGS_SVN_LOG_DEFAULT_LIMIT` is a positive integer if provided.
- `TGS_SVN_LOG_DEFAULT_BRANCH` and `TGS_DEFAULT_WORKING_BRANCH` are valid branch names (`main` or `test-<n>`) if provided.
- No credentials or secrets were written into `.claude/settings.local.json`.
