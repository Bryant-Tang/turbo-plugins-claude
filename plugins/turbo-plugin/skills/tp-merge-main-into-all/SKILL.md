---
name: tp-merge-main-into-all
description: '把最新的 main merge 進專案內所有非 remote-svn/* 分支(排除 main 本身與 remote-svn/* 橋接分支)。使用者明確要求「把 main 同步到所有分支」/「merge main 進每個分支」時執行。會改動 branch 狀態,不 auto-trigger。'
argument-hint: '(無參數)'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-merge-main-into-all

## Purpose

把目前 `main` 的最新 tip merge 進專案內**每一個非 `remote-svn/*` 的本地分支**(且排除 `main` 自己)。讓所有開發中分支一次跟上 main,避免逐支手動 merge。

只在 main worktree 操作,逐分支 `checkout main` → `merge main` → 還原原分支;不碰 `remote-svn/*` SVN 橋接分支。

## Procedure

1. **必須在 main worktree 跑**(script 內部用 `Get-MainWorktree` 自動定位 main worktree;若在 linked worktree 呼叫,操作仍落在 main worktree)。

2. 跑 script,參數依平台(force_bash routing 決定走哪個):

   ```powershell
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Merge-MainIntoAll.ps1"
   ```
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-main-into-all.sh"
   ```

   無參數。script 自己列出目標分支、逐支 merge、最後印 summary。

3. 把 script stdout echo 給使用者,重點是結尾 summary:
   - `Merged cleanly: <branches>` — 乾淨 merge 進去的分支。
   - `CONFLICT (aborted): <branches>` — 有衝突、已 `git merge --abort` 還原、**未** merge 的分支。

4. 若有 `CONFLICT` 分支(script exit 1),提醒使用者那些分支需要手動 merge 解衝突;其餘乾淨分支已更新。

## Decision Rules

- **Exclude filter**:目標 = 所有本地分支中**既不是 `main`、也不是 `remote-svn/*`** 的分支。`remote-svn/*` 是 SVN 橋接分支,**絕不**動。
- **衝突處理**:某分支 merge 衝突時,對該分支 `git merge --abort` 還原乾淨、標記 `CONFLICT`、**繼續下一支**;不中斷整個 run,也不留下衝突狀態。
- **Dirty main worktree → 拒跑**:開跑前若 main worktree 有未 commit 變更,script 直接報錯退出、不動任何分支(避免 merge 進髒樹)。
- **還原原分支**:全部跑完後 `checkout` 回開跑時所在的分支。
- 這會**改動 branch 狀態**(各分支 merge commit),屬寫操作,**不**自動觸發,只在使用者明確要求時跑。

## Completion Checks

- script exit 0(全部乾淨)或 exit 1(至少一支 CONFLICT)。
- stdout 末尾出現 `Merged cleanly:` 與 `CONFLICT (aborted):` 兩行 summary。
- `remote-svn/*` 與 `main` 不在目標清單、未被動到。
- 跑完後 HEAD 回到開跑時的原分支。
- 乾淨 merge 的分支都含有 main 的最新 tip。

## Test Scenarios

- **Happy**: main 領先、有 `test-x` / `feature-y` 兩支落後分支 → 跑後兩支都含 main tip;`main` 與 `remote-svn/main` 不在目標、不被動。
- **Exclude**: 確認 `remote-svn/*` 分支與 `main` 被跳過。
- **Conflict**: 某分支與 main 有衝突改動 → 該分支列為 `CONFLICT`、保持未 merge(已 abort、無衝突標記殘留),其餘非衝突分支照常 merge;跑完 HEAD 回原分支。
- **Dirty main**: main worktree 有未 commit 變更 → script 報錯退出、不動任何分支。
