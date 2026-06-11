# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [0.5.2] - 2026-06-11

> 真實環境(zh-TW Windows + PowerShell 5.1 + Big5 codepage)手動實測 v0.5.x 抓到的 push-to-svn 與 tp-setup 缺陷修正。

### Added

- test: 新增中文(非 ASCII)檔名 push-to-svn 回歸測試(`svn-status-xml-roundtrip.test.sh` + `Svn-StatusXml-Roundtrip.test.ps1`)——含結構守衛(腳本須維持 `svn status --xml` / ANSI `OutputEncoding` 修法,防被 revert)+ 真實 svn 行為測試(建 live svn working copy、放中文檔名;`.sh` 直接 `sed` 抽出腳本本體的 `svn_status_xml` 函式測真碼)。**核心斷言是 capture**(`svn_status_xml` 把中文檔名擷取成 byte-for-byte 正確的 UTF-8 path,這正是 `--xml` 修法的本體,deterministic);`svn add`/`svn commit` 的 argv re-pass 因 svn.exe 跟 console codepage 走(PS orchestrator 強制 console=65001 會讓 MSYS native argv mangle、與擷取正確性無關)改為 **env-gated**:環境支援才驗、不支援印 WARNING 跳過(真實 Claude Code Bash tool / CI Linux 都支援)。`svn`/`svnadmin` 缺席則 SKIP。補上舊測試「在 UTF-8 CI 跑綠卻漏掉 Big5-specific bug」的缺口

### Changed

- doc(tp-setup): case (a) 不再自動代填 git 提交身分(issue 1)——偵測到 `git config user.name`/`user.email` 缺時,改以 `AskUserQuestion` 請使用者輸入(寫 **repo-local**,不加 `--global`),**絕不**拿 Claude 帳號 email / 本機使用者名稱代填;新增通用 Decision Rule「不自動代填使用者身分或設定,先問再做」。case (b) 建 merge commit 前同樣先確認身分
- doc(tp-setup): case (a) `.gitignore` 預先寫入 .NET Framework Web 產物區塊(`.vs/` / `bin/` / `obj/` / `*.user` / `packages/`),並新增明確的「初始 commit」步驟——**commit 前先列「將被 commit / 被忽略」兩份清單並 `AskUserQuestion` 確認**,避免把機器產物掃進版控、也不再事後才叫使用者跑 `/tp-suggest-ignore`(issue 2)。skill-tests.md 的 P2-tp-setup-1 期望鏈與觀察錨點同步更新
- doc/refactor(encoding): 改寫 `Test-EncodingSupport.ps1` WARNING 與 tp-setup Phase 1.2 的中文檔名前提——v0.5.2 腳本修法後,「PowerShell 端中文 SVN 操作必壞、要自動走 `.sh`」的前提已**作廢**(實測證明該 routing 從未真正解決問題,真正修法在腳本本身)。detector 改述為:本機操作兩個 shell 皆已正確處理,`ARGV_SAFE_FOR_UNICODE=False` 只是**跨平台可攜性**訊號(SVN 端存 UTF-8 vs 系統 DBCS);Phase 1.2 的 `AskUserQuestion` 重框為「是否有 Mac/Linux 同事 checkout」的純資訊性詢問,option (a) 不再寫任何 `.sh` routing。token 契約(`PS_VERSION` / `ANSI_CODEPAGE` / `ARGV_SAFE_FOR_UNICODE` / `RECOMMENDATION`)保留不變,detector 測試全綠

### Fixed

- fix: push-to-svn 中文(非 ASCII)檔名不再 mangle——`build-svn-commit.sh` / `submit-svn-commit.sh` 改用 `svn status --xml`(輸出恆 UTF-8)解析路徑,取代舊的「擷取 ANSI codepage 文字 `svn status` → 按欄位 offset 切路徑 → 回傳當 argv」流程(zh-TW Windows 經 Git Bash/MSYS 會把 Big5 bytes 當 UTF-8 重編 → svn「not under version control」)。`.ps1` 端(`Build-SvnCommit.ps1` / `Submit-SvnCommit.ps1`)改為把 `[Console]::OutputEncoding` 暫設系統 ANSI codepage 包住 svn 區段(PS native argv 編碼跟 `OutputEncoding` 走,故 `svn status` 解碼與 `svn add/commit` argv 同為 ANSI、與磁碟檔名一致;git log 的 UTF-8 subject 留在 scope 外)。同時解掉 submit drift-guard 因 snapshot 端與現場端 CRLF 不一致而把全部檔案誤判「新出現」的 bug
- fix: `svn_status_xml` helper 改用 `grep -oE`(ERE)+ `sed` 取代 `grep -oP`(PCRE)——PCRE 在非 UTF-8 locale 會直接拒跑(`grep: -P supports only unibyte and UTF-8 locales`),而 zh-TW Windows Git Bash 預設正是非 UTF-8 locale,乾淨環境會讓整支 push 炸掉;ERE 為 byte-based、任何 locale 皆可(此為實測加測試後新發現,非原始修法所含)
- fix(tp-setup): case (a) `git init` 改 `git init -b main`(issue 3)——裸 `git init` 落在 `master`,與 `remote-svn/main` bridge 名稱不符,導致首次 `/tp-push-to-svn` branch mismatch 卡住;明確指定 `-b main` 對齊(Git ≥ 2.31 必支援)
- fix(tp-setup): case (a) 新增 main ↔ remote-svn/main 的 connect merge(issue 4 root)——orphan `remote-svn/main` 與 main 無共同祖先,首次 push(remote 端 `git merge main`)/ pull(main 端 `git merge remote-svn/main`)會撞 `refusing to merge unrelated histories`;改為在主 worktree 跑 `git merge --allow-unrelated-histories remote-svn/main`(與 case (b) 同機制),連接後首推/首拉不再卡

## [0.5.1] - 2026-06-07

> v0.5.0 合併前 code review(多 persona)修正。無 P0/P1;trust anchor(KTD-8)經確認未放寬。

### Added

- test: 為 v0.5.1 新行為補測試——`Get-PushPreflight` 消毒後失敗發 `TP_TOKEN:ERROR`(非 git 目錄觸發,PS+sh)、`Merge-MainIntoBranches` git status 失敗時 fail-loud 不靜默 merge(毀損 index 觸發,PS+sh)、`New-RemoteBridge` 「worktree dir 在但 ref 不在」的對稱半套狀態(PS Case 4c + sh `test_bridge_dir_without_ref`)。`Reset-BranchToMain` 的 reset/checkout **失敗**復原路徑因真 git sandbox 無法注入命令失敗而未加測試(記為已知缺口)
- test: 複審 r3 強化上述測試穩健性——`TP_TOKEN:ERROR` 測試加「目錄非 git」hermetic 守衛(否則理論上可 false-pass)、Merge git-status 測試 PS 斷言收緊為實際失敗文字、New-RemoteBridge dir-without-ref 測試加「區分另一半套臂」斷言、sh Merge 測試補「未靜默 merge」守衛
- test: 複審 r4 收尾——hermetic 守衛 skip 時印可見 warning(避免 regression guard 在 CI 默默消失)、Merge PS 斷言改為「git 原生訊息 `index file` 或腳本 guard 訊息」兩者任一(精準且不耦合單一 git 版本措辭)、`New-RemoteBridge` 兩臂訊息旁加註提醒測試依賴其措辭

### Changed

- doc: 修正落後於程式的 agent 面向文件——`tp-pull-from-svn` / `tp-svn-log` SKILL 的 `argument-hint` 與範例由 `<main|test-<n>>` 改為泛化的 `<branch>`;`tp-suggest-ignore` SKILL 枚舉 worktree 的 pseudocode 由 `remote-svn-test-*` 改為 `remote-svn-*`;`README.md` worktree 模型圖由 `remote-svn-test-<n>` 改為 `remote-svn-<branch>`(補斜線轉 dash 說明);`tests/docs/skill-tests.md` VALIDATION_ROOT 慣例描述同步泛化(具體 `test-<n>` fixture 保留)。這些殘留的舊命名會誤導 agent 以為 bridge 只支援 `main`/`test-<n>`,抵銷 v0.5.0 的任意分支泛化
- doc: `tp-push-to-svn` Step 0 對新腳本 `Get-PushPreflight` / `New-RemoteBridge` 的呼叫改為分列 PowerShell(`-Branch`/`-SvnUrl`)與 bash(`--branch`/`--svn-url`)雙 block 並加警告(GNU `--` 形式在 `powershell -File` 下不可靠),比照既有 `tp-reset-branch-to-main` 的安全寫法;補 `TP_TOKEN:ERROR` 與「無 token + 非零 exit」的處理規則
- refactor: 移除 `tests/docs/skill-tests.md` 中已隨 U5 移除的 `force_bash` 失敗 pattern 說明

### Fixed

- fix: `Reset-BranchToMain.ps1` / `reset-branch-to-main.sh`——reset 失敗後的補救切回未檢查結果、正常切回失敗時訊息未明示 worktree 停在何分支;改為兩條失敗路徑皆檢查 exit code 並明講「main worktree 現停在 `<branch>`(預期 `<original>`)+ 手動復原指令」
- fix: `Get-PushPreflight.ps1` / `get-push-preflight.sh`——消毒後仍可能 throw(如 MAX_PATH)卻不發 token,使 SKILL 收到未定義的「exit 1 無 token」;改為在錯誤路徑發 `TP_TOKEN:ERROR reason=...`(collapse 換行 + 中和內嵌 `TP_TOKEN:`,維持 anti-forge)
- fix: `Merge-MainIntoBranches.ps1` / `merge-main-into-branches.sh`——dirty 檢查的 `git status` 失敗(如 index 損壞)會被當成乾淨而繞過守衛;改為檢查 `git status` 結果,失敗則 fail-loud
- fix: `New-RemoteBridge.ps1` / `new-remote-bridge.sh`——「ref 在但 worktree 目錄不在」(或反向)的半套殘留狀態會 hard-fail「already exists」而卡住宣稱可重跑的首推;改為偵測 ref XOR dir 並給明確復原指令(`git worktree prune` / `git branch -D`)
- fix: `Common.ps1` / `common.sh`——MAX_PATH guard 由 `>260` 改為 `>=260`(260 含結尾 NUL,可用長度 259),修正放行剛好 260 字元路徑的邊界差一
- fix: `get-push-preflight.sh`——上一條 `TP_TOKEN:ERROR` 修正只包到 `resolve_remote_worktree`(MAX_PATH)站,漏了同樣在消毒後的 `get_main_worktree` / `get_worktrees_dir`;改為同樣包進 `_die_token`,與 `.ps1` 端(消毒後任何 throw 都發 ERROR token)恢復 parity(複審 r2 發現)
- fix: `reset-branch-to-main.sh`——reset **前**切入分支的 `git checkout` 未檢查 exit code(`.ps1` 端有);改為失敗時明示「main worktree 仍停在原分支」並 exit 1(pre-existing parity gap,複審 r2 發現)

## [0.5.0] - 2026-06-07

### Added

- feat: 新增 `tp-commit-msg` skill(LLM-only)——撰寫 / 檢查 commit message 的**語意**規範:commit type 一律依 `.commitlintrc.json`(skill 不列舉 type);**不得**引用特定 git SHA(遠端 SVN、跨 clone 不一致)或僅本地識別碼(需求 / 計畫 / 任務代號、session 項目編號);要求祈使句、what+why、語言一致(U13)
- feat: `tp-push-to-svn` 首推自動建 bridge——偵測到某分支尚無 git↔SVN bridge 時,確認後自動建立(取代手動 `/tp-create-remote-test`)。新增 pre-flight 偵測腳本 `Get-PushPreflight.ps1` / `get-push-preflight.sh`,發**單一終結 token**(`TP_TOKEN:` 前綴,優先序 `DETACHED_HEAD` > `BRANCH_MISMATCH_WARNING` > `BRIDGE_ABSENT` > `BRIDGE_PRESENT`;detached 用 `git symbolic-ref` 偵測並拒字面 `HEAD`;發 token 前消毒 requested、帶 `current=`/`requested=`/`target=` payload);SKILL 只讀 token 分流,不自跑 git（U9）

### Changed

- chore: 版本號重編,修正先前誤用 `1.0.0` 的版本語意——原 `## [1.0.0]` 改列為 `## [0.3.0]`、原 `## [Unreleased]` 定版為 `## [0.4.0]`;`plugin.json` `version` 由 `1.0.0` 改為 `0.5.0`,三份檔(`plugin.json` 描述、`README.md` 行 3 與行 141)的 skill 數由「14」更正為「16」（U1）
- chore: 清除版控文件中僅限本機之物為固定 placeholder token(機器絕對路徑 → `<MACHINE-PATH>`、內部 SVN/host → `<INTERNAL-SVN-URL>`),範圍限 `docs/`、CHANGELOG、`tests/docs/skill-tests.md`,保留泛 Windows 字串;根 `CLAUDE.md` 加常駐規則「不得提交僅限本機之物」(advisory)（U2/U3）
- refactor: 編碼初始化集中到共用 lib——`Common.ps1` 加 guarded `[Console]::InputEncoding`(補齊三編碼變數)、`common.sh` 開頭加 portable 且非致命的 UTF-8 locale 設定(R-2 fallback);`Test-EncodingSupport.ps1` 補齊三編碼變數(維持獨立偵測語意不受影響)、`Invoke-PostToolUseEnterWorktree.ps1` 補 guarded 編碼 init(保留 EAP=Continue)（U4）
- refactor: 所有呼叫配對 `.ps1`/`.sh` 的 skill(push / pull / svn-log / suggest-ignore / 四個 .NET skill / cleanup-orphan-iis)改用統一執行路由——依環境 + Git Bash 偵測選工具(排除 WSL `System32\bash.exe`),不再用 Bash 工具呼叫 `pwsh`/`powershell`;移除舊 `[svn] force_bash` 機制(skill 規則、tp-setup option (a) 寫入、config 範本註解)（U5）
- feat: `Resolve-RemoteWorktree` / `resolve_remote_worktree` 一般化,接受**任意 branch**(不再限 `main`/`test-<n>`)——ref `remote-svn/<branch>`(保留斜線)、worktree 目錄 `remote-svn-<branch-dash>`;新增 allowlist 消毒(拒 `..` / 前導 `-` / `\`/`:`/控制字元 / 結尾點或空白 / 保留名 `main` 非小寫與 Windows 裝置名 CON/PRN/AUX/NUL/COM1-9/LPT1-9)、normalize-then-compare 碰撞偵測(`Find-RemoteWorktreeCollision`)、MAX_PATH>260 hard-fail + 引導;PS/bash 兩端一致（U7）
- refactor: 去耦其餘寫死 `main|test-<n>` 的 call site——`Set-SvnIgnore` / `set-svn-ignore.sh` 的 remote worktree 列舉改掃任意 `remote-svn-*`(不再 regex 限定 main/test-`<n>`);各 SVN 腳本(Build/Submit/Sync/Get-SvnLog/Tag-Release 之 `.ps1`+`.sh`)的 usage / 錯誤訊息字串改泛指 `<branch>`（U8）
- refactor: `New-RemoteTest.ps1`/`.sh` 改名 `New-RemoteBridge.ps1`/`.sh` 並一般化(收 `--branch` + `--svn-url`、去 `test-<n>` 編號),成為 `tp-push-to-svn` 首推呼叫的內部 helper;首推模型下**不建工作分支**(工作分支即當前分支),只建 bridge ref + worktree + svn checkout;`svn copy` commit message 用消毒後 dash-form;rollback 只清本機 git 端(已建的 SVN 路徑為永久,重跑首推 idempotent 接續)。`Build-SvnCommit` 的 backstop `BRANCH_MISMATCH_WARNING` 改發 `TP_TOKEN:` 前綴(R3-1),`tp-push-to-svn` SKILL 加 Step 0 bootstrap pre-flight + 三道 gate（U9）
- refactor: `tp-reset-remote-test` 改名 `tp-reset-branch-to-main` 並一般化——`Reset-RemoteTest.*` → `Reset-BranchToMain.*`,參數 `--n <number>` → `--branch <name>`,適用任意分支(不再限 `test-<n>`);保留 LOSE/GAIN/FILES_LOST 預覽(三基準刻意不同:LOSE=`main..<branch>` 本機毀掉的 commit、FILES_LOST_AFTER_PUSH=`main..remote-svn/<branch>` SVN 端刪的檔)+ 強制確認 gate + footgun 強警告(顯示 N 個不在 main 的 commit);加統一執行路由、移除 `force_bash` 規則（U10）
- refactor: `tp-merge-main-into-all` 改名 `tp-merge-main-into-branches` 並一般化——`Merge-MainIntoAll.*` → `Merge-MainIntoBranches.*`,新增可指定分支子集(`-Branch`/`--branch` 可重複;不指定維持「全部非 `remote-svn/*` 本地分支」),指定但不存在/被排除者 `SKIP` 續跑;保留髒工作區守門 + 逐分支 `git merge --abort` 衝突隔離 + 還原原分支;加統一執行路由、移除 `force_bash` 規則（U11）
- ci: `.github/workflows/tests.yml` 對齊 Pester 5 + shUnit2——`test-windows` 裝 Pester 5(WinPS 5.1)跑單一 PS orchestrator(`.ps1` Pester + `.sh` shUnit2 via git-bash);`test-ubuntu` 兩支 orchestrator(bash 跑 `.sh` vendored shUnit2 + pwsh 步驟裝 Pester 5 跑 PS orchestrator 的 `.ps1`,帶 `-SkipPreflight`、BashPath 非 Windows 不解析故 `.sh` 不雙跑);framework 缺席(Pester 5 / vendored shUnit2)= 該 job **FAIL**(R20)。orchestrator 子程序改用 `$psExe`(Desktop→`powershell` / Core→`pwsh`)以支援 ubuntu pwsh。`tests/runs/v1.0.0` → `tests/runs/0.4.0`(版本對齊,凍結歷史證據)+ 新增 `tests/runs/0.5.0/` 證據;移除新 orchestrator 已無 caller 的 tracking helper(`Get-ScriptTestStatus.ps1` / `Write-TrackingRow.ps1`)（U18）
- refactor: bash 測試遷移到 **shUnit2**(vendored v2.1.8 於 `tests/lib/shunit2`)——全部 `.test.sh` 改寫為 `test_*`/`setUp`/`tearDown` + `assertEquals`/`assertTrue` + 末尾 `source shunit2`(per-test SKIP 用 `startSkipping`,僅 Unix×Windows-only-tool;`.sh` 不帶 BOM);orchestrator `invoke-script-tests.sh` 重塑為 shUnit2-native(**只跑 `.sh`**——`.ps1` 由 PS orchestrator 負責,避免雙跑;**framework gate**:vendored shUnit2 缺席→exit 1;exit 契約 **0/1**;移除 AssertHelpers infra gate);新增 `get-push-preflight.test.sh` 驗 Token 契約;`common.test.sh` re-key `force_bash`/`schema_version` 載體到 `[iis] enabled`(KTD-7);`new-remote-test`/`reset-remote-test`/`merge-main-into-all` 的 `.test.sh` 改名+泛化;**移除手刻 `AssertHelpers.ps1` + `AssertHelpers.test.ps1`**(兩 orchestrator 皆已不引用)。Windows PS orchestrator 實跑:Pester `.ps1` 288 + shUnit2 `.sh` 25 全綠（U17）
- refactor: PowerShell 測試遷移到 **Pester 5**——全部 `.test.ps1`(unit/scripts + hooks + lib + fixtures meta-test,共 24+)改寫為 `Describe`/`It`/`Should`(skip 條件放 `BeforeDiscovery`、區塊名避開 `<...>`/`$` token、含中文者存 UTF-8 BOM);orchestrator `Invoke-ScriptTests.ps1` 重塑為 Pester-native——**framework gate**(`Import-Module Pester -MinimumVersion 5.0` 缺席→exit 1,**不**受 `-SkipPreflight` 影響,R3-3)、`-SkipPreflight` 只擋 lint、**child-process per-file 隔離**(避免 in-process Invoke-Pester 跨檔 state 污染)、exit 契約 **0/1**(不再 exit 2)、BashPath 非 Windows 不解析(R3-4);新增 `Get-PushPreflight.test.ps1` 驗證 Token 契約(detached/anti-forge/mismatch/單一 token/BRIDGE_ABSENT);`Common.test.ps1` 移除 validator 警告測試 + `force_bash`/`schema_version` 載體 re-key 到 `[iis] enabled`(KTD-7);`New-RemoteTest`/`Reset-RemoteTest`/`Merge-MainIntoAll` 的 `.test.ps1` 改名+泛化對齊新腳本。本機 Pester 5.7.1 實跑 PS 測試 288 pass / 0 fail / 6 skip（U16）
- doc: `tp-db-management` 補三條約束——(1) 已 push 到 `remote-svn/*` 且已打 release tag 的 `.sql` 視為不可變(修正走新檔);(2) 版控 `.turbo-plugin/sql/` 的 `.sql` 不得含字面憑證 / 含密碼連線字串 / 超出 schema 遷移所需 PII;(3) 強化「DBHub 連線範圍 = `local-db` only」（U15）
- refactor: 規範集中進 `.turbo-plugin/conventions.md`、精簡 CLAUDE.md 注入——新增 `default-files/.turbo-plugin/conventions.md` 範本(DB→`tp-db-management`、commit→`tp-commit-msg`、`*.cs`→`tp-csharp-comment`、`*.js`→`tp-js-comment` 四條指向);`tp-setup` 注入 CLAUDE.md 的 snippet 由 commit-type 表改為**祈使指向**(「執行 DB/commit/`*.cs`/`*.js` 操作前先讀 conventions.md」)+ R3a 常駐規則,不再 inline 整份規範;conventions.md 隨 Phase 2 範本部署(git-versioned shared file）（U14）
- refactor: 以「讓 git 忽略 `.svn/`」取代各腳本手動 `.svn/*` dirty-filter(R12a)——`tp-setup` 在專案 main `.gitignore` 的 turbo-plugin 規則區塊加一條 `.svn/`(idempotent),bridge 經 `New-RemoteBridge` 既有 copy-from-main 繼承;移除 `Sync-FromSvn` / `sync-from-svn.sh` 與 `Reset-BranchToMain` / `reset-branch-to-main.sh` 的 `.svn` dirty-filter(改為直接 `git status --porcelain`);`.gitignore` 內容同步本體保留、僅清掉已失效的 `wc.db` 衝突理由註解。修正 F-U18 sync/reset 對 `.svn/wc.db` 誤判 dirty 的死循環,改用更乾淨的純 git 端機制（U12）

### Removed

- chore: 移除 `schema_version` config gate(過度設計)——刪 `Common.ps1` `Test-TurboPluginConfigSchema` + once-guard + call site、`common.sh` `check_turbo_plugin_config_schema` + guard + call site、config 範本與 fixture 的 `schema_version` 鍵、`tp-push-to-svn` 的 stale schema_version 測試情境;既有檔殘留該鍵由 TOML reader 自然忽略(不警告、不報錯)（U6）
- chore: 移除 `tp-create-remote-test` skill——其「建立 git↔SVN bridge」功能併入 `tp-push-to-svn` 首推 bootstrap(底層 helper 改名 `New-RemoteBridge`)（U9）

## [0.4.0] - 2026-06-06

### Added

- feat: GitHub Actions 自動探索測試 CI(`.github/workflows/tests.yml`)——discover job 掃 `plugins/*/tests/` 輸出 matrix,windows-latest 跑全部 `.ps1`+`.sh`、ubuntu-latest 跑可移植 `.sh`,缺工具測試自我 SKIP(≠fail),新增遵循佈局的 plugin 免改 yml（U7）
- feat: release tag——`Tag-Release.ps1`/`tag-release.sh` + `tp-push-to-svn` Step 7,判準為「有產出 git merge commit」(即使檔案全被 `svn:ignore`、svn commit 為空也照問;nothing-to-push 才跳過)（U9）
- feat: `tp-merge-main-into-all`——把最新 main merge 進所有「非 main 且非 `remote-svn/*`」的本地分支,衝突時 per-branch `git merge --abort` + 標記 CONFLICT 續跑（U10）
- feat: `tp-db-management`——DBHub(`tp-dbhub` MCP)唯讀檢視 + SQL 標準化到 `.turbo-plugin/sql/<env>-db/<branch>/`(branch 名 `/`→`-`),de-couple 舊 dev-flow slug 耦合（U11）

### Changed

- refactor: 全 plugin scripts + tests 改名符合 PowerShell `Get-Verb` 規範(Verb-Noun PascalCase / lib noun-only / Bash kebab),Phase 1/2 jargon 改 Script/Skill tests
- refactor: orchestrator `Run-Phase1.ps1` 重寫為 `Invoke-ScriptTests.ps1`,加 lint pre-flight + infra gate (AssertHelpers FIRST + fixture skip-only) + path-based routing + Bash sibling `invoke-script-tests.sh`
- refactor: `_Common.ps1` 從 `tests/unit/scripts/` 搬到 `tests/lib/ScriptsCommon.ps1` (KD-8)
- refactor: `resolve-iis-settings.ps1` 重新分類為 lib (`scripts/lib/IisHelpers.ps1`)
- refactor: `tools/verify-approved-verbs.ps1` 新增 — 用 `Get-Verb` + Build/Deploy policy whitelist 強制命名規範
- refactor: worktree 容器從 sibling `<proj>.worktrees/` 移進 `<proj>/.turbo-plugin/worktrees/`(抽 `Get-WorktreesDir`/`get_worktrees_dir` helper,7 對 SVN script 改呼叫);worktree 目錄與 branch ref 改 `remote-svn-*` / `remote-svn/*` 命名（U1/U2）
- feat: `tp-setup` 在首次 `git worktree add` 之前把 `.turbo-plugin/worktrees/` 寫進 `.gitignore` + svn:ignore,確保巢狀 worktree 不弄髒主 worktree status（U2）
- refactor: 測試工作根改 repo 相對 gitignored `tests/.sandbox/`、含空格路徑容忍(`GetFullPath` 長形)、`svn --config-dir` 隔離 `%APPDATA%` 全域狀態,消除所有機器專屬絕對路徑;真跨平台 `.sh` 測試 powershell-free + .NET/IIS `.sh` 依能力 SKIP 以支援 ubuntu CI（U4/U5）
- doc: skill-test 套件改 `<VALIDATION_ROOT>` placeholder + 反映新結構(remote-svn / `.turbo-plugin/worktrees/` / release tag / 無 .code-workspace)+ 新增 2 skill case(16 skills / 54 cases)（U8）
- doc: 根 `CLAUDE.md` 改 marketplace plugin-agnostic 通用規範 + 明訂兩層測試標準;plugin 專屬規範(worktree 模型、commit-type 過濾、C#/JS 註解)移進 `README.md`（U12）

### Fixed

- fix: `Build-Web.ps1` / `Publish-Web.ps1` 呼叫已不存在的 `pack-content.ps1`(verb-approval 改名為 `Compress-Content.ps1`,呼叫端未同步)——`$ErrorActionPreference='Stop'` 下每次 `/tp-build`、`/tp-publish` 都在 frontend pack 步驟 throw → exit 1;呼叫端與註解改指向 `Compress-Content.ps1`(code review P0)
- fix: `tp-reset-remote-test` SKILL 的 PowerShell invocation 用 GNU 風格 `--diff-only`——`powershell -File` 會靜默忽略該旗標,使 `$DiffOnly=False`,「預覽」步驟反而直接執行真正的 `git reset --hard`;改用 PS switch `-DiffOnly`,並補上四處遺漏的必填 `-N <n>` / `--n <n>`(code review P1)

## [0.3.0] - 2026-05-27

turbo-plugin 第一次 marketplace release。整合 4 個舊 plugin（`tdp` / `tnf` / `tgs` / `tpi`）的 dev 流程進單一 plugin,加上 v1.0 refinements(apphost 跟 VS 分離、tp-setup 4-Phase 重組、Claude Code 友善功能推薦、svn-log 中文亂碼修正 + 互動分頁、tp-suggest-ignore 文件修正)。

### Added

- `[tools]` section 在 `.turbo-plugin/config.local.toml`,集中存 machine-specific tool paths(`msbuild_path` / `iis_express_path`)——**取代** 舊版 user-level env(`TURBO_PLUGIN_MSBUILD_PATH` / `TURBO_PLUGIN_IIS_EXPRESS_PATH`)。（U1 / U2）
- `[iis]` section 在 `.turbo-plugin/config.toml` 加入 `enabled` 開關(預設 `true`),沒有 .NET Framework Web 開發需求時可設 `false` 跳過所有 IIS 相關 SKILL(tp-run / tp-stop / tp-build-web / tp-publish-web / tp-cleanup-orphan-iis)的 IIS lifecycle 動作,改 emit 統一 fail-loudly 訊息引導重新啟用。（U1 / U4）
- `Resolve-ConfigValue` / bash `resolve_config_value` 現在支援 `config.toml` + `config.local.toml` key-level shallow merge(local 優先),`Read-TurboPluginConfig` 接受 array of paths 依序讀入。（U1）
- `tp-setup` SKILL 重組為 **4 Phase 結構**(偵測 / case-specific bootstrap / 環境配置 / 完成報告),取代既有堆疊式 Step 0 / 0.5 / 1 / 2-5 / 6 / 7 / 8。新需求未來只能融入 Phase 內或開新 skill,不再 append 新 Step。（U5）
- `tp-setup` Phase 2 加入 **apphost.config bootstrap** 三選一:`.turbo-plugin/applicationhost.config` 已存在 → 跳過;`.vs/<sln>/config/applicationhost.config` 存在 → 複製進來(`physicalPath` 屬性替換為佔位符 `__TURBO_PLUGIN_PHYSICAL_PATH__`);都缺 → AskUserQuestion 三選一(暫停 setup 去開 VS / 寫 `[iis] enabled = false` / 取消)。（U5）
- `tp-setup` Phase 3 引導使用者啟用 Claude Code 友善功能,per-item AskUserQuestion 4-選項(跳過 / user-level / project-level / local-level):**C# LSP**(`csharp-lsp@claude-plugins-official` + `dotnet tool install -g csharp-ls`)、**TS/JS LSP**(`typescript-lsp@claude-plugins-official` + `npm install -g typescript-language-server typescript`)、**compound-engineering**(3-option:跳過 / 自動更新 / 不自動更新;寫 `extraKnownMarketplaces` + `enabledPlugins`)、**agent teams**(`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`)、**TUI fullscreen**(`tui = "fullscreen"`)。`ENABLE_LSP_TOOL = "1"` 在任一 LSP 啟用時 idempotent 寫入。LSP binary 自動安裝失敗則記入 Phase 4 補裝清單。（U5 / U6）
- `tp-svn-log` 新增 `--revision <spec>` 參數,接受 svn 原生格式(`r5`、`3:10`、`HEAD`、`BASE`、`{2026-01-01}:{2026-05-26}` 等),純 forward 給 svn,腳本不 validate。（U10）
- `tp-svn-log` SKILL 互動分頁:每次顯示 5 筆 commit 後在對話訊息 emit「1. 下 5 筆 / 2. 指定修訂 / 3. 其他」三選一 plain-text 選項(**非** AskUserQuestion),使用者下一輪訊息回 `1` / `2` / `3` 或直接打 revision spec(`r5` / `3:10` 等)即可續看,不必重打完整指令;不符合分頁意圖的訊息(換話題 / unrelated)則退出迴圈讓 agent 一般對話處理。（U11）
- `svn-log.ps1` / `.sh` 在 stdout 末尾 emit `# LAST_SHOWN_REV=<最小 revision>` 結構化 trailer line,SKILL pagination loop 從 stdout 直接讀(主路徑),conversation compaction 不會丟失 state;若 stdout 不可得 fallback 到 parse chat history `r<n>` headers。（U10 / U11）

### Changed

- **apphost.config runtime 從 VS 共生改為 turbo-plugin canonical**:canonical `.turbo-plugin/applicationhost.config` 進 git,進 git 時所有 `<site>` 的 `physicalPath` 屬性值固定為佔位符 `__TURBO_PLUGIN_PHYSICAL_PATH__`(跨機器 / 跨同事 portable)。Runtime 由 `start-iis.ps1` 複製到 `%TEMP%\turbo-plugin-iis-<identity-hash>.config`,在 temp file 把佔位符替換為當前 worktree 實際 csproj 路徑,再以 `iisexpress -config:<temp>` 啟動。Canonical **永遠不被 physicalPath 改寫污染**。VS UI 仍會自行維護 `.vs/<sln>/config/applicationhost.config`,turbo-plugin 從本版起**不再讀寫該檔**(VS 自管)。同專案在所有 worktree 之間仍只能啟動一個 IIS Express(切換 worktree 自動 stop 舊 instance 再用新 physicalPath 重啟,既有 line 102-118 邏輯不變)。（U3 / U5）
- `Find-MSBuild` / `Find-IisExpressPath` **嚴格切**到 `.turbo-plugin/config.local.toml [tools]`,**不**再 fallback 到 `$env:TURBO_PLUGIN_MSBUILD_PATH` / `$env:TURBO_PLUGIN_IIS_EXPRESS_PATH`(v1.0 首次 marketplace release,無 v0.2.x 既有 user 需要 migration)。讀不到就 throw 引導跑 `/tp-setup` 補設定 path(`build-web.ps1` / `publish-web.ps1` 等 call site 同步切換)。（U2）
- `tp-svn-log` 中文 commit message 在中文 Windows 上**不再變 `?` 亂碼** — `svn-log.ps1` / `.sh` 內部一律呼叫 `svn log --xml`(svn XML 輸出永遠 UTF-8,不看 console codepage),腳本自己解析後 format 純文字輸出。PowerShell 走 `[xml]` cast + `InnerText`;bash 走 `xmllint --xpath` 優先 + grep / sed / awk fallback。（U10）
- `tp-svn-log` `--limit` 預設值由 50 改為 **5**(原本一次塞滿訊息;v1.0 配合 U11 互動分頁讓使用者主動續看)。（U10）
- `tp-svn-log` SKILL Procedure 強化「必須把 script stdout 完整 echo 到對話訊息(用 markdown code block 包起來)」要求,避免只依賴 tool result UI(可能被折疊或截斷)。（U10）
- `tp-suggest-ignore` SKILL `--add-svn` / `--remove-svn` 文件描述從「on all remote worktrees in a single SVN commit」更正為「on all remote worktrees, **one SVN commit per worktree** (cross-worktree sync; propset failure rolls back all)」,與實際 `svn-ignore.ps1` / `.sh` 兩-pass commit 邏輯一致。（U9）

### Removed

- 舊 user-level env `TURBO_PLUGIN_MSBUILD_PATH` / `TURBO_PLUGIN_IIS_EXPRESS_PATH` 不再被讀取,改走 `.turbo-plugin/config.local.toml [tools]`。（U2）
- `tp-setup` 舊版堆疊式 Step 0 / 0.5 / 1 / 2-5 / 6 / 7 / 8 編號模式整段 rewrite 為 4-Phase 結構。（U5）
- `posttooluse-enterworktree.ps1` 不再對 `.vs/<sln>/config/applicationhost.config` 做任何寫入(VS UI 自管,turbo-plugin 不介入);hook 改為直接 `Emit-Json @{} + exit 0`。（U3）
- `sessionstart.ps1` Branch (i) 對 `.vs/<sln>/config/applicationhost.config` 的處理移除。（U3）
- `cleanup-orphan-iis.ps1` XML orphan scan 分支移除(canonical `.turbo-plugin/applicationhost.config` 不再累積 stale site 條目);只保留**殺孤兒 process** 邏輯,並順手清掉 `%TEMP%\turbo-plugin-iis-*.config` 中找不到對應 PID 的 temp file。（U3）
- **F-U3.9(P3)** Removed bash `get_project_identity_hash()` from `common.sh`. Was dead code(no caller — all SVN scripts are native bash, all build/IIS scripts are ps1-delegate so hash computation always happens on PS side). Bash version produced **different** hashes than PS due to forward-slash vs backslash difference in sha256 input — kept-but-divergent was a foot-gun for future callers.

### Fixed

- **F-U17.5(P1)** `create-remote-test.ps1` git mutations(`git branch`/`worktree add`)移進 rollback try 內,任一 git op 失敗也觸發 rollback 清掉部分建好的 branch。.sh 端早有 `trap ERR` 涵蓋,行為一致。
- **F-U16.bridge(P1)** create-remote-test 在 svn commit 前同步 main 當前 `.gitignore` 進 remote-test-N worktree。Root cause:SVN copy 帶過去的 .gitignore 是 main SVN 過去版本,跟 main git 當前版本不同 → 第一次 tp-push-to-svn 必撞 .gitignore + .svn/wc.db merge conflict。同步後 pull/push 完全乾淨。.ps1 + .sh 兩端同修。
- **F-U3.11(P1)** bash `read_turbo_plugin_config` sentinel-mode 判斷條件 `[[ -n "$filter_section" && -n "$filter_key" ]]` 對 top-level key(section="")永遠 false → `check_turbo_plugin_config_schema` 對 invalid schema_version 永遠不發 warning。改成 `[[ -n "$filter_key" ]]` 以 key 為 sentinel。
- **F-U2.3(P2)** `Get-MainWorktree` 包 try/catch 防 PS 5.1 + StrictMode + EAP=Stop 把 git fatal stderr 變 terminating error 蓋掉自寫的 `Not inside a git repository.` 訊息。
- **F-U2.9(P2)** `Get-RelativePathSafe -From X -To X` same-path case 加 special-case return `''`(原 MakeRelativeUri 行為視 trailing separator state 不確定)。
- **F-U18.svn-state(P2)** `reset-remote-test` `.ps1 + .sh` 兩端 git status check 都 filter 掉 `.svn/*` paths。原本把 SVN binary metadata `.svn/wc.db` 視為 user uncommitted change → 拒絕 reset,提示 user 用 push/pull 解,但 push/pull 自己也 touch wc.db,死循環。
- **F-U13.6(P3)** `cleanup-orphan-iis -RemoveSite X` 在 orphanMap.Count=0 時 emit warning「X specified but no orphans found」,不再 silent exit 0(原本 user 不知道請求 mismatch)。

## [0.2.7] - 2026-05-25

### Added

- **`scripts/Test-EncodingSupport.ps1`(+ `.sh` delegate)**:偵測當前 PowerShell + Windows codepage 是否支援中文檔名 SVN 操作。輸出結構化 token(`PS_VERSION` / `ANSI_CODEPAGE` / `ARGV_SAFE_FOR_UNICODE` / `RECOMMENDATION`)讓 SKILL parse,搭配 byte-level evidence 後修正的精確訊息(見 Documented)。
- **`tp-setup` SKILL Step 0.5 — Encoding support check**(plan 002 U16.enc 環境性限制 user-side remediation):tp-setup 跑時 detect codepage,若非 UTF-8(PS 5.1 + zh-TW/zh-CN/ja-JP Windows 常態)→ 用 `AskUserQuestion` 依「團隊性質」三選一:(a) 同質中文 Windows 團隊 → 接受 SVN repo 存 DBCS bytes、SVN 中文檔名操作走 `.sh`(plugin sibling)/ (b) 跨 OS 團隊 → nested `AskUserQuestion` 選 winget PS 7+ 或 Win10 UTF-8 codepage / (c) 避用中文檔名。記載於 `.turbo-plugin/encoding-status.local.md`(gitignored,user-specific)。

### Documented

- **Refined understanding:PS 5.1 + non-UTF-8 ANSI codepage 對中文檔名 SVN 的影響不是「全 fail」,而是 path-dependent**(plan 002 U16.enc 第二輪 byte-level 驗證後修正先前結論):
  - **PowerShell 5.1 .ps1 path**:**fail**(`svn: file not found`)。PS .NET 用 UTF-16 字串建檔(Windows FS 存 UTF-16),但 svn.exe argv 透過 CreateProcessA 從 UTF-16 轉到 CP_ACP (Big5),svn 找的 bytes 跟 filesystem 不 match
  - **Git Bash .sh path**:**work**(對同質 zh-TW Windows 團隊)。bash 建檔走 MSYS2 + CP_ACP,svn.exe 接 argv 也走 CP_ACP,**bash 跟 svn 在 ANSI 編碼世界 round-trip 一致**。`svn ls URL` byte dump 確認 SVN repo 存 `b4 fa b8 d5`(Big5 bytes for 測試),不是 UTF-8 e6b8ac e8a9a6。Team 內 Windows zh-TW 使用者全部來回看到一致檔名
  - **跨 OS 不 work**:SVN repo 內是 Big5 bytes,Mac/Linux UTF-8 系統 svn checkout 看到 garbage 檔名
  - **PS 7+ 或 Win10 UTF-8 codepage**:**真正 UTF-8 work**(CreateProcessW + UTF-8 argv → SVN 存 UTF-8 bytes),跨平台 OK
  - byte-level evidence(實機驗):磁碟 UTF-8 `e6 b8 ac e8 a9 a6` + bash svn commit → SVN repo Big5 `b4 fa b8 d5`,清楚展示 CP_ACP round-trip 路徑
  - **推論修正**:之前說「Git Bash silent corruption 比 PS 明顯 fail 更危險」**過度悲觀**;對 zh-TW Windows homogeneous team 來說,Git Bash 是可用工作流;只有 cross-platform 場景才需 PS 7+ / Win10 UTF-8 codepage

## [0.2.6] - 2026-05-25

### Fixed

- **🔴 P0 `create-remote-test.ps1` happy path 在 PS 5.1 + StrictMode 完全跑不過 — 三條 bug 連環**(plan 002 U17.1 在實機 <MACHINE-PATH> 跑時抓到,沒人能成功跑 tp-create-remote-test):
  1. **`svn propget svn:ignore` 對乾淨 remote-main 寫 `W200017 Property 'svn:ignore' not found`** → PS 5.1 + StrictMode + `$ErrorActionPreference='Stop'` 在 stderr stream 被 redirect **之前**就把 native exe stderr 當 terminating NativeCommandError throw,`2>$null` 完全擋不住(v0.2.2 fix 設計不完整)。修:`svn propget` call 包進 nested try/catch,在 call site swallow + 設 `$inherited` 為空,outer rollback catch 不觸發
  2. **`git worktree add` 先建 `.git` pointer file + init-commit 內容(`init.txt`)**,然後 `svn checkout` 遇到既有檔案 → 標 "obstructed/conflict",`svn commit` 拒絕。修:`svn checkout --force` 把既有檔當 svn-added
  3. **`--force` 把 git 的 `.git` pointer file 也加進 svn 控管 → svn commit 推 `.git` 進 SVN 永久 history,污染其它人 svn checkout 的 test-N 分支**(`.git` 指向原 committer 的本機路徑)。修:`svn checkout --force` 之後立刻 `svn rm --keep-local .git`,從 svn 控管移除但保留檔案(git 仍要它),然後再 svn propset svn:ignore + svn commit。**`.sh` 同步同樣修法**(bug #2+#3 universal,跟 PS 5.1 無關)

## [0.2.5] - 2026-05-25

### Fixed

- **`publish-web.ps1` 兩條 bug 連環,publish 實際成功但 script exit 1、不 emit `PUBLISH_OUTPUT_PATH=` token,SKILL 誤判失敗**(plan 002 U9.1 抓到):
  - (a) `[xml](Get-Content -Raw)` cast 在 PS 5.1 + StrictMode + outer try/catch 內失敗(`$pubxml` 變 String → `.SelectNodes` 不存在);改用 `Select-Xml -Path ... -XPath ...` 直接讀檔解 XPath,完全繞過 XmlDocument 物件處理
  - (b) XPath query 用 `local-name()='PublishUrl'`(PascalCase),但 VS 生 pubxml 用 camelCase `<publishUrl>`,case-sensitive `local-name()` 永遠找不到;改用 `translate()` lowercase-match 同時涵蓋兩種 case(`<publishUrl>` 與 `<PublishUrl>`)

## [0.2.4] - 2026-05-24

### Fixed

- **PowerShell 5.1 在中文 Windows 跑時 native exe(svn/msbuild/iisexpress)的 UTF-8 stdout 渲染成 mojibake**:在 `scripts/lib/common.ps1` 開頭加 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` 與 `$OutputEncoding = [System.Text.Encoding]::UTF8`,所有 dot-source common.ps1 的 script 自動取得 UTF-8 解碼。實機 svn-log 對 UTF-8 中文 commit message 顯示問題的 fix。

## [0.2.3] - 2026-05-24

### Fixed

- **PostToolUse EnterWorktree hook 報「for N site(s)」N 錯誤**(off-by-N → 4 而非 1):`($updates | Where-Object { $_.Updated }).Count` 在 pipeline 結果只 1 個 hashtable 時 PowerShell 不會 wrap 成 array,`.Count` 讀的是 **hashtable 自己的 key 數**(4 個 key:`Updated, SiteName, OldPaths, NewPath`)而非 update 過的 site 數。改用 `@(... | Where-Object {}).Count` 強制 array semantics。經典 PS single-element pipeline 陷阱。

### Added

- 根目錄 `tools/lint-ps-compat.ps1`(+ `.sh` wrapper):靜態掃 `.ps1` 偵測 Windows PowerShell 5.1 不相容 patterns:3+ arg `Join-Path`、`[System.IO.Path]::GetRelativePath`、含非 ASCII 但無 UTF-8 BOM。可手動跑 `pwsh tools/lint-ps-compat.ps1` 或進 pre-commit hook。
- 根目錄 `CLAUDE.md` 加 **Windows PowerShell 5.1 相容性** 條目(5 條禁忌:Join-Path 3+arg / GetRelativePath / 無 BOM 中文 / `2>&1` on native exe / 單元素 pipeline 直接 `.Count`),讓未來貢獻者免踩同坑。

## [0.2.2] - 2026-05-24

### Fixed

- **`create-remote-test.ps1` 對 `svn propget svn:ignore` 過度敏感**:當 remote-main 沒設 `svn:ignore` propset 時(乾淨初始狀態的常見情況),`svn propget` 對 stderr 寫 warning(`W200017: Property 'svn:ignore' not found`)。原本程式用 `2>&1` 捕捉 stderr → PS 5.1 把 native exe stderr 包成 NativeCommandError → script throw + rollback。改用 `2>$null` 抑制 warning + 明確 check `$LASTEXITCODE`,缺 propset 時 fall through 用 default 值(`.git\n.gitignore`)。
- **SKILL Test Scenarios shell-only 語法 → 改成 PowerShell + bash 雙列**:`tp-svn-log` 與 `tp-suggest-ignore` 的 Test Scenarios 寫成 `--limit 5` / `--add-svn "..."`,但 PS script 用 `-Limit 5` / `-Add "..."`。改成兩種語法並列(PowerShell `-Limit 5` / bash `--limit 5`),並把 Procedure 改成顯示 powershell + bash 各自完整 invocation。

## [0.2.1] - 2026-05-24

### Fixed

- **P0:Windows PowerShell 5.1 完全不能跑** — 20 個 .ps1 用 3-arg `Join-Path $X 'a' 'b'` syntax(PS 7+ only),PS 5.1 dot-source lib 階段就 die。改用 `[System.IO.Path]::Combine($X, 'a', 'b')`(PS 5.1 + PS 7+ 通吃)。
- **P0:`[System.IO.Path]::GetRelativePath` 不在 .NET Framework** — 4 處 call site(`compute-project-identity.ps1`、`resolve-iis-settings.ps1`、`hooks/posttooluse-enterworktree.ps1`、`hooks/sessionstart.ps1`)用 .NET Core / .NET 5+ only 的 method,PS 5.1 跑到 identity hash 計算就 die。新增 `Get-RelativePathSafe` helper(用 `System.Uri.MakeRelativeUri`,PS 5.1 + 7+ 通吃)放 `scripts/lib/common.ps1`,4 處 call site 改用 helper。
- **P0:含中文 .ps1 沒 UTF-8 BOM,PS 5.1 在中文 Windows 上 mojibake → parser fail** — 9 個含中文的 .ps1 加 UTF-8 BOM(`build-web.ps1`、`publish-web.ps1`、`start-iis.ps1`、`stop-iis.ps1`、`svn-ignore.ps1`、`hooks/posttooluse-enterworktree.ps1`、`hooks/sessionstart.ps1`、`lib/applicationhost-helpers.ps1`、`lib/common.ps1`)。

### Test verification

實機在 `<MACHINE-PATH>` 跑通:
- compute-project-identity 跨 worktree hash 完全一致(`0eb9b6ee` from main = from dev-1)
- build 從 dev-1 → 產物只進 dev-1 bin/、main bin/ mtime 不變(關鍵 EnterWorktree bug 不重現)
- PostToolUse hook 接 stdin JSON → applicationhost.config physicalPath 從 main 改到 dev-1
- SessionStart peer worktree 無 marker → systemMessage 含真正 main path(非字面 `$mainPath`)
- svn-log / svn-ignore 直接模式 PASS
- create-remote-test SVN setup 失敗時 ERR trap 完整 rollback git branches + worktree

## [0.2.0] - 2026-05-24

### Added

- `tp-cleanup-orphan-iis` skill：清除孤兒 IIS Express process 及 applicationhost.config site 條目（worktree rename / project 搬移後遺留）
- `scripts/Remove-OrphanIis.ps1`：掃描同 csproj-stem 不同 hash 的 orphan process + XML site,支援 `-RemoveSite` / `-RemoveAll`
- `scripts/remove-orphan-iis.sh`：thin ps1-delegate wrapper(Windows-only)
- `Remove-ApplicationhostSite` helper(`scripts/lib/applicationhost-helpers.ps1`)

## [0.1.0] - 2026-05-22

### Added

- 首發版本,整合既有 `tdp` / `tnf` / `tgs` / `tpi` 四 plugin 為單一 `turbo-plugin`,共 13 個 skill 全部 `user-invocable: true`,以 `/tp-<skill>` 為觸發入口
- **Setup skill**:`tp-setup`(四 case 整合入口:新建 / init-from-existing / 主 worktree 補設定 / peer-mode)
- **SVN bridge skills**:`tp-pull-from-svn`、`tp-push-to-svn`、`tp-svn-log`、`tp-create-remote-test`、`tp-reset-remote-test`
- **.NET Framework Web skills**:`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`
- **Ignore / 註解 skills**:`tp-suggest-ignore`、`tp-csharp-comment`、`tp-js-comment`
- **Hooks**:plugin 自帶 `PostToolUse EnterWorktree` 自動補 applicationhost.config + `SessionStart` 三分支提示性 prompt
- **MCP server**:`tp-dbhub` 透過 `.mcp.json` 宣告,路徑用 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml`
- **集中設定目錄** `.turbo-plugin/`:`config.toml`(build/publish/frontend 偏好,schema_version=1)+ `applicationhost.config` 共享 source-of-truth + `dbhub.example.local.toml` template(進 git)+ `dbhub.local.toml`(gitignored 含 credentials)
- **共用 helper lib** `scripts/lib/common.{ps1,sh}` 提供 `Get-MainWorktree` / `Resolve-RepoPath` / `Write-Utf8NoBom` / `Resolve-RemoteWorktree` / `Test-IsMainWorktree` / `Test-IsSubmodule` / `Get-NormalizedAbsolutePath` / `Probe-GitVersion` 等通用函式
- **IIS-specific helper** `scripts/lib/applicationhost-helpers.ps1`:`Update-ApplicationhostConfig` + `Find-ApplicationhostSite`(.ps1-only;bash 端 hook script 為 thin wrapper 轉呼叫 .ps1)
- **新 IIS Express identity 演算法**:`(port + project identity)` 複合 key,project identity = `git rev-parse --path-format=absolute --git-common-dir` + `.csproj` 對 worktree top-level 相對路徑;site name = `<csproj-stem>-<sha256前8字元>`,寫入 applicationhost.config 讓 `Get-CimInstance Win32_Process` 跨 worktree 撈得到
- **tp-push-to-svn 自 parse subject 篩 SVN history**:runtime 讀 `.commitlintrc.json` `rules.type-enum[2]` 取 valid types(配 hard-coded default 12 類 fallback + stderr notice),kept-subset 為 `feat` / `fix` / `refactor` / `perf` / `revert`;unknown type AskUserQuestion 三選一
- 取代既有 commitlint + husky enforce 機制:本 plugin 不裝 npm 工具鏈、不裝 git hook、`.commitlintrc.json` 純諮詢
