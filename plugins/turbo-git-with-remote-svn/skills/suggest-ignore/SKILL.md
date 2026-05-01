---
name: suggest-ignore
description: 'Manage git/SVN ignore settings: directly add or remove .gitignore / svn:ignore patterns, or run interactive analysis to detect and fix inconsistencies'
argument-hint: 'Direct: --add-git|--remove-git|--add-svn|--remove-svn <pattern> [--path <dir>] | Analysis: [--branch <main|test-<n>>]'
user-invocable: true
---

# suggest-ignore

## Purpose

Single entry point for managing ignore settings across both git and SVN in a tgs project.

**Direct mode** — when `--add-git`, `--remove-git`, `--add-svn`, or `--remove-svn` is given: skip analysis and execute the operation immediately.

**Analysis mode** — when no direct-mode flag is given: analyse the project and interactively recommend ignore settings. Handles four categories:

- **A** — Files not tracked by git that should be added to `.gitignore`
- **B** — Files tracked by git that should be added to `svn:ignore` (kept in git, excluded from SVN)
- **C** — Files tracked by SVN but git-ignored (inconsistency — SVN changes won't propagate through git)
- **D** — Files tracked by both git and SVN that should be un-tracked

## Direct Mode Arguments

| Argument | Description |
|---|---|
| `--add-git <pattern>` | Append pattern to `.gitignore` and commit |
| `--remove-git <pattern>` | Remove pattern from `.gitignore` and commit |
| `--add-svn <pattern>` | Add pattern to `svn:ignore` on all remote worktrees |
| `--remove-svn <pattern>` | Remove pattern from `svn:ignore` on all remote worktrees |
| `--path <dir>` | Target subdirectory for SVN operations (default: `.`) |

Constraints: only one direct-mode flag per invocation; `--path` is ignored for git operations; `--branch` is ignored in direct mode.

## Direct Mode Procedure

### `--add-git <pattern>`

1. Resolve main worktree via `git rev-parse --git-common-dir`.
2. If `.gitignore` does not exist, create it as an empty file.
3. If pattern is already present in `.gitignore` → report "already exists" and stop.
4. Check `git -C <main> ls-files` for files matching the pattern. If any are found, **warn**: "The following files are already git-tracked; adding to .gitignore will not un-track them. Use analysis mode or run `git rm --cached` manually if you want to stop tracking them." (still proceed)
5. Edit `.gitignore` to append the pattern.
6. `git -C <main> add .gitignore && git -C <main> commit -m "chore: update .gitignore"`
7. Report success.

### `--remove-git <pattern>`

1. Resolve main worktree.
2. If `.gitignore` does not exist, or pattern is not in it → report "not found" and stop.
3. Edit `.gitignore` to remove the matching line.
4. `git -C <main> add .gitignore && git -C <main> commit -m "chore: update .gitignore"`
5. Report success.

### `--add-svn <pattern> [--path <dir>]`

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.ps1" -Add "<pattern>" [-Path "<dir>"]
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.sh" --add "<pattern>" [--path "<dir>"]
```

Forward the script output to the user.

### `--remove-svn <pattern> [--path <dir>]`

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.ps1" -Remove "<pattern>" [-Path "<dir>"]
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.sh" --remove "<pattern>" [--path "<dir>"]
```

Forward the script output to the user.

---

## Analysis Mode

### Branch Mapping

The `--branch` argument selects which remote worktree to inspect for SVN-side analysis (Categories B, C, D):

| Working branch | Remote worktree |
|---|---|
| `main` | `remote-main` |
| `test-<n>` | `remote-test-<n>` |

## Procedure

### Step 1 — Resolve branch and paths

1. If `--branch` is not given, check `TGS_DEFAULT_WORKING_BRANCH`. If set and valid, use it. Otherwise use `AskUserQuestion` to ask which branch to analyse.
2. Resolve main worktree and remote worktree paths from `git rev-parse --git-common-dir`.
3. If the remote worktree does not exist, skip Categories B, C, D and proceed with Category A only.

### Step 2 — Collect data

Run the following (all read-only):

```powershell
git -C <main-worktree> status --short
git -C <main-worktree> ls-files
# Read <main-worktree>/.gitignore  (empty string if file does not exist)
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.ps1"
git -C <remote-worktree> ls-files -i --exclude-standard
```

```bash
git -C <main-worktree> status --short
git -C <main-worktree> ls-files
# Read <main-worktree>/.gitignore  (empty string if file does not exist)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.sh"
git -C <remote-worktree> ls-files -i --exclude-standard
```

### Step 3 — Classify candidates

Use the collected data to build candidate lists for each category. Common "should-be-ignored" patterns to recognise:

- IDE/OS: `.idea/`, `.vscode/`, `.DS_Store`, `Thumbs.db`
- Environment: `.env`, `.env.*`, `.env.local`
- Build artifacts: `build/`, `dist/`, `out/`, `target/`, `bin/`, `obj/`
- Compiled output: `*.o`, `*.obj`, `*.class`, `*.pyc`, `__pycache__/`
- Logs / temp: `*.log`, `*.tmp`, `*.cache`
- Claude Code config: `.claude/`

**Category A — Add to `.gitignore`**
- Source: `git status --short` entries starting with `??`
- Condition: matches a common ignore pattern AND not already in `.gitignore`
- **Guard**: if the file is already git-tracked (`git ls-files` includes it) → move to Category D instead

**Category B — Add to `svn:ignore`**
- Source: `git ls-files` (git-tracked files)
- Condition: matches a pattern that belongs in git but not SVN (e.g. `.claude/`, CI configs) AND not already in `svn:ignore`
- **Limitation note to show user**: `svn:ignore` is per-directory only, not recursive. For recursive exclusions use `.gitignore`.
- **Warning if already SVN-tracked**: check `svn status <file>` in remote worktree — if the file is tracked (blank output, not `?`) warn: "svn:ignore won't affect already-tracked files. To stop pushing modifications, consider D2 flow instead."

**Category C — SVN-tracked but git-ignored (inconsistency)**
- Source: `git ls-files -i --exclude-standard` in remote worktree
- Condition: for each found file, run `svn status <file>` — if output is blank or `M` (not `?`) the file is SVN-tracked
- These files exist in SVN but git ignores them; SVN changes won't propagate through git

**Category D — Tracked by both, should be un-tracked**
- Source: `git ls-files` (git-tracked files in main worktree)
- Condition: matches a common ignore pattern AND not already in `.gitignore`
- (Note: Category A candidates that are already git-tracked are automatically reclassified here)

Filter out patterns already present in `.gitignore` or `svn:ignore` before presenting.

### Step 4 — Interactive prompts (one round per category with candidates)

If all four categories are empty → report "No ignore issues found" and stop.

**Round A — git ignore:**

Use `AskUserQuestion` to present all Category A candidates at once:
- Option A: Add all to `.gitignore`
- Option B: Confirm one by one
- Option C: Skip all

**Round B — svn:ignore:**

Same format as Round A. Show the per-directory limitation note in the question description.

**Round C — SVN/git inconsistency (one question per file):**

For each inconsistent file use `AskUserQuestion`:
- Option A: Remove from `.gitignore` (let git track it — both systems consistent)
- Option B: Delete from SVN + add to `svn:ignore` (remove from both — **destructive**, confirm once more before executing)
- Option C: Skip (accept inconsistency)

**Round D — Un-track from both (one question per file):**

For each candidate use `AskUserQuestion`:
- Option A: Stop git tracking + delete from SVN (full cleanup: `git rm --cached` + `.gitignore` + SVN delete + `svn:ignore`)
- Option B: Stop git tracking, keep SVN version (**show mandatory warning**: "After this, SVN changes to this file will no longer propagate through git to your working directory.")
- Option C: Skip

### Step 5 — Execute approved changes

Apply changes in this order: A → B → C → D.

**Category A (edit `.gitignore`):**
1. If `.gitignore` does not exist, create it as an empty file first.
2. Use the Edit tool to append approved patterns to `<main-worktree>/.gitignore`.
3. Commit:
```powershell
git -C <main-worktree> add .gitignore
git -C <main-worktree> commit -m "chore: update .gitignore"
```
If main worktree has uncommitted changes, report the error and ask user to commit or stash first.

**Category B (add to `svn:ignore`):**
For each approved pattern:
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.ps1" -Add "<pattern>"
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.sh" --add "<pattern>"
```

**Category C — Option A (remove from `.gitignore`):**
Use the Edit tool to remove the matching line from `.gitignore`, then commit as above.

**Category C — Option B (delete from SVN):**
In the remote worktree:
```powershell
svn delete "<file>"
svn commit -m "remove <file> (no longer tracked in git)"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.ps1" -Add "<pattern>"
```

**Category D — Option A (full cleanup):**
In main worktree:
```powershell
git -C <main-worktree> rm --cached "<file>"
# edit .gitignore to add pattern
git -C <main-worktree> add .gitignore
git -C <main-worktree> commit -m "chore: stop tracking <file>"
```
Then in remote worktree:
```powershell
svn delete "<file>"
svn commit -m "remove <file>"
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-ignore.ps1" -Add "<pattern>"
```

**Category D — Option B (git stops, SVN keeps):**
In main worktree only — no SVN changes needed:
```powershell
git -C <main-worktree> rm --cached "<file>"
# edit .gitignore to add pattern
git -C <main-worktree> add .gitignore
git -C <main-worktree> commit -m "chore: stop git tracking of <file>"
```
The `push-to-svn` explicit commit list ensures future M-status modifications to this file won't be pushed to SVN.

### Step 6 — Report summary

List what was changed in each category and what was skipped.

## Decision Rules

- If `.gitignore` does not exist, create it before editing.
- If remote worktree is absent, only Category A is available.
- **D2 warning is mandatory** — never skip it before proceeding with Option B of Category D.
- SVN delete (C-B and D-A) is destructive: always ask a second `AskUserQuestion` confirmation before executing.
- A Category C or D file must be confirmed individually — no "apply all" option.
- On git operation failure (dirty working tree), stop and report; do not proceed to the next step.
- Script failures should be reported immediately; subsequent items of the same category are skipped.

## Completion Checks

- Category A: new patterns appear in `.gitignore` and in a new git commit on main branch.
- Category B: `svn-ignore` (list) shows the new patterns in all remote worktrees.
- Category C (option B) / D (option A): `svn log` on the remote worktree shows a deletion commit; `svn list` no longer includes the file.
- Category D (option B): `git ls-files <file>` returns empty in main worktree; `.gitignore` includes the pattern.
