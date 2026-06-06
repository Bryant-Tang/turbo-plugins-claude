---
name: tp-reset-remote-test
description: '把 test-<n> 分支硬重置(`git reset --hard main`)使其等同 main 內容。**git reset --hard 會搬 branch 指標丟掉 test-<n> 自己的 commit**(被搬掉的 commit 可透過 reflog 找回,或若先前已用 `/tp-push-to-svn` Step 7 建立 release tag 則可從該 tag 找回),必須使用者明確要求才執行;agent 偵測需重設 test 環境時可建議,但需明確確認。'
argument-hint: '--n <number> [--diff-only]'
user-invocable: true
allowed-tools: Bash, Read, AskUserQuestion
---

# tp-reset-remote-test

## Purpose

把 `test-<n>` branch 重置成跟 `main` 一樣。常用於完成一輪 test 部署後,想用最新 main 重新建立 test 環境。

## Procedure

### Step 1 — Preview LOSE / GAIN / FILES_LOST_AFTER_PUSH

Run the script with `--diff-only` to compute and print the LOSE / GAIN summary without performing the reset.

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Reset-RemoteTest.ps1" --diff-only
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.sh" --diff-only
```

Script 印出:
- `LOSE` 後跟即將從 test-<n> 被砍掉的 commit subject 清單(test-<n> 領先 main 的部分)
- `GAIN` 後跟 reset 後會獲得的 commit subject 清單(main 領先 test-<n> 的部分)
- `FILES_LOST_AFTER_PUSH` 後跟下一次 /tp-push-to-svn 後 SVN 上會被刪除的檔案清單(git diff --name-status `main..remote-svn/test-<n>`)
- 或 `<test-n> already equals main. Nothing to reset.` (early exit, no Step 2 needed)

### Step 2 — Confirm with AskUserQuestion

If Step 1 was not the "already equal" early exit:

1. **Parse `FILES_LOST_AFTER_PUSH` section** from the script output.
2. If non-empty, list the affected files to the user and use `AskUserQuestion`:

   Question: "即將執行 `git reset --hard main` 對 test-<n>。重設後下次推送 SVN 會**刪除** N 個檔案(如上列)。確認執行?"

   Options:
   - **Apply**: 跑 Step 3
   - **Cancel**: 終止 skill,不動 git(使用者可用 `git checkout` 放棄 test-<n> 的特定改動,或保留現狀)

3. If `FILES_LOST_AFTER_PUSH` is empty, use AskUserQuestion with simplified prompt:

   Question: "即將執行 `git reset --hard main` 對 test-<n>(LOSE / GAIN 如上)。確認執行?"

   Options:
   - **Apply**: 跑 Step 3
   - **Cancel**: 終止 skill,不動 git

### Step 3 — Execute the reset

Re-run the script without `--diff-only`:
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Reset-RemoteTest.ps1"
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.sh"
```

Script 跑 `git reset --hard main` 然後 emit `Reset test-<n> to main.`

### Step 4 — 下一步建議

提示使用者下一步動作(例如「現可跑 /tp-push-to-svn --branch test-<n>」)。

## Decision Rules

- **force_bash routing**: 呼叫 script 前,讀取 `.turbo-plugin/config.toml` 中 `[svn] force_bash` 的值(透過 `Resolve-ConfigValue -Section 'svn' -Key 'force_bash' -Default 'false'`)。若為 `true`,改以 Git Bash 執行 `.sh` sibling 而非 `.ps1`(對應 Step 0.5 case (a) 的中文 Windows 使用者)。
- 必須在主 worktree 跑。
- 兩個 worktree(main + remote-svn-test-<n>)都必須 clean,否則拒跑。
- **`git reset --hard` 不是真的丟失資料**:被搬掉的 commit 可透過 reflog 找回;若先前推送時用 `/tp-push-to-svn` 的 Step 7 建立過 release tag(`<branch>-release-<date>-<NNN>`),也可從該 tag 找回對應的 commit。但 SKILL.md 仍應在 prompt 強調這點。
- 預設不寫,先 `AskUserQuestion` 確認:Apply / Cancel(顯示 LOSE / GAIN diff)。

## Completion Checks

- `git log --oneline test-<n>` 與 `git log --oneline main` 對齊。
- 主 worktree 仍在原 branch(check `git rev-parse --abbrev-ref HEAD` 沒被意外切走)。
- remote-svn-test-<n> 仍 clean。

## Test Scenarios

- **--diff-only preview**: test-1 領先 main 3 commits、main 領先 test-1 5 commits → `--diff-only` 應印 `LOSE: 3 commits ...` + `GAIN: 5 commits ...` 並 exit 0,**git 沒任何改動**。
- **Already equal**: test-1 == main(same SHA)→ `--diff-only` 印 `Branches already equal — nothing to reset.` 並 exit 0,SKILL 略過 AskUserQuestion 直接結束。
- **Apply path**: Step 1 preview 完使用者選 Apply → Step 3 跑無 flag,`Reset test-<n> to main.` 出現,`git log test-1..main` 為空。
- **Cancel path**: Step 1 preview 完使用者選 Cancel → SKILL 結束,test-1 的 HEAD 未動,LOSE / GAIN 仍維持原本不平衡。
