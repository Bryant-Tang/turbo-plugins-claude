# turbo-plugin-dotnet-framework

.NET Framework Web 本機開發雜務 plugin（IIS Express + MSBuild）。turbo-plugins-claude marketplace 的獨立 plugin。

env-free 設計，集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

> **沒有 setup 指令**——需要什麼就在用到的時候才建,跟 Visual Studio 一樣(VS 的 `applicationhost.config`
> 也是第一次執行專案時才出現,不是裝好 VS 就有)。`applicationhost.config` 由第一次 `/tp-run` 依 csproj 產生;
> 設定檔與其中的區塊由「要寫它的那一方」自己建。詳見〈設定〉。

- **`tp-build-dotnet-framework`** — 用 MSBuild 建置 .NET Framework Web 專案(csproj 或整個 `.sln`)。
- **`tp-run-dotnet-framework`** — 以 IIS Express 啟動某個 csproj 的站台。
- **`tp-stop-dotnet-framework`** — 停止某個 csproj 對應的 IIS Express 站台。
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
  - `.turbo-plugin/applicationhost.config` — 第一次 `/tp-run` 時,**以 IIS Express 自帶的
    `AppServer\applicationhost.config` 為底**、加上依 csproj 的 `<IISUrl>` / `<IISExpressSSLPort>` /
    `<IISExpressUseClassicPipelineMode>` 合成的站台產生(站台名 = 專案名、physicalPath 是佔位符,
    所以這個檔可以進版控、跨同事跨 worktree 共用)。同一份檔案可以放多個 web 專案的站台。
    - 它會有一千行左右——那是 IIS Express 真正需要的內容(`<configSections>` 宣告 +
      `<system.webServer>` 的模組表),少了就直接拒絕載入。Visual Studio 的
      `.vs/<sln>/config/applicationhost.config` 也是同樣的量級。裡面沒有機器專屬絕對路徑,
      只有 `%IIS_BIN%` 這類由 IIS Express 自行展開的變數。
    - 如果既有的那份是舊版產生的、IIS Express 載不進去,下次執行會自動重建並保留站台設定。
  - `.turbo-plugin/config.toml` 的 dotnet 區塊 — 由記憶存回在寫入時自己建立(含標記區塊與 section)。
    `[iis] enabled` 未設定即視為啟用;要停用 IIS 相關 skill 才需要手動寫 `enabled = false`。
  - MSBuild / IIS Express 路徑寫在 `.turbo-plugin/config.local.toml` 的 `[tools]`(gitignored、機器專屬),
    **只在自動探測失敗時才需要**;skill 會自己探測標準安裝路徑,找不到才 throw 並引導你手動填。
- **不強制 git repo**:專案識別(IIS Express 站台名的後綴)優先用 `git --git-common-dir` 算——那是 repo
  裡所有 worktree 共用的根,所以同一個專案在不同 worktree 下拿到同一個身分。**不在 git work tree 內時
  改用專案資料夾自己的絕對路徑**,一樣穩定,只是失去跨 worktree 共用(沒有 worktree 的資料夾本來也用不到)。
  所以沒有版控的專案 build / run / stop / publish 都能用。
  要建 git + SVN 環境請裝 `turbo-plugin-git-svn` 跑它的 `/tp-setup`(那些動作會碰外部伺服器,不能 lazy)。
- **前端打包**(可選):在 `.turbo-plugin/config.toml` 的 `[frontend]` 設 `dir` / `install_command` /
  `build_command`(可選 `node_version`),build 與 publish 成功後會在該目錄跑安裝與打包。**沒設定也不會
  默默跳過**——skill 偵測到專案裡有 `package.json` 就會主動問要不要設定,而結果模板一律回報
  `Frontend: 已執行 (<dir>)` 或 `Frontend: 未設定`。確定不需要前端打包就寫 `[frontend] enabled = false`,
  之後不再詢問。首次執行(或指令改過)會要求確認實際要跑的指令,核准記在**主 worktree** 的
  `.turbo-plugin/pack-content-trust.local.toml`——被 hash 的兩個指令都來自進版控的 `config.toml`,
  同一個 repo 的每個 worktree 一定算出同一個值,所以新開 worktree 不會再問你一次同樣的指令。
- **哪些檔案不該進版控**(`bin/` / `obj/` / `.vs/` / 本機設定 …)由 `turbo-plugin-git-svn` 的
  `/tp-suggest-ignore` 判斷,本 plugin 不寫死清單。唯一的例外是 `*.local.*`:記憶存回在寫
  `config.local.toml` 之前會先確保 `.gitignore` 擋住它(誰寫這種檔誰負責)。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-dotnet-framework@turbo-plugins-claude
```

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-git-svn`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊。

**相依 `turbo-plugin-feedback`**（安裝時自動一起裝上，不必自己裝）：它只有一個 skill `/tp-report-issue`，
用途是把你遇到的 turbo-plugin bug 或沉默失敗整理成 issue 送出，含**送進 public repo 前的消毒規則**。
相依宣告不帶版本約束，理由見 `turbo-plugin-feedback/README.md`。

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 各腳本與 `lib` helper（IisHelpers / ApplicationHostHelpers / Common 的 dotnet concern）的行為測試；缺 MSBuild / IIS 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
