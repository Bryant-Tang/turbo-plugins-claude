---
name: tp-reset-remote-test
description: '把 test-<n> 分支硬重置(`git reset --hard main`)使其等同 main 內容。**git reset --hard 會搬 branch 指標丟掉 test-<n> 自己的 commit**(原 commit 可透過 release tag / reflog 找回),必須使用者明確要求才執行;agent 偵測需重設 test 環境時可建議,但需明確確認。'
argument-hint: '--n <number> [--diff-only]'
user-invocable: true
---

# tp-reset-remote-test

## Purpose

把 `test-<n>` branch 重置成跟 `main` 一樣。常用於完成一輪 test 部署後,想用最新 main 重新建立 test 環境。

## Procedure

### Step 1 — Preview LOSE / GAIN

Run the script with `--diff-only` to compute and print the LOSE / GAIN summary without performing the reset.

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.ps1" --diff-only
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.sh" --diff-only
```

Script 印出:
- `LOSE: <count> commits` 後跟即將從 test-<n> 被砍掉的 commit subject 清單(test-<n> 領先 main 的部分)
- `GAIN: <count> commits` 後跟 reset 後會獲得的 commit subject 清單(main 領先 test-<n> 的部分)
- 或 `Branches already equal — nothing to reset.` (early exit, no Step 2 needed)

### Step 2 — Confirm with AskUserQuestion

If Step 1 was not the "already equal" early exit, use AskUserQuestion to confirm:

Question: "即將執行 `git reset --hard main` 對 test-<n>(LOSE <N> commits / GAIN <M> commits)。確認執行?"

Options:
- **Apply**: 跑 Step 3
- **Cancel**: 終止 skill,不動 git

### Step 3 — Execute the reset

Re-run the script without `--diff-only`:
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.ps1"
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reset-remote-test.sh"
```

Script 跑 `git reset --hard main` 然後 emit `Reset test-<n> to main.`

### Step 4 — 下一步建議

提示使用者下一步動作(例如「現可跑 /tp-push-to-svn --branch test-<n>」)。

## Decision Rules

- 必須在主 worktree 跑。
- 兩個 worktree(main + remote-test-<n>)都必須 clean,否則拒跑。
- **`git reset --hard` 不是真的丟失資料**:被搬掉的 commit 若有 release tag / 其它 ref 指到仍可找回。但 SKILL.md 仍應在 prompt 強調這點。
- 預設不寫,先 `AskUserQuestion` 確認:Apply / Cancel(顯示 LOSE / GAIN diff)。

## Completion Checks

- `git log --oneline test-<n>` 與 `git log --oneline main` 對齊。
- 主 worktree 仍在原 branch(check `git rev-parse --abbrev-ref HEAD` 沒被意外切走)。
- remote-test-<n> 仍 clean。

## Test Scenarios

- **--diff-only preview**: test-1 領先 main 3 commits、main 領先 test-1 5 commits → `--diff-only` 應印 `LOSE: 3 commits ...` + `GAIN: 5 commits ...` 並 exit 0,**git 沒任何改動**。
- **Already equal**: test-1 == main(same SHA)→ `--diff-only` 印 `Branches already equal — nothing to reset.` 並 exit 0,SKILL 略過 AskUserQuestion 直接結束。
- **Apply path**: Step 1 preview 完使用者選 Apply → Step 3 跑無 flag,`Reset test-<n> to main.` 出現,`git log test-1..main` 為空。
- **Cancel path**: Step 1 preview 完使用者選 Cancel → SKILL 結束,test-1 的 HEAD 未動,LOSE / GAIN 仍維持原本不平衡。
