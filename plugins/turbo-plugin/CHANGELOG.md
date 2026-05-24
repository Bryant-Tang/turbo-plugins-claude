# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

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
