---
name: tp-merge-main-into-branches
description: 'Merge the latest main into local branches (default: all but main and the remote-svn/* bridges). Run on explicit request only; it changes branch state, so do NOT auto-trigger.'
argument-hint: '[--branch <name>]...'
user-invocable: true
allowed-tools: Bash, Read, ListAgents, SendMessage
---

# tp-merge-main-into-branches

## Purpose

把目前 `main` 的最新 tip merge 進**指定的本地分支**;**不指定時預設為每一個非 `remote-svn/*` 的本地分支**(且排除 `main` 自己)。讓開發中分支一次跟上 main,避免逐支手動 merge。

只在 main worktree 操作,逐分支 `checkout` → `merge main` → 還原原分支;不碰 `remote-svn/*` SVN 橋接分支。

## Procedure

1. **先確定要對哪個 repo 動手**——讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`,依它的判準決定要不要帶 `-RepoRoot` / `--repo-root`。單一專案的目錄不用帶。**作用對象是目標 repo 的主 worktree**:script 內部用 `Get-MainWorktree` 自動定位,所以在 linked worktree 呼叫時操作仍落在主 worktree。

2. 跑 script。**不傳分支** → merge 進全部非 `remote-svn/*` 分支;**傳指定分支** → 只 merge 那些(`.ps1` 用 `-Branch a,b`,`.sh` 用可重複的 `--branch a --branch b`):

   ```powershell
   # 全部(預設)
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Merge-MainIntoBranches.ps1" [-RepoRoot <path>]
   # 指定分支
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Merge-MainIntoBranches.ps1" -Branch feature-a,feature-b [-RepoRoot <path>]
   ```
   ```bash
   # 全部(預設)
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-main-into-branches.sh" [--repo-root <path>]
   # 指定分支
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-main-into-branches.sh" --branch feature-a --branch feature-b [--repo-root <path>]
   ```

   script 自己列出目標分支、逐支 merge、最後印 summary。指定但不存在 / 被排除(`main` / `remote-svn/*`)的分支會印一行 `SKIP <b> (not found / excluded)` 略過,不中止。

3. 把 script stdout echo 給使用者,重點是結尾 summary:
   - `Merged cleanly: <branches>` — 乾淨 merge 進去的分支。
   - `CONFLICT (aborted): <branches>` — 有衝突、已 `git merge --abort` 還原、**未** merge 的分支。
   - `Skipped (checked out elsewhere): <branches>` — **只有真的發生時才會印**。那些分支正被別的 worktree checkout,git 不允許同一分支同時 checkout 在兩處,所以**根本沒有嘗試 merge**。這**不是**內容衝突。

4. 依 summary 分別處理:
   - 有 `CONFLICT` 分支(script exit 1)→ 提醒使用者那些分支需要手動 merge 解衝突;其餘乾淨分支已更新。
   - 有 `Skipped (checked out elsewhere)` 分支(**不影響 exit code**)→ **不要講成衝突,也不要叫使用者去比 diff**。每支的 `SKIP <b> (checked out at <path>)` 那行有佔用它的 worktree 絕對路徑。`<path>` 多半是另一條 Claude session 的工作副本,所以**先讀 `${CLAUDE_PLUGIN_ROOT}/assets/occupied-worktree.md`,照它的判準直接跟那條 session 說**:請它在自己的 worktree 裡跑 `git merge --no-ff main`。對不上、或它回不方便時才回頭問使用者,那時再把路徑講給他,並說明兩條處置(到那個 worktree 裡直接 `git merge --no-ff main`,或先移除該 worktree 再重跑本 skill)。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **目標分支選擇**:不傳分支 → 全部非 `main` / 非 `remote-svn/*` 的本地分支;傳指定分支 → 只那些。指定但不存在或被排除(`main` / `remote-svn/*`)的分支 → 印 `SKIP <b> (not found / excluded)` 略過,不中止。
- **Exclude filter**:目標 = 所有本地分支中**既不是 `main`、也不是 `remote-svn/*`** 的分支。`remote-svn/*` 是 SVN 橋接分支,**絕不**動。
- **衝突處理**:某分支 merge 衝突時,對該分支 `git merge --abort` 還原乾淨、標記 `CONFLICT`、**繼續下一支**;不中斷整個 run,也不留下衝突狀態。
- **「被別的 worktree 佔用」不是衝突**:那是 git 不允許同一分支同時 checkout 在兩處,跟內容無關,所以走 `SKIP <b> (checked out at <path>)`、獨立列在 summary、**且不讓整個 run 失敗**(隔離 worktree 是本 plugin 的常態工作方式,一有 linked worktree 就 exit 1 等於天天在報錯)。轉述時務必帶上那個路徑——正確處置在那裡,不在 diff 裡。
- **被佔用的分支先找佔用它的那條 session,不要一律把工作推回給使用者**。判準與訊息寫法在 `${CLAUDE_PLUGIN_ROOT}/assets/occupied-worktree.md`(與 `tp-request-merge` 共用同一份)。**界線在那份檔案裡,一定要照著**:自己被權限擋下的動作,不可以改送給另一條 session 去做。
- **Dirty main worktree → 拒跑**:開跑前若 main worktree 有未 commit 變更,script 直接報錯退出、不動任何分支(避免 merge 進髒樹)。
- **還原原分支**:全部跑完後 `checkout` 回開跑時所在的分支。
- 這會**改動 branch 狀態**(各分支 merge commit),屬寫操作,**不**自動觸發,只在使用者明確要求時跑。

## Completion Checks

- script exit 0(全部乾淨,或只有被佔用而略過的分支)或 exit 1(至少一支**真的**衝突)。
- stdout 末尾出現 `Merged cleanly:` 與 `CONFLICT (aborted):` 兩行 summary;有分支被別的 worktree 佔用時**才**多一行 `Skipped (checked out elsewhere):`。
- `remote-svn/*` 與 `main` 不在目標清單、未被動到。
- 跑完後 HEAD 回到開跑時的原分支。
- 乾淨 merge 的分支都含有 main 的最新 tip。

## Test Scenarios

- **Happy**: main 領先、有 `test-x` / `feature-y` 兩支落後分支 → 跑後兩支都含 main tip;`main` 與 `remote-svn/main` 不在目標、不被動。
- **Exclude**: 確認 `remote-svn/*` 分支與 `main` 被跳過。
- **Conflict**: 某分支與 main 有衝突改動 → 該分支列為 `CONFLICT`、保持未 merge(已 abort、無衝突標記殘留),其餘非衝突分支照常 merge;跑完 HEAD 回原分支。
- **Specify subset**: 傳 `--branch feature-y`(或 `-Branch feature-y`)→ 只 merge `feature-y`,其餘落後分支不被動。
- **Specify excluded / missing**: 傳不存在的分支或 `main` / `remote-svn/*` → 印 `SKIP <b> (not found / excluded)` 略過、續跑其餘有效分支。
- **Dirty main**: main worktree 有未 commit 變更 → script 報錯退出、不動任何分支。
- **Checked out elsewhere**: 目標分支被某個 linked worktree checkout → `SKIP <b> (checked out at <path>)`、summary 多一行 `Skipped (checked out elsewhere):`、**不列入 CONFLICT、exit code 仍為 0**,其餘分支照常 merge;沒有任何分支被佔用時,那行 summary **不出現**。
