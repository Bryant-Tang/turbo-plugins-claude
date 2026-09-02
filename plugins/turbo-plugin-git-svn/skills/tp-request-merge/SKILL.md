---
name: tp-request-merge
description: 'The stand-in for a pull request in a repo with no git remote: report what a working branch would merge into main, get the user to confirm, then merge it in the main worktree. Suggest it when work on an isolated/peer worktree branch is finished, but it writes to main, so NEVER merge without explicit confirmation.'
argument-hint: '--branch <name> [--base <name>]'
user-invocable: true
allowed-tools: Bash, Read, AskUserQuestion
---

# tp-request-merge

## Purpose

在**沒有 git remote** 的專案裡補上 PR 那一關。

`turbo-plugin-git-svn` 服務的是純本地 git ↔ SVN 專案:沒有遠端 → 開不了 PR → **「人手動按 Merge」這一步憑空消失**。那一步不是形式:`ExitWorktree` 的 `remove` 會**連分支一起刪**,而它只有在分支已經被合併之後才安全。沒有東西提供那個保證時,`remove` 在「工作順利完成」這條最正常的路徑上反而用不了——不帶 `discard_changes` 會被拒,帶了會毀掉還沒合併的成果。

本 skill 補上那一關:先產出一份唯讀的 **Merge Request** 報告(分支、base、要合併的 commit、diffstat、領先 / 落後數),**由使用者確認**,再由腳本**在主 worktree** 執行 `git merge --no-ff`。合併完成後 `remove` 才真的安全。

它是 `tp-merge-main-into-branches` 的**鏡像**:那支是下行(main → 分支),這支是上行(分支 → main)。兩支同樣用 `Get-MainWorktree` 自行定位,所以**在 linked worktree 裡呼叫,操作仍落在主 worktree**。

## Procedure

### Step 0 — 確定要對哪個 repo 動手

讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`,依它的判準決定要不要帶 `-RepoRoot` / `--repo-root`。單一專案的目錄不用帶。**決定後本 SKILL 每一次呼叫都要帶同一個值**——報告階段與合併階段指到不同 repo 會讓使用者對著 A 的報告核准 B 的合併。

這支會**寫入 main**,所以 Step 2 的確認裡**必須**帶上要動的專案絕對路徑——報告本體的 `repo :` 那一行就是,直接用它。

### Step 1 — 產出報告(唯讀)

依**執行路由**選工具(**PowerShell 用單破折號參數**):

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Request-Merge.ps1" -Branch <name> [-Base <name>] [-RepoRoot <path>]
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/request-merge.sh" --branch <name> [--base <name>] [--repo-root <path>]
```

`--base` 省略時預設 `main`。腳本會印出報告,並以**一行** `TP_TOKEN:` 結尾。**SKILL 只認以 `TP_TOKEN:` 開頭的行,且不要自己跑 git 判斷**,完全依此 token 路由:

- `TP_TOKEN:READY branch=<b> base=<base> ahead=<n> behind=<n> worktree=<yes|no> main=<path>` → 進 Step 2。`worktree=` 說的是**來源分支有沒有自己的 worktree**,Step 2 要用它決定收尾怎麼問。
- `TP_TOKEN:BEHIND_BASE branch=<b> base=<base> ahead=<n> behind=<n> main=<path>` → **停下,先問**。`<base>` 有 `<n>` 顆 commit 不在 `<b>` 裡——**這批東西從來沒有跟 `<base>` 的最新狀態一起建置或檢查過**。GitHub 的 PR 把這種狀態標成 out-of-date,也可以設定成必須先更新才准 merge;這裡就是那一關。用 `AskUserQuestion` 讓使用者二選一:
  - **先同步再合併(建議)**:`<base>` 是 `main` 時叫 `/tp-merge-main-into-branches --branch <b>` 把 main 併進該分支(若它回報該分支被別的 worktree 佔用,照那支的指示到那個 worktree 裡做);`<base>` **不是** `main` 時那支幫不上忙(它固定只併 `main`),請使用者自己在分支上 `git merge --no-ff <base>`。完成後**從 Step 1 重跑**。
  - **仍然直接合併**:回 Step 1 帶上 `--allow-behind` / `-AllowBehind` 重跑,拿到 `READY` 之後照常進 Step 2;**Step 3 也要一路帶著那個旗標**,否則會再被擋一次。
- `TP_TOKEN:SOURCE_DIRTY path=<p>` → **停下**。`<p>` 那個 worktree 有未 commit 的變更。這是本 skill 最重要的一道守門:那些變更**不在**這次合併裡,而合併後的 `remove` 會把它們一起刪掉。請使用者先 commit(或明確捨棄)再重跑。
- `TP_TOKEN:MAIN_DIRTY path=<p>` → **停下**。主 worktree 有未 commit 的變更,請先 commit / stash 再重跑。
- `TP_TOKEN:MAIN_DETACHED path=<p>` → **停下**。主 worktree 是 detached HEAD,合併後沒有分支可以回去。請使用者先 `git checkout <分支>`。
- `TP_TOKEN:BASE_ELSEWHERE base=<base> path=<p>` → **停下**。`<base>` 被 `<p>` 這個 worktree 佔用,git 不允許同一分支同時 checkout 在兩處。請先處理那個 worktree。
- `TP_TOKEN:NOTHING_TO_MERGE branch=<b> base=<base> worktree=<yes|no> deleted=<yes|no> [reason=<slug>]` → 沒有東西要合併(已經合併過,或這條分支沒有新 commit)。這條分支現在就可以安全清掉,而「清掉」是誰的事由 `worktree=` 決定:`yes` → 建議 `ExitWorktree` 的 `remove`(連 worktree 一起收);`no` → 照 Step 4 第 3 點問使用者要不要刪掉這條分支(要刪就用 Step 3 的指令加 `--delete-branch` / `-DeleteBranch` 跑一次,`--merge` 一起帶——這時腳本不會 merge 任何東西,只做刪除)。**不要自己跑 `git branch -d`。**
- `TP_TOKEN:BRANCH_NOT_FOUND branch=<b>` / `TP_TOKEN:BASE_NOT_FOUND base=<base>` → 名字打錯或分支不存在,請使用者確認後重跑。
- `TP_TOKEN:BRANCH_IS_BASE branch=<b>` → 來源與目標同一條,無意義,結束。
- `TP_TOKEN:BRIDGE_BRANCH name=<n>` → **停下**。`<n>` 是 `remote-svn/*` SVN 橋接分支,本 skill 兩端都不碰它。
  - 它出現在**目標**那一端 → 那是「把工作併進橋接分支」,會污染要 commit 回 SVN 的樹。不要做。
  - 它出現在**來源**那一端 → 使用者想要的多半是**從 SVN 拉更新**,請他改用 `/tp-pull-from-svn`;那支會連同修訂簿記一起維護,本 skill 只會產生一顆一樣的 merge commit 卻不更新任何狀態。
- `TP_TOKEN:ERROR reason=<訊息>` → 把 `reason` 原文顯示給使用者並**結束 skill,不合併任何東西**。
- (防呆)非零 exit 且**完全沒有** `TP_TOKEN:` 行(例如分支名不合法)→ 顯示 stderr 給使用者並結束,**不要臆測路由**。

### Step 2 — 把報告交給使用者確認

把報告本體**原樣** echo 給使用者——就是兩條 `───` 橫線之間那一段。**`TP_TOKEN:` 那行不要給使用者看**,它是給你路由用的內部標記,對使用者沒有意義。然後用 `AskUserQuestion` 取得明確確認,確認訊息裡要有:

- 要動的專案**絕對路徑**(報告的 `repo :` 那一行)
- `<branch>` → `<base>`,以及 `ahead` 筆 commit
- 你自己對驗收狀態的敘述(建置過了沒、實測了什麼)——**用你自己的話講,不要宣稱腳本驗過**。腳本報的是客觀事實(commit、diffstat、乾不乾淨),**沒有 CI、沒有驗收把關**;判斷「這批東西可不可以進 main」的是使用者。

**同一次 `AskUserQuestion` 順便問收尾**——只在 token 的 `worktree=no` 時問:「合併成功後要不要刪掉 `<branch>` 這條分支?」**預設不刪**。理由要講白話:有些分支併進整合用的分支之後還要繼續用,刪掉會很痛,所以這件事一律問過才做。`worktree=yes` 時**不要問這題**,那條分支的收法是 `ExitWorktree` 的 `remove`(見 Step 4)。

**取消 → 結束 skill,不合併。** 確認 → 進 Step 3。

### Step 3 — 執行合併

同一組參數再跑一次,加上 `-Merge` / `--merge`(Step 1 若用了 `--allow-behind`,這裡**也要帶**;Step 2 使用者同意刪分支才加 `-DeleteBranch` / `--delete-branch`):

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Request-Merge.ps1" -Branch <name> [-Base <name>] [-RepoRoot <path>] [-AllowBehind] [-DeleteBranch] -Merge
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/request-merge.sh" --branch <name> [--base <name>] [--repo-root <path>] [--allow-behind] [--delete-branch] --merge
```

`--merge` 會**重跑 Step 1 的每一道守門**再動手,所以使用者思考期間如果狀態變了(例如又有人動了那個 worktree),這裡會擋下來而不是拿舊報告放行。依 token 路由:

- `TP_TOKEN:MERGED branch=<b> base=<base> commit=<sha> deleted=<yes|no> [reason=<slug>]` → 成功。進 Step 4;`deleted=` / `reason=` 決定 Step 4 第 3 點怎麼講。
- `TP_TOKEN:CONFLICT branch=<b> base=<base>` → 有衝突,腳本已 `git merge --abort`,**`<base>` 與開跑前完全一樣、沒有留下衝突狀態**。建議使用者先跑 `/tp-merge-main-into-branches --branch <b>` 把 main 併進該分支、在**分支上**解衝突,再重跑本 skill(在分支上解衝突比在 main 上解安全)。
  - 走到這個 token 一定是因為**帶了 `--allow-behind`**:會衝突就表示 `<base>` 動過,而 `<base>` 動過分支就是落後的,`BEHIND_BASE` 那一關會先擋。也就是說使用者已經被問過一次、選了直接合併——現在的建議就是那時的另一個選項,直接給步驟就好。
- 任何 Step 1 的守門 token → 照 Step 1 的處理方式,並告訴使用者**沒有合併**。

### Step 4 — 收尾

1. 回報合併結果(merge commit 的 short sha)。
2. **明確告訴使用者:`<branch>` 已經併入 `<base>`,現在 `ExitWorktree` 的 `remove` 才是安全的**——分支已經合併,刪掉不會掉東西。(這條分支**有** worktree 時才講,那正是 `remove` 的用途。)
3. **把來源分支收掉這件事講完,不要留給使用者自己想起來。** 這一步比照 GitHub PR 合併後的 **Delete branch**;缺了它,每合併一次就多留一條沒用的 ref,而它跟還在進行中的功能分支長得一模一樣,過一陣子就分不出哪些還活著。依 token:
   - `deleted=yes` → 告訴使用者分支已刪(腳本驗證過 `<base>` 確實含有它才刪)。
   - `deleted=no reason=has-worktree` → 那條分支有自己的 worktree,**刪 ref 與移除 worktree 是兩件事**,而後者是 harness 的 `ExitWorktree` `remove`(它會連分支一起收)。請使用者用那個,不要在這裡刪 ref。
   - `deleted=no reason=not-ancestor` / `delete-failed` → 原樣說明沒刪成功、分支還在,**不要**自己改用 `git branch -D` 補刀。
   - `deleted=no reason=not-requested` 且分支沒有 worktree → 使用者在 Step 2 沒同意刪(或你沒問)。這時**問一次**:要不要刪掉 `<branch>`?同意就用 Step 3 的指令加 `--delete-branch` / `-DeleteBranch` 再跑一次(這時已經沒有東西要合併,腳本只會做刪除)。
   - `remote-svn/*` 永遠不會走到這裡(腳本更早就以 `BRIDGE_BRANCH` 擋下),**任何情況都不要刪橋接分支**。
4. **不要順手推 SVN。** 推 SVN 是永久寫入,是獨立的一次明確決定;需要的話請使用者另外叫 `/tp-push-to-svn`。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **合併是寫入 main,一定要明確確認**。可以在「隔離 worktree 的工作完成、要收尾」時**主動建議**這支,但**絕不**在沒有使用者確認的情況下跑 `--merge`。
- **報告與合併是同一支腳本的兩個模式,不是兩支腳本**。`--merge` 會重跑全部守門,所以使用者看到的那道關卡與放行合併的那道關卡是**同一段程式碼**,不會漂移。不要為了省一次呼叫而跳過 Step 1 直接跑 `--merge`。
- **`SOURCE_DIRTY` 一律停下,不要建議繞過**。那條分支的 worktree 還有沒 commit 的東西時,合併會少帶,而接下來的 `remove` 會把少帶的部分刪掉——這是這條路徑上唯一會**無聲掉東西**的地方。
- **`remote-svn/*` 兩端都不碰**。腳本會直接以 `BRIDGE_BRANCH` 擋下,不管它出現在來源還是目標。要從 SVN 拉更新請用 `/tp-pull-from-svn`。
- **刪來源分支預設不刪、每次都問**。沒有「以後不用再問我」的設定,而且那是刻意的:有些分支合併之後還要繼續用(先併進整合分支驗測、之後才單獨併進 `main`),而刪分支不可逆。同意才帶 `--delete-branch`,而且**永遠由腳本刪**——它會用 `git merge-base --is-ancestor <branch> <base>` 對**這次真正併入的 base** 驗證,`git branch -d` 自己那套是相對當前 HEAD 判斷的,分支明明併進了另一條也可能回 `not fully merged`。你自己下 `git branch -d` / `-D` 就繞過了那個驗證。
- **落後 `<base>` 預設擋下,不要自己加 `--allow-behind` 繞過**。那個旗標是**使用者看過落後筆數之後親口說「還是要併」**才帶的;由你自作主張帶上,等於把這一關整個拿掉,而它擋的正是「兩邊各自都好、併起來壞掉」這種要等下一個人建置才發現的問題。**優先建議先同步**。
- **衝突在分支上解,不在 `<base>` 上解**。腳本永遠 `merge --abort`,不會留下衝突樹要人收拾。
- **不串 SVN**。合併進 main 之後要不要推 SVN 是另一個決定,而且 SVN 寫入是永久的。
- **沒有 CI 就不要假裝有**。腳本不做驗收把關,也不要求 agent 提交結構化的「測試通過」宣告——那只會變成一句沒人驗證的自我宣稱。客觀事實由腳本提供,判斷交給使用者。

## Completion Checks

- 全程 stdout 只出現**一行** `TP_TOKEN:`(每次呼叫各一行)。
- 合併成功時:`<base>` 含有 `<branch>` 的 tip、多了一顆**有兩個 parent** 的 merge commit,且主 worktree 回到開跑時所在的分支。
- 衝突時:`<base>` 的 sha **與開跑前相同**、沒有 `MERGE_HEAD` 殘留、HEAD 回到原分支、腳本 exit 1。
- 使用者取消時:沒有任何 git 狀態被改動。
- 收尾訊息有把來源分支的去向交代完(已刪 / 交給 `ExitWorktree` `remove` / 問過了不刪),而且**沒有**順手推 SVN。
- 使用者沒同意刪分支時,`git branch` 裡那條分支**還在**;同意刪時它**不在**,而 `<base>` 仍含有它的內容。

## Test Scenarios

- **Happy**:分支領先 main 兩顆 → 報告列出兩顆 commit + diffstat → 確認 → `MERGED`,main 含分支 tip、HEAD 回原分支。
- **Source dirty**:分支的 peer worktree 有未 commit 檔 → `SOURCE_DIRTY`,不進確認、不合併。
- **Clean peer**:同樣有 peer worktree 但乾淨 → 照常 `READY`(確認守門不是無條件觸發)。
- **Stale report**:報告拿到 `READY` 之後才把 peer worktree 弄髒 → `--merge` 回 `SOURCE_DIRTY`、main 不動。
- **Conflict**:分支與 main 改同一行 + `--allow-behind` → `CONFLICT`,main sha 不變、無 `MERGE_HEAD`、HEAD 回原分支。(不帶那個旗標會先被 `BEHIND_BASE` 擋下,因為會衝突就代表 main 動過。)
- **Nothing to merge**:已經合併過的分支 → `NOTHING_TO_MERGE`,並告知可以安全清掉。
- **Delete branch**:合併後帶 `--delete-branch` → `MERGED ... deleted=yes`,`git branch` 裡沒有那條分支、`<base>` 仍含其內容;不帶 → `deleted=no reason=not-requested`,分支還在。
- **Delete branch(有 worktree)**:分支被 peer worktree 佔用時帶 `--delete-branch` → `deleted=no reason=has-worktree`,**合併照樣成功**、分支還在(該用 `ExitWorktree` 的 `remove`)。
- **Delete without merge**:只給 `--delete-branch` 不給 `--merge` → exit 1 且**完全沒有** `TP_TOKEN:` 行(報告模式永遠唯讀)。
- **Behind base**:`<base>` 有分支沒有的 commit → `BEHIND_BASE`(報告照樣印,只是不放行);同一次呼叫加上 `--allow-behind` → 回到 `READY`;`--merge` 沒帶那個旗標時**不會合併**、`<base>` 不動。
- **Detached / base elsewhere**:主 worktree detached、或 `main` 被別的 worktree 佔用 → 各自的 token,不合併。
- **Bridge branch**:`remote-svn/*` 出現在來源或目標任一端 → `BRIDGE_BRANCH`,不合併;名字只是相似(如 `remote-svn-ish`)則**不受影響**。
- **不存在的分支 / 不合法的分支名**:前者 `BRANCH_NOT_FOUND`;後者 exit 1 且**完全沒有** `TP_TOKEN:` 行。
- **git 在 stderr 出警告但 exit 0**(`detected dubious ownership` 之類):乾淨的樹仍然 `READY`(不得誤判成髒),而任何 validation 之後的意外失敗仍然吐得出一行 `TP_TOKEN:ERROR`(不得靜默退出)。
