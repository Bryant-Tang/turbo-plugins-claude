---
name: tp-reset-branch-to-main
description: '把任意分支硬重置(`git reset --hard main`)使其等同 main 內容。**git reset --hard 會搬 branch 指標丟掉該分支自己的 commit**(被搬掉的 commit 可透過 reflog 找回,或若先前已用 `/tp-push-to-svn` Step 7 建立 release tag 則可從該 tag 找回),必須使用者明確要求才執行;agent 偵測需重設環境時可建議,但需明確確認。'
argument-hint: '--branch <name> [--diff-only]'
user-invocable: true
allowed-tools: Bash, Read, AskUserQuestion
---

# tp-reset-branch-to-main

## Purpose

把 `<branch>` 重置成跟 `main` 一樣。常用於完成一輪部署後,想用最新 main 重新建立該分支環境。

## Procedure

### Step 1 — Preview LOSE / GAIN / FILES_LOST_AFTER_PUSH

Run the script in diff-only mode to compute and print the LOSE / GAIN summary without performing the reset. `<branch>` is the branch name from the user's `--branch` argument. **PowerShell 用 `-DiffOnly`(單破折號 switch);GNU 風格的 `--diff-only` 在 `powershell -File` 下會被靜默忽略,導致 `$DiffOnly=False` 而直接跑真正的 `git reset --hard`。**

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Reset-BranchToMain.ps1" -Branch <branch> -DiffOnly
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-branch-to-main.sh" --branch <branch> --diff-only
```

Script 印出:
- `LOSE` 後跟即將從 `<branch>` 被砍掉的 commit subject 清單(`<branch>` 領先 main 的部分)
- `GAIN` 後跟 reset 後會獲得的 commit subject 清單(main 領先 `<branch>` 的部分)
- `FILES_LOST_AFTER_PUSH` 後跟下一次 /tp-push-to-svn 後 SVN 上會被刪除的檔案清單(git diff --name-status `main..remote-svn/<branch>`)
- 或 `<branch> already equals main. Nothing to reset.` (early exit, no Step 2 needed)

### Step 2 — Confirm with AskUserQuestion

If Step 1 was not the "already equal" early exit:

1. **Parse `LOSE` and `FILES_LOST_AFTER_PUSH` sections** from the script output. Let `N` = the number of commits listed under `LOSE`.
2. If `FILES_LOST_AFTER_PUSH` is non-empty, list the affected files to the user and use `AskUserQuestion`:

   Question: "此分支有 **N 個 commit 不在 main**,`git reset --hard main` 會把它們從分支移除(可從 reflog 或先前的 release tag 找回)。重設後下次推送 SVN 會**刪除** M 個檔案(如上列)。確認執行?"

   Options:
   - **Apply**: 跑 Step 3
   - **Cancel**: 終止 skill,不動 git(使用者可用 `git checkout` 放棄該分支的特定改動,或保留現狀)

3. If `FILES_LOST_AFTER_PUSH` is empty, use AskUserQuestion with simplified prompt:

   Question: "此分支有 **N 個 commit 不在 main**,`git reset --hard main` 會把它們從分支移除(可從 reflog 或先前的 release tag 找回)。確認執行?"

   Options:
   - **Apply**: 跑 Step 3
   - **Cancel**: 終止 skill,不動 git

### Step 3 — Execute the reset

Re-run the script without the diff-only flag:
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Reset-BranchToMain.ps1" -Branch <branch>
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-branch-to-main.sh" --branch <branch>
```

Script 跑 `git reset --hard main` 然後 emit `Reset <branch> to main.`

### Step 4 — 下一步建議

提示使用者下一步動作(例如「現可跑 /tp-push-to-svn --branch <branch>」)。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- 必須在主 worktree 跑。
- 兩個 worktree(main + remote-svn/<branch>)都必須 clean,否則拒跑。
- **`git reset --hard` 不是真的丟失資料**:被搬掉的 commit 可透過 reflog 找回;若先前推送時用 `/tp-push-to-svn` 的 Step 7 建立過 release tag(`<branch>-release-<date>-<NNN>`),也可從該 tag 找回對應的 commit。但 SKILL.md 仍應在 prompt 強調這點。
- 預設不寫,先 `AskUserQuestion` 確認:Apply / Cancel(顯示 LOSE / GAIN diff)。

## Completion Checks

- `git log --oneline <branch>` 與 `git log --oneline main` 對齊。
- 主 worktree 仍在原 branch(check `git rev-parse --abbrev-ref HEAD` 沒被意外切走)。
- remote-svn/<branch> 仍 clean。

## Test Scenarios

- **--diff-only preview**: `<branch>` 領先 main 3 commits、main 領先 `<branch>` 5 commits → `--diff-only` 應印 `LOSE: 3 commits ...` + `GAIN: 5 commits ...` 並 exit 0,**git 沒任何改動**。
- **Already equal**: `<branch>` == main(same SHA)→ `--diff-only` 印 `<branch> already equals main. Nothing to reset.` 並 exit 0,SKILL 略過 AskUserQuestion 直接結束。
- **Apply path**: Step 1 preview 完使用者選 Apply → Step 3 跑無 flag,`Reset <branch> to main.` 出現,`git log <branch>..main` 為空。
- **Cancel path**: Step 1 preview 完使用者選 Cancel → SKILL 結束,`<branch>` 的 HEAD 未動,LOSE / GAIN 仍維持原本不平衡。
