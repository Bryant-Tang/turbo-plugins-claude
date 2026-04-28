# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.2.0] - 2026-04-28

### Added

- 自 `turbo-plugins-claude` 拆分為獨立 plugin
- `finish-dev` skill：歸檔已完成分支的 specs 與 SQL files
- `setup` 安裝時自動建立 `specs/archives` 與 `sql files/archives` 目錄結構
- 開發流程支援逐目標循環，`write-plan`、`implement-task`、`testing-and-proof` 可在 `start-dev` 後選擇性執行
- `goal.md` 拆分為多個小目標，每個小目標使用 plan mode 實作

### Changed

- `write-plan` 改為每個 goal 建立獨立 `goal-N/` 子目錄，避免覆蓋前次計畫
- `default-config-files` 改名為 `default-files`，並補上 `specs/`、`sql files/` 目錄骨架
- 補上預設的範例設定檔
- 移除技能文件中的舊專案專有識別字
- README 更新安裝說明

### Fixed

- `setup` skill 對路徑變數的不同格式支援
- `setup` 一併新增 `sql files` 與 `specs` 結構
- 修正 `revert-stash`、參數解析與 port 驗證的潛在錯誤，補充 `.gitignore`
- 修正多項腳本 bug 與 skill 邏輯漏洞
- 修正全專案靜態審查發現的 bug 與代碼品質問題

## [0.1.0] - 2026-04-26

### Added

- 使用 `my-sample-skills` 建立 claude plugin
