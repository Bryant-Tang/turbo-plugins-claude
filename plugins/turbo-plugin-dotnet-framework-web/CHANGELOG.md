# Changelog

本檔記錄 turbo-plugin-dotnet-framework-web 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 自單體 `turbo-plugin` v0.6.0 拆出,成為獨立可安裝 plugin。
- 6 支 skill:`tp-setup`、`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`(保 `tp-*` 前綴)。
- `tp-setup` skill(standalone:共用 `assets/setup-base.md` concern-neutral 骨架 + dotnet concern〔`config.toml` 的 `[iis]`/`[build]`/`[publish]` 標記區塊、`applicationhost.config` bootstrap、`.gitignore` 的 .NET 產物區塊〕;`default-files/.turbo-plugin/{config.toml,conventions.md}` base 範本;無 git repo 時 fail-loud,不自行 git init)。
- 對應腳本對(`.ps1` + `.sh` delegate):Build-Web / Publish-Web / Start-Iis / Stop-Iis / Test-IisListening / Remove-OrphanIis / Compress-Content / Get-ProjectIdentity / Get-TargetUrl。
- `lib`:`Core.{ps1}` 複本 + dotnet concern `Common.ps1`(`Find-MSBuild` / `Find-SingleCsproj` / `Get-ProjectIdentityHash` / `Format-IisExpressSiteName`,自單體 `Common.ps1` 抽出、去除 SVN concern)+ `IisHelpers.ps1` / `ApplicationHostHelpers.ps1` + `ps1-delegate.sh`。
- PostToolUse EnterWorktree advisory hook(Windows-only,目前 no-op)。
- `default-files/.turbo-plugin/applicationhost.config` 範本。
- 兩層測試套件入口 + 各腳本 / lib helper / hook 行為測試(`Common.test.ps1` 自單體拆出、只保留 dotnet concern + Core 覆蓋)。

### 遷移說明

- 舊安裝 `turbo-plugin@turbo-plugins-claude` 已由四個獨立 plugin 取代。若需 .NET Framework Web 開發,改裝 `turbo-plugin-dotnet-framework-web@turbo-plugins-claude`。
