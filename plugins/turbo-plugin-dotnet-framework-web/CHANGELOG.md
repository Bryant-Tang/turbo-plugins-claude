# Changelog

本檔記錄 turbo-plugin-dotnet-framework-web 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-06-20

初版:獨立可安裝的 .NET Framework Web 本機開發 plugin。build / run / stop / publish 採「給 agent 用的 VS 2022」行為模型——agent 判斷要操作哪個 csproj / `.sln` 與 configuration / platform / pubxml,把明確參數傳給變薄的 executor;executor 對齊 VS,agent 沒指定的 config 一律省略、交 MSBuild / `.sln` / `Directory.Build.props` / pubxml 決定。

### Added

- 5 支 skill:`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`(保 `tp-*` 前綴)。**沒有 setup 指令**——所有設定都是用到才建、且能自我修復,跟 Visual Studio 一樣(VS 的 `applicationhost.config` 也是第一次執行專案才出現)。
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
