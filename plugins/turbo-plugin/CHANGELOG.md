# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [1.0.0] - 2026-05-27

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

- **🔴 P0 `create-remote-test.ps1` happy path 在 PS 5.1 + StrictMode 完全跑不過 — 三條 bug 連環**(plan 002 U17.1 在實機 SampleGitWithSvn 跑時抓到,沒人能成功跑 tp-create-remote-test):
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

實機在 `SampleGitWithSvn` 跑通:
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
