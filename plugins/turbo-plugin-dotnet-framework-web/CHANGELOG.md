# Changelog

本檔記錄 turbo-plugin-dotnet-framework-web 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

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
