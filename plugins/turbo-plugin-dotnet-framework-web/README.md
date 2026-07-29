# turbo-plugin-dotnet-framework-web

.NET Framework Web 本機開發雜務 plugin（IIS Express + MSBuild）。turbo-plugins-claude marketplace 的獨立 plugin。

env-free 設計，集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

> **沒有 setup 指令**——需要什麼就在用到的時候才建,跟 Visual Studio 一樣(VS 的 `applicationhost.config`
> 也是第一次執行專案時才出現,不是裝好 VS 就有)。`applicationhost.config` 由第一次 `/tp-run` 依 csproj 產生;
> 設定檔與其中的區塊由「要寫它的那一方」自己建。詳見〈設定〉。

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

- 需 Windows + IIS Express + MSBuild。MSBuild 來自 **Visual Studio 2017/2019/2022 任一版本,或只裝
  「Build Tools for Visual Studio」**(沒有 IDE 也可以,CI 機器就是這樣)。
- **不需要先跑任何設定指令。** 各項設定都是用到才建、且都能自我修復:
  - `.turbo-plugin/applicationhost.config` — 第一次 `/tp-run` 時依 csproj 的 `<IISUrl>` /
    `<IISExpressSSLPort>` / `<IISExpressUseClassicPipelineMode>` 產生(站台名 = 專案名、physicalPath 是佔位符,
    所以這個檔可以進版控、跨同事跨 worktree 共用)。同一份檔案可以放多個 web 專案的站台。
  - `.turbo-plugin/config.toml` 的 dotnet 區塊 — 由記憶存回在寫入時自己建立(含標記區塊與 section)。
    `[iis] enabled` 未設定即視為啟用;要停用 IIS 相關 skill 才需要手動寫 `enabled = false`。
  - MSBuild / IIS Express 路徑寫在 `.turbo-plugin/config.local.toml` 的 `[tools]`(gitignored、機器專屬),
    **只在自動探測失敗時才需要**;skill 會自己探測標準安裝路徑,找不到才 throw 並引導你手動填。
- **需要 git repo**:專案識別用 `git --git-common-dir` 算,不在 git work tree 內的話 skill 會 fail loudly。
  要建 git + SVN 環境請裝 `turbo-plugin-git-svn` 跑它的 `/tp-setup`(那些動作會碰外部伺服器,不能 lazy)。
- **哪些檔案不該進版控**(`bin/` / `obj/` / `.vs/` / 本機設定 …)由 `turbo-plugin-git-svn` 的
  `/tp-suggest-ignore` 判斷,本 plugin 不寫死清單。唯一的例外是 `*.local.*`:記憶存回在寫
  `config.local.toml` 之前會先確保 `.gitignore` 擋住它(誰寫這種檔誰負責)。

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
- 各腳本與 `lib` helper（IisHelpers / ApplicationHostHelpers / Common 的 dotnet concern）的行為測試；缺 MSBuild / IIS 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
