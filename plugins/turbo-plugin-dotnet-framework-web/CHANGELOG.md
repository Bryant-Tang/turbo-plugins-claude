# Changelog

本檔記錄 turbo-plugin-dotnet-framework-web 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-06-20

初版:獨立可安裝的 .NET Framework Web 本機開發 plugin。build / run / stop / publish 採「給 agent 用的 VS 2022」行為模型——agent 判斷要操作哪個 csproj / `.sln` 與 configuration / platform / pubxml,把明確參數傳給變薄的 executor;executor 對齊 VS,agent 沒指定的 config 一律省略、交 MSBuild / `.sln` / `Directory.Build.props` / pubxml 決定。

### Added

- 6 支 skill:`tp-setup`、`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`(保 `tp-*` 前綴)。
- **「給 agent 用的 VS 2022」行為模型**:build / run / stop / publish 的 skill 由 agent 探索候選(Glob csproj/`.sln`、跳過 `bin`/`obj`/`node_modules`/`.vs`/`.git`、讀 `.sln`)、查記憶、不確定就 `AskUserQuestion`,再傳明確 `-Project`;executor 只有 CLI 或記憶有值才附 `/p:Configuration|Platform`、否則省略(對齊 VS);publish 的 configuration 以 pubxml 內嵌 `<Configuration>` 為準。build 可建整個 `.sln`(`SolutionDir` 由 `.sln` 目錄推導);run / stop / publish 只能 csproj,收到 `.sln` 清楚報錯。
- **per-operation 記憶(兩層設定查找)**:`[build].project`(可為 `.sln`)、`[run].project`(無值時 fallback `[build].project`,向後相容)、`[publish].project` / `[publish].default_pubxml`;各操作讀寫自己的 key,沿用 `Resolve-ConfigValue` 的 CLI → config.toml → config.local.toml → 預設 四層(local 蓋 committed)。
- **記憶 save-back**:`skills/tp-setup/assets/memory-save-back.md` 共用片段(read-the-file 機制),build / publish / run 執行後讀並遵循它,比對 agent 這次選定的 target / config / pubxml 與已存記憶,有差異就 `AskUserQuestion` 問四去向(存 committed / 存 local / 撤回省略〔刪 key〕/ 不存)。stop 不 save-back。`tp-setup` 在 `config.toml` 的 dotnet 區塊 seed `[build]` / `[run]` / `[publish]` 啟用空 section,讓存回直接在既有 section 下填 key。
- **per-operation 結果模板**:build / run / publish / stop 收尾各印 `BUILD_OUTPUT` / `RUN_OUTPUT` / `PUBLISH_OUTPUT` / `STOP_OUTPUT`,回報 agent 傳入值 + executor 解析後的**實際 target**(糾錯閘);未指定 config 標「由 MSBuild / solution 決定」。publish 的 `PUBLISH_OUTPUT` 含 `Target:` / `Profile:` + 產出路徑 / `file:///` URL(路徑/URL 各自成行、結尾無標點、保持終端可點擊);路徑解析抽成 lib helper `Get-PublishOutputLines`。
- **`tp-cleanup-orphan-iis`**:有 `-Project` 時 scoped(只清該專案 stem-hash 家族、排除其活站台);無 `-Project` 時用通用 turbo-plugin 站台樣式 `^.+-[0-9a-f]{8}$` 列舉、**拒絕 `-RemoveAll`**(無法分辨活站台,只能逐站台 `-RemoveSite`、刪前警示),避免誤殺正在跑的 instance。清理對象為孤兒 `iisexpress.exe`(`ORPHAN:`)與殘留的 per-launch temp applicationhost.config 暫存檔(`ORPHAN_TEMP:`,只能 scoped `-RemoveAll` 清)。
- `tp-setup` skill(standalone:共用 `assets/setup-base.md` concern-neutral 骨架 + dotnet concern〔`config.toml` 的 `[iis]`/`[build]`/`[run]`/`[publish]` 標記區塊、`applicationhost.config` bootstrap、`.gitignore` 的 .NET 產物區塊〕;`default-files/.turbo-plugin/config.toml` base 範本;無 git repo 時 fail-loud,不自行 git init)。
- 對應腳本對(`.ps1` + `.sh` delegate):Build-Web / Publish-Web / Start-Iis / Stop-Iis / Test-IisListening / Remove-OrphanIis / Compress-Content / Get-ProjectIdentity / Get-TargetUrl。
- `lib`:`Core.ps1` 複本 + dotnet concern `Common.ps1`(`Find-MSBuild` / `Resolve-ProjectTarget`〔明確 target 解析 + csproj/`.sln` 型別判別 + 向後相容 fallback〕/ `Get-ProjectIdentityHash` / `Format-IisExpressSiteName` / `Test-TurboPluginSiteName` / 結果模板 helper 家族)+ `IisHelpers.ps1` / `ApplicationHostHelpers.ps1` + `ps1-delegate.sh`。
- PostToolUse EnterWorktree advisory hook(Windows-only,目前 no-op)。
- `default-files/.turbo-plugin/applicationhost.config` 範本。
- 兩層測試套件入口(`tests/Invoke-ScriptTests.ps1` + `tests/invoke-script-tests.sh`)+ 各腳本 / lib helper / hook 行為測試。
