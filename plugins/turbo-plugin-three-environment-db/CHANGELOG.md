# Changelog

本檔記錄 turbo-plugin-three-environment-db 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [0.1.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-three-environment-db--v0.1.0...turbo-plugin-three-environment-db--v0.1.1) (2026-08-13)


### Fixed

* **core:** config 改用 UTF-8 讀取,非 ASCII 註解不再讓後面整段設定消失 ([c65b4a5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c65b4a50807b71fe8f0cf0c4e1a310d856473fd1))
* **git-svn:** tp-setup 注入的 base ignore 加上 .claude/worktrees/ ([bfc3264](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/bfc32649ba0fac901a4a63b656a181bd0c779688))

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 初版:三環境 DB 開發輔助的獨立可安裝 plugin。
- `tp-db-management` skill(含 `assets/sql-script-template.sql`)。
- `tp-setup` skill(standalone:共用 `assets/setup-base.md` concern-neutral 骨架 + db concern〔`dbhub.example.local.toml` 範本、提示填 `dbhub.local.toml`、peer-mode 處理 per-peer `dbhub.local.toml`〕;無 git repo 時 fail-loud,不自行 git init)。
- `tp-db-management` 的 `description` 強化為**主動觸發**式(「做任何資料庫 / SQL 工作時主動使用、不要繞過直接手寫 SQL」),改靠 description 讓 agent 自動採用;`conventions.md`「先讀慣例」機制已整套退役,db setup 不再寫它。
- `tp-dbhub` MCP server 宣告(`.mcp.json`,經 DBHub 容器連 SQL Server,讀 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml`)。
- SessionStart advisory hook:當專案使用 db(`.turbo-plugin/dbhub.example.local.toml` 存在)、於 peer worktree 啟動且缺 `dbhub.local.toml` 時,提示 tp-dbhub MCP 將無法啟動。advisory(不 block session);專案未用 db 時 no-op(concern-marker gate)。
- `default-files/.turbo-plugin/dbhub.example.local.toml` 連線設定範本。
- 兩層測試套件入口 + SessionStart hook 行為測試(PS + bash:non-git / dbhub 警示 / no-marker 靜默 / gate no-op)。
- `scripts/lib/Core.{ps1,sh}`:universal core helper 複本(供 hook 用),與其它 plugin 逐位元組一致(由 repo 層 CI job 把關)。
