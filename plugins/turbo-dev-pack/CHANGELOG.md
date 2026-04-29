# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.2.2] - 2026-04-29

### Added

- 新增 `write-test-plan` skill：負責規劃整體最終驗證任務（涵蓋 `goal.md` 中所有目標），產出 `test-plan.md` 與 `test-n.md`，存放於 spec 資料夾根目錄
- `goal.md` 目標編號支援「數字 + 可選字母字尾」格式（例如 `1`、`2a`、`2b`、`3`）：相同數字的目標群組合起來必須獨立可交付，但每個個別子目標只需能在單一 chat session 內完成；plan mode 規劃時若發現目標太大，可回到 `start-dev` 將其拆分為更多同數字子目標並重新編號

### Changed

- `write-plan` 改為僅產出 `goal-<id>/plan.md`（其中 `<id>` 為目標編號，例如 `goal-1/`、`goal-2a/`、`goal-2b/`），不再產出 `test-plan.md` 與 `test-n.md`；移除驗證模式判斷、證據規則與相關步驟
- 開發流程調整：每個目標 `plan mode → write-plan → implement-task` 循環；所有目標完成後可選擇性走 `plan mode → write-test-plan → testing-and-proof`
- `start-dev` 規範與 Handoff 文字、`goal.template.md`、`implement-task` 內 `### 進度總覽` 比對與 checkbox 邏輯均更新以支援帶字母字尾的目標編號
- `testing-and-proof` 將 `test-plan.md` 預設位置改為 spec 資料夾根目錄；`screenshots/` 也改放於 spec 資料夾根目錄

## [0.2.1] - 2026-04-29

### Added

- `goal.md` 在「修正或開發目標」下方新增 `### 進度總覽` 子章節，列出所有目標的 checkbox 清單
- `implement-task` 結束時會詢問使用者是否確認該目標完成，確認後自動將 `goal.md` 進度總覽中對應的 `- [ ]` 改為 `- [x]`

### Changed

- `start-dev` 要求新增、移除或調整目標時必須同步更新 `### 進度總覽` checkbox，並加入對應的 Completion Check
- `start-dev` Handoff 文字補充說明 `implement-task` 結束會詢問並勾選進度總覽
- `implement-task` 增訂規則：任務 `BLOCKED` 時跳過 checkbox 詢問，且不得在未經使用者確認的情況下勾選 checkbox

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
