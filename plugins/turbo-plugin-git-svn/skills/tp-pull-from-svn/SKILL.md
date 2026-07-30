---
name: tp-pull-from-svn
description: '從 SVN 拉新 revision 到 remote-svn/<branch>(`remote-svn-main` / `remote-svn-<branch>` worktree)並 merge 進對應本地工作分支。使用者明確要求 pull / 偵測到 remote 有新 SVN commit 而本地 working branch 落後時建議執行;**不要自動觸發**(merge 衝突需使用者介入)。'
argument-hint: '--branch <branch>'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-pull-from-svn

## Purpose

從 SVN 拉新 revision、commit 進對應 `remote-svn/*` git branch、merge 進本地工作 branch。

## Procedure

0. **先確定要對哪個 repo 動手**——讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`,依它的判準決定要不要帶 `-RepoRoot` / `--repo-root`。單一專案的目錄不用帶(維持既有行為);當前目錄自己不是 repo 但底下並排著多個 repo 時**必須先問使用者是哪一個**再指名,否則 script 只會倒在 `not inside a git repository`。
1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Sync-FromSvn.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/sync-from-svn.sh`)帶 `--branch <branch>` 參數(以及 step 0 決定要帶的 `--repo-root`)。這會改動本機 git 狀態,所以**在跑之前先用白話講出要動的專案絕對路徑**,讓使用者當場能看出目標打錯。
2. 解讀 script 輸出:
   - `Already up to date at SVN r<rev>` → 完成
   - `Replaying <n> SVN revision(s) ...` / `Pulled SVN r<lo>..r<hi> into <branch> (<n> revision(s), <mode>)` → 完成。逐修訂(per-revision)模式下**每個 SVN 修訂都變成一顆對應的 git commit**,保留原作者 / 訊息 / 時間;squash 模式則是壓成單一 `sync: svn r<rev>`。
   - `TP_TOKEN:GRANULARITY_REQUIRED count=<N> range=r<lo>:r<hi>` → 這次要拉的 SVN 修訂較多、需要先問使用者用哪種顆粒度保留歷史(此時 script 尚未建立任何 commit、也沒有落地任何變更)。**此行是給 agent 內部解析的機器標記,絕不可原樣丟給使用者** → 進入 step 3。
   - `Error: merge conflict detected. The merge has been aborted and main worktree restored ...` → **script 已自動 `git merge --abort` 並把主 worktree 還原到原分支**(零殘留、沒有進行中的 merge)。agent:把 token 後列出的衝突檔**白話**告訴使用者,說明「這次拉取與本機有衝突,已自動還原、沒有留下半成品」,請使用者在自己的流程裡調和這些檔案後**重跑 `/tp-pull-from-svn`**。**不要**叫使用者 `git merge --continue`(此時沒有進行中的 merge 可續)。若訊息是 `... automatic rollback failed ...`(回滾本身失敗)→ 工作樹處於不一致狀態,請使用者依訊息手動修復後再重跑。
3. **粒度選擇(僅在 step 2 出現 `GRANULARITY_REQUIRED` 時做)**

   用**白話**把三個選項呈現給使用者(可以帶「這次有 <N> 個新的更新」這種白話說明,但**不要**露出 `TP_TOKEN` / `refs/tp/svn/<n>` / `per-revision` / `squash` / `range` / worktree 名等內部字眼):

   ```
   這次要從 SVN 拉的更新比較多(<N> 個更新)。你想怎麼保留這段歷史?
   1. 一顆一顆保留(推薦)—— 每個更新都變成一顆對應的 git commit,作者 / 訊息 / 時間都留著,日後對齊分支最準。
   2. 壓成一顆 —— 整段更新併成單一 commit,歷史最精簡,但看不到中間每一步。
   3. 只挑一段一顆一顆保留 —— 指定一個更新範圍,在範圍內逐一保留、範圍外壓成一顆。

   回 1 / 2 / 3;選 3 請一併告訴我要逐一保留的範圍。
   ```

   依使用者回覆**重跑 step 1 的 script**,補上對應參數(PowerShell 用單破折號、bash 用雙破折號):
   - 選 1 → 加 `-Granularity per-revision`(bash `--granularity per-revision`)。
   - 選 2 → 加 `-Granularity squash`(bash `--granularity squash`)。
   - 選 3 → 加 `-Granularity range`(bash `--granularity range`)**且**加 `-Range <lo>:<hi>`(bash `--range <lo>:<hi>`),把使用者給的範圍換算成純數字 `<lo>:<hi>`(範圍上下界即 step 2 機器標記裡的 `r<lo>:r<hi>`)。

   重跑後回到 step 2 解讀輸出。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **作用對象是目標 repo 的主 worktree**,不是要求你先切到某個目錄:script 從當前目錄(或 `--repo-root` 指名的路徑)往上找 repo,再自動定位到它的主 worktree。判準見 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`。
- main worktree 不乾淨(`git status --porcelain` 非空)→ 拒跑,提示先 commit / stash。
- 衝突時 **不自動 abort**,讓使用者選擇手動解決。
- 跑兩次無 SVN 新 commit → 第二次回 "Already up to date" 不重做。
- **粒度只在更新數 > 5 時才問**:5 個(含)以內,script 直接一顆一顆保留、**不打擾使用者**;超過 5 個且未帶粒度參數時,script 才回報 `GRANULARITY_REQUIRED` 讓 agent 去問(此時零 commit、零落地,可安全重跑)。
- **預設推薦「一顆一顆保留」**:使用者沒特別偏好時建議選 1(逐修訂),因為它讓日後 `/tp-checkout-svn-branch` 對齊分支接點(fork-point)最準;要最精簡歷史才選壓成一顆。
- **粒度選項一律白話**:呈現給使用者時只講「一顆一顆保留 / 壓成一顆 / 挑一段保留」與白話理由,**不要**出現 `TP_TOKEN` / `refs/tp/svn/<n>` / `per-revision` / `squash` / `range` 這些內部參數名或 worktree 名;內部參數只在你**重跑 script** 時用。

## Completion Checks

- 若有 SVN 變更:逐修訂模式下 `git log --oneline remote-svn/<branch>` **對每個新 SVN 修訂各有一顆 commit**(而非單一 lump);squash 模式則含單一 `sync: svn r<rev>` commit。
- 本地 working branch 已 merge `remote-svn/<branch>`,`git log --oneline` 含 `Merge branch 'remote-svn/<branch>' into <branch>` commit(若有變更)。
- main worktree clean,`git status --porcelain` 為空。
- 若曾出現粒度選擇:已用**白話三選一**問過使用者,重跑 script 時帶上對應的 `-Granularity`(選 3 時另帶 `-Range`)參數;問使用者的文字裡**沒有**任何內部 token / 參數名。

### After a merge conflict + rollback

If `/tp-pull-from-svn` aborts due to merge conflict, the script restores the working tree but **does not auto-retry the merge** on rerun (svn revision already matches, so the rerun sees "Already up to date" and skips the merge).

To complete the pull after resolving conflicts:
1. Manually merge: `git -C <main-worktree> merge remote-svn/<branch>` then resolve conflicts and commit
2. Confirm: `git log --oneline <branch>..remote-svn/<branch>` is empty (no unmerged SVN commits remain)

This workflow trade-off is intentional — auto-retry would loop indefinitely on persistent conflicts.

## Test Scenarios

- **Already up-to-date**: SVN HEAD == local HEAD → script印 `Already up to date.` 並 exit 0,git 沒 fast-forward。
- **Happy-path pull**: SVN HEAD 領先,跑 script → svn update + git fetch + git merge `remote-svn/<branch>` 完成,主 worktree HEAD 前進。
- **Merge conflict + 自動 rollback**: 故意製造一個本地 commit 改同行,SVN 同行也改 → script abort merge + 切回原 branch,emit `Merge conflict detected. ... Conflicting files: <list>`,working tree 為原 branch 乾淨狀態。
- **Rollback failure (inconsistent state)**: 故意鎖 `.git/index`(讓 `git merge --abort` 失敗)→ script emit `Working tree is in an inconsistent state. Resolve manually before re-running.`,exit 1。
- **粒度 ≤5 靜默逐修訂**: 只有 ≤5 個新修訂 → script 不回報 `GRANULARITY_REQUIRED`、直接逐修訂替每個修訂建一顆 commit,SKILL **不問使用者**。
- **粒度 >5 白話三選一**: >5 個新修訂且未帶粒度參數 → script 回報 `GRANULARITY_REQUIRED count=<N> range=r<lo>:r<hi>`(零 commit) → SKILL 以**白話**呈現「一顆一顆保留(推薦)/ 壓成一顆 / 挑一段保留」三選一(**不裸露** token / 參數名)→ 依回覆重跑帶 `-Granularity`(選 3 另帶 `-Range <lo>:<hi>`)。
