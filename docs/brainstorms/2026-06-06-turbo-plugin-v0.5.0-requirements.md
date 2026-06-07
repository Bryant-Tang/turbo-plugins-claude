---
title: turbo-plugin v0.5.0 — SVN bridge 一般化、commit-msg 規範回歸、測試框架化與跨環境韌性
status: ready-for-planning
created: 2026-06-06
reviewed: 2026-06-06
type: requirements
target_version: 0.5.0
scope: deep
---

# turbo-plugin v0.5.0 需求

> 本文件已經過一輪 `ce-doc-review`(6 persona),16 條 actionable findings 全數裁示並回寫。重大變動:reset/merge skill 改泛化保留(非移除)、`.NET csproj / VS 2022 自動分析`抽出另開 brainstorm、R3 擴張為「清除所有僅限本機的東西」、新增 `.svn` gitignore 簡化、R6 取代並移除 `[svn] force_bash`。

## 問題框架（Problem Frame）

turbo-plugin 目前仍是 0.x 未發佈狀態,但 CHANGELOG 已誤植 `[1.0.0]` 並與 `[Unreleased]` 並存,版本語意失真。實際使用累積出五類結構性痛點:

1. **SVN bridge 過度限定** — `Resolve-RemoteWorktree` 寫死只接受 `main` 與 `test-<n>`,任何其它本機 branch 無法上 SVN。實務上使用者想把任意 branch 推上 SVN 遠端,`test-<n>` 編號制是多餘約束。
2. **跨環境編碼脆弱** — 腳本依賴使用者 console 的 `OutputEncoding` / `InputEncoding` / `$OutputEncoding`,不同機器、不同環境變數下會亂碼(尤其中文 commit message 與檔名)。
3. **測試手刻難維護** — 自製的兩層測試 orchestrator 維護成本高,缺少成熟框架的斷言與報表;且未來新 plugin / skill 缺方便的測試工具。
4. **僅限本機的東西外洩進版控** — 規範一條條塞進使用者專案的 `CLAUDE.md`;且本 repo(含舊 docs)殘留機器專屬絕對路徑、內部 SVN/host URL 等只對作者某台電腦有效、不適用其他開發者的內容。
5. **commit-msg 語意無規範** — 先前移除的 commit-msg 引導未回歸,導致 commit message 可能引用僅本地有效的東西(git SHA、需求/計畫/任務代號);但遠端是 SVN、不同 clone 的 git SHA 不一致,這類引用會誤導。

本需求一次處理上述五類,定版為 **v0.5.0**。

> **抽出項**:原 item 17「.NET 技能接收 csproj、自動分析(組態/平台/pubxml/輸出)、體驗對齊 VS 2022」野心較大,**整個抽出另開第二個 brainstorm** 細談範圍,不在 v0.5.0。詳見「抽出到後續 brainstorm」。

## 目標（Goals）

- 把 git↔SVN bridge 一般化為「任意 branch → `remote-svn/<branch>`」,移除 `main`/`test-<n>` 特例。
- 讓所有腳本在任意 console 編碼/環境變數下都不亂碼(集中於共用 lib,不逐腳本複製)。
- 以 Pester + shUnit2 取代手刻測試框架(刻意全面遷移,讓未來新 plugin/skill 有成熟好用的測試工具)。
- 把規範集中進 `.turbo-plugin/` 的單一規範檔,`CLAUDE.md` 只留指向 + 常駐「不得提交僅限本機之物」規則;全 repo(含舊 docs)清除所有僅限本機才有的內容。
- 回歸 commit-msg 語意規範(只管語意、不管 type)。
- 修正版本號語意(移除 `1.0.0`,定版 0.5.0)。

## 非目標（Non-Goals）

- **不**改 git↔SVN bridge 的基本架構(per-remote-branch worktree 模型保留)。
- **不**自動推導 SVN repo layout(不引入 `trunk`/`branches/<name>` 慕約);使用者仍透過 `--svn-url` 指定。
- **不**進入已發佈的 `1.0.0`(明確維持 0.x 預發佈)。
- **不**改變 commit type 的 enforcement 機制(type 仍由 commitlint + `tp-push-to-svn` 處理,不裝 husky/npm)。
- **不**自動安裝 Pester / shUnit2 到使用者本機(本機缺則跑測試時報錯;CI 自行安裝)。
- **不**在 v0.5.0 做 `.NET csproj 自動分析 / VS 2022 體驗`(抽出另開 brainstorm)。

---

## 關鍵決策（Key Decisions）

> brainstorm 過程與使用者確認、並經 doc-review 修正後的架構分岔結論,planning 須據此實作。

### KD1 — SVN URL 由使用者每次 `--svn-url` 指定(沿用現行機制)

調查現況確認:**目前沒有任何 `trunk`/`branches` 寫死慕約**。`main` 的 SVN URL 就是 `/tp-setup` 時使用者給的 URL(存在 `remote-svn-main` worktree 的 `.svn` metadata);`test-<n>` 的 URL 由使用者透過 `--svn-url` 完整指定,plugin 只驗證它在同一 `repos-root-url` 之下、不存在則 `svn copy` 自 `main` 當前 URL。

v0.5.0 **沿用此機制**,只拿掉 `test-<n>` 名稱限制:push 一個還沒有對應 SVN 路徑的 branch 時,使用者傳完整 `--svn-url`,plugin 驗證 trust + 不存在則 `svn copy`。**不**引入 config layout 樣板、**不**從 branch 名自動推導 URL。

### KD2 — 命名:git ref 保留斜線、worktree 目錄 slash→dash、含消毒與碰撞處理

- git ref:`remote-svn/<local branch name>`,**保留斜線**(本機 `feat/login` → ref `remote-svn/feat/login`)。
- bridge worktree 目錄:`remote-svn-<branch>` 且 **slash→dash**(`remote-svn-feat-login`),避免巢狀路徑。
- SVN 路徑:由 `--svn-url` 決定(見 KD1),plugin 不推導。
- **branch 名消毒(必須)**:把 branch 名轉成 dash-form 路徑片段前,以 allowlist 驗證並**拒絕**:含 `..`(路徑穿越)、以 `-` 開頭(會被命令列當旗標)、含 slash→dash 以外的路徑分隔/控制字元、轉換後撞到保留名。**保留名比對須大小寫不敏感**(`MAIN`/`Main` 在不分大小寫的 Windows FS 仍撞 `remote-svn-main`、汙染 trust 錨點)。保留名集合至少含:`main`,以及 **Windows 裝置名** `CON` / `PRN` / `AUX` / `NUL` / `COM1`–`COM9` / `LPT1`–`LPT9`(這些當資料夾名會被 Windows 解析成裝置而非檔案,造成 git/svn/PS 操作誤動或卡住)。另**拒絕結尾點或空白**(Windows 靜默去除 → 與其它名碰撞)。
- **MAX_PATH 語意釐清(必須)**:對組出的 worktree 絕對路徑加 **MAX_PATH(260)上限** 檢查,但此檢查守的是「**本機能否建此 worktree 目錄**」(路徑長度取決於 clone 位置、機器相關),**不是**「branch 名是否合法」(branch 名與 SVN ref 是機器無關的永久產物)。因此:① MAX_PATH 超限的錯誤訊息須與 allowlist 拒絕**分開**,提示「縮短 clone 路徑或啟用 long-path support」而非「改 branch 名」;② 區分兩態避免承諾 OS 做不到的事——(a) 本機**已 bootstrap** 的 bridge worktree:pull/sync 不建目錄,MAX_PATH 本就不 gate,正常同步;(b) **未在本機**的已發佈 ref 要在深 clone 機器首次取得:bootstrap 必經 `git worktree add` 建目錄,OS 會 hard-fail 超長路徑,此時 guard 以 ① 的訊息(縮短 clone 路徑 / 開 long-path support,如 `core.longpaths` 或 `\\?\` 前綴)fire——**不**承諾「sync 照跑」。plan 須裁示 (b) 是 hard-fail 引導,還是嘗試 long-path-aware 建立。
- **碰撞偵測(必須)**:因 `feat/login` 與 `feat-login` 都映射到同一 worktree 目錄名,建立前先檢查該目錄名是否已被「不同 ref」佔用;是則**拒絕並提示改名**,不得默默接到錯的 working copy。比對採 **normalize-then-compare**(大小寫、結尾點/空白正規化後再比),避免結尾點等變體繞過。

### KD3 — 測試框架:全面遷移 Pester + shUnit2(硬需求),CI 安裝、本機缺則報錯

刻意全面以 Pester(PS)+ shUnit2(bash)取代手刻測試框架——**這是硬需求**:就是要重寫既有測試、採用最新 Pester,才能讓未來新 plugin / skill 有成熟、好用、可重用的測試工具與報表,值得一次性遷移成本。

- CI workflow 明確安裝 Pester(最新版)+ shUnit2,確保綠燈。
- 本機開發者若未安裝框架 → 跑測試時**報錯**(fail loudly,非 SKIP)。
- **SKIP 規則(精確)**:框架(Pester/shUnit2)缺席一律 FAIL;**SKIP 僅限**「在 **Unix 環境** 跑、且需要**只在 Windows 才有的工具**(.NET Framework/MSBuild、IIS Express 等)」的個別測試。這些 Windows-only 工具測試**必須在 Windows / Git Bash 真的執行驗證**,不得到處 SKIP——否則測試形同無效。

### KD4 — 建立 remote bridge 折進 `tp-push-to-svn`(首推自動 bootstrap,含安全 gate)

移除獨立的 `tp-create-remote-test`。`tp-push-to-svn` 偵測到當前 branch 還沒有 `remote-svn/<branch>` bridge 時,於 push 流程內以 `AskUserQuestion` 確認後,自動建立 bridge(git branch + bridge worktree + `svn copy` + `svn checkout`)再 push。因含永久 SVN 路徑創建,bootstrap gate **必須**:

1. **先**做「分支不符檢查」(current vs requested branch)並讓使用者確認,**再**進入 bootstrap 確認——避免在不知推錯分支的情況下先建了刪不掉的永久路徑。
2. **拒絕 detached HEAD**(無分支名可推導)。
3. 確認視窗明示完整 `--svn-url` 與「**這會在 SVN 建立永久路徑(建後刪不掉、進所有人 SVN 歷史)**」。

---

## 需求（Requirements）

### A. 版本號與「僅限本機之物」衛生

- **R1**(item 1):修正 CHANGELOG 版本語意。將現有 `[1.0.0] - 2026-05-27` 改為 `[0.3.0]`;現有 `[Unreleased]`(U7–U12 + code review 修正)整段改為 `[0.4.0]`(補日期);本次 v0.5.0 工作另起區段。由舊到新:`… [0.2.7] → [0.3.0] → [0.4.0] → [0.5.0]`。發版前確認無 git/SVN tag、marketplace.json pin 或外部 clone 引用 `1.0.0`(現況 `git tag -l` 為空)。
- **R2**:`plugin.json` `version` 最終定為 `0.5.0`;skill 數描述同步更新為 **16**(移除 `tp-create-remote-test`、新增 `tp-commit-msg`、2 支改名,淨數不變;見 R12)。
  - **注意:現況三處不一致,非僅 stale** — `plugin.json` 與 `README` 目前寫 **14**(且 `plugin.json` version 仍 `1.0.0`)、`marketplace.json` 已寫 **16**(實際數 16)。且 **README 有兩處** skill 數(描述段 + 行 141 附近的遷移文案)。plan 須 **grep 全部 4 處**(plugin.json 1 + marketplace.json 1 + README 2)而非假設「三處同步」。
- **R3**(item 12,審查後擴張):清除**整個 `turbo-plugins-claude` repo**(含舊 `docs/brainstorms/`、`docs/plans/`、`docs/solutions/`、CHANGELOG、README、所有 SKILL/script/測試)中**所有僅限本機才有、不適用其他開發者或作者另一台電腦的內容**,不只絕對路徑——包含:機器專屬絕對路徑、內部 SVN/host URL(`file://` / `svn://` / `http://` 內含內部 hostname 或專案路徑片段,如 `file:///C:/.../SampleSvnServer/`)、其它僅限本機/單次情境的識別碼。改為 repo 相對路徑或 placeholder。
  - **範圍:所有既有 doc 都要清** — turbo-plugin 全未發佈,不分「protected / 草稿」;`docs/brainstorms/`、`docs/plans/`、`docs/solutions/` 等全部歷史文件都在清理範圍內(受保護不刪,但內容 placeholder 化)。
  - **固定 placeholder token 慕約(必須)** — 定一組固定字串讓全 repo 一致替換,例如:內部 SVN/host URL → `<INTERNAL-SVN-URL>`、機器絕對路徑 → `<MACHINE-PATH>`、其它僅本機識別碼 → 對應的 `<...>` token。禁止臨時自創不一致的替代字串,確保歷史紀錄仍可讀且可驗證。
- **R3a**(常駐規則,於 R15/CLAUDE.md 落地):在 `CLAUDE.md`(或其指向的 conventions 檔)加一條常駐規則——**不得把僅限本機才有的東西提交進版控**(機器路徑、內部 hostname/URL、僅本機或單次情境的識別碼等),因為這些不適用其他開發者或作者的別台電腦。R3 是一次性清理,R3a 防止復發。
  - **enforcement(FYI,plan 評估)**:R3a 目前是書面/祈使規則、無自動把關。plan 可評估加一個輕量 CI lint(grep `file:///`、絕對 drive 路徑、已知內部 hostname 片段);若決定維持 advisory-only,明記為已接受風險。

### B. 腳本跨環境韌性(集中,不複製)

- **R4**(item 2,審查後改為集中式):編碼初始化**集中於共用 lib 一處**,不逐腳本複製——
  - PowerShell:`Common.ps1` 開頭設 `[Console]::OutputEncoding` / `$OutputEncoding` = UTF-8(現已有),**新增** `[Console]::InputEncoding` = UTF-8 但**須 guard**(try/catch 或無 console input handle 時略過,避免非互動 / redirected console 下 throw)。**所有 `.ps1`(含目前未 source 的進入點)一律在開頭 dot-source `Common.ps1`** 以繼承編碼設定。
  - Bash:`common.sh` 設定 UTF-8 locale(或等效);**所有 native `.sh` 一律 source `common.sh`**。`ps1-delegate.sh` trampoline 只轉呼叫 `.ps1`,不需 source。
- **R5**(item 16):`tp-push-to-svn`、`tp-svn-log` 路徑特別驗證 console I/O 不受使用者環境變數影響(R4 的重點驗證子集)。
  - **註**:R4/R5 處理的是 **console I/O 顯示層亂碼**;中文**檔名** push 到 SVN 的正確性是另一條既有機制(tp-setup encoding profile detect + 走 .sh)在管,見 R6 與 KD;R4 不改變該結論。

### C. 技能執行路由(取代 force_bash)+ 移除 schema_version

- **R6a**(移除 `schema_version`,審查 round 3 新增):`config.toml` 的 `schema_version` 欄位整個**移除**。它原是為 `force_bash` 而從 v1 升 v2 的格式版本 gate,但加可選欄位本就不需升版(`Resolve-ConfigValue` 讀不到鍵即用預設),validator 對「不認得版本」的警告對單一 co-evolving plugin 價值低、卻每加欄位就要 bump。移除範圍:
  - `default-files/.turbo-plugin/config.toml` 範本的 `schema_version`(現寫死 `2`,對每個 setup 過的專案都標 v2)。
  - schema_version validator 檢查碼:`Test-TurboPluginConfigSchema`(`Common.ps1`)/ `check_turbo_plugin_config_schema`(`common.sh`)整個函式,其在 `Resolve-ConfigValue` / `resolve_config_value` 的 call site,以及 module-scope once-guard 變數(`$script:_TpSchemaWarned` / `_TP_SCHEMA_WARNED`)。(validator 是 warn-only、不參與 control flow / 回傳值,刪除安全。)
  - schema_version 測試:`tp-push-to-svn` SKILL.md 內的 schema_version warning 案例(該案例現已 stale——斷言 v2「not recognized」但 live validator 其實接受 v1/v2),**以及**專用單元測試斷言 `tests/unit/scripts/lib/Common.test.ps1`(schema_version warning 區塊 + `Get-SchemaWarningStderr` helper)與 `common.test.sh` 對應斷言。
  - 既有已寫 `schema_version` 的 config:讀取端**忽略該鍵即可**(不警告、不報錯),config 讀取維持寬鬆(缺鍵用預設)。


- **R6**(item 4,審查後含 force_bash 釐清):**所有要執行腳本的 skill** 遵循統一 script 優先序:
  - Windows + 有 Git Bash → 優先用 **Bash 工具執行 `.sh`**。
  - Windows + 無 Git Bash → 優先用 **PowerShell 工具執行 `.ps1`**。
  - Linux / macOS → 優先用 **Bash 工具執行 `.sh`**。
  - 明確註明:**不要**用 Bash 工具再去呼叫 `pwsh …` / `powershell …`。
  - **Git Bash 偵測法(原 OQ4,審查後在此定案)**:先檢查標準 Git for Windows 安裝路徑的 `bash.exe`(`C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`);找不到再 fallback `where.exe bash`,但**排除** `System32\bash.exe`(WSL)。`Invoke-ScriptTests.ps1` 既有的候選路徑可當實作起點。
  - **取代 `[svn] force_bash`**:R6 一般化路由**取代並移除** `config.toml [svn] force_bash` flag——有 Git Bash 時 SVN 操作本就走 .sh,force_bash 的工作被涵蓋。「Windows **無** Git Bash + 中文檔名」之縫仍由 tp-setup 的 encoding profile detect 引導(裝 PS7 / 開 Win10 UTF-8 codepage)處理。
  - **完整 call-site sweep(必須,比照 R7 嚴謹度)**:移除 force_bash 不只刪 config key,須一併處理——(1) **tp-setup Step 0.5 case (a)** 目前會**寫入** `force_bash = true`,須改為不再寫此 key、改靠 R6 的 Git Bash 自動偵測;(2) 所有透過 `Resolve-ConfigValue` 讀 `force_bash` 路由的 skill(tp-push / tp-pull / tp-reset / tp-merge / 原 create 等)的對應分支。

### D. SVN bridge 模型一般化

- **R7**(item 13 + KD1/KD2/KD4):任意本機 branch 可推上 SVN,遠端 ref = `remote-svn/<branch>`(保留斜線),bridge worktree 目錄 = `remote-svn-<branch-dash>`,含 KD2 的消毒與碰撞處理。`Resolve-RemoteWorktree` 移除 `main`/`test-<n>` 寫死、接受任意 branch。
  - **完整去耦(審查後新增,涵蓋 PS + bash 兩端)**:R7 須涵蓋**所有**比對 `main|test-<n>` 的 call site,不只 `Resolve-RemoteWorktree`——包含:
    - PS 端:`lib/Common.ps1` 的 `Resolve-RemoteWorktree`、`Set-SvnIgnore.ps1` 寫死的列舉 regex `^remote-svn-(main|test-\d+)$`、Submit/Build/Sync/Tag/Get-SvnLog 的預設 `-Branch main` 與 `<main|test-<n>>` 驗證。
    - **bash 端(易漏,且非 Windows 主走 bash)**:`lib/common.sh` 的 `resolve_remote_worktree`(硬編 `remote-svn-main` / `remote-svn-test-$n`,約行 125/130)、`set-svn-ignore.sh` 的 glob + pattern、各 `.sh` 的 `-Branch` 用法字串。
    - 明訂「任意分支列舉」取代列舉 regex,否則 tp-suggest-ignore 會漏掉任意名 bridge;只改 PS 端會讓 .sh 仍拒任意分支。
- **R8**(KD4):移除 `tp-create-remote-test`;其建立 bridge 邏輯折進 `tp-push-to-svn` 首推自動 bootstrap,含 KD4 的三道安全 gate(分支不符檢查先於 bootstrap、拒 detached HEAD、明示永久路徑)。沿用 `New-RemoteTest` 既有的 trust-先驗、rollback try/catch、`.git` untrack、`svn:ignore` 繼承等完整序列。
- **R9**(item 15,審查後改為泛化保留):`tp-reset-remote-test` **泛化保留為 `tp-reset-branch-to-main`**——去掉 `test-<n>` 假設、適用任意分支,**保留** LOSE/GAIN/FILES_LOST 預覽 + 強制確認 gate。(原 `.svn/*` dirty-check 過濾改由 R12a 的 `.svn` gitignore 取代,不再逐處過濾。)不刪除。
  - **footgun 防護(FYI)**:泛化到任意分支後,`git reset --hard main` 會全毀目標分支的領先 commit。確認視窗須**凸顯 LOSE commit 數**,並對「此分支有 N 個 commit 不在 main」加強警告,讓 `test-<n>` 過去隱含的「可丟棄」安全感對任意分支變成明示。
- **R10**(item 14,審查後改為泛化保留):`tp-merge-main-into-all` **泛化保留為 `tp-merge-main-into-branches`**——讓使用者指定要合哪些分支,**保留** 髒工作區守門 + 逐分支 `git merge --abort` 衝突隔離 + 還原原分支。不刪除。
- **R11**:trust base 仍錨定 `remote-svn-main` 的 `repos-root-url`(`main` 維持 SVN trunk 錨點與 trust 驗證基準);`Assert-TrustedSvnUrl` 行為不變。
- **R12**(skill 清單淨變動,審查後修正):移除 1(`tp-create-remote-test`,折進 push)、新增 1(`tp-commit-msg`)、改名 2(`tp-reset-remote-test`→`tp-reset-branch-to-main`、`tp-merge-main-into-all`→`tp-merge-main-into-branches`)。**16 → 16 skills**(數不變)。受影響的測試、README、marketplace/plugin manifest 同步。
- **R12a**(`.svn` gitignore 簡化,審查後新增):讓 tp-setup / 建 bridge 流程把 `.svn/` 寫進 bridge worktree 適用的 gitignore(現況 `.gitignore` **沒含** `.svn/*` rule,見 `New-RemoteTest.ps1` 註解),使後續 `git add -A` 不再 stage `.svn`。據此**移除** Sync-FromSvn / Reset-RemoteTest 各處的 `.svn` dirty-check 過濾,以及 New-RemoteTest 的 `.svn/wc.db` merge 衝突處理。
  - **無需 migration**:turbo-plugin 全未發佈、無外部使用者,既有開發用 bridge worktree 視為可重建,不處理「`.svn` 已被 git track」的舊狀態(否則需 `git rm -r --cached .svn`)。
  - **gitignore 落點 ordering(load-bearing,必須明訂)**:bridge 的 `.gitignore` 是從 main 逐字 `Copy-Item` 來的(`New-RemoteTest.ps1` 約行 142),而 main 的 `.gitignore` 不含 `.svn/*`。因此 `.svn/` rule 必須**在第一次 `git add -A`(`Sync-FromSvn.ps1` 約行 72)之前**就到位——做法二擇一:(a) 把 `.svn/` 加進 **main 的 `.gitignore`**,讓 copy 自然帶走;或 (b) 在 copy-from-main **之後** append `.svn/` 到 bridge 的 `.gitignore`。不可寫在第一次 `git add` 之後,否則 `.svn` 仍會被 stage 一次。
  - 註:svn 本就不收自己的 `.svn`,git 忽略它是標準做法、不干擾 SVN。`.svn/wc.db` merge 衝突與 `.gitignore` 內容同步衝突是兩回事,後者(`New-RemoteTest` 既有的 `.gitignore` 同步)**不**隨此項移除。

### E. commit-msg 語意規範回歸

- **R13**(item 6):新增(回歸)`tp-commit-msg` skill,**只規範 commit message 語意,不規範 type**。type 一律依 commitlint(`.commitlintrc.json`),skill 內**不**列舉任何 type 清單。
- **R14**(item 6):commit-msg 語意規則須包含(至少):
  - **不得**引用特定 git SHA(遠端是 SVN,不同 clone 的 git SHA 不一致)。
  - **不得**引用僅限本地專案才有的東西:需求代號、計畫代號、任務代號,或僅限單一 session 內的項目代號等(與 R3a「不得提交僅限本機之物」同源)。
  - (搭配一般語意規則:祈使語氣、說明 what + why、語言一致等。)

### F. 規範集中化 + 精簡 CLAUDE.md

- **R15**(item 7,審查後加祈使觸發):`tp-setup` 不再把規範一條條寫進使用者專案的 `CLAUDE.md`。`CLAUDE.md` 只寫「本專案已安裝 turbo-plugin,須遵守 turbo-plugin 規範」+ 指向規範檔 + R3a 常駐規則。
  - **祈使觸發(必須)**:為避免「agent 不主動讀指向檔 → 規則無聲漏遵循」,CLAUDE.md 的指向須是**祈使觸發語**(例:「執行任何 DB / commit / `*.cs` / `*.js` 操作前,先讀 `.turbo-plugin/<conventions>`」),而非被動的「須遵守」。高風險不變量(DB 不可變、no-SHA 等)亦可酌情 inline。把「讀檔可靠性」列為驗收考量。
- **R16**(item 7–11,審查後去懸空參照):turbo-plugin 規範集中寫進 `.turbo-plugin/` 內的單一規範檔(提案檔名見 OQ1,進版控、由 tp-setup 從 default-files 範本佈署),內容含(**直接列 skill 名,不用 item 編號**):
  - 對 DB / dbhub 的操作、讀寫、修改…等都須遵守 **`tp-db-management`** skill。
  - commit message 須遵守 **`tp-commit-msg`** skill。
  - `*.cs` 檔須遵守 **`tp-csharp-comment`** skill。
  - `*.js` 檔須遵守 **`tp-js-comment`** skill。

### G. tp-db-management 補述

- **R17**(item 5,審查後加敏感資料約束):在 `tp-db-management` 明確記載:
  - **已 push 到 `remote-svn/*` 且已打 release tag 的 `.sql` 檔不可更改**(視為不可變;要改走新檔/新變更)。
  - 版控的 `.turbo-plugin/sql/` **不得含字面憑證、含密碼的連線字串、或超出 schema 遷移所需的 PII**(一旦 push 進 SVN 即進永久 history)。
- **R18**(item 5):明確註明 dbhub 連接的是 **local-db**(強化現有敘述)。

### H. 測試框架化

- **R19**(item 3 + KD3):全面以 Pester(PS)+ shUnit2(bash)取代手刻測試框架(硬需求,理由見 KD3);重塑 orchestrator(`Invoke-ScriptTests.ps1` / `invoke-script-tests.sh`)與 CI(`.github/workflows/tests.yml`)以呼叫框架並彙整 PASS/SKIP/FAIL。
  - **覆蓋 re-key(advisory)**:現有手刻測試**借** `force_bash`(設定合併鏈測試載體)與 `schema_version`(top-level key 解析測試載體)當測試對象;兩者於 v0.5.0 都被移除(R6/R6a)。新 Pester/shUnit2 套件須把「config.toml + config.local.toml 合併鏈」與「top-level / empty-section key 解析」這兩種行為**改綁到仍存在的 key**(如 `[iis] enabled`),以免移除後這兩種 parser 行為失去覆蓋。
- **R20**(KD3):CI 安裝最新 Pester + shUnit2。框架缺席 → FAIL(pre-flight 硬 gate,任何 case 跑前先檢查)。SKIP **僅限** Unix 環境 × 需 Windows-only 工具的測試,且該類測試須在 Windows/Git Bash 真的執行驗證(見 KD3 精確規則)。

---

## 抽出到後續 brainstorm（不在 v0.5.0）

- **.NET 技能 csproj 化 / VS 2022 自動分析**(原 item 17,**目標 v0.6.0**):build/run/publish/stop 接收單一 `.csproj` 並自動分析組態/平台/pubxml/輸出路徑、體驗對齊 VS 2022,並改為 agent 每次傳入 csproj、移除寫死專案的 config 預設。**整個抽出另開第二個 brainstorm**(種子已存:`docs/brainstorms/2026-06-06-turbo-plugin-dotnet-csproj-vs2022-SEED.md`)細談「自動分析到什麼程度算完成」的範圍與驗收準則(VS 真實行為涉及 MSBuild 屬性求值 + Import 鏈 + Directory.Build.props,需先界定)。v0.5.0 不動 .NET 技能。

## 範圍邊界（Scope Boundaries）

- **保留**:worktree-per-remote-branch 的 bridge 架構、`Assert-TrustedSvnUrl` trust 模型、commitlint type enforcement 在 `tp-push-to-svn`、PS 5.1 相容 5 條禁忌、兩層測試 + CI 自動探索佈局、tp-setup encoding profile detect。
- **延後 / 不做**:SVN layout 自動推導、husky/npm enforcement、發佈 1.0.0、自動安裝測試框架到本機、`.NET csproj 自動分析 / VS 2022 體驗`(抽出)。

## 依賴與假設（Dependencies / Assumptions）

- CI runner 可安裝最新 Pester(注意 Windows PS 5.1 內建為 Pester 3.4,需於 CI 安裝 5.x)與 shUnit2(取得方式見 OQ3)。
- `main` 維持為 SVN trunk 錨點與 trust base。
- 規範檔名暫定見 OQ1。
- 既有 `remote-svn-test-<n>` worktree 的遷移:本 plugin 為 0.x 預發佈,假設無外部既有使用者需自動遷移(見 OQ2)。

## 待決問題（Outstanding Questions,非阻塞）

- **OQ1**:規範檔最終檔名與格式(`.turbo-plugin/conventions.md` vs 其它)。
- **OQ2**:是否需要為既存 `remote-svn-test-<n>` 命名提供遷移/相容說明,或僅文件註記。
- **OQ3**:shUnit2 在 CI 的取得方式(套件管理 vs vendored)——留給 plan。

> OQ4(Git Bash 偵測法)已於 R6 定案,自待決移除。

## 建議分期（Suggested Phasing,供 planning 參考）

- **Phase A — 版本與「僅限本機之物」衛生**:R1–R3a。
- **Phase B — 跨環境韌性 + 技能路由**:R4–R6a(集中編碼、統一路由、移除 force_bash、移除 schema_version)。
- **Phase C — SVN bridge 一般化**:R7–R12a(任意 branch + 消毒/碰撞、折進 push + 安全 gate、泛化保留 reset/merge、完整去耦、`.svn` gitignore)。
- **Phase D — 規範與 commit-msg**:R13–R18(tp-commit-msg、conventions 檔 + 祈使觸發、CLAUDE.md 精簡、db 補述含敏感資料約束)。
- **Phase E — 測試框架化**:R19–R20(全面 Pester/shUnit2、CI 安裝、精確 SKIP 規則)。

> 版本機制提醒:本批工作全部累積在 CHANGELOG 的新 `[0.5.0]` 區段,`plugin.json` 同步 bump 至 `0.5.0`。

## 審查殘留觀察（FYI,不阻塞）

- **任意 branch 上 SVN 的 sprawl**:any-branch 模型可能讓拋棄式分支累積永久 `remote-svn/<branch>` 路徑,長期需有人從 SVN 清理;v0.5.0 接受此取捨,KD4 的確認 gate 提供 friction,未提供自動清理。
- **Non-goal 與 R13 的關係**:type enforcement 留在 commitlint + tp-push-to-svn,tp-commit-msg 只管語意——已於 R13/Non-goal 一致,無需改。
- **R1 改版號**:現況 `git tag -l` 為空,故重編號不破壞既有 tag 引用(R1 已含發版前確認)。
