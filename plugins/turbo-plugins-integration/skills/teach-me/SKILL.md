---
name: teach-me
description: 'Generate an integrated tutorial for installed turbo-plugins-claude plugins and answer follow-up questions. Use to onboard a new workspace or learn cross-plugin workflows.'
argument-hint: '[alias | workflow:<name>]'
user-invocable: true
---

# Teach-Me

## Purpose

Dynamically generate a unified learning document drawn entirely from the files of each installed turbo-plugins-claude plugin, then enter a multi-turn Q&A session. Because the content is read fresh every invocation, the tutorial always reflects the currently installed plugin versions.

## Discovery

1. Read `~/.claude/plugins/installed_plugins.json` (Windows: `C:\Users\<username>\.claude\plugins\installed_plugins.json`).
2. Filter keys ending with `@turbo-plugins-claude`. Extract aliases; exclude `tpi`.
3. For each alias, read the first entry in its array and note the `installPath` value — this is the authoritative path to that plugin's installed files. Do **not** hardcode the marketplace directory layout. `${CLAUDE_PLUGIN_ROOT}` only points to the tpi directory itself; do not use it to locate sibling plugins.
4. For each plugin, read these files from `<installPath>/`:
   - `README.md`
   - `.claude-plugin/plugin.json` (version, description)
   - All `skills/*/SKILL.md` files (frontmatter: name, description)
   - All `commands/*.md` files (frontmatter: name, description)
   - `skills/setup/SKILL.md` specifically, for its "What This Skill Configures" table (to extract env var names)

## Procedure

1. Perform Discovery. If no eligible plugins are found, report this and stop.
2. Use `AskUserQuestion` to ask which tutorial scope the user wants:
   - **Overview** — quick reference table only
   - **Per-plugin deep dive** — full chapter per plugin
   - **Cross-plugin workflows** — workflow chains combining multiple plugins
   - **Full guide** — all three sections
3. Generate the tutorial inline in chat using only content read in Discovery. Structure:

   **Section 1 — Overview** (always included):
   A markdown table: `| Plugin | Version | Description |` — one row per installed non-tpi plugin, sorted tdp → tnf → tgs → alphabetically.

   **Section 2 — Per-plugin chapters** (per-plugin or full scope):
   For each plugin, one section containing:
   - **Skills** table: `| Skill | Description |`
   - **Commands** table: `| Command | Description |` (omit if no commands)
   - **Key env vars** list: variable names from that plugin's `setup/SKILL.md` "What This Skill Configures" table (omit if no setup skill)

   **Section 3 — Cross-plugin workflows** (cross-plugin or full scope):
   Build workflow chains from the detected skill names across installed plugins:
   - `start-dev` (tdp) contributes to a "Start Development" step
   - `build-web` or `run-web` (tnf) contributes to a "Build / Run" step
   - `pull-from-svn` or `push-to-svn` (tgs) contributes to a "SVN Sync" step
   Render only chains where at least two plugins contribute. Do not invent workflows for skills not detected.

4. After rendering, enter the Q&A loop:
   - Use `AskUserQuestion` to ask 「想深入哪一段，或有什麼問題？」 with options corresponding to the rendered sections, plus 「結束」.
   - Answer questions using the files already read this invocation.
   - Repeat until the user selects 「結束」.
5. After Q&A ends, use `AskUserQuestion` to ask whether to save the tutorial as a file.
   - If yes: check whether `./TURBO_PLUGINS_GUIDE.md` exists. If it does, write to `./TURBO_PLUGINS_GUIDE-<YYYYMMDD-HHmmss>.md` instead. Use the `Write` tool. Confirm the saved path.
   - If no: exit without writing any file.

## Decision Rules

- Re-read all plugin files on every invocation. Do not use content from previous runs.
- Chapter ordering: tdp → tnf → tgs → others alphabetically (consistent with setup-all).
- If a plugin's `README.md` is missing, fall back to the `plugin.json` description plus skill/command frontmatter only. Never invent content.
- Section 3 workflows are derived from actually installed skill names only. Never hardcode a workflow that depends on plugins not found in Discovery.
- If an argument names a single alias (e.g. `/tpi:teach-me tdp`): render only that plugin's per-plugin chapter and enter Q&A.
- If an argument is `workflow:<name>` (e.g. `workflow:svn-sync`): jump directly to the matching cross-plugin workflow and enter Q&A.
- Do not write any file unless the user explicitly requests it at the end of Q&A.
- Never overwrite `./TURBO_PLUGINS_GUIDE.md`; use a timestamp-suffixed name when the base file already exists.

## Completion Checks

- Every installed non-tpi plugin appears exactly once in the tutorial.
- All tutorial content is traceable to files read during this invocation.
- The Q&A loop exits only after the user explicitly selects 「結束」.
- If the user chose to save, the file exists at the confirmed path and `./TURBO_PLUGINS_GUIDE.md` was not overwritten if it already existed.
