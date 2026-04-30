---
name: setup-all
description: 'Run the setup skill of every installed turbo-plugins-claude plugin in sequence. Use after first install or after updating multiple plugins.'
argument-hint: '[alias-csv | all]'
user-invocable: true
---

# Setup-All

## Purpose

Run each installed turbo-plugins-claude plugin's own `setup` skill in a single session. This skill is an orchestrator — it does not duplicate any setup logic itself; the authoritative setup steps for each plugin live in that plugin's own setup skill.

## Discovery

1. Read `~/.claude/plugins/installed_plugins.json` (Windows: `C:\Users\<username>\.claude\plugins\installed_plugins.json`).
2. Filter keys that end with `@turbo-plugins-claude`. Extract the alias from each key (the part before `@`).
3. Exclude `tpi` from the list.
4. If an `alias-csv` argument was provided (e.g. `tdp,tnf`), intersect with the detected list. If the argument is `all` or absent, use the full detected list.

## Procedure

1. Perform Discovery. If no eligible plugins are found, report this and stop.
2. Sort the eligible aliases in fixed order: `tdp` → `tnf` → `tgs` → remaining aliases alphabetically.
3. Use `AskUserQuestion` with `multiSelect: true` to show the ordered list and let the user choose which plugins to run setup for. Present all aliases as pre-selected options.
4. For each alias the user selected, in sorted order:
   a. Announce which plugin's setup is starting.
   b. Invoke the plugin's setup skill using the `Skill` tool with `skill: "<alias>:setup"`. If the plugin has no `setup` skill, mark as SKIPPED and continue.
   c. After the skill returns, record the outcome: DONE, SKIPPED, or FAILED.
5. Print an aggregate summary table: `alias | result`. For each FAILED entry, include the retry command `/<alias>:setup`.

## Decision Rules

- **Invocation method**: always use the `Skill` tool with the namespaced id `<alias>:setup`, not a slash command. The `Skill` tool preserves `AskUserQuestion` interactivity within the child skill.
- **Failure handling**: continue-on-error. A FAILED setup for one plugin does not abort the remaining plugins. Record the failure and proceed.
- **No setup skill**: if `<alias>:setup` is not available, mark as SKIPPED. Do not attempt to replicate the setup steps manually.
- **No caching**: re-read `installed_plugins.json` fresh on every invocation.
- **tpi exclusion**: `tpi` must never appear in the setup list, even if it is present in `installed_plugins.json`.
- **Unknown alias in argument**: if the user provides an alias not found in the installed list, warn and exclude it.

## Completion Checks

- Every alias the user selected has a result of DONE, SKIPPED, or FAILED.
- `tpi` does not appear in the execution list.
- All FAILED entries have an explicit retry command in the summary.
- The aggregate summary is shown before the skill exits.
