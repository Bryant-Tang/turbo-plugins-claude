---
name: tp-push-to-svn
description: 'Push a local working branch to SVN. The message body is locked by the prepare script to the in-range non-merge commit subjects; you write only the title. **An SVN write is permanent: run ONLY on explicit request**; may be suggested, but requires explicit confirmation.'
argument-hint: '--branch <branch> [--svn-url <url>]'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-push-to-svn

## Purpose

把本地 git working branch 的新 commits push 上 SVN。SVN message body 由 prepare 腳本**確定性鎖定**為這次推送範圍內**所有非-merge commit 的 subject 條列**(`- ` 開頭、無 hash、無 commit-type 過濾);跨多個來源分支時(例如把 main 併進分支後再推),body 會自動**按來源分支分組**、各組冠上 `【<分支名>】` 標題,目前分支排最前。agent 只負責寫一行 **title**。body 經 temp 檔交付給 commit 腳本自行組合(title + 換行 + 鎖定 body,中間不空行),agent 無法竄改 body。

**設計理念**:SVN history 的可讀性來自「完整保留每個 code-level subject」,不再做 type 篩選或逐筆未知 type 詢問。要改 body 內容,請對對應 commit `git rebase` / amend subject 後重跑本 skill。commit 訊息的語意品質由獨立的 `tp-commit-msg` 負責(它**不**驗證 / 限制 commit type),與本 skill 無關。

## Procedure

### Step 0a — 確定要對哪個 repo 動手

讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`,依它的判準決定要不要帶 `-RepoRoot` / `--repo-root`。單一專案的目錄不用帶(維持既有行為);當前目錄自己不是 repo 但底下並排著多個 repo 時**必須先問使用者是哪一個**再指名。**決定後,本 SKILL 之後每一次呼叫腳本都要帶同一個值**(pre-flight、New-RemoteBridge、prepare、submit——目標中途變掉會把不同 repo 的狀態混在一起)。

這支會寫 SVN(永久),所以 Step 4 的確認裡**必須**帶上要動的專案絕對路徑。理由見該判準檔:當前目錄**是**一個合法 repo、但使用者講的是隔壁那個 repo 時,沒有任何守門會響。

### Step 0 — First-push bootstrap pre-flight(gate 順序:detached → mismatch → bridge)

依**執行路由**選工具跑 pre-flight 腳本(**PowerShell 用單破折號參數 `-Branch`;GNU 風格 `--branch` 在 `powershell -File` 下不可靠,可能不綁定**;Step 0a 決定要帶 `--repo-root` 的話一併帶上):

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PushPreflight.ps1" -Branch <name> [-RepoRoot <path>]
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-push-preflight.sh" --branch <name> [--repo-root <path>]
```

腳本只輸出**一行**以 `TP_TOKEN:` 為前綴的終結 token——**SKILL 只認以 `TP_TOKEN:` 開頭的行**(raw branch 名內嵌的假 token 不算),且**不要自己跑 git 判斷**,完全依此 token 路由:

- `TP_TOKEN:DETACHED_HEAD requested=<r>` → **拒絕**:HEAD 為 detached(或 `--branch HEAD`),沒有分支名可推導 bridge。提示使用者先 `git checkout <具名分支>` 再重跑。結束 skill,**不建任何東西**。
- `TP_TOKEN:BRANCH_MISMATCH_WARNING current=<c> requested=<r>` → `AskUserQuestion`:「你目前在 `<c>` branch,但要推 `<r>`。先確認沒有推錯分支?」
  - **取消** → 結束 skill。
  - **確認** → 請使用者切到 `<r>`(`git checkout <r>`)後重跑本 Step 0,避免誤推。
- `TP_TOKEN:BRIDGE_ABSENT requested=<r> target=<path>` → 進入**首推 bootstrap**(見下)。
- `TP_TOKEN:BRIDGE_PRESENT requested=<r>` → 已有 bridge,直接進 Step 1(正常 push)。
- `TP_TOKEN:ERROR reason=<訊息>` → pre-flight 無法判定(例:worktree 路徑超過 Windows MAX_PATH)。把 `reason` 原文顯示給使用者並**結束 skill,不建任何東西**。
- (防呆)若腳本**非零 exit 且完全沒有 `TP_TOKEN:` 行** → 顯示 stderr 給使用者並結束 skill,不要臆測路由。

**首推 bootstrap(僅 `BRIDGE_ABSENT`)**:

1. 需要 `--svn-url <url>`(該分支對應的 SVN 路徑)。使用者已經給了就用他給的;**沒給的話先自己推導
   一個預設值,拿去問,不要一開口就要人手打完整 URL。**
   - 推導方式:讀主線橋接的 SVN URL(`svn info --show-item url <主 worktree>/.turbo-plugin/worktrees/remote-svn-main`)。
     它以 `/trunk` 結尾時 → 預設值是把 `/trunk` 換成 `/branches/<消毒過的分支名>`
     (消毒＝斜線換短橫,與 worktree 目錄同一套規則,例如 `feature/x` → `feature-x`)。
   - 用 `AskUserQuestion` 把這個預設值當**第一個選項**讓使用者確認或改。
   - **推導不出來就退回原本作法**:主線 URL 不是以 `/trunk` 結尾(非標準佈局)時不要硬猜,直接請使用者提供。
   - **`branches/` 這一層必須已經存在**:建立分支用的 `svn copy` 沒有帶 `--parents`,中間層不存在會直接失敗。
     同理,`.../branches/team-a/feat-x` 這種多層路徑要先有 `team-a` 才建得起來。
   - 這裡沒有任何「一定要放在 `branches/` 底下」的強制:URL 給什麼就建在哪,漏掉 `branches` 也照建,
     而且 **SVN 的歷史是永久的**。所以下一步的確認一定要把完整 URL 原樣寫出來給使用者看。
2. `AskUserQuestion` 明示風險:「這會建立一個**永久** SVN 路徑 `<url>`(SVN 路徑建立後無法刪除)。若建立過程後段失敗,該 SVN 路徑可能已經留下,可由**重跑首推** idempotent 接續(偵測到既有路徑→checkout,不重複建立);本機 git 端(分支/worktree)失敗會自動 rollback。確認建立?」
   - **取消** → 結束 skill,不建任何東西。
   - **確認** → 依執行路由跑 New-RemoteBridge(**PowerShell 用單破折號參數**):
     ```powershell
     powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/New-RemoteBridge.ps1" -Branch <r> -SvnUrl <url> [-RepoRoot <path>]
     ```
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/new-remote-bridge.sh" --branch <r> --svn-url <url> [--repo-root <path>]
     ```
3. New-RemoteBridge 成功 → 進 Step 1 繼續正常 push。失敗 → 腳本已 rollback 本機 git 端;若訊息提到 SVN 路徑已建立,提醒使用者可重跑首推接續。

### Step 1 — Pre-flight clean check

- 跑 `git status --porcelain` 確認當前 main worktree 乾淨。非空 → 拒跑,提示先 commit / stash。
- `--branch` 接受**任意分支**(合法性 / 消毒由 Step 0 的 pre-flight 腳本以 allowlist 處理)。

### Step 2 — Prepare merge

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Build-SvnCommit.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/build-svn-commit.sh`)帶 `--branch <name>`。Script 會:
- check remote SVN up-to-date(local rev == HEAD rev)
- check 是否有 pending merge state(見下方 PENDING_MERGE_DETECTED 處理)
- 跑 `git merge --no-ff --no-commit` stage merge
- 把 source branch HEAD SHA 寫入 `<remote-path>/.git/MERGE_HEAD.tp_branch_sha`(供 commit 步驟驗證)
- 把**鎖定 body**(這次範圍內所有非-merge commit subject、`- ` 條列;跨來源分支時帶 `【<分支名>】` 分組標題)寫入 `<remote-path>/.git/MERGE_HEAD.tp_svn_body`(供 commit 步驟讀回自組)
- 印出 `BODY\n- <subject>\n...\n\nFILES\n<diff_status>|<git_status>|<path>\n...`

**Script 已自動處理失敗情境**:
- `Nothing to push`(範圍零 commit)→ 直接結束
- **only merge commit(s) in range ...**(範圍有 commit,但 `--no-merges` 過濾後 body 空,即區間只有 merge commit)→ fail loudly、**不 stage merge、不詢問 tag**(與 release-tag 規則一致:沒有 code-level 內容就不推、也不 tag)。提示使用者 amend / rebase 出非-merge commit 後重跑
- remote SVN 不 up-to-date → fail loudly 提示先 `/tp-pull-from-svn`
- merge 衝突 → 列出衝突檔,**不自動 abort**(由使用者解或手動 `git merge --abort`)
- `PENDING_MERGE_DETECTED <remote-path>` → Script 輸出此 token 並 exit 0;SKILL 進入下方三選一 prompt
- `TP_TOKEN:BRANCH_MISMATCH_WARNING current=<current> requested=<requested>` → Build-SvnCommit 的 backstop(主要偵測已在 Step 0 pre-flight;此為正常 push 路徑上的二次防線),token 同以 `TP_TOKEN:` 前綴。Script 輸出此 token 並**繼續執行**;SKILL 進入下方確認 prompt

**BRANCH_MISMATCH_WARNING 處理** — 當 prepare 輸出含以 `TP_TOKEN:BRANCH_MISMATCH_WARNING` 開頭的行時,在繼續解析其他輸出之前,`AskUserQuestion` 詢問:

> 你目前在 `<current>` branch,但要推送 `<requested>`。確認推送 `<requested>`?

選項:
1. **Yes, push `<requested>`**:繼續執行 Step 3
2. **No, cancel**:跑 `git -C <remote-path> merge --abort` 清掉 prepare 已 stage 的 merge,結束 skill

**PENDING_MERGE_DETECTED 處理** — 當 prepare 輸出以 `PENDING_MERGE_DETECTED` 開頭時,`AskUserQuestion` 提示三選一:
1. **Abort + re-prepare**:跑 `git -C <remote-path> merge --abort`,再次跑 prepare(返回本 Step,得到新的 `BODY` / `FILES` 輸出)
2. **Continue to commit**:略過 prepare,直接進 Step 3(使用既有 staged merge)。**注意**:此路徑沒有新的 prepare 輸出可顯示 `BODY` / `FILES`;直接請 agent propose title 進 Step 4。commit 腳本會讀既有 prepare 寫下的 `MERGE_HEAD.tp_svn_body`;若該 pin 不存在會 fail-closed,要求 abort + 重 prepare
3. **Cancel**:結束 skill,不做任何清理

### Step 3 —(agent 內部準備:解析 prepare 輸出 + 寫 title;**不對使用者輸出任何東西**)

prepare 輸出含 `BODY` 與 `FILES` 兩段。agent 在此**只做內部準備、不印任何給使用者**(內容到 Step 4 才呈現):

- 解析 `FILES` 段(svn status:`?`→新增、`!`→刪除、`M`→修改;標 `ignored` 者被 git check-ignore 過濾、本次不進 SVN)——清單留待 Step 4 列出。
- **對「本次會新增到 SVN」的檔案(`?`)跑一次 ignore 檢查**:讀
  `${CLAUDE_PLUGIN_ROOT}/skills/tp-suggest-ignore/assets/ignore-rubric.md`,依判準看有沒有建置產物 /
  本機專屬設定 / 機密混在裡面。**這是最後一道關**——SVN 提交是永久的,推上去之後把檔案刪掉,歷史裡還在。
  - **有發現才出聲**;沒發現就什麼都不提,Step 4 照常只列異動檔案。不要每次 push 都問使用者 ignore 的事。
  - 這裡**只偵測、不修**:不要在 push 流程中途去改 `.gitignore` 或呼叫別的 skill(merge 已經 stage 好了,
    中途插入寫檔會把這次推送的內容弄髒)。把發現帶到 Step 4 讓使用者決定要不要先取消。
- 解析 `BODY` 段(每個 commit 一行的條列)——原樣留待放進 Step 4 的訊息預覽。
- propose 一行 **title**(白話摘要,**固定不加 conventional-commit type 前綴**——`feat:` / `fix:` / `chore:` / `docs:` / `refactor:` 等都不要;SVN 端不跑 release-please / commitlint,type 前綴只是雜訊)。它會成為 Step 4 預覽訊息的第一行;commit 腳本端會把 title collapse 成單行,agent **無法**藉換行把額外內容塞進 body。

### Step 4 — 確認送出(**整個 push 流程唯一對使用者輸出的步驟**)

**先印異動檔案、緊接著直接 `AskUserQuestion`**。**不要把「Step 4」「Step 3」這類內部流程編號 / 步驟標題輸出給使用者**——那是 SKILL 內部結構、不是要顯示的內容;這一步直接從「異動檔案」開始印,不加任何 step 前言或標題。

1. **要動的專案 + 異動檔案(純文字,AskUserQuestion 正上方)**:**這是唯一的純文字輸出**,前面不加「Step X」標題或前言。
   - **第一行先寫要動的專案絕對路徑**(Step 0a 決定的目標,或不帶 `--repo-root` 時腳本實際作用的那個 repo):
     `要動的專案:<絕對路徑>`。這一行讓「打錯 repo」在寫 SVN 之前就被看出來——沒有任何守門會替你攔這種錯,因為那個 repo 本身完全合法。
   - 接著把 `FILES` 以白話列出(新增 / 刪除 / 修改;ignored 者不進 SVN)。
   - **Step 3 的 ignore 檢查有發現時**(只有有發現才寫這段):接在檔案清單後面,用白話點出是哪幾個檔案、
     它們看起來是什麼(「這是建置產生的輸出」「這看起來是資料庫連線字串」),並提醒**SVN 提交是永久的、
     推上去之後刪檔也救不回來**。疑似機密要**單獨列在最前面**,不要混在產物裡帶過。
     然後在 Step 4 的 `AskUserQuestion` 多給一個選項:「先取消,處理這幾個檔案」——使用者選它就
     `git -C <remote-path> merge --abort` 清掉已 stage 的 merge、結束 skill,並告訴他可以跑
     `/tp-suggest-ignore` 處理完再重推。
2. **`AskUserQuestion`**:把**完整 SVN message 預覽放進 `question` 本身**(**不要**先用純文字把預覽印一次、再用「以上 / 上方」帶過;**不洩漏內部術語**):
   - `question`:

     ```
     即將提交到 SVN 的訊息如下,要怎麼做?

     <title>
     <BODY 原樣>
     ```

     `<title>` 之後**直接接** `BODY`、**中間不空行**,且 `BODY` 要**原樣照搬**(不要自己重排、補空行或改寫)——
     這樣預覽才會跟腳本真正送出的訊息逐字一致。`BODY` 只有一個來源分支時是平坦的 `- <subject>` 條列;
     跨多個來源分支時會自帶 `【<分支名>】` 分組標題,例如:

     ```
     <title>
     【<目前分支>】
     - <subject 1>
     - <subject 2>
     【<merge 進來的分支>】
     - <subject 3>
     ```

   - `header`:短籤,如「送出 SVN」。
   - 三選一(選項描述也用白話;Step 3 的 ignore 檢查有發現時多加第 4 個選項):
     1. **確認送出** → 進 Step 5。
     2. **改標題** → 請使用者輸入新標題(自由文字,單行)→ 以「新標題 + 同一份 BODY」**重組同樣的預覽問句**再問一次(同樣不印 step 前言、標題與 BODY 之間一樣不空行)。**只有第一行標題可改,下面的 BODY 永遠是系統帶出的那份、原樣不動。**
     3. **取消** → 跑 `git -C <remote-path> merge --abort` 清掉 prepare 已 stage 的 merge,結束 skill。
     4. (**只在有發現時出現**)**先取消,處理那幾個檔案** → 同「取消」清掉 stage 的 merge、結束 skill,
        並告訴使用者可以跑 `/tp-suggest-ignore` 把它們排除掉再重推。

> 注意:送出前若你又 commit 新內容進 working branch,Step 5 的 commit 腳本會偵測 git HEAD SHA 不符並 abort,提示重跑 prepare。請在送出前確認不會再 commit 新內容。

### Step 5 — Commit to SVN

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Submit-SvnCommit.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/submit-svn-commit.sh`)帶 `--branch <name> --title "<那一行 title>"`(**只傳 title,不傳 body / message**)。Script 會:
- 再次 re-validate SVN HEAD + SHA pin + svn-status drift(防止 race condition)
- 讀 `MERGE_HEAD.tp_svn_body`(鎖定 body;缺檔則 fail-closed 要求重 prepare),把 title collapse 成單行,自組 `title` + 換行 + `body`(**兩者之間不空行**,與 Step 4 預覽逐字一致)寫入 UTF-8 no-BOM temp 檔
- `git commit --no-edit` 完成 stage merge
- 處理 `?` `!` `M` 的 svn add / delete
- `svn commit --file <tmp> --encoding UTF-8` push(避免中文 Big5 mangle)
- `svn update` 同步 working copy revision

Script 輸出 `Pushed to SVN r<rev>` 或 `No changes to commit to SVN`(全被 git-ignore 篩掉)。

### Step 6 — Optional release tag

**Trigger rule(KTD7 / R29 — 判準是「有無產出 git merge commit」,不是「svn commit 有無內容」)**:

- 只要 Step 2 的 prepare 階段找到 **≥1 個新 commit** 可 merge(即 prepare 沒有印 `Nothing to push` 也沒有 only-merge 硬停,而是實際 stage 了一個 git merge commit)→ **詢問 release tag**。
- 這代表:即使 Step 5 回 `No changes to commit to SVN`(所有變更檔案都被 `.gitignore` / push 腳本的 git check-ignore 過濾,svn commit 為空),**只要 git 那側仍產出了 merge commit,就照樣詢問** release tag。tag 指向的是 `remote-svn/<branch>` 這條 git 分支的 tip,與 svn 是否有內容無關。
- 反之,若 prepare 階段就 `Nothing to push`(根本沒有 merge commit 產出),或 only-merge 硬停(沒 stage merge)→ **直接跳過 Step 6**,不詢問。

當觸發條件成立時,用 `AskUserQuestion`:

- **Yes**:建立 release tag
- **No**:略過 tagging

選 Yes → 呼叫 `${CLAUDE_PLUGIN_ROOT}/scripts/Tag-Release.ps1`(或依執行路由改 `${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.sh`)帶 `--branch <name>`:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Tag-Release.ps1" -Branch "main" [-RepoRoot <path>]
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.sh" --branch "main" [--repo-root <path>]
```

Script 印出 `Created tag: <branch>-release-<yyyy-MM-dd>-<NNN>`(serial 同日自動遞增)。把建立的 tag 名回報給使用者。tag 指向 `remote-svn/<branch>` 的 tip。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **Body 由腳本鎖定,agent 只寫 title**:body = prepare 階段 `git log --no-merges` 取出的**所有非-merge commit subject**(`- ` 條列、無 hash、無 type 過濾),經 `MERGE_HEAD.tp_svn_body` temp 檔交付。commit 腳本只收 `--title`,自行組合 `title + 空行 + 鎖定 body`;**agent 不可傳自由 message / body**。要改 body 內容請 amend / rebase 對應 commit 後重跑 prepare。
- **對使用者一律白話、不洩漏內部術語**:`title` / `鎖定 body` / `BODY` / `FILES` / `prepare` / token 名等是 agent / 腳本的**內部用語**,呈現給使用者(尤其 `AskUserQuestion` 問句與選項標籤)時一律換白話——例如 body 講「每個 commit 一行的條列、由系統自動帶出、不能在這裡改」、title 講「第一行標題」。內部結構描述(如「title + 鎖定 body」)只供 agent 對照,**不要照進使用者看得到的文字**。
- **不輸出「Step N」流程編號 / 步驟標題**:本 SKILL 的 `Step 0`–`Step 6` 是**內部程序結構**,**不是要顯示給使用者的內容**。執行時不要印「Step 4 — 確認…」這類 step 標題或前言;使用者看到的應該只有實質內容(異動檔案 + `AskUserQuestion`)。Push 流程**唯一**對使用者輸出的地方是 Step 4 的「異動檔案 + AskUserQuestion」,直接從異動檔案開始印。
- **SVN 訊息 title 不帶 commit-type 前綴**:agent propose 的 title 是白話一行摘要,**固定不寫成** `feat:` / `fix:` / `chore:` / `docs:` 這種 conventional-commit 形式(SVN 端無 release-please / commitlint 消費 type,純雜訊)。**body 條列是 verbatim git subject、保留原樣(可能含 type),不在此限**——只規範 agent 寫的 title。「改標題」時也提示使用者免帶 type 前綴。
- **推送前的 ignore 檢查:偵測到才出聲,而且只偵測不修**(Step 3/4)——對本次會**新增**到 SVN 的檔案套
  `skills/tp-suggest-ignore/assets/ignore-rubric.md` 的判準。沒發現就完全不提(push 是最常用的指令,
  每次都問 ignore 只會變成雜訊);有發現才在 Step 4 的檔案清單後面白話點名,並多給一個「先取消去處理」
  的選項。**不要在 push 中途改 `.gitignore` 或呼叫別的 skill**:merge 已經 stage 好了,中途寫檔會弄髒
  這次推送的內容。之所以值得擋這一下:SVN 提交是永久的,推上去之後刪檔,歷史裡還在。
- **Merge state 必須乾淨**:Step 2 開頭 check `MERGE_HEAD` 不存在;cancel 一律呼叫 `git merge --abort` 確保不留 stale state。
- **UTF-8 no-BOM commit message**:Step 5 script 已正確處理,**不要**改成 `svn commit -m "..."`(Windows CP_ACP 會 mangle 中文)。
- **Pull-from-svn 是 prerequisite**:remote SVN HEAD 不 up-to-date 直接拒跑,讓使用者先 `/tp-pull-from-svn`。
- **Release tag 判準 = 有無 git merge commit**(Step 6):prepare 階段只要產出 merge commit 就詢問 tag,**即使 svn commit 為空**(檔案全被 `.gitignore` / git check-ignore 過濾)也照問;`Nothing to push` 或 only-merge 硬停時才跳過。tag ref 用 `remote-svn/<branch>`。

## Completion Checks

- SVN message body = 本次範圍內**所有非-merge commit subject** 的 `- ` 條列(無 type 過濾);merge commit 不在 body;message 第一行為 agent 寫的 title(白話、**無 conventional-commit type 前綴**)。
- SVN log 顯示新 revision 含繁體中文正確編碼(no mangle)。
- 本地 `git log --oneline remote-svn/<branch>` 含 `Merge branch '<branch>' into remote-svn/<branch>` 自動 merge commit。
- Remote worktree 內 `git status --porcelain` 為空,`svn status` 為空(或只有 git-ignored 的本地檔案)。
- (Step 6,可選)若使用者選擇建立 release tag:`git tag -l "<branch>-release-*"` 出現新 tag,且 `git rev-parse <tag>` 等於 `git rev-parse remote-svn/<branch>`;若 prepare 為 `Nothing to push` / only-merge 硬停則不應出現詢問也不應有新 tag。

## Test Scenarios

- Manual: 推送含 docs / test / chore commit → 它們**全部**出現在 SVN body(確認**無** type 過濾,不再篩掉非程式碼 type)。
- Manual: 推送含一個自動 merge commit + 數個非-merge commit → SVN body **只列非-merge subject**,merge commit 不在 body(`--no-merges` 以 parent 數判定,不靠 `Merge ` 前綴)。
- Manual: 區間只有 merge commit(`--no-merges` 後 body 空)→ prepare fail loudly「only merge commit(s) in range ...」,**不 stage merge、不詢問 release tag**。
- Manual: subject 含 `` ` `` / `$` / 引號 / 前導 `- ` → 經 temp 檔原樣進 SVN message,不被 shell 內插破壞。
- **SHA pin guard (race protection)**: 跑 `/tp-push-to-svn --branch test-1` 進到 Step 4 確認前,在另一個 terminal `git commit` 新 commit 到 working branch。回 SKILL 按確認送出,commit 腳本應 throw `Branch '...' has new commits since prepare (pinned: ..., current: ...). Abort the merge...`。執行該指示,remote worktree `git status` clean。重跑 `/tp-push-to-svn` 應正常進。**.ps1 + .sh 兩條都要跑。**
- **SHA pin cleanup**: 成功 push 後,`<main>/.git/worktrees/<remote-name>/MERGE_HEAD.tp_branch_sha`、`.tp_svn_status`、`.tp_svn_body` 皆不應存在(`Test-Path` / `[[ -f ]]` 皆 false)。
- **PENDING_MERGE Continue path**: prepare 偵到既有 staged merge → SKILL 三選一選 Continue(option 2)→ 略過 prepare,agent propose title 後送出,既有 staged content + 既有鎖定 body 推上 SVN,push 成功。
- **PENDING_MERGE Cancel path**: prepare 偵到既有 staged merge → SKILL 三選一選 Cancel(option 3)→ SKILL 結束,remote worktree `git status` 仍顯示 unstaged merge state(刻意不清,讓使用者手動處理)。
- **ignore 檢查:乾淨的 push 不出聲**: 推一批純程式碼變更 → Step 4 只列異動檔案 + 三選一,**完全沒有**關於 ignore 的文字或第 4 個選項。
- **ignore 檢查:有發現才出聲**: 讓一個明顯是建置產物的新檔(以及一個含連線字串的設定檔)進入本次推送範圍 → Step 4 在檔案清單後白話點名(機密那筆單獨列最前面)、出現「先取消去處理」選項;選它 → `git -C <remote-path> status --porcelain` 乾淨(merge 已 abort)、SVN 無新 revision。

## Tool Preference

檔案 read / write 用 Read / Edit / Write。shell 操作限 `git` / `svn` / 跑 plugin scripts。
