# Changelog

本檔記錄 turbo-plugin-dotnet-framework-web 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.2.0] - 2026-06-24

把 build / run / stop / publish 改成「給 agent 用的 VS 2022」:agent 判斷要操作哪個 csproj / `.sln` 與
configuration / platform,把明確參數傳給變薄的 executor;沒指定的 config 一律省略、交 MSBuild / `.sln` /
`Directory.Build.props` / pubxml 決定(對齊 VS)。

### Changed

- **skill 改為 agent 判斷 target/config**:`tp-build` / `tp-publish` / `tp-run` / `tp-stop` 由 agent 探索候選(Glob csproj/`.sln`、跳過 `bin`/`obj`/`node_modules`/`.vs`/`.git`、讀 `.sln`)、查記憶、不確定就 `AskUserQuestion`,再傳明確 `-Project`;不再靠 script 自動偵測單一 csproj。
- **executor 無值才省略 config(對齊 VS)**:`Build-Web` / `Publish-Web` 不再恆傳 `/p:Configuration`(舊版 build 恆 Debug、publish 恆 Release),只有 CLI 或記憶有值才附 `/p:Configuration|Platform`;publish 的 configuration 改以 pubxml 內嵌 `<Configuration>` 為準。
- **run/stop 記憶 key 由 `[build].project` 遷移為 `[run].project`(有 fallback,向後相容)**:run/stop 改讀 `[run].project`,無值時 fallback 讀既有 `[build].project`——既有只設過 `[build].project` 的專案不會 break。save-back 之後一律寫 `[run].project`。
- **build 接受 `.sln`(整方案)**:build 預設可建整個 `.sln`(`SolutionDir` 由 `.sln` 所在目錄推導);run / stop / publish 的 target 只能 csproj,收到 `.sln` 清楚報錯。
- **per-operation 結果模板**:build / run / publish / stop 收尾各印 `BUILD_OUTPUT` / `RUN_OUTPUT` / `PUBLISH_OUTPUT` / `STOP_OUTPUT`,回報 agent 傳入值 + **executor 解析後的實際 target**(糾錯閘);未指定的 config 標「由 MSBuild / solution 決定」,不假造預設值。
- **cleanup 無-project 行為差異(KTD8)**:`tp-cleanup-orphan-iis` 有 `-Project` 時行為完全不變(scoped、排除活站台);移除自動偵測後,**無 `-Project` 時**改用通用 turbo-plugin 站台樣式 `^.+-[0-9a-f]{8}$` 列舉,並**拒絕 `-RemoveAll`**(無法分辨活站台,只能逐站台 `-RemoveSite`),避免誤殺正在跑的 instance。
- `tp-setup` 在 `config.toml` 的 dotnet 區塊 seed `[build]` / `[run]` / `[publish]` 啟用空 section(欄位全註解、不預填值),讓記憶存回直接在既有 section 下填 key。

### Added

- **記憶 save-back**:`skills/tp-setup/assets/memory-save-back.md` 共用片段(read-the-file 機制),build / publish / run 執行後讀並遵循它,比對 agent 這次選定的 target / config / pubxml 與已存記憶,有差異就 `AskUserQuestion` 問四去向(存 committed / 存 local / 撤回省略〔刪 key〕/ 不存)。stop 不 save-back。
- per-operation 記憶 key:`[build].project`(可為 `.sln`)、`[run].project`、`[publish].project` / `[publish].default_pubxml`;各操作讀寫自己的 key。
- lib:`Resolve-ProjectTarget`(明確 target 解析 + csproj/`.sln` 型別判別 + 向後相容 fallback)、`Test-TurboPluginSiteName`(cleanup 無-project 通用樣式)、`Format-BuildResultLines` / `Format-RunResultLines` / `Format-StopResultLines`(結果模板)。

### Removed

- `Find-SingleCsproj` 的「掃 repo 自動取單一 csproj、多個就 throw」邏輯(改 `Resolve-ProjectTarget` 一律吃明確 target)。
- executor 的 Configuration / Platform 內建 default(`Debug` / `Release` / `Any CPU`)——改為無值即省略 `/p:`。

### Fixed

- executor 恆傳 `/p:Configuration` 壓過 csproj `<Configuration Condition="'$(Configuration)'==''">` 預設、靜默偏離 VS 的問題:無值省略後,build/publish 的 config 解析與 VS 一致。
- SKILL 文件移除過時敘述(自動偵測、內建 default、誤植的 `TURBO_PLUGIN_MSBUILD_PATH` env〔實際讀 `config.local.toml [tools].msbuild_path`〕)。
- `tp-cleanup-orphan-iis` Step 3 的刪除指令補回 `-Project`:scoped 模式的「全部清除」原本叫 `-RemoveAll` 卻沒帶 `-Project`,而 script 在無 `-Project` 時會拒絕 `-RemoveAll`(KTD8),導致 scoped-via-CLI 情境下「全部清除」直接報錯;`-RemoveSite` 也補上 `-Project` 以讓刪除範圍與 Step 1 枚舉範圍一致。
- publish 的 `PUBLISH_OUTPUT` 補上 `Target:` / `Profile:` 行(糾錯閘),與 build/run/stop 的 per-op 模板一致:原本 publish 只 relay 產出路徑/URL、解析後 target 只出現在 relay 區塊外的 prose(R12 對 publish 的缺口);現把 target/profile 放進 agent 逐字轉述的區塊,路徑/URL 仍維持光禿可點擊。
- `tp-run` / `tp-stop` SKILL 的 Step 1 補上:`[build].project` fallback **撈到 `.sln` 時不要當 target**,改由 agent 自己 Glob 探索 web csproj(run/stop 不能跑/停整個方案)。修掉「只設過 `[build].project = *.sln` 的向後相容使用者跑 run/stop 會被 script `.sln` 報錯擋下」的邊角——agent 現在會自行判斷出該跑/停的 csproj,而非把方案硬傳給 script。
- `tp-cleanup-orphan-iis` SKILL 文件對齊現行 script:移除早已退役的 applicationhost.config XML `<site>` 孤兒描述(`<kind>` = process/xml/both、`pid=-`、`Select-Xml` / `Remove-ApplicationhostSite` / `Move-Item` 等 Test Scenarios),改為現行實際輸出——`ORPHAN: <site> process pid=<n>`(只有 process 類)+ 先前完全未記載的 `ORPHAN_TEMP: <path>`(殘留 temp 暫存檔,只能靠 scoped `-RemoveAll` 清、`-RemoveSite` 不動);並修正 no-orphan 訊息字串。

## [0.1.0] - 2026-06-20

### Added

- 自單體 `turbo-plugin` v0.6.0 拆出,成為獨立可安裝 plugin。
- 6 支 skill:`tp-setup`、`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`(保 `tp-*` 前綴)。
- `tp-setup` skill(standalone:共用 `assets/setup-base.md` concern-neutral 骨架 + dotnet concern〔`config.toml` 的 `[iis]`/`[build]`/`[publish]` 標記區塊、`applicationhost.config` bootstrap、`.gitignore` 的 .NET 產物區塊〕;`default-files/.turbo-plugin/config.toml` base 範本;無 git repo 時 fail-loud,不自行 git init)。
- 共用 setup base 檔(`setup-base.md` / `claudemd-base-snippet.md`)與 git-svn / db 同步:**`conventions.md`「先讀慣例」機制整套退役**(base 不再建、移除 `default-files` 範本),`CLAUDE.md` snippet 只留「不得提交僅限本機之物」硬規則;tp-* skill 全改靠各自 `description` 主動觸發。
- 對應腳本對(`.ps1` + `.sh` delegate):Build-Web / Publish-Web / Start-Iis / Stop-Iis / Test-IisListening / Remove-OrphanIis / Compress-Content / Get-ProjectIdentity / Get-TargetUrl。
- `lib`:`Core.{ps1}` 複本 + dotnet concern `Common.ps1`(`Find-MSBuild` / `Find-SingleCsproj` / `Get-ProjectIdentityHash` / `Format-IisExpressSiteName`,自單體 `Common.ps1` 抽出、去除 SVN concern)+ `IisHelpers.ps1` / `ApplicationHostHelpers.ps1` + `ps1-delegate.sh`。
- PostToolUse EnterWorktree advisory hook(Windows-only,目前 no-op)。
- `default-files/.turbo-plugin/applicationhost.config` 範本。
- 兩層測試套件入口 + 各腳本 / lib helper / hook 行為測試(`Common.test.ps1` 自單體拆出、只保留 dotnet concern + Core 覆蓋)。
- **`tp-publish` 發佈路徑改固定兩行模板(U10 / R15 / KTD8)**:`Publish-Web.ps1` 成功後改印一行 `PUBLISH_OUTPUT (...)` marker + 緊接兩行——raw Windows 絕對路徑、`file:///` URL,各自成行、**結尾無標點**(非 FileSystem 發佈方式則 marker 後只有一行 URL),取代舊「`Published to:` 散文 + `PUBLISH_OUTPUT_PATH=` token」。SKILL 改要求 agent **逐字、各自成行**轉述那兩行、前後不接散文/句號(維持終端可點擊),不轉述 marker 行。路徑解析抽成 lib helper `Get-PublishOutputLines`(FileSystem rooted/relative 解析 + trailing backslash 去除 + 反斜線轉正斜線;非 FileSystem passthrough),新增單元測試(絕對/相對、含空白單行、結尾無標點、`file:///` 無反斜線、非 FileSystem passthrough)讓兩行格式不需 MSBuild 即可驗。

### 遷移說明

- 舊安裝 `turbo-plugin@turbo-plugins-claude` 已由四個獨立 plugin 取代。若需 .NET Framework Web 開發,改裝 `turbo-plugin-dotnet-framework-web@turbo-plugins-claude`。
