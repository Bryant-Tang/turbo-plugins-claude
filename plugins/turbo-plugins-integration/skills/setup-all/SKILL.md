---
name: setup-all
description: 'Run the setup skill of every installed turbo-plugins-claude plugin in sequence, then propagate the resulting env values to peer worktrees in the same project. Use after first install, after updating multiple plugins, or after adding new worktrees.'
argument-hint: '[alias-csv | all]'
user-invocable: true
---

# Setup-All

## Purpose

Run each installed turbo-plugins-claude plugin's own `setup` skill in a single session. In a tgs multi-worktree project, also propagate the resulting env configuration to every other worktree the user selects — so each worktree's `.claude/settings.local.json` is kept in sync without re-answering the same questions per worktree.

This skill is an orchestrator — it does not duplicate any setup logic itself; the authoritative setup steps for each plugin live in that plugin's own setup skill.

## Discovery

### D1 — Alias discovery

1. Read `~/.claude/plugins/installed_plugins.json` (Windows: `C:\Users\<username>\.claude\plugins\installed_plugins.json`).
2. Filter keys that end with `@turbo-plugins-claude`. Extract the alias from each key (the part before `@`).
3. Exclude `tpi` from the list.
4. If an `alias-csv` argument was provided (e.g. `tdp,tnf`), intersect with the detected list. If the argument is `all` or absent, use the full detected list.

### D2 — Alias selection

Use `AskUserQuestion` with `multiSelect: true` to show the ordered list and let the user choose which plugins to run setup for. Sort order: `tdp` → `tnf` → `tgs` → remaining aliases alphabetically. Present all aliases as pre-selected options. If no eligible plugins are found, report this and stop.

### D3 — Worktree discovery

Run `git worktree list --porcelain` from the current working directory. Parse the output into a list of `{ path, branch }` entries (one per blank-line-separated block; `branch` may be `detached` for detached HEADs).

The **primary worktree** for this run is whichever entry's `path`, after resolving with `realpath`, equals the cwd at invocation. The user does not need to be in the git main worktree; whichever worktree they invoked from is primary.

**Trigger single-worktree mode** (skip D4 and all propagation) if:
- `git worktree list --porcelain` fails or produces no output (not a git repo or no worktrees), OR
- The result contains only one worktree entry.

Announce single-worktree mode: "Single-worktree project detected — running setup in current worktree only." Then proceed directly to P2.

### D4 — Peer worktree selection

Use `AskUserQuestion` with `multiSelect: true`:
- Question: `"Setup will run interactively in <primary-basename>. Which other worktrees should receive the same env values?"`
- Options: each non-primary worktree. Label = directory basename. Description = `"branch: <branch>"`.
- Default: all options pre-selected.

If the user selects zero peers, proceed with primary-only setup (no propagation step). Announce: "No peer worktrees selected — setup will apply to current worktree only."

## Procedure

### P1 — Snapshot init

Read `<primary>/.claude/settings.local.json` if it exists and capture its `env` block as `envBefore` (an object). If the file does not exist or has no `env` key, treat `envBefore` as `{}`.

### P2 — Per-alias loop

For each alias the user selected in D2, in sorted order:

1. Re-read primary's `.claude/settings.local.json` → `envBefore_alias` (captures changes written by the previous alias's setup).
2. Announce which plugin's setup is starting.
3. Invoke the plugin's setup skill using the `Skill` tool with `skill: "<alias>:setup"`. If the plugin has no `setup` skill, mark as SKIPPED and continue.
4. Re-read primary's `.claude/settings.local.json` → `envAfter_alias`.
5. Compute `aliasChanges[alias]`: collect every key `k` where `k` is new (not in `envBefore_alias`) or its value changed (`envBefore_alias[k] !== envAfter_alias[k]`). Store as `{ k: envAfter_alias[k], ... }`. Keys the user chose to keep unchanged produce no diff and are excluded — this is correct.
6. Merge `aliasChanges[alias]` into a flat `propagationSet` object (last-write-wins across aliases; no two plugins manage the same key in practice).
7. Record alias outcome: DONE, SKIPPED, or FAILED.

Continue on error — a FAILED alias does not abort the remaining aliases.

**If in single-worktree mode** or **user selected zero peers in D4**: after all aliases complete, skip P2.5–P5 and go directly to P6.

**If `propagationSet` is empty** after all aliases complete (e.g. every alias was SKIPPED, or the user kept all existing values unchanged): skip P2.5–P5, print P6 summary with only the plugin section.

### P2.5 — Smart key handling

Before entering the override discovery funnel, handle the two keys that have intelligent per-worktree defaults. Run each sub-step only when the corresponding key is in `propagationSet` and at least one peer was selected in D4.

**P2.5-A — MARKITDOWN_WORKDIR_PATH**

Use `AskUserQuestion` (single select):
- Question: `"MARKITDOWN_WORKDIR_PATH is set to '<primary-value>'. How should this be distributed to peer worktrees?"`
- Header: `"MarkItDown workdir"`
- Options:
  1. **"Per-worktree (Recommended)"** — description: `"Each peer gets its own path: <peer>/.markdown/workdir. Directories will be created automatically."` → set flag `autoMarkdownWorkdir = true`
  2. **"Same for all"** — description: `"Copy primary's value to every peer as-is."` → set flag `autoMarkdownWorkdir = false`

If user selects **"Per-worktree"**: remove `MARKITDOWN_WORKDIR_PATH` from `propagationSet` (it will not appear in the P3 key list; per-worktree values are injected directly in P4).

**P2.5-B — RUN_IIS_APPLICATIONHOST_CONFIG_PATH**

Use `AskUserQuestion` (single select):
- Question: `"RUN_IIS_APPLICATIONHOST_CONFIG_PATH is set to '<primary-value>'. How should applicationhost.config be handled in peer worktrees?"`
- Header: `"applicationhost.config"`
- Options:
  1. **"Per-worktree physicalPath (Recommended)"** — description: `"Same relative path propagated to all peers; copy the config file to peers that lack it, then update each peer's physicalPath to point to that worktree's web project directory."` → set flag `autoApplicationHostConfig = true`
  2. **"Propagate as-is"** — description: `"Copy the env value to all peers without any file operations."` → set flag `autoApplicationHostConfig = false`

If user selects **"Per-worktree physicalPath"**: keep `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` in `propagationSet` unchanged (the same relative path is propagated to all peers); file operations are handled in P4.5. Immediately after selection, scan the primary worktree and all selected peer worktrees for `<worktree>/<primary-value>`. If none of them contain the file, warn the user: "applicationhost.config not found in any worktree — please open the solution in Visual Studio first to auto-generate the file, then re-run /tpi:setup-all." (Continue regardless; P4.5 will record individual results per peer.)

### P3 — Override discovery (three-stage funnel)

**Stage A** — One `AskUserQuestion`, `multiSelect: true`:
- Question: `"Setup wrote {N} key(s): [{comma-separated key list}]. These will be copied as-is to {M} peer worktree(s): [{comma-separated basename list}]. Any peers need different values for one or more keys?"`
- Header: `"Override scope"`
- Options: each selected peer worktree (label = basename, description = branch).
- Default: all options **unchecked**.

If user selects no peers → skip Stages B and C; proceed to P4 with `propagationSet` unchanged.

**Stage B** — For each peer worktree selected in Stage A, one `AskUserQuestion`, `multiSelect: true`:
- Question: `"Which keys should differ in <peer-basename>?"`
- Header: `"Overrides for <peer-basename>"`
- Options: each key in `propagationSet` (label = key name, description = `"primary: <value>"`).
- Default: all options **unchecked**.

**Stage C** — For each `(peer, key)` pair selected in Stage B, one `AskUserQuestion`:
- Question: `"New value for <key> in <peer-basename>? (primary: <primary-value>)"`
- Header: `"<peer-basename> / <key>"`
- Offer the most common valid values as options plus "Other…" for free-form input.
- Apply the validator rules from Decision Rules. If the value fails validation, re-ask.
- Record each answer in `overrides[peerPath][key]`.

### P4 — Propagation

For each selected peer worktree (from D4), in order:

1. Check that the peer's directory exists on disk. If not → mark peer FAILED with reason "worktree directory missing on disk"; continue to next peer.
2. Compute `peerEnv = { ...propagationSet, ...(overrides[peerPath] ?? {}) }`. Then, if `autoMarkdownWorkdir == true`, inject `MARKITDOWN_WORKDIR_PATH = <peer-abs-path>/.markdown/workdir` (forward slashes, e.g. `C:/Projects/MyProj-dev2/.markdown/workdir` on Windows) as the final value for that key — this overrides anything from propagationSet or overrides.
3. Invoke the appropriate helper script to merge `peerEnv` into `<peer>/.claude/settings.local.json`:
   - **Windows (PowerShell)**: `& "<CLAUDE_PLUGIN_ROOT>/scripts/merge-settings-env.ps1" -SettingsFile "<peer>/.claude/settings.local.json" -EnvJson '<peerEnv-as-JSON>'`
   - **Other (bash)**: `bash "<CLAUDE_PLUGIN_ROOT>/scripts/merge-settings-env.sh" "<peer>/.claude/settings.local.json" '<peerEnv-as-JSON>'`
   - `CLAUDE_PLUGIN_ROOT` is the directory of this plugin's `plugin.json`.
4. If the script exits 0 → mark peer DONE. Record how many keys were merged and how many were overrides.
5. If the script exits non-zero → mark peer FAILED with the stderr text as reason; continue.

### P4.5 — applicationhost.config sync

Run this step only if `autoApplicationHostConfig == true`.

1. Let `configRelPath` = the value of `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` from `propagationSet` (a relative path such as `.vs/MySolution/config/applicationhost.config`).
2. **Find a source**: scan the primary worktree and all selected peer worktrees in order; use the first one where `<worktree>/<configRelPath>` exists on disk as `sourceWorktree`. If none found, `sourceWorktree = null`.
3. For each peer worktree that was marked DONE in P4:
   a. **If `<peer>/<configRelPath>` does not exist**:
      - If `sourceWorktree != null`: create parent directories (as a separate step), then copy the file. Record: "copied from `<sourceWorktree-basename>`".
      - If `sourceWorktree == null`: record "applicationhost.config not found in any worktree — skipped". Skip physicalPath correction for this peer.
   b. **physicalPath correction** (run when the file exists at `<peer>/<configRelPath>`):
      - Read `<peer>/.claude/settings.local.json` and extract `env.BUILD_PROJECT_PATH`. If missing, record "BUILD_PROJECT_PATH not set — physicalPath not verified" and skip.
      - Compute `expectedPhysicalPath` = `<peer-abs-path>\<dirname(BUILD_PROJECT_PATH)>` in Windows backslash format (e.g. `C:\Projects\MyProj-dev2\src\Web`).
      - Read the XML content of `<peer>/<configRelPath>`.
      - **Locate the matching site**: first try matching `<site name="<X>">` where X equals `basename(dirname(BUILD_PROJECT_PATH))`; if not found, try matching a site whose `<binding bindingInformation="...">` has a port equal to the port in `<IISUrl>` from the `.csproj` file. If no match, record "unable to match site in applicationhost.config" and skip.
      - Compare the `physicalPath` attribute of that site's `<virtualDirectory path="/">` element (case-insensitive, normalising backslash/forward-slash):
        - If it matches `expectedPhysicalPath`: record "physicalPath already correct".
        - If it differs: use the Edit tool to update only that attribute value to `expectedPhysicalPath`, preserving all other XML content; record "physicalPath updated from `<old>` to `<expectedPhysicalPath>`".
4. Append an **"applicationhost.config sync"** sub-section beneath Section 2 of the P6 summary (only when this step ran):
   ```
   applicationhost.config sync (.vs/.../applicationhost.config)
     worktree       result
     remote-main    physicalPath already correct
     dev-2          copied from main, physicalPath updated
   ```

### P5 — Companion files for tdp on peer worktrees

Run this step only if `aliasChanges['tdp']` is non-empty (i.e. `tdp` ran and actually wrote something to primary).

For each peer worktree that was marked DONE in P4:

- **Always** create the following directories inside the peer if they do not already exist (create each as a separate step; do not chain with `&&`):
  - `<peer>/specs/bugfix/`
  - `<peer>/specs/feature/`
  - `<peer>/specs/archives/bugfix/`
  - `<peer>/specs/archives/feature/`

- **Only if** `aliasChanges['tdp']` contains the key `DBHUB_TOML_FILE_PATH` (meaning the DB area was configured in primary), also create:
  - `<peer>/sql files/local-db/`
  - `<peer>/sql files/test-db/`
  - `<peer>/sql files/main-db/`
  - `<peer>/sql files/archives/local-db/`
  - `<peer>/sql files/archives/test-db/`
  - `<peer>/sql files/archives/main-db/`

Do **not** recreate `.claude/dbhub.local.toml`, `.claude/memory-server.local.jsonl`, the MarkItDown workdir, or `.claude/frontend-standard.local.md` in peer worktrees — these are pointed to by absolute paths shared across worktrees, or are workspace-root-level files that need not be duplicated.

If `tdp` was SKIPPED or FAILED, skip this step entirely for all peers.

Additionally, if `autoMarkdownWorkdir == true`, create the `.markdown/workdir` directory inside each peer worktree that was marked DONE in P4 (regardless of whether `tdp` ran). Create each directory as a separate step; do not chain with `&&`.
- Windows (PowerShell): `New-Item -ItemType Directory -Force -Path "<peer>/.markdown/workdir"`
- Other: `mkdir -p "<peer>/.markdown/workdir"`

### P6 — Summary

Print a two-section summary.

**Section 1 — Plugin setups** (always printed):
```
Plugin setups (primary worktree: <primary-basename>)
  alias  result   notes
  tdp    DONE     wrote 4 env keys, created specs/
  tnf    SKIPPED  no setup skill
  tgs    DONE     wrote 2 env keys
```

**Section 2 — Propagation** (printed only if propagation ran):
```
Propagation to peer worktrees
  worktree         result   notes
  remote-main      DONE     6 keys merged
  remote-test-3    DONE     6 keys merged, 1 override (TGS_DEFAULT_WORKING_BRANCH=test-3)
  dev-2            FAILED   settings.local.json invalid JSON; fix and re-run /tpi:setup-all
```

After the summary, print retry commands for any failures:
- Alias FAILED → `/<alias>:setup` (run from primary worktree).
- Peer FAILED → describe the fix then re-run `/tpi:setup-all`.

## Decision Rules

- **Primary = cwd at invocation**. Do not force the user to be in the git main worktree. Whichever worktree they invoke from is primary; the others are peers.
- **Alias selection is global** (from `installed_plugins.json`). It is done once per run, not per worktree.
- **Per-alias diff compares `(key, value)` pairs**, not just keys. A key whose value was re-confirmed unchanged produces no diff entry and is not propagated. This is correct — propagating an unchanged value would be noisy, and an empty diff correctly triggers the "nothing to propagate" early-exit.
- **Empty string is a valid value** (`""`). Propagate it. Do not treat it as absent.
- **Propagation only touches the `env` block** of each peer's `.claude/settings.local.json`. All other top-level keys and any env keys not in `propagationSet` (or their overrides) are left untouched.
- **Never overwrite a peer file that fails JSON parsing.** Mark the peer FAILED with the parse error. The user must fix the file manually before re-running.
- **Peer directory missing on disk** → FAILED, reason "worktree directory missing on disk". This can happen when `git worktree remove` was not run after manually deleting the directory. The user should run `git worktree prune`.
- **Invocation method for child setups**: always use the `Skill` tool with id `<alias>:setup`, not a slash command — preserves `AskUserQuestion` interactivity within the child skill.
- **Failure handling**: continue-on-error at both the alias level and the peer level.
- **`tpi` exclusion**: `tpi` must never appear in the alias execution list.
- **Unknown alias in argument**: warn and exclude.
- **No caching**: re-read `installed_plugins.json` fresh on every invocation.
- **Security guard**: refuse to propagate any entry whose key or value matches the regex `/password|secret|token|api[_-]?key/i`. Log a warning if such a key is encountered. (In practice the child setup skills do not write such keys, but this is a defence-in-depth guard.)

- **P2.5 smart questions** fire only when the corresponding key is present in `propagationSet` AND at least one peer was selected in D4. If either condition fails for a key, its smart question is silently skipped (no flag is set; the key stays in `propagationSet` and flows through the standard P3 override funnel).
- **`autoMarkdownWorkdir = true`** removes `MARKITDOWN_WORKDIR_PATH` from `propagationSet`, so that key never appears in P3 Stage B. The per-worktree path is injected directly in P4.
- **physicalPath comparison** in P4.5 is case-insensitive and treats backslashes and forward slashes as equivalent. Only the `physicalPath` attribute value is changed; no other XML structure is modified.

**Validator table** (used in Stage C to validate override values before accepting them):

| Key | Valid values |
|---|---|
| `TGS_DEFAULT_WORKING_BRANCH` | `main` or `test-<n>` (n is a positive integer) |
| `TGS_SVN_LOG_DEFAULT_BRANCH` | `main` or `test-<n>` |
| `TGS_SVN_LOG_DEFAULT_LIMIT` | Positive integer string |
| `TGS_SVN_LOG_DEFAULT_VERBOSE` | `1`, `true` (case-insensitive), or empty string |
| `TDP_IMPLEMENT_TASK_REVIEWERS` | Integer string in range 1–7 |
| All other keys | No validation — accept as-is |

## Completion Checks

- Every alias the user selected has a result of DONE, SKIPPED, or FAILED.
- Every selected peer worktree has a result of DONE or FAILED (if propagation ran).
- `tpi` does not appear in the alias execution list.
- All FAILED entries have an explicit retry hint in the summary.
- Primary's `.claude/settings.local.json` is valid JSON (verified implicitly by the child setup skills writing to it successfully).
- For each peer marked DONE: its `.claude/settings.local.json` contains all keys from `propagationSet` (with any overrides applied), and all pre-existing env keys in that file outside the propagation set are still present. If `autoMarkdownWorkdir == true`, the peer's `MARKITDOWN_WORKDIR_PATH` is set to `<peer>/.markdown/workdir` (injected directly in P4, not from propagationSet).
- If `aliasChanges['tdp']` is non-empty: each DONE peer contains `specs/bugfix/`, `specs/feature/`, `specs/archives/bugfix/`, and `specs/archives/feature/`.
- No value matching the security-guard regex was written into any peer file.
- If `autoMarkdownWorkdir == true`: each DONE peer's `.markdown/workdir` directory exists on disk.
- If `autoApplicationHostConfig == true`: each DONE peer's applicationhost.config file exists (or a skip reason was recorded), and its physicalPath is correct (or the mismatch/skip reason was recorded).
- The aggregate summary (both sections as applicable) is shown before the skill exits.
