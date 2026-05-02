# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.3.0] - 2026-05-02

### Added

- `setup-all` 新增 P2.5 smart key handling：當 `MARKITDOWN_WORKDIR_PATH` 在傳播集合中時，詢問使用者是否採用「per-worktree `.markdown/workdir`」模式（預設選項）；選擇後自動為每個 peer 設定各自的 `.markdown/workdir` 絕對路徑並建立目錄
- `setup-all` 新增 P4.5 applicationhost.config sync：當 `RUN_IIS_APPLICATIONHOST_CONFIG_PATH` 在傳播集合中且使用者選擇「per-worktree physicalPath」模式（預設選項），自動複製缺少 applicationhost.config 的 peer，並校正每個 peer 的 physicalPath 至該 worktree 的 web 專案目錄

## [0.2.0] - 2026-04-30

### Added

- `setup-all` skill 支援多 worktree 一次性 setup：偵測 `git worktree list` 後，把當下 worktree 互動產生的 env 值複製到使用者勾選的其他 worktree，並支援 per-worktree per-key override；單 worktree 專案行為與 v0.1.0 相同
- `scripts/merge-settings-env.sh` 與 `scripts/merge-settings-env.ps1`：把 env key/value 集合 atomic 合併進指定 `.claude/settings.local.json`，僅動 `env` 區塊

## [0.1.0] - 2026-04-30

### Added

- `setup-all` skill：自動偵測已安裝的 turbo-plugins-claude plugin，讓使用者勾選後依固定順序（tdp → tnf → tgs → 其他）依序呼叫每個 plugin 的 setup skill；continue-on-error，失敗項目於彙總中顯示重試指令
- `teach-me` skill：動態讀取已安裝 plugin 的 README、skills、commands，產生包含 Overview、Per-plugin 章節、Cross-plugin 工作流三段的整合教學，並進入多輪 Q&A；Q&A 結束後可選擇是否將教學存成 `.md` 檔
