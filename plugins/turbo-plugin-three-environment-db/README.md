# turbo-plugin-three-environment-db

三環境 DB 開發輔助 plugin。turbo-plugins-claude marketplace 的獨立 plugin。

## 內容

- **`tp-setup`** skill — 設定入口:先跑共用 base 段（建 `.turbo-plugin/` + concern-neutral 共用檔），再做 db concern（部署 `dbhub.example.local.toml` 範本、提示複製填 `dbhub.local.toml`、peer-mode 處理 per-peer `dbhub.local.toml`）。無 git repo 時 fail-loud。`tp-db-management` 靠 skill 自身 description 讓 agent 主動觸發（`conventions.md` 機制已退役）。
- **`tp-db-management`** skill — DB 相關開發雜務（SQL 腳本撰寫等），附 `assets/sql-script-template.sql`。
- **`tp-dbhub`** MCP server（`.mcp.json`）— 經 [DBHub](https://github.com/bytebase/dbhub) 連 SQL Server，讓 agent 能查詢資料庫。
  設定檔的位置由 `scripts/start-dbhub.js` 解析：**工作區根**的 `.turbo-plugin/dbhub.local.toml` 優先；沒有的話往下掃**直屬子資料夾**，剛好一個就用它；
  好幾個就停下來把它們列出來，請你在工作區根放一份指明要用哪個。找不到時**乾淨結束並說明原因**（exit 0，不會讓 MCP server 看起來像掛掉）。
  這一層存在的理由：`${CLAUDE_PROJECT_DIR}` 是 session 開啟的那一層，在「並排放著多個專案」的工作區永遠不會是任何一個專案。
- **SessionStart advisory hook** — 兩種情況出聲：本機沒有 Node.js（`tp-dbhub` 必然起不來），或在 peer worktree 缺 `dbhub.local.toml`。
  advisory（不 block session），專案未使用 db 時 no-op。

## 前置需求

**只需要 Node.js。** `tp-dbhub` 以 `node scripts/start-dbhub.js` 啟動，它解析出設定檔位置後用
`npx @bytebase/dbhub@<釘死的版本>` 跑起來——**不需要 Docker，也不掛載任何路徑**。

> **為什麼是 node，而且為什麼只有這一支腳本是 `.js`**
>
> plugin 的 `.mcp.json` 只吃字面的 `command`，**沒有平台條件式**；而且 Claude Code 是**直接 spawn**
> 它，不像 hook 那樣走 Claude Code 自己的 shell。差別在 Windows 上是致命的：
>
> | PATH 上的名字 | 實際是什麼 |
> |---|---|
> | `bash` | `C:\WINDOWS\system32\bash.exe` = **WSL 轉接器**，沒裝 distro 就 `execvpe(/bin/bash) failed` |
> | `sh` | **不存在** |
> | `git` | `C:\Program Files\Git\cmd\git.exe`；Git 的 `bash.exe` 在 `bin\`，**不在 PATH 上** |
>
> 所以 `"command": "bash"` 在標準 Git for Windows 機器上一定起不來——即使你天天在用 Git Bash。
> （曾經就這麼出貨過，因為本 plugin 的 hook 用 `bash` 一直是好的；但 hook 和 MCP 的前提不一樣。）
> `node` 是三個平台**同名都在 PATH 上**的唯一選擇。因此這裡是一支 `.js` 而不是慣例的 `.ps1` + `.sh`
> 成對——那條規則的目的是「兩個平台不會漂移」，單一實作更直接達成它，而且兩套測試（Pester + shUnit2）
> 都驅動這同一支腳本，對稱性仍然有人守。
>
> **沒有 Node.js 時會怎樣**：MCP server 在我們的程式碼跑起來之前就死了，`/mcp` 只有一個紅叉，
> 原因埋在 debug log。所以 `tp-setup` 會在設定當下 probe `node --version`，SessionStart hook 也會
> 在「這個專案有用到資料庫但沒有 node」時補講一次。

### dbhub 版本是釘死的

`scripts/start-dbhub.js` 的 `DBHUB_SPEC` 釘死到 patch 版。**故意的**：浮動版本是拿「可能過期」去換
「某天早上無預警壞掉、而且查不出原因」，而只有前者能靠提醒補救。
`.github/workflows/dbhub-version-check.yml` 每月比對 npm registry，落後就開 issue 通知。

**升級步驟**：改 `DBHUB_SPEC` → 跑本 plugin 的測試 → **手動對真實資料庫起一次確認**
（測試斷言的是「會下什麼指令」，不驗 dbhub 自己的行為）。

## 設定

1. 跑 `/tp-setup`：自動部署 `.turbo-plugin/dbhub.example.local.toml`（committed 範本）並提示你複製成 `.turbo-plugin/dbhub.local.toml`（gitignored）填入實際連線字串（credentials **永不**自動建立）。
2. 填好之後**重開 session**，`tp-dbhub` 才會連上。

> `.turbo-plugin/` 為四個 turbo-plugin 共用的專案根設定目錄；本 plugin 的 `tp-setup` 先跑共用 base 段建立 concern-neutral 共用檔（用標記區塊),再只寫自己的 db 相關檔,不覆蓋其它 plugin 的區塊。無 git repo 時 fail-loud（建 git/SVN 環境屬 `turbo-plugin-git-svn`）。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-three-environment-db@turbo-plugins-claude
```

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-git-svn`、`turbo-plugin-dotnet-framework`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊。

**相依 `turbo-plugin-feedback`**（安裝時自動一起裝上，不必自己裝）：它只有一個 skill `/tp-report-issue`，
用途是把你遇到的 turbo-plugin bug 或沉默失敗整理成 issue 送出，含**送進 public repo 前的消毒規則**。
相依宣告不帶版本約束，理由見 `turbo-plugin-feedback/README.md`。

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- SessionStart hook 行為測試：`tests/unit/scripts/hooks/`（non-git / dbhub 警示 / no-marker 靜默 / 未用 db 的 gate no-op 各情境）。

## License

MIT — 見 [LICENSE](LICENSE)。
