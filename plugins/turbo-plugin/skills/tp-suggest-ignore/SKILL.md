---
name: tp-suggest-ignore
description: '管理 `.gitignore`:直接增刪 pattern,或互動分析偵測「該被 git ignore」與「該從 SVN untrack」的檔案。**Add / remove ignore pattern 可逆**(寫錯可拿掉),agent 偵測到新 untracked 檔案符合常見 ignore pattern 時可建議執行;使用者明確要求 analysis mode 全 repo 掃描時也可跑。'
argument-hint: 'Direct: --add-git|--remove-git <pattern>… | Analysis: (no args)'
user-invocable: true
allowed-tools: Bash, Read, Edit, Glob, Grep, AskUserQuestion
---

# suggest-ignore

## Purpose

Single entry point for managing `.gitignore`, plus interactive analysis that can un-track files from SVN, in a turbo-plugin project. (svn:ignore is not user-managed: the bridge keeps a fixed `svn:ignore=.git` internally — everything else is decided by `.gitignore` + the push scripts' `git check-ignore` filter.)

> **NOTE**: When the procedure shows `git -C <main> add .gitignore && git -C <main> commit -m "..."`,
> treat it as two separate steps — run `git add` first, observe success, then run `git commit`. CLAUDE.md
> prohibits `&&` chains across state-changing git commands.

**Direct mode** — when `--add-git` or `--remove-git` is given: skip analysis and execute the operation immediately.

**Analysis mode** — when no direct-mode flag is given: analyse the project and interactively recommend ignore settings. Handles three categories:

- **Git Ignore** — Files not tracked by git that should be added to `.gitignore`
- **Inconsistency** — Files tracked by SVN but git-ignored (inconsistency — SVN changes won't propagate through git)
- **Un-track** — Files tracked by both git and SVN that should be un-tracked

## Direct Mode Arguments

| Argument | Description |
|---|---|
| `--add-git <pattern>` | Append pattern to `.gitignore` and commit |
| `--remove-git <pattern>` | Remove pattern from `.gitignore` and commit |

Constraints: only one direct-mode flag per invocation.

## Direct Mode Procedure

### `--add-git <pattern>`

1. Resolve main worktree via `git rev-parse --git-common-dir`.
2. If `.gitignore` does not exist, create it as an empty file.
3. If pattern is already present in `.gitignore` → report "already exists" and stop.
4. Check `git -C <main> ls-files` for files matching the pattern. If any are found, **warn**: "The following files are already git-tracked; adding to .gitignore will not un-track them. Use analysis mode or run `git rm --cached` manually if you want to stop tracking them." (still proceed)
5. Edit `.gitignore` to append the pattern.
6. `git -C <main> add .gitignore`
7. `git -C <main> commit -m "chore: update .gitignore"`
8. Report success.

### `--remove-git <pattern>`

1. Resolve main worktree.
2. If `.gitignore` does not exist, or pattern is not in it → report "not found" and stop.
3. Edit `.gitignore` to remove the matching line.
4. `git -C <main> add .gitignore`
5. `git -C <main> commit -m "chore: update .gitignore"`
6. Report success.

---

## Analysis Mode

## Procedure

### Step 1 — Resolve paths

1. Resolve main worktree and all remote worktrees (`remote-svn-*`, e.g. `remote-svn-main`, `remote-svn-feat-login`) from `git rev-parse --git-common-dir`.
2. If no remote worktrees exist, skip Inconsistency and Un-track, and proceed with Git Ignore only.

### Step 2 — Collect data

Run the following (all read-only):

```powershell
git -C <main-worktree> status --short
git -C <main-worktree> ls-files
# Read <main-worktree>/.gitignore  (empty string if file does not exist)
# For each remote worktree (remote-svn-*):
git -C <remote-worktree> ls-files -o -i --exclude-standard
```

```bash
git -C <main-worktree> status --short
git -C <main-worktree> ls-files
# Read <main-worktree>/.gitignore  (empty string if file does not exist)
# For each remote worktree (remote-svn-*):
git -C <remote-worktree> ls-files -o -i --exclude-standard
```

### Step 3 — Classify candidates

Use the collected data to build candidate lists for each category. Common "should-be-ignored" patterns to recognise:

- IDE/OS: `.idea/`, `.vscode/`, `.DS_Store`, `Thumbs.db`
- Environment: `.env`, `.env.*`, `.env.local`
- Build artifacts: `build/`, `dist/`, `out/`, `target/`, `bin/`, `obj/`
- Compiled output: `*.o`, `*.obj`, `*.class`, `*.pyc`, `__pycache__/`
- Logs / temp: `*.log`, `*.tmp`, `*.cache`
- Claude Code config: `.claude/`

**Git Ignore — Add to `.gitignore`**
- Source: `git status --short` entries starting with `??`
- Condition: matches a common ignore pattern AND not already in `.gitignore`
- **Guard**: if the file is already git-tracked (`git ls-files` includes it) → move to Un-track instead

**Inconsistency — SVN-tracked but git-ignored**
- Source: `git ls-files -o -i --exclude-standard` in **each** remote worktree (different SVN branches may track different files)
- Condition: for each found file, run `svn status <file>` in that worktree — if output is blank or `M` (not `?`) the file is SVN-tracked
- Report which worktree(s) have the inconsistency
- These files exist in SVN but git ignores them; SVN changes won't propagate through git

**Un-track — Tracked by both, should be un-tracked**
- Source: `git ls-files` (git-tracked files in main worktree)
- Condition: matches a common ignore pattern AND not already in `.gitignore`
- (Note: Git Ignore candidates that are already git-tracked are automatically reclassified here)

Filter out patterns already present in `.gitignore` before presenting.

### Step 4 — Interactive prompts (one round per category with candidates)

If all three categories are empty → report "No ignore issues found" and stop.

**Git Ignore:**

Use `AskUserQuestion` to present all Git Ignore candidates at once:
- Option A: Add all to `.gitignore`
- Option B: Confirm one by one
- Option C: Skip all

**Inconsistency — SVN/git (one question per file):**

For each inconsistent file use `AskUserQuestion`:
- Option A: Remove from `.gitignore` (let git track it — both systems consistent). 此檔本就在 SVN 版控中,Option A 只是讓 git 也追蹤、兩端一致,不會新增 SVN 內容。
- Option B: Delete from SVN (remove from both — **destructive**, confirm once more before executing)
- Option C: Skip (accept inconsistency)

**Un-track — from both (one question per file):**

For each candidate use `AskUserQuestion`:
- Option A: Stop git tracking + delete from SVN (full cleanup: `git rm --cached` + `.gitignore` + SVN delete)
- Option B: Stop git tracking, keep SVN version (**show mandatory warning**: "After this, SVN changes to this file will no longer propagate through git to your working directory.")
- Option C: Skip

### Step 5 — Execute approved changes

Apply changes in this order: Git Ignore → Inconsistency → Un-track.

**Git Ignore (edit `.gitignore`):**
1. If `.gitignore` does not exist, create it as an empty file first.
2. Use the Edit tool to append approved patterns to `<main-worktree>/.gitignore`.
3. Commit:
```powershell
git -C <main-worktree> add .gitignore
git -C <main-worktree> commit -m "chore: update .gitignore"
```
If main worktree has uncommitted changes, report the error and ask user to commit or stash first.

**Inconsistency — Option A (remove from `.gitignore`):**
Use the Edit tool to remove the matching line from `.gitignore`, then commit as above.

**Inconsistency — Option B (delete from SVN):**
In the remote worktree:
```powershell
svn delete "<file>"
svn commit -m "remove <file> (no longer tracked in git)"
```

**Un-track — Option A (full cleanup):**
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
```

**Un-track — Option B (git stops, SVN keeps):**
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
- If remote worktree is absent, only Git Ignore is available (Inconsistency / Un-track need remote worktrees).
- **Un-track option B warning is mandatory** — never skip it before proceeding with Un-track Option B.
- SVN delete (Inconsistency option B and Un-track option A) is destructive: always ask a second `AskUserQuestion` confirmation before executing.
- An Inconsistency or Un-track file must be confirmed individually — no "apply all" option.
- On git operation failure (dirty working tree), stop and report; do not proceed to the next step.

## Completion Checks

- Git Ignore: new patterns appear in `.gitignore` and in a new git commit on main branch.
- Inconsistency (option B) / Un-track (option A): `svn log` on the remote worktree shows a deletion commit; `svn list` no longer includes the file.
- Un-track (option B): `git ls-files <file>` returns empty in main worktree; `.gitignore` includes the pattern.

## Test Scenarios

- **Direct mode --add-git**: PowerShell `--add-git "*.log"` / bash `--add-git "*.log"` → .gitignore 末尾出現 "*.log"、新 commit on main branch 內容只有 .gitignore。
- **Direct mode --remove-git**: 對已存在 pattern 跑 `--remove-git` → 該行從 .gitignore 移除、commit 新增。對不存在 pattern 跑 → 印 "not found" 不 commit。
- **Direct mode --add-svn / --remove-svn 已移除**: 跑 `--add-svn` 或 `--remove-svn` → 回報 unknown/unsupported flag,不執行任何 svn 操作。
- **Analysis mode**: 在有 untracked `.env` 的 repo 跑 analysis mode → Git Ignore prompt 出現 .env,使用者選 Apply all → .gitignore 加 .env、commit 新增;分析不出現「SVN Ignore」分類。
- **Un-track Option A 無 svn:ignore 寫入**: 對同被 git/SVN 追蹤的檔跑 Un-track Option A → `git rm --cached` + `.gitignore` + `svn delete` 生效,流程**不再**有任何 svn:ignore 寫入。
- **No remote worktrees**: 沒 remote-* worktree 的 repo 跑 analysis mode → 只跑 Git Ignore 分類,跳過 Inconsistency / Un-track。
