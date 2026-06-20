# turbo-plugin-dotnet-framework-web

.NET Framework Web 本機開發雜務 plugin（IIS Express + MSBuild）。是單體 `turbo-plugin`（v0.6.0）拆出的四個獨立 plugin 之一。

env-free 設計，集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

- **`tp-build-dotnet-framework-web`** — 用 MSBuild 建置 .NET Framework Web 專案。
- **`tp-run-dotnet-framework-web`** — 以 IIS Express 啟動站台。
- **`tp-stop-dotnet-framework-web`** — 停止 IIS Express 站台。
- **`tp-publish-dotnet-framework-web`** — 發佈,並以固定模板輸出終端可點擊的路徑。
- **`tp-cleanup-orphan-iis`** — 清理孤兒 IIS Express 程序 / 站台。

## 設定

- 需 Windows + IIS Express + MSBuild（VS 2017/2019/2022 任一）。
- MSBuild / IIS Express 路徑寫在 `.turbo-plugin/config.local.toml` 的 `[tools]`（gitignored、機器專屬）；找不到時 `/tp-*` skill 會引導跑 setup 偵測。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-dotnet-framework-web@turbo-plugins-claude
```

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-git-svn`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊。

## 測試

兩層測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 各腳本、`lib` helper（IisHelpers / ApplicationHostHelpers / Common 的 dotnet concern）、EnterWorktree hook 的行為測試；缺 MSBuild / IIS 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
