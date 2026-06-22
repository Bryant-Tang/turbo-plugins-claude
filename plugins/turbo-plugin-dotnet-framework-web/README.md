# turbo-plugin-dotnet-framework-web

.NET Framework Web 本機開發雜務 plugin（IIS Express + MSBuild）。是單體 `turbo-plugin`（v0.6.0）拆出的四個獨立 plugin 之一。

env-free 設計，集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

- **`tp-setup`** — 設定入口:先跑共用 base 段(建 `.turbo-plugin/` + concern-neutral 共用檔),再做 dotnet concern(`config.toml` 的 `[iis]`/`[build]`/`[publish]` 標記區塊、`applicationhost.config` bootstrap、`.gitignore` 的 .NET 產物區塊)。無 git repo 時 fail-loud。
- **`tp-build-dotnet-framework-web`** — 用 MSBuild 建置 .NET Framework Web 專案。
- **`tp-run-dotnet-framework-web`** — 以 IIS Express 啟動站台。
- **`tp-stop-dotnet-framework-web`** — 停止 IIS Express 站台。
- **`tp-publish-dotnet-framework-web`** — 發佈,並以固定模板輸出終端可點擊的路徑。
- **`tp-cleanup-orphan-iis`** — 清理孤兒 IIS Express 程序 / 站台。

## 設定

- 需 Windows + IIS Express + MSBuild（VS 2017/2019/2022 任一）。
- 跑 `/tp-setup` 部署 `.turbo-plugin/config.toml` 的 dotnet 區塊（`[iis]` 等）與 `applicationhost.config`。`tp-setup` 用共用 base 段建立 concern-neutral 共用檔（標記區塊),只寫自己的 dotnet 區塊,不覆蓋其它 plugin。
- MSBuild / IIS Express 路徑寫在 `.turbo-plugin/config.local.toml` 的 `[tools]`（gitignored、機器專屬）；**不在 setup 詢問**——`/tp-*` skill 會自動探測標準 VS 安裝,找不到時 throw 引導你手動填入。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-dotnet-framework-web@turbo-plugins-claude
```

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-git-svn`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊。

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 各腳本、`lib` helper（IisHelpers / ApplicationHostHelpers / Common 的 dotnet concern）、EnterWorktree hook 的行為測試；缺 MSBuild / IIS 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
