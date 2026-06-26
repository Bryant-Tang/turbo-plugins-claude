# turbo-plugin-dotnet-framework-web

.NET Framework Web 本機開發雜務 plugin（IIS Express + MSBuild）。turbo-plugins-claude marketplace 的獨立 plugin。

env-free 設計，集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

- **`tp-setup`** — 設定入口:先跑共用 base 段(建 `.turbo-plugin/` + concern-neutral 共用檔),再做 dotnet concern(`config.toml` 的 `[iis]`/`[build]`/`[run]`/`[publish]` 標記區塊、`applicationhost.config` bootstrap、`.gitignore` 的 .NET 產物區塊)。無 git repo 時 fail-loud。
- **`tp-build-dotnet-framework-web`** — 用 MSBuild 建置 .NET Framework Web 專案(csproj 或整個 `.sln`)。
- **`tp-run-dotnet-framework-web`** — 以 IIS Express 啟動某個 csproj 的站台。
- **`tp-stop-dotnet-framework-web`** — 停止某個 csproj 對應的 IIS Express 站台。
- **`tp-publish-dotnet-framework-web`** — 發佈某個 csproj,並以固定模板輸出終端可點擊的路徑。
- **`tp-cleanup-orphan-iis`** — 清理孤兒 IIS Express 程序 / 站台。

### 行為模型:給 agent 用的 VS 2022

build / run / stop / publish 設計成「給 agent 用的 VS 2022」:**由 agent 判斷**要操作哪個 csproj / `.sln`
與 configuration / platform / pubxml(看 context、查記憶、不確定就問),把明確參數傳給變薄的執行器。執行器
**對齊 VS**——agent 沒指定的 configuration / platform 一律省略,交 MSBuild / `.sln` / `Directory.Build.props`
/ pubxml 自行解析(不再硬帶 Debug / Release)。每次執行用固定模板回報 **agent 傳入值 + 執行器解析後的實際
target**(糾錯閘:讓你確認操作的是不是對的專案);選擇若與記憶不同,會問你要不要存回專案記憶。

- **目標**:build 預設整個 `.sln`(大改)或單一 csproj(小改、agent 判斷);run / stop / publish 只接受 csproj。
- **記憶(VS `.suo` 類比)**:走既有兩層設定查找,每個操作各自的 key——`[build].project`(可為 `.sln`)、
  `[run].project`(無值時 fallback `[build].project`)、`[publish].project` / `[publish].default_pubxml`。
  執行後若與記憶不同,`AskUserQuestion` 問存 committed(`config.toml`)/ 存 local(`config.local.toml`)/
  撤回省略 / 不存。stop 只回報、不存回。

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
