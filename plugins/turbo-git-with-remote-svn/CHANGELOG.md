# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.4.0] - 2026-05-02

### Added

- `init-from-existing` skill：分析既有 git 專案結構與 tgs 標準的落差，並互動式地執行遷移（建立 `remote/main` orphan 分支、`<proj>.worktrees/remote-main` worktree、SVN checkout、`.code-workspace`，以及初始 SVN sync）；已符合 tgs 結構的元件自動跳過（冪等）

## [0.3.0] - 2026-05-02

### Added

- `merge-main-into-all` command：將 `main` branch merge 進所有非 `remote/*` 的 branch（`test-<n>`、`dev-<n>` 等）；每個 branch 獨立報告 `OK` / `SKIP`（dirty worktree）/ `CONFLICT`（merge 已 abort）
- `pull-from-svn` skill：成功 pull 進 `main` 後推薦執行 `/tgs:merge-main-into-all`

## [0.2.0] - 2026-05-02

### Added

- `suggest-ignore` skill：管理 git/SVN ignore 的單一入口
  - **直接模式**：`--add-git` / `--remove-git` 直接操作 `.gitignore`（並 git commit）；`--add-svn` / `--remove-svn` 同步所有 remote worktrees 的 `svn:ignore`（支援 `--path`）
  - **分析模式**（不帶直接操作旗標）：互動式分析，推薦並設定 `.gitignore` 與 `svn:ignore`；處理 4 類情境：(A) 新增 git ignore、(B) 新增 svn:ignore、(C) 修正 SVN 追蹤但 git 忽略的不一致、(D) 從 git 和/或 SVN 停止追蹤

### Changed

- `create-remote-test`：新 remote worktree 的 `svn:ignore` 從 remote-main 複製現有設定（含使用者自訂 pattern），而非硬編碼 `.git`/`.gitignore`

### Fixed

- `push-to-svn-commit`：改用 explicit commit list，`?`/`!`/`M` 狀態的 git-ignored 項目不再被加入 / 刪除 / 提交到 SVN；本地檔案完整保留（不執行 svn revert）
- `create-remote-test`：`svn propget svn:ignore` 移除多餘的 `'.'` 路徑參數，避免從非 SVN 工作目錄呼叫時因 CWD 不是 SVN WC 而報錯
- `svn-log`：移除與 `[CmdletBinding()]` common parameter 衝突的 `[switch]$Verbose`，改用 `$VerbosePreference` 偵測 `-Verbose` 旗標

## [0.1.1] - 2026-04-30

### Added

- `push-to-svn` skill：push 完成後詢問是否建立 release tag；tag 格式為 `<branch>-release-YYYY-MM-DD-<serial>`（例如 `main-release-2026-04-30-001`），serial 為該分支單日流水號
- `tag-release` 腳本（`.sh` / `.ps1`）：計算當天流水號並在 `remote/<branch>` 上建立 git tag

### Fixed

- 所有 PowerShell 腳本新增 `[CmdletBinding()]`，傳入未知參數時現在會立即報錯而非靜默忽略

## [0.1.0] - 2026-04-30

### Added

- `create-project` command：在指定位置建立初始專案結構（main worktree + remote-main worktree + SVN checkout + .code-workspace）
- `pull-from-svn` skill：從 SVN 更新對應的 remote-* worktree，commit 到 remote/* branch，merge 進指定的 git 工作分支
- `push-to-svn` skill：將指定 git 工作分支 merge 進對應的 remote/* branch，並在 remote-* worktree 執行 SVN 送交
- `create-remote-test` command：建立 test-\<n\> branch + remote/test-\<n\> branch + remote-test-\<n\> worktree，可選擇性連結 SVN 分支 URL
- `create-dev-worktree` command：建立 dev-\<n\> worktree + 指定或新建的 git 分支，供個人開發隔離使用
- `svn-log` command：在指定 branch 對應的 remote-* worktree 執行 `svn log`，列出 SVN 歷史紀錄；支援 `--branch`（預設 main）、`--limit`（預設 50）、`--verbose` 參數
- `/tgs:setup` skill：互動式設定 tgs 環境變數，將設定寫入 `.claude/settings.local.json`
- `TGS_SVN_LOG_DEFAULT_BRANCH`、`TGS_SVN_LOG_DEFAULT_LIMIT`、`TGS_SVN_LOG_DEFAULT_VERBOSE` 環境變數：可覆寫 `svn-log` command 的 `--branch`、`--limit`、`--verbose` 預設值（優先序：CLI 參數 > 環境變數 > 內建預設值）
- `TGS_DEFAULT_WORKING_BRANCH` 環境變數：`pull-from-svn` / `push-to-svn` skill 的 `--branch` 預設分支；未設定時維持原本的互動詢問行為
- `create-project`、`create-remote-test`、`create-dev-worktree` 完成後顯示 `/tgs:setup` 推薦執行提示
