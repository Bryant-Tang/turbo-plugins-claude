# Changelog

本檔記錄 turbo-plugin-three-environment-db 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 自單體 `turbo-plugin` v0.6.0 拆出,成為獨立可安裝 plugin。
- `tp-db-management` skill(含 `assets/sql-script-template.sql`)。
- `tp-setup` skill(standalone:共用 `assets/setup-base.md` concern-neutral 骨架 + db concern〔`dbhub.example.local.toml` 範本、提示填 `dbhub.local.toml`、`conventions.md` 的 db 標記區塊、peer-mode 處理 per-peer `dbhub.local.toml`〕;`default-files/.turbo-plugin/conventions.md` base 範本;無 git repo 時 fail-loud,不自行 git init)。
- `tp-dbhub` MCP server 宣告(`.mcp.json`,經 DBHub 容器連 SQL Server,讀 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml`)。
- SessionStart advisory hook:當專案使用 db(`.turbo-plugin/dbhub.example.local.toml` 存在)、於 peer worktree 啟動且缺 `dbhub.local.toml` 時,提示 tp-dbhub MCP 將無法啟動。advisory(不 block session);專案未用 db 時 no-op(concern-marker gate)。
- `default-files/.turbo-plugin/dbhub.example.local.toml` 連線設定範本。
- 兩層測試套件入口 + SessionStart hook 行為測試(PS + bash:non-git / dbhub 警示 / no-marker 靜默 / gate no-op)。
- `scripts/lib/Core.{ps1,sh}`:universal core helper 複本(供 hook 用),與其它 plugin 逐位元組一致(由 repo 層 CI job 把關)。

### 遷移說明

- 舊安裝 `turbo-plugin@turbo-plugins-claude` 已由四個獨立 plugin 取代。若需三環境 DB,改裝 `turbo-plugin-three-environment-db@turbo-plugins-claude`。
