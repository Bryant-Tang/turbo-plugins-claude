---
name: tp-checkout-svn-branch
description: '一步把「既有的 SVN 分支」匯入成本機 git↔SVN bridge + 一條已填好內容的工作分支,讓使用者直接在 git 上接著開發、日後用 /tp-pull-from-svn 同步。**對 SVN 端唯讀**(不建立、不寫入任何 SVN 路徑);只在本機 git 端建立 bridge / worktree / 工作分支,失敗會完全回滾。使用者說「把某個 SVN 分支拉下來 / checkout 既有 SVN branch 開始開發」時適用。'
argument-hint: '--svn-url <existing-svn-branch-url> [--branch <work-branch-name>]'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-checkout-svn-branch

## Purpose

匯入一個**已存在的 SVN 分支**(例如 `<repos-root>/branches/feature-x`)成為:
1. 一條 `remote-svn/<branch>` bridge 分支 + 對應 worktree(內含該 SVN 分支內容的 svn working copy)。
2. 一條**工作分支** `<branch>`,內容已填好、且 **descend from `remote-svn/<branch>`**(KTD5),所以第一次 `/tp-pull-from-svn` 不會撞 "unrelated histories"。

**對 SVN 端完全唯讀**:只 `svn checkout`(讀),不 `svn copy` / `svn propset` / `svn commit`。被匯入的 SVN 分支**不會新增任何 revision**。所有寫入都在本機 git 端,中途失敗一律完整回滾(bridge / worktree / 工作分支)。

> 與 `tp-push-to-svn` 首推 bootstrap 的差別:首推 bootstrap 是把**本機已有**的工作分支推上去、會**建立**新的 SVN 路徑;本 skill 是把**SVN 上已有**的分支拉下來、對 SVN 唯讀。

## Procedure

### Step 0 — 執行路由

依環境選工具(**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**):
- Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
- Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`(**單破折號參數 `-SvnUrl` / `-Branch`**;GNU 風格 `--svn-url` 在 `powershell -File` 下不可靠)。
- Linux / macOS → 用 **Bash 工具**跑 `.sh`。
Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL)。

### Step 1 — 前置確認

- **先確定要對哪個 repo 動手**——讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`,依它的判準決定要不要帶 `-RepoRoot` / `--repo-root`。單一專案的目錄不用帶;當前目錄自己不是 repo 但底下並排著多個 repo 時**必須先問使用者是哪一個**再指名。這支會在本機 git 端建分支 / worktree,所以**跑之前先用白話講出要動的專案絕對路徑**。
- 需要 `--svn-url <url>`(要匯入的既有 SVN 分支 URL)。未提供 → 要求使用者提供後再續。
- 前置條件:`remote-svn-main` bridge 必須已存在(本 skill 以它為信任錨,且**不**自行 bootstrap 主 bridge)。若不存在 / 損壞,腳本會 fail-closed 並導向先跑 git-svn `/tp-setup`。
- 工作分支名:預設 = SVN URL 的葉名(最後一段)消毒後;要自訂用 `--branch <name>`。

### Step 2 — 執行匯入

依執行路由跑:
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Checkout-SvnBranch.ps1" -SvnUrl <url> [-Branch <name>] [-RepoRoot <path>]
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checkout-svn-branch.sh" --svn-url <url> [--branch <name>] [--repo-root <path>]
```

Script 會(全部在任何 mutation 之前做完):
- 確認 `remote-svn-main` 是有效 svn working copy(訊息區分「目錄缺」vs「WC 損壞」並帶 svn info 原因)。
- 衍生 / 消毒工作分支名(葉名空或被 allowlist 拒 → 要求改用 `--branch`)。
- 碰撞 / 部分狀態守衛(同 dir 不同 ref、bridge 已存在、ref-XOR-dir 不一致)。
- **R20**:本機已有同名工作分支 → 拒絕、零副作用。
- **R18 信任檢查**:`Assert-TrustedSvnUrl`(錨 `remote-svn-main` repos-root-url),URL 不在受信任根下 → 拒絕、零副作用。
- 確認該 SVN 分支**確實存在**(唯讀,不建立)。
- **分支接點(fork-point)分級解析(唯讀,U5)**:讀分支的原始名稱與對齊資訊,把工作分支接到本機主線裡**正確的分出點**,而不是一律掛在主線最新處。若本機主線缺了接點所需的更新,script 會**在任何 mutation 之前停下並說明**(exit 1、零殘留),見下方 Decision Rules「分支接點分級處理」。

通過後(rollback-guarded):建 `remote-svn/<branch>`(根於解析出的 fork-point commit)→ 加 worktree → 清空 worktree → `svn checkout`(讀,純 checkout 無 `--force`)→ `svn rm --keep-local .git` → 同步 main 的 `.gitignore` → `git add -A` + commit 匯入內容到 bridge(只搬 SVN 分支相對主線的差異,tree 就是 SVN 分支內容)→ 開工作分支 `<branch>`(由 bridge ref 開出)。任一步失敗 → 回滾本機 git 三件,SVN 端無新 revision。

### Step 3 — 回報

把腳本輸出的「Working branch / Bridge branch / SVN worktree / Next」原樣呈現給使用者,並提示下一步:`git checkout <branch>` 開始開發,日後用 `/tp-pull-from-svn --branch <branch>` 同步 SVN 後續變更。

**分支名是從路徑推出來的時候,要說明為什麼。** 本工具建立的分支會把原始名稱記在 SVN 上,所以
`feature/x` 抓回來還是 `feature/x`。但**不是本工具建的分支**(同事直接用 `svn copy` 開的)沒有那筆
記錄,SVN 路徑上只剩短橫形式、也無法反推——這時本機分支就叫路徑名。

**判斷條件(不要靠「名字裡有沒有斜線」去猜**——本來就沒有斜線的分支會被誤判**)**:只有在
**使用者沒有指定 `--branch`**(名稱是從 SVN 路徑推出來的)時才需要判斷,這時跑一次唯讀查詢:
`svn propget tp:branch-name <svn-url>`。有值 → 已經還原成原始名稱,**什麼都不用講**。
沒有值(空的)→ 在回報裡加一句白話:

> 這條分支不是用本工具建立的,SVN 路徑上沒有記下原始名稱,所以本機分支沿用了路徑名 `<name>`。
> 如果你們的慣例是 `feature/xxx` 這種寫法,你本機的分支名可能會跟同事的不一樣。要改的話
> `git branch -m <新名字>` 就可以,不影響 SVN 那邊。

還原成功、或使用者本來就自己指定了 `--branch` 時**不要**印這段——沒事講一輪只會讓人以為出問題了。

## Decision Rules

- **執行路由**:同上 Step 0;PowerShell 一律用單破折號參數。
- **對 SVN 唯讀**:本 skill 永不對被匯入的 SVN 分支寫入(無 `svn copy` / `propset` / `commit`);失敗只回滾本機 git,SVN 端零變更。要**建立**新 SVN 分支請走 `tp-push-to-svn` 首推 bootstrap,不是本 skill。
- **工作分支必須 descend from bridge ref**(KTD5):工作分支由 `remote-svn/<branch>` 開出,確保第一次 `/tp-pull-from-svn` 的 merge 不是 unrelated histories。
- **同名工作分支零副作用拒絕**(R20):本機已有同名分支即拒絕、不動任何 git/svn 狀態;請改 `--branch` 或先處理既有分支。
- **remote-svn-main 是前置、不自行 bootstrap**:缺 / 壞 → fail-closed 導向 git-svn `/tp-setup`。
- **branch 名消毒走 `Resolve-RemoteWorktree`**:葉名衍生後若被 allowlist 拒,改要求 `--branch` 明確命名。

### 分支接點(fork-point)分級處理

Script 會把工作分支接到本機主線裡**正確的分出點**。若接不上,它會**停下並說明**(exit 1、零殘留),stderr 訊息是給 agent 讀的、**含 `r<n>` 等技術字眼**。呈現給使用者時**一律白話**,不要把 script 原文或 `refs/tp/svn/<n>` / `remote-svn/main` / `tp:last-aligned-rev` / `copyfrom-rev` / 「replayed revision」/ 「aligned rev」等內部字眼丟出去。常見的三種停下情況(a)/(b)/(c)如下;**其餘任何 fork-point 相關的 exit 1**(例如接點資料格式不對「不是修訂號」、接點對到不只一顆 commit 而無法唯一決定、讀不到分支當初的分出版本等)一律走 (d) catch-all——**同樣白話**、只說「這個分支的接點資訊有問題,無法安全接上」並建議請分支作者刷新接點後重試,**絕不**照抄 stderr 或把屬性名/修訂號丟給使用者。

- **(a) 缺的更新可以補**(stderr 類似 `... is newer than the newest replayed revision on local main ... Pull trunk first: run /tp-pull-from-svn --branch main`):分支是從主線後來的某個更新分出去的,而本機主線還沒拉到那個更新。**白話向使用者說明並主動提議**:「這個分支是從主線比較新的一次更新分出去的,你本機的主線還沒跟到那裡。要我先幫你把主線的 SVN 更新拉下來,再重試把這個分支拉進來嗎?」使用者同意 → 先跑 `/tp-pull-from-svn --branch main`(逐修訂拉齊)→ **再重跑本 checkout**。使用者拒絕 → 停在此,不建立任何東西。
- **(b) 缺的更新補不回來**(stderr 類似 `... has no replayed commit on local main and cannot be pulled (it predates the earliest replayed revision, or its range was squashed away). Ask the branch author to merge main into the branch and push ...`):分支要接的那個主線版本在本機**找不到、也沒法用拉取補回來**(那段歷史在本機被壓成一顆 / 略過了)。**白話告訴使用者**:「這個分支要接上的主線版本,在你這邊的歷史裡已經被壓縮/略過、補不回來了。請**分支作者**把主線(main)併進這個分支後再 push 一次(這會把分支的接點更新到能對得上的版本),之後你再重試把它拉進來。」不自行猜一個接點、不硬掛。
- **(c) 接點資料看起來過期/矛盾**(stderr 類似 `stored alignment r<R> is older than the branch's fork revision r<...>, so the branch metadata looks stale/contradictory`):分支記錄的接點比它當初分出去的版本還舊,資料自相矛盾。**白話**:「這個分支的接點資訊看起來怪怪的(可能過期了)。請分支作者把主線併進分支再 push 一次刷新接點,然後再重試。」同樣不硬掛。
- **(d) 其他接點問題(catch-all)**(stderr 例如 `branch metadata tp:last-aligned-rev ... is not a revision number`、floor 對到多顆 commit 的 ambiguous、讀不到 copyfrom-rev 等):不屬 (a)/(b)/(c) 的任何 fork-point exit 1 都歸這裡。**白話**:「這個分支的接點資訊有問題,沒辦法安全地把它接到主線上。請**分支作者**把主線併進分支再 push 一次刷新接點,然後再重試;若仍失敗請回報。」**絕不**照抄 stderr、不把 `tp:last-aligned-rev` / `copyfrom-rev` / 修訂號等內部字眼丟給使用者,也**不硬掛**。
- 四種情況都**絕不**把工作分支掛在錯的/過期的接點上(R11);(a) 補齊後可續,(b)/(c)/(d) 需分支作者刷新後才可續。

## Completion Checks

- `git branch --list <branch>` 出現工作分支;`git rev-parse <branch>` == `git rev-parse remote-svn/<branch>`(工作分支建立於 bridge tip)。
- `git merge-base <branch> remote-svn/<branch>` 非空(首次 pull 不會 unrelated histories)。
- 成功時工作分支接在**正確的分出點**:`git merge-base main <branch>` 解析到解析出的 fork-point commit(不是主線最新處)。
- 分支接不上而停下時(上述 (a)/(b)/(c)/(d)):給使用者的說明是**白話**、不含 `refs/tp/svn/<n>` / `remote-svn/main` / `tp:last-aligned-rev` / `copyfrom-rev` / 「replayed / aligned revision」等內部字眼;(a) 有主動提議先 pull 再重試,(b)/(c)/(d) 有請分支作者刷新接點再重試;皆**零殘留**(無 bridge / worktree / 工作分支)。
- bridge worktree(`remote-svn-<branch>`)存在且是該 SVN 分支的 working copy;其 `git status --porcelain` 乾淨(`.svn/` 已被 `.gitignore` 忽略)。
- 被匯入的 SVN 分支**無新 revision**(`svn log` 末筆未變)。
- 拒絕 / 失敗路徑:無殘留 bridge 分支 / worktree / 工作分支。

## Test Scenarios

- Manual(happy):對既有 `<repos-root>/branches/feature-x` 跑本 skill → 建 `remote-svn/feature-x` + `feature-x` 工作分支(內容已填)→ `git checkout feature-x` 看得到 SVN 內容 → `/tp-pull-from-svn --branch feature-x` 成功(無 unrelated histories)。SVN 端無新 revision。
- Manual(同名衝突,R20):先 `git branch feature-x`(內容不同)→ 跑本 skill → 拒絕、零副作用(無 bridge / worktree 建立、SVN 無新 revision)。
- Manual(無 remote-svn-main):未 setup 主 bridge → 跑本 skill → fail-closed,訊息導向先跑 git-svn `/tp-setup`,不建任何東西。
- Manual(信任邊界):`--svn-url` 指向受信任根外(或 `..` traversal / `repos-evil`)→ 拒絕、零副作用。
- Manual(自訂名):`--branch my-work` → 工作分支名用 `my-work`,worktree = `remote-svn-my-work`。
- Manual(接點就在本機,靜默接上):本機主線已有分支對齊版本對應的 commit → checkout 不問、直接把工作分支接在正確分出點(`git merge-base main <branch>` == 該 fork commit)。
- Manual(缺更新可補,path a):本機主線落後於分支對齊版本 → checkout **停下並白話說明**,主動提議先 `/tp-pull-from-svn --branch main` 再重試;同意並拉齊後重跑 → 接在正確分出點。零殘留。
- Manual(補不回來,path b):分支對齊版本在本機被壓縮/略過、拉不回來 → checkout **停下並白話說明**,請分支作者把 main 併進分支再 push 刷新接點後重試;**不硬掛**、零殘留。
- Manual(接點資料矛盾,path c):分支記錄的對齊版本比它 fork 版本還舊 → checkout **停下並白話說明**,請分支作者刷新接點後重試;**不硬掛**、零殘留。

## Tool Preference

檔案 read / write 用 Read / Edit / Write。shell 操作限 `git` / `svn` / 跑 plugin scripts。
