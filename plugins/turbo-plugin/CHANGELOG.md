# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.2.0] - 2026-05-24

### Added

- `tp-cleanup-orphan-iis` skill：清除孤兒 IIS Express process 及 applicationhost.config site 條目（worktree rename / project 搬移後遺留）
- `scripts/cleanup-orphan-iis.ps1`：掃描同 csproj-stem 不同 hash 的 orphan process + XML site,支援 `-RemoveSite` / `-RemoveAll`
- `scripts/cleanup-orphan-iis.sh`：thin ps1-delegate wrapper(Windows-only)
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
