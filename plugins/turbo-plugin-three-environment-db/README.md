# turbo-plugin-three-environment-db

三環境 DB 開發輔助 plugin。是單體 `turbo-plugin`（v0.6.0）拆出的四個獨立 plugin 之一。

## 內容

- **`tp-setup`** skill — 設定入口:先跑共用 base 段（建 `.turbo-plugin/` + concern-neutral 共用檔），再做 db concern（部署 `dbhub.example.local.toml` 範本、提示複製填 `dbhub.local.toml`、在 `conventions.md` 的 db 標記區塊寫 db-management 指向、peer-mode 處理 per-peer `dbhub.local.toml`）。無 git repo 時 fail-loud。
- **`tp-db-management`** skill — DB 相關開發雜務（SQL 腳本撰寫等），附 `assets/sql-script-template.sql`。
- **`tp-dbhub`** MCP server（`.mcp.json`）— 經 [DBHub](https://github.com/bytebase/dbhub) 容器連 SQL Server，讓 agent 能查詢 / 操作資料庫。讀取 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml` 的連線設定。
- **SessionStart advisory hook** — 於 peer worktree 缺 `dbhub.local.toml` 時提示（MCP 將無法啟動）；advisory（不 block session），專案未使用 db 時 no-op。

## 設定

1. 跑 `/tp-setup`：自動部署 `.turbo-plugin/dbhub.example.local.toml`（committed 範本）並提示你複製成 `.turbo-plugin/dbhub.local.toml`（gitignored）填入實際連線字串（credentials **永不**自動建立）。
2. 需要本機有 Docker（`tp-dbhub` 以 `docker run bytebase/dbhub` 啟動）。

> `.turbo-plugin/` 為四個 turbo-plugin 共用的專案根設定目錄；本 plugin 的 `tp-setup` 先跑共用 base 段建立 concern-neutral 共用檔（用標記區塊),再只寫自己的 db 相關檔,不覆蓋其它 plugin 的區塊。無 git repo 時 fail-loud（建 git/SVN 環境屬 `turbo-plugin-git-svn`）。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-three-environment-db@turbo-plugins-claude
```

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-git-svn`、`turbo-plugin-dotnet-framework-web`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊。

## 測試

兩層測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- SessionStart hook 行為測試：`tests/unit/scripts/hooks/`（non-git / dbhub 警示 / no-marker 靜默 / 未用 db 的 gate no-op 各情境）。

## License

MIT — 見 [LICENSE](LICENSE)。
