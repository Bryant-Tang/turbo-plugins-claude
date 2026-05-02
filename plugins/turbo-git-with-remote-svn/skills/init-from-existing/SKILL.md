---
name: init-from-existing
description: 'Analyse an existing git project and migrate it to tgs structure: create the required remote/* branches, .worktrees/ worktrees, and SVN checkout, then run the initial sync. Use when converting an existing git repo to work with tgs.'
argument-hint: 'Optional: --svn-url <svn-url-for-main>'
user-invocable: true
---

# init-from-existing

## Purpose

Convert an existing git project into a tgs-structured project by detecting which tgs components are missing and adding them interactively. Already-present components are skipped (idempotent). Afterwards, the full `/tgs:pull-from-svn` / `/tgs:push-to-svn` workflow operates normally.

## When to Use

- You have an existing git project and want to connect it to an SVN repository via tgs.
- You want to add the tgs worktree structure (`remote-main`, `.code-workspace`) to a project that was not created with `/tgs:create-project`.

Do **not** use this skill for brand-new projects — use the `create-project` command instead.

## Phase 1 — Explore (read-only)

Run the following commands to collect current state:

```powershell
git rev-parse --show-toplevel
git rev-parse --git-common-dir
git worktree list
git branch -a
git status --short
git config --get svn-remote.svn.url
```

```bash
git rev-parse --show-toplevel
git rev-parse --git-common-dir
git worktree list
git branch -a
git status --short
git config --get svn-remote.svn.url
```

Derive:
- `$mainWorktree` = output of `git rev-parse --show-toplevel`
- `$projName` = basename of `$mainWorktree`
- `$parent` = parent directory of `$mainWorktree`
- `$worktreesDir` = `$parent/$projName.worktrees`
- `$workspaceFile` = `$parent/$projName.code-workspace`

Also check:
- Does `$worktreesDir` directory exist?
- Does `$workspaceFile` exist?
- Does `$mainWorktree/.svn/` exist (pre-existing SVN checkout)?

## Phase 2 — Gap Analysis

Report findings to the user as a table:

| tgs component | Status |
|---|---|
| `main` branch | ✅ exists / ⚠️ default branch is `master` — rename required |
| `remote/main` branch | ✅ exists / ❌ missing |
| `$projName.worktrees/` directory | ✅ exists / ❌ missing |
| `remote-main` worktree | ✅ exists / ❌ missing |
| SVN checkout in `remote-main` | ✅ `.svn/` present / ❌ missing |
| `$projName.code-workspace` | ✅ exists / ❌ missing |

If all components are already present → report "Project already matches tgs structure. Nothing to do." and stop.

## Phase 3 — Interactive Inputs

Use `AskUserQuestion` for each required input. Ask only what is actually needed based on the gap analysis.

**3.1 Main branch name** — if the current default branch is not `main`:

Ask: "Your default branch appears to be `master`. tgs uses `main` as the primary branch name. Should I rename it?"
- Option A: Yes, rename `master` → `main` (recommended)
- Option B: No, keep `master` (not fully tgs-compatible — warn user that all tgs scripts expect `main`)

**3.2 SVN URL** — if `--svn-url` was not passed and `remote/main` or the SVN checkout is missing:

Ask: "What is the SVN URL for the main branch? (e.g. `https://svn.example.com/project/trunk`)"
- Required — stop if left empty.

**3.3 SVN content** — once the URL is known:

Ask: "Does this SVN URL already contain your project files, or is it a new empty repository?"
- Option A: Already has files — checkout and sync into git
- Option B: Empty / not yet populated — set up the connection only; sync later with `/tgs:pull-from-svn`

**3.4 Test environments** (optional, always ask last):

Ask: "Do you want to set up `test-<n>` SVN worktrees as well?"
- Option A: Set them up now (run `/tgs:create-remote-test` at the end)
- Option B: Skip — I will run `/tgs:create-remote-test` manually later

## Phase 4 — Pre-flight Validation

Before making any changes:

1. **Working tree must be clean.** Run `git status --short`. If output is non-empty → stop and ask the user to commit or stash all changes before retrying.
2. **git-svn detection.** If `git config --get svn-remote.svn.url` returns a value → warn: "This project uses git-svn integration. tgs is incompatible with git-svn. Please remove git-svn configuration before continuing." Use `AskUserQuestion` to let the user confirm whether to proceed or abort.
3. **SVN URL reachability.** Run `svn info <svn-url>`. If it fails → report the error and stop.

## Phase 5 — Execute Migration

Apply each missing component in order. Skip components that already exist.

### 5.1 Rename main branch (if needed)

```powershell
git branch -m master main
```

```bash
git branch -m master main
```

### 5.2 Create `remote/main` as an orphan branch

`remote/main` must have no shared history with `main` — it will only ever contain SVN-sync commits. Create it as an orphan:

```powershell
git checkout --orphan remote/main
git rm -rf --cached .
git commit --allow-empty -m "init: remote/main branch"
git checkout main
```

```bash
git checkout --orphan remote/main
git rm -rf --cached .
git commit --allow-empty -m "init: remote/main branch"
git checkout main
```

`git checkout --orphan` does not touch working-directory files. `git rm -rf --cached .` clears only the index. After `git checkout main` the index is restored from `main`. Working-directory files are unchanged throughout.

### 5.3 Create `<proj>.worktrees/` directory

```powershell
New-Item -ItemType Directory -Force -Path "$worktreesDir"
```

```bash
mkdir -p "$worktreesDir"
```

### 5.4 Add `remote-main` git worktree

```powershell
git worktree add "$worktreesDir/remote-main" "remote/main"
```

```bash
git worktree add "$worktreesDir/remote-main" "remote/main"
```

Because `remote/main` is an orphan (empty tree), the created worktree directory contains no project files — it is ready for SVN checkout.

### 5.5 SVN checkout in `remote-main`

```powershell
# Run inside $worktreesDir/remote-main:
svn checkout $SvnUrl .
```

```bash
# Run inside $worktreesDir/remote-main:
svn checkout "$SvnUrl" .
```

The directory is empty at this point, so `svn checkout` succeeds without conflicts.

### 5.6 Create `.code-workspace`

Create `$workspaceFile` with the following content (replace `<projName>` with the actual project name):

```json
{
  "folders": [
    { "name": "main", "path": "<projName>" },
    { "name": "remote-main", "path": "<projName>.worktrees/remote-main" }
  ],
  "settings": {}
}
```

If the file already exists, do not overwrite it — skip and note it to the user.

## Phase 6 — Initial SVN Sync

**Only when Phase 3 option A was chosen (SVN already has content).**

### 6.1 Read SVN revision

Inside `remote-main`, run `svn info .` and extract the `Revision` value.

### 6.2 Commit SVN content to `remote/main`

```powershell
git -C "$worktreesDir/remote-main" add -A
git -C "$worktreesDir/remote-main" commit -m "sync: initial SVN import (r<rev>)"
```

```bash
git -C "$worktreesDir/remote-main" add -A
git -C "$worktreesDir/remote-main" commit -m "sync: initial SVN import (r<rev>)"
```

### 6.3 Merge `remote/main` into `main` (initial connection)

Because `remote/main` is an orphan, this first merge requires `--allow-unrelated-histories`. All subsequent `/tgs:pull-from-svn` calls will be normal merges.

```powershell
git -C "$mainWorktree" merge --allow-unrelated-histories -m "chore: connect SVN via tgs (r<rev>)" remote/main
```

```bash
git -C "$mainWorktree" merge --allow-unrelated-histories -m "chore: connect SVN via tgs (r<rev>)" remote/main
```

**If merge conflicts occur:**
- List all conflicting files.
- Ask the user to open the main worktree, resolve each conflict manually, then run:
  ```
  git add <resolved-files>
  git merge --continue
  ```
- Do **not** abort automatically — let the user decide.

**If Phase 3 option B was chosen (SVN empty):**
- Skip Phase 6.
- Inform the user: "SVN connection is set up. When the SVN repository has content, run `/tgs:pull-from-svn --branch main` to perform the initial sync."

## Phase 7 — Completion Report

Report a summary:

**Created:**
- List each component that was newly created.

**Skipped (already existed):**
- List each component that was already in place.

**Next steps:**
- Run `/tgs:setup` to configure environment variable defaults.
- If the initial sync was done: run `/tgs:merge-main-into-all` to propagate SVN content to other branches.
- If the initial sync was skipped (empty SVN): run `/tgs:pull-from-svn --branch main` once the SVN repository has content.
- If test environments are needed: run `/tgs:create-remote-test --svn-url <test-svn-url>`.

## Decision Rules

- All Phase 5 steps are idempotent: skip silently if the component already exists.
- Stop immediately if the main worktree is dirty; do not proceed with any changes.
- Stop immediately if the SVN URL is unreachable.
- On merge conflict: list conflicting files, guide the user to resolve them manually; never auto-abort.
- git-svn detected: warn and require explicit user confirmation before proceeding.
- Only the `main` remote worktree is created by this skill. Additional `test-<n>` worktrees are handled by `/tgs:create-remote-test`.
- Never prompt about `.code-workspace` overwrite — if it exists, skip it unconditionally.
- If `git rev-parse --git-common-dir` shows the CWD is already a linked worktree (not the main one), resolve all paths from the common git dir and work in the main worktree for branch and worktree operations.

## Completion Checks

- `git branch -a` includes `remote/main`.
- `git worktree list` includes `<proj>.worktrees/remote-main`.
- `<proj>.worktrees/remote-main/.svn/` exists (when SVN URL was provided and reachable).
- `<proj>.code-workspace` exists with correct folder entries.
- `git status --short` in main worktree is empty (clean).
- If Phase 6 ran: `git log --oneline main` contains a "chore: connect SVN via tgs" merge commit.
