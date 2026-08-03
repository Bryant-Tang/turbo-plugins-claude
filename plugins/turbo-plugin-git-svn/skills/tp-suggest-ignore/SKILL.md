---
name: tp-suggest-ignore
description: 'Manage `.gitignore`: add/remove patterns, or analyse which files should be git-ignored and which untracked from SVN -- judged from the project''s actual contents, not a fixed list. **Reversible**, so proactively suggest it on spotting untracked build output or secrets; also runs on request.'
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

1. Resolve main worktree via `git -C <目標> rev-parse --git-common-dir`（`<目標>` 依
   `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`;單一專案的目錄就是它自己）。
2. If `.gitignore` does not exist, create it as an empty file.
3. If pattern is already present in `.gitignore` → report "already exists" and stop.
4. Check `git -C <main> ls-files` for files matching the pattern. If any are found, **warn**: "The following files are already git-tracked; adding to .gitignore will not un-track them. Use analysis mode or run `git rm --cached` manually if you want to stop tracking them." (still proceed)
5. Edit `.gitignore` to append the pattern.
6. `git -C <main> add .gitignore`
7. `git -C <main> commit -m "chore: update .gitignore"`
8. Report success.

### `--remove-git <pattern>`

1. Resolve main worktree（同上,`<目標>` 依 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`）。
2. **基礎設施 pattern 不可移除**:若 pattern 是 `.svn/`、`.turbo-plugin/worktrees/`、
   `.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*` 其中之一 → **拒絕**,用白話說明後果
   (見 §判準的硬規則:`.svn/` 一旦不再被忽略,bridge 的 SVN 管理目錄會被推上 SVN)並停止。
3. If `.gitignore` does not exist, or pattern is not in it → report "not found" and stop.
4. Edit `.gitignore` to remove the matching line.
4. `git -C <main> add .gitignore`
5. `git -C <main> commit -m "chore: update .gitignore"`
6. Report success.

---

## Analysis Mode

## Procedure

### Step 1 — Resolve paths

0. **先確定要對哪個 repo 動手**——讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`。這支 SKILL 自己下 `git`(不只透過腳本),所以「指名目標」在這裡的作法是**每個 `git` 都帶 `-C <目標>`**(本 SKILL 各步驟已經都是這個寫法);唯一要決定的是 `<目標>` 從哪來:當前目錄本身是 repo → 就用它;當前目錄自己不是 repo 但底下並排著多個 repo → **先問使用者是哪一個**。呼叫 `Remove-SvnFile` / `remove-svn-file.sh` 時把同一個路徑用 `-RepoRoot` / `--repo-root` 傳進去。
1. Resolve main worktree and all remote worktrees (`remote-svn-*`, e.g. `remote-svn-main`, `remote-svn-feat-login`) from `git -C <目標> rev-parse --git-common-dir`.
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

### Step 3 — Classify candidates（判斷由你做，不套固定清單）

**先讀 `${CLAUDE_PLUGIN_ROOT}/skills/tp-suggest-ignore/assets/ignore-rubric.md`**,依它的判準逐檔判斷。
那份檔案裡**沒有**pattern 清單,這是刻意的:一份寫死的清單只對某個技術棧成立,會同時漏掉這個專案真正的
產物、又硬塞不適用的項目。先從 `*.csproj` / `*.sln` / `package.json` / `requirements.txt` / `pom.xml` /
CI 設定看出這個專案是什麼、產物長什麼樣,必要時直接讀檔案內容,再判斷每一個候選。

判斷時把 §判準的「不應該 ignore」那一組**也套一次**——尤其「不確定就不要動」:誤判成該 ignore 的代價
(別人 clone 下來少檔案、build 壞掉)比留著不管大得多。

**Git Ignore — Add to `.gitignore`**
- Source: `git status --short` entries starting with `??`
- Condition: 你依判準認定它是產物 / 本機專屬 / 機密 AND not already in `.gitignore`
- **Guard**: if the file is already git-tracked (`git ls-files` includes it) → move to Un-track instead

**Inconsistency — SVN-tracked but git-ignored**
- Source: `git ls-files -o -i --exclude-standard` in **each** remote worktree (different SVN branches may track different files)
- Condition: for each found file, run `svn status <file>` in that worktree — if output is blank or `M` (not `?`) the file is SVN-tracked
- Report which worktree(s) have the inconsistency
- These files exist in SVN but git ignores them; SVN changes won't propagate through git
- **例外**:`.svn/` 底下的東西不是候選,那是 bridge 的管理目錄(見 §判準的硬規則)

**Un-track — Tracked by both, should be un-tracked**
- Source: `git ls-files` (git-tracked files in main worktree)
- Condition: 你依判準認定它不該進版控 AND not already in `.gitignore`
- 這一類要**更保守**:已經被追蹤很久的檔案,預設是「刻意進版控的」(§判準「不應該 ignore」第 3 條)。
  沒有明確理由不要提議 un-track。
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

For each candidate use `AskUserQuestion` (keep the labels plain — describe the outcome, not the git/svn commands):
- Option A: Keep the file locally, but stop tracking it and remove it from SVN (full cleanup).
- Option B: Stop tracking it locally, keep it in SVN (**show mandatory warning**: "After this, SVN changes to this file will no longer propagate through git to your working directory.")
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
**Do NOT run raw `svn delete` / `svn commit` yourself.** Delegate to `Remove-SvnFile` (it does the
UTF-8-safe `svn delete` + commit; the file is git-ignored so the bridge stays clean, no reconcile).
`<branch>` is the branch of the remote worktree the inconsistent file lives in; `<file>` is its
bridge-relative path. Pick the tool per **Execution routing** (Decision Rules):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-svn-file.sh" --branch <branch> --path <file> [--repo-root <path>]
```
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Remove-SvnFile.ps1" -Branch <branch> -Path <file> [-RepoRoot <path>]
```

**Un-track — Option A (stop git tracking + delete from SVN, keep the local file):**
1. In the main worktree, stop tracking but **keep the file on disk**, then ignore it (`.gitignore`
   **may be added now** — unlike push, `Remove-SvnFile` deletes directly and is not affected by
   `.gitignore`). Run as two separate steps (no `&&`):
```powershell
git -C <main-worktree> rm --cached "<file>"
```
   then Edit `.gitignore` to append `<file>`, then commit (`git add .gitignore` then
   `git commit -m "chore: stop tracking <file>"`). The main worktree is now clean.
2. Delegate the SVN removal to `Remove-SvnFile` (the file is git-tracked on the bridge, so the
   script reconciles: `svn delete` + a `sync: svn r<rev>` commit + a merge into `<branch>`, formats
   identical to `/tp-pull-from-svn`). Pick the tool per **Execution routing**:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-svn-file.sh" --branch <branch> --path <file> [--repo-root <path>]
```
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Remove-SvnFile.ps1" -Branch <branch> -Path <file> [-RepoRoot <path>]
```
   If the script exits non-zero, report its message and stop (the local file is kept regardless).
3. **Sync the updated `.gitignore` to SVN** so it does not linger only on `main` until some later
   push. `Remove-SvnFile`'s SVN commit is scoped to the deleted file only, so the new `.gitignore`
   line is still git-side. Delegate to `/tp-push-to-svn --branch <branch>` (NOT to do the removal —
   that is already done — only to propagate the `.gitignore`). Push merges `main` into the bridge
   and commits the modified `.gitignore`; the removed file is already gone from SVN, so push does
   **not** re-add it. **Note**: push carries *all* commits pending on `<branch>` (not only the
   `.gitignore`) and runs its own confirmation, so the user sees the full change list and can cancel
   there. If they cancel or the push fails, the un-track itself is already complete (file removed
   from SVN + git, kept local); only the `.gitignore`-to-SVN sync defers to their next push.

**Un-track — Option B (git stops tracking, SVN keeps the file):**
In main worktree only — no SVN changes. Run as two separate steps (no `&&`):
```powershell
git -C <main-worktree> rm --cached "<file>"
```
then Edit `.gitignore` to append `<file>`, then commit (`git add .gitignore` then
`git commit -m "chore: stop git tracking of <file>"`). **Add the `.gitignore` entry now (before any
future push)**: with the file git-ignored, a later `/tp-push-to-svn` skips it (its `git check-ignore`
filter), so the SVN copy is protected from an accidental `!`-delete.

### Step 6 — Report summary

List what was changed in each category and what was skipped.

## Decision Rules

- **判斷交你、執行走既有路徑**:哪些檔案該 ignore 由你看專案實際內容判斷(§判準,無固定清單);但**實際的
  SVN 移除一律走 `Remove-SvnFile`**,不要自己下 `svn delete` / `svn commit`。判斷沒有標準答案所以留給你,
  執行有標準答案所以留在腳本裡(腳本才有測試守著)。
- **基礎設施 pattern 是不變式,不歸你判斷也不可移除** — `.svn/`、`.turbo-plugin/worktrees/`、
  `.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*` 由 `/tp-setup` 寫死。不要建議加(已經在了)、
  **不要照使用者要求移除**(拒絕並說明後果)、分析時不要把它們底下的東西列成候選。
- **機密單獨講、講在最前面** — 憑證 / 連線字串 / token 推上 SVN 之後是永久的,之後刪檔也救不回來
  (歷史裡還在)。不要混在一串建置產物裡帶過。
- If `.gitignore` does not exist, create it before editing.
- If remote worktree is absent, only Git Ignore is available (Inconsistency / Un-track need remote worktrees).
- **All SVN removal is delegated to `Remove-SvnFile`; never run raw `svn delete` / `svn commit`, and never delegate to `/tp-push-to-svn` for the removal itself.** push can't remove: it refuses to start on an unignored-but-untracked file (main-clean gate) and skips git-ignored files (`git check-ignore`). `Remove-SvnFile` deletes directly and, when the path is git-tracked on the bridge, reconciles with commit formats **identical to `/tp-pull-from-svn`** (`sync: svn r<rev>` + `Merge branch 'remote-svn/<branch>' into <branch>`), so `remote-svn/*` only ever carries sync + merge commits. (Un-track A's follow-up `/tp-push-to-svn` in step 3 is a *different* thing — it runs **after** `Remove-SvnFile` has already removed the file, only to propagate the updated `.gitignore` to SVN.)
- **`.gitignore` timing differs by intent**: Un-track A adds `.gitignore` **before** calling `Remove-SvnFile` and it's fine (the script isn't push, so `check-ignore` never suppresses the delete); Un-track B adds `.gitignore` immediately to **protect** the SVN copy from a future push's `!`-delete. Both are "add now" here — the after-push ordering only matters when a removal is routed through push, which this SKILL never does.
- **Execution routing (pick `.ps1` vs `.sh`)**: don't use the Bash tool to call `pwsh` / `powershell`. Windows + Git Bash → **Bash tool** runs `.sh`; Windows + no Git Bash → **PowerShell tool** runs `.ps1` (single-dash params `-Branch` / `-Path`); Linux / macOS → **Bash tool** runs `.sh`. Git Bash detection: check `C:\Program Files\Git\bin\bash.exe`, then `C:\Program Files (x86)\Git\bin\bash.exe`; else `where.exe bash` but **exclude** `System32\bash.exe` (WSL).
- **Un-track option B warning is mandatory** — never skip it before proceeding with Un-track Option B.
- SVN removal (Inconsistency option B and Un-track option A) is destructive: always ask a second `AskUserQuestion` confirmation before delegating to `Remove-SvnFile`. **該確認的第一行寫要動的專案絕對路徑**(`要動的專案:<絕對路徑>`)——這是 SVN 上的永久刪除,而「目標 repo 本身完全合法、只是不是使用者想的那個」沒有守門攔得住。判準見 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`。
- An Inconsistency or Un-track file must be confirmed individually — no "apply all" option.
- On git operation failure (dirty working tree), stop and report; do not proceed to the next step.

## Completion Checks

- Git Ignore: new patterns appear in `.gitignore` and in a new git commit on main branch.
- Inconsistency (option B): `svn list` no longer includes the file; the bridge worktree `git status --porcelain` is clean (no-reconcile — the file was git-ignored).
- Un-track (option A): `svn list` no longer includes the file; `remote-svn/<branch>` tip (before the step-3 push) is a `sync: svn r<rev>` commit and `<branch>` tip is a `Merge branch 'remote-svn/<branch>' into <branch>` commit (both matching `/tp-pull-from-svn`); the **local file is still on disk** in the main worktree but `git ls-files <file>` returns empty; `.gitignore` includes the pattern; the bridge worktree is clean. After the step-3 `/tp-push-to-svn` (unless the user cancelled it), the `.gitignore` change is also in SVN and the removed file is **not** re-added.
- Un-track (option B): `git ls-files <file>` returns empty in main worktree; the file is still on disk; `.gitignore` includes the pattern; SVN copy unchanged.

## Test Scenarios

- **Direct mode --add-git**: PowerShell `--add-git "*.log"` / bash `--add-git "*.log"` → .gitignore 末尾出現 "*.log"、新 commit on main branch 內容只有 .gitignore。
- **Direct mode --remove-git**: 對已存在 pattern 跑 `--remove-git` → 該行從 .gitignore 移除、commit 新增。對不存在 pattern 跑 → 印 "not found" 不 commit。
- **Direct mode --add-svn / --remove-svn 已移除**: 跑 `--add-svn` 或 `--remove-svn` → 回報 unknown/unsupported flag,不執行任何 svn 操作。
- **基礎設施 pattern 移除被擋**: 跑 `--remove-git ".svn/"`(及另外三條)→ 拒絕並白話說明後果,`.gitignore` 不變、無新 commit。
- **Analysis mode**: 在有 untracked `.env` 的 repo 跑 analysis mode → Git Ignore prompt 出現 .env,使用者選 Apply all → .gitignore 加 .env、commit 新增;分析不出現「SVN Ignore」分類。
- **判斷不套固定清單**: 在一個把產物輸出到非慣例目錄(例如 `artifacts/`)的專案跑 analysis mode → 該目錄被認出是產物;反過來,在一個刻意把某個 `bin/` 進版控且已被追蹤已久的專案跑 → **不**提議 un-track 它。
- **Un-track Option A 委派 Remove-SvnFile(reconcile)**: 對同被 git/SVN 追蹤的檔跑 Un-track Option A → main `git rm --cached` + `.gitignore` + commit,再委派 `Remove-SvnFile`;`svn list` 不含該檔、`remote-svn/<branch>` 末筆 `sync: svn r<rev>` + `<branch>` 末筆 `Merge branch ...`(格式同 pull)、本機檔仍在但不被 git 追蹤、bridge 乾淨。流程**不再**有裸 `svn delete` / `svn commit` 或 push 委派。(自動化覆蓋見 `tests/unit/scripts/Remove-SvnFile.test.*`。)
- **Inconsistency Option B 委派 Remove-SvnFile(no-reconcile)**: 對 git-ignored + svn-tracked 檔跑 Option B → 委派 `Remove-SvnFile`;`svn list` 不含該檔、bridge 乾淨、`remote-svn/<branch>` 無新 commit。
- **No remote worktrees**: 沒 remote-* worktree 的 repo 跑 analysis mode → 只跑 Git Ignore 分類,跳過 Inconsistency / Un-track。
