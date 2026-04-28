# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

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
