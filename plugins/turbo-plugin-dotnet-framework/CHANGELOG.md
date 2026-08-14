# Changelog

本檔記錄 turbo-plugin-dotnet-framework 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [0.2.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-dotnet-framework--v0.1.3...turbo-plugin-dotnet-framework--v0.2.0) (2026-08-14)


### Added

* **core:** linked worktree 繼承主 worktree 的機器層設定與 pack-content 核准 ([5a8ffc0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/5a8ffc01774e018bd58d5b8c04d63e176bc51007)), closes [#61](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/61)


### Fixed

* **core:** 設定檔的行內註解不再吃掉整個 section 或整個值 ([7b0a34e](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7b0a34e0cb84d88435c0d1f2da1e357c2b1ae253)), closes [#60](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/60)
* **dotnet:** 結果模板改用 fenced code block 轉述,路徑不再被 Markdown 吃掉反斜線 ([c5ad9f0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c5ad9f02dbf3ef2d5707dd0e0ba0cfdd38b382be)), closes [#63](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/63)


### Changed

* **core:** 主 worktree 直接短路,不為了繼承設定多 fork 一次 git ([7d98b3b](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7d98b3b0cabea5d3513e5968d81d6ba2644f9ea3))

## [0.1.3](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-dotnet-framework--v0.1.2...turbo-plugin-dotnet-framework--v0.1.3) (2026-08-13)


### Fixed

* **core:** config 改用 UTF-8 讀取,非 ASCII 註解不再讓後面整段設定消失 ([c65b4a5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c65b4a50807b71fe8f0cf0c4e1a310d856473fd1))
* **dotnet:** node_version 寫成版本範圍時不再擋下所有 Node 版本 ([6866802](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/6866802f23a3b53525156acd8f86a65b6fed9d26))
* **dotnet:** publish 跟上 VS 實際寫入的組態/平台,並開放傳入額外 MSBuild 屬性 ([23dc97f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/23dc97f23add7bb02ef98363576c2f61853e27c1))
* **dotnet:** 依 csproj 的 Use64BitIISExpress 決定啟動哪一支 IIS Express ([193c872](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/193c872c22ea16d9eb66e0301115364300b9490c))

## [0.1.2](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-dotnet-framework--v0.1.1...turbo-plugin-dotnet-framework--v0.1.2) (2026-08-07)


### Fixed

* **dotnet:** build skill 明講要走它而不是自己叫 MSBuild,並補上還原失敗的判讀規則 ([f541438](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/f5414380e73cc35ed11e233072574a1f7cea3ccf))
* **dotnet:** build 印出完整 MSBuild 命令列,套件沒還原不再被誤判成程式碼壞掉 ([d4461b9](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/d4461b9c8080381889ba3da6bd77a64935e4c4bf))
* **dotnet:** publish 也會還原 NuGet 套件(含 packages.config),乾淨 clone 首次發佈不再失敗 ([e375d68](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/e375d68b36a12a4b53fa37a556959568f9d47290))

## [0.1.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-dotnet-framework--v0.1.0...turbo-plugin-dotnet-framework--v0.1.1) (2026-08-06)


### Fixed

* **dotnet:** 沒版控的專案也能 run IIS,前端未設定不再無聲略過 ([c1d83b6](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c1d83b6da0634c667e8ce178f6806a0030e5e58c)), closes [#29](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/29) [#30](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/30)

## [Unreleased]

## [0.1.0] - 2026-06-20

初版:獨立可安裝的 .NET Framework Web 本機開發 plugin。build / run / stop / publish 採「給 agent 用的 VS 2022」行為模型——agent 判斷要操作哪個 csproj / `.sln` 與 configuration / platform / pubxml,把明確參數傳給變薄的 executor;executor 對齊 VS,agent 沒指定的 config 一律省略、交 MSBuild / `.sln` / `Directory.Build.props` / pubxml 決定。

### Added

- 5 支 skill:`tp-build-dotnet-framework`、`tp-run-dotnet-framework`、`tp-stop-dotnet-framework`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`(保 `tp-*` 前綴)。**沒有 setup 指令**——所有設定都是用到才建、且能自我修復,跟 Visual Studio 一樣(VS 的 `applicationhost.config` 也是第一次執行專案才出現)。
- **「給 agent 用的 VS 2022」行為模型**:build / run / stop / publish 的 skill 由 agent 探索候選(Glob csproj/`.sln`、跳過 `bin`/`obj`/`node_modules`/`.vs`/`.git`、讀 `.sln`)、查記憶、不確定就 `AskUserQuestion`,再傳明確 `-Project`;executor 只有 CLI 或記憶有值才附 `/p:Configuration|Platform`、否則省略(對齊 VS);publish 的 configuration 以 pubxml 內嵌 `<Configuration>` 為準。build 可建整個 `.sln`(`SolutionDir` 由 `.sln` 目錄推導);run / stop / publish 只能 csproj,收到 `.sln` 清楚報錯。
- **per-operation 記憶(兩層設定查找)**:`[build].project`(可為 `.sln`)、`[run].project`(無值時 fallback `[build].project`,向後相容)、`[publish].project` / `[publish].default_pubxml`;各操作讀寫自己的 key,沿用 `Resolve-ConfigValue` 的 CLI → config.toml → config.local.toml → 預設 四層(local 蓋 committed)。
- **記憶 save-back**:`assets/memory-save-back.md` 共用片段(read-the-file 機制),build / publish / run 執行後讀並遵循它,比對 agent 這次選定的 target / config / pubxml 與已存記憶,有差異就 `AskUserQuestion` 問四去向(存 committed / 存 local / 撤回省略〔刪 key〕/ 不存)。stop 不 save-back。存回時自己確保 `.turbo-plugin/`、設定檔、dotnet 標記區塊與對應 `[section]` 存在;寫 `config.local.toml` 之前先確保 `.gitignore` 擋住 `*.local.*`(誰寫這種檔誰負責)。
- **per-operation 結果模板**:build / run / publish / stop 收尾各印 `BUILD_OUTPUT` / `RUN_OUTPUT` / `PUBLISH_OUTPUT` / `STOP_OUTPUT`,回報 agent 傳入值 + executor 解析後的**實際 target**(糾錯閘);未指定 config 標「由 MSBuild / solution 決定」。publish 的 `PUBLISH_OUTPUT` 含 `Target:` / `Profile:` + 產出路徑 / `file:///` URL(路徑/URL 各自成行、結尾無標點、保持終端可點擊);路徑解析抽成 lib helper `Get-PublishOutputLines`。
- **`tp-cleanup-orphan-iis`**:有 `-Project` 時 scoped(只清該專案 stem-hash 家族、排除其活站台);無 `-Project` 時用通用 turbo-plugin 站台樣式 `^.+-[0-9a-f]{8}$` 列舉、**拒絕 `-RemoveAll`**(無法分辨活站台,只能逐站台 `-RemoveSite`、刪前警示),避免誤殺正在跑的 instance。清理對象為孤兒 `iisexpress.exe`(`ORPHAN:`)與殘留的 per-launch temp applicationhost.config 暫存檔(`ORPHAN_TEMP:`,只能 scoped `-RemoveAll` 清)。
- **不需要 Visual Studio**:`applicationhost.config` 由第一次 `/tp-run` 產生(也可用 `New-ApphostConfig` 單獨產)——以 **IIS Express 自帶的 `AppServer\applicationhost.config` 為底**(可攜、無機器專屬路徑),加上依 csproj 的 `<IISUrl>` / `<IISExpressSSLPort>` / `<DevelopmentServerPort>` / `<IISExpressUseClassicPipelineMode>` 合成的站台;缺這個專案的站台就 append(同一份檔可放多個 web 專案、不動別人的站台),既有內容若是 IIS Express 載不進去的形狀則自動重建並保留站台。MSBuild 探測含「Build Tools for Visual Studio」,只裝 Build Tools + IIS Express 的機器也能用。
- **啟動與診斷**:IIS Express 以 `-NoNewWindow` 啟動(不開視窗、可在腳本結束後存活;用 `-WindowStyle` 會讓它在綁 port 前就以 exit code 0 結束),stdout / stderr 導到 per-launch log,啟動失敗時把它自己的訊息一起回報。
- **站台命名雙軌**:進版控的 `applicationhost.config` 用**專案名**(與 VS 寫的一致、不含機器資訊、可跨同事共享);帶 project identity hash 的**執行期名**只出現在每次啟動渲染的暫存設定檔與 iisexpress 命令列上,供 stop / orphan 清理辨識專案。
- **https 開發憑證**:產生設定檔時診斷 SSL port 綁定狀況(IIS Express 安裝時已預綁 44300-44399);`Approve-IisExpressCert` 可代為把開發憑證加進**本使用者**的信任清單(同 VS 首次跑 https 專案的那個詢問),獨立成一支明確呼叫的腳本、加完讀回存放區驗證。
- 對應腳本對(`.ps1` + `.sh` delegate):Build-Web / Publish-Web / Start-Iis / Stop-Iis / Test-IisListening / Remove-OrphanIis / Compress-Content / Get-ProjectIdentity / Get-TargetUrl / New-ApphostConfig / Approve-IisExpressCert。
- `lib`:`Core.ps1` 複本 + dotnet concern `Common.ps1`(`Find-MSBuild` / `Resolve-ProjectTarget`〔明確 target 解析 + csproj/`.sln` 型別判別 + 向後相容 fallback〕/ `Get-ProjectIdentityHash` / `Format-IisExpressSiteName` / `Test-TurboPluginSiteName` / 結果模板 helper 家族)+ `IisHelpers.ps1` / `ApplicationHostHelpers.ps1` + `ps1-delegate.sh`。
- `default-files/.turbo-plugin/applicationhost.config` 範本(只有 `<applicationPools>` / `<sites>` 骨架,`<site>` 條目由 `New-ApphostConfig` 依 csproj 產生)。
- 兩層測試套件入口(`tests/Invoke-ScriptTests.ps1` + `tests/invoke-script-tests.sh`)+ 各腳本 / lib helper 的行為測試。
- **`applicationhost.config` 改成第一次執行時自己產生(lazy),不必先跑設定指令**。`Initialize-ApplicationhostSite`(`scripts/lib/ApplicationHostHelpers.ps1`)是唯一實作,`New-ApphostConfig` 與 `Start-Iis` 共用。**以 IIS Express 自帶的 `<install>\AppServer\applicationhost.config` 為底**而不是自寫骨架:自寫的 40 行版本缺 `<configSections>`,IIS Express 會整份拒收(實測)。**append 而非重建**(一份設定檔可放多個 web 專案的站台,重建會清掉別人的),site id 取現有 max+1(重複 id 也會讓整份被拒);讀到缺 `<configSections>` 的舊檔會以原廠範本重建並保留既有站台。加了 `appcmd list site /apphostconfig:<path>` 當驗證預言——它不啟動伺服器就能判斷設定檔載不載得進去,先前 260+ 測試全綠卻沒抓到問題,就是因為缺這個預言(fixture 用的正是同一份無效骨架)。
- **啟動方式改用 `-NoNewWindow`**。原本歸因錯誤:以為 `-WindowStyle Hidden` 導致 IIS Express 立刻 exit 0,實測是**設定檔無效**才是元凶;而 `-WindowStyle` 任何值都會迫使 `UseShellExecute=$true`,IIS Express 在綁定前就結束。`-NoNewWindow` 可用且不開視窗,但**不會自動為參數加引號**,要自己處理。
- **只裝「Build Tools for Visual Studio」(沒有完整 Visual Studio)也找得到 MSBuild**:`Find-MSBuild` 的搜尋路徑加入 BuildTools 版位;找不到時的錯誤訊息直接給出可貼上的 `config.local.toml` 片段。
- **移除本 plugin 的 `tp-setup`**,設定改成**用到才建**:需要寫設定的那一方自己把 `.turbo-plugin/`、設定檔與自己的標記區塊建起來(含在寫任何 `*.local.*` 之前先確保 `.gitignore` 有 `.turbo-plugin/**/*.local.*`)。所以只裝本 plugin 時不必先做任何事。
- **哪些檔案該 ignore 改由 agent 看專案實際內容判斷**,不套固定 pattern 清單;判準集中在 `skills/tp-suggest-ignore/assets/ignore-rubric.md`(git-svn 提供,三處共用)。只有 plugin 自造的基礎設施 pattern 仍寫死,因為它們必須在任何 `git add` 之前就位。
