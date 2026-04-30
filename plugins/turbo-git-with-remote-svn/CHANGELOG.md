# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

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
