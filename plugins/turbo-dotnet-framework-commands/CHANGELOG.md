# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.2.4] - 2026-05-02

### Changed

- `setup` skill 在設定 `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` 時，若偵測到唯一 `.sln` 檔，自動以 `.vs/<SolutionName>/config/applicationhost.config` 為首選推薦選項
- `setup` skill 若目標 applicationhost.config 不存在，自動掃描其他 worktree 並複製
- `setup` skill 在 applicationhost.config 確認存在後，自動校正 physicalPath 為當前 workspace 的 web 專案絕對路徑

## [0.2.3] - 2026-05-02

### Changed

- `publish-web` FileSystem 發佈的 `Published to:` 行改輸出 `file:///` URI，讓使用者可在終端機直接點擊開啟目錄（`PUBLISH_OUTPUT_PATH=` 仍維持 Windows 路徑）

## [0.2.2] - 2026-04-28

### Added

- `publish-web` 在 MSBuild 發佈成功後輸出發佈路徑：人讀的 `Published to:` 行 + 機讀的 `PUBLISH_OUTPUT_PATH=` 行（永遠是最後一行）
- 路徑取自 `.pubxml` 的 `<PublishUrl>`，相對路徑會以 `.csproj` 目錄為基準轉為絕對路徑（對齊 MSBuild `Microsoft.WebApplication.targets` 行為）

### Notes

- 目前針對 `WebPublishMethod=FileSystem` 最佳化；其他 method（Package、MSDeploy、FTP）會輸出 `<PublishUrl>` 原值與 method 名稱供參考
- 若 `<PublishUrl>` 缺失、為空、或含 MSBuild property（如 `$(SolutionDir)`），會在 stderr 寫警告並跳過 `PUBLISH_OUTPUT_PATH=` 機讀行，但發佈本身仍視為成功（exit 0）

## [0.2.1] - 2026-04-28

### Added

- `publish-web` 支援 `--configuration` / `-Configuration` 與 `--platform` / `-Platform` 引數，可由新環境變數 `PUBLISH_DEFAULT_CONFIGURATION`、`PUBLISH_DEFAULT_PLATFORM` 設定預設值；皆未提供時預設為 `Release` + `AnyCPU`
- `setup` skill 表格與 Decision Rules 加入 `PUBLISH_DEFAULT_*` 對應的設定流程說明

### Changed

- `publish-web` 改為呼叫 MSBuild 時一律傳入 `/p:Configuration` 與 `/p:Platform`，會覆寫 `.pubxml` 中對應的 `<Configuration>` / `<Platform>` 元素（`WebPublishMethod` / `PublishUrl` 等其他設定仍由 `.pubxml` 主導）

## [0.2.0] - 2026-04-28

### Added

- 自 `turbo-plugins-claude` 拆分為獨立 plugin
- 新增 `publish-web`（原 `publish-project`）命令，支援 `.pubxml` 發佈設定檔
- `build-web`（原 `build-project`）支援自訂 Configuration 與 Platform
- 補上 LICENSE

### Changed

- 將 `build-project` / `publish-project` / `run-project` 命令重新命名為 `build-web` / `publish-web` / `run-web`
- `default-config-files` 改名為 `default-files`
- 補上預設的範例設定檔
- README 更新安裝說明

### Fixed

- `publish-web` 改用 `PublishProfile` + `PublishProfileRootFolder`，避免 `.pubxml` 被預設 Package 行為覆蓋
- `publish-web` 改用 `DeployOnBuild` 與 `PublishProfileFullPath`
- `setup` skill 對路徑變數的不同格式支援
- 修正 `revert-stash`、參數解析與 port 驗證的潛在錯誤，補充 `.gitignore`
- 修正多項腳本 bug 與 skill 邏輯漏洞
- 修正全專案靜態審查發現的 bug 與代碼品質問題

## [0.1.0] - 2026-04-26

### Added

- 使用 `my-sample-skills` 建立 claude plugin
