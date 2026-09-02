# turbo-plugin-three-environment-db

三環境 DB 開發輔助 plugin。turbo-plugins-claude marketplace 的獨立 plugin。

## 內容

- **`tp-setup`** skill — 設定入口:先跑共用 base 段（建 `.turbo-plugin/` + concern-neutral 共用檔），再做 db concern（部署 `dbhub.example.toml` 範本、提示複製填 `dbhub.local.toml`、寫 `config.toml` 的 `db` 標記區塊、peer-mode 處理 per-peer `dbhub.local.toml`）。無 git repo 時**照樣完成**（見下方）。`tp-db-management` 靠 skill 自身 description 讓 agent 主動觸發（`conventions.md` 機制已退役）。
- **`tp-db-management`** skill — DB 相關開發雜務（SQL 腳本撰寫等），附兩份模板
  （`assets/sql-script-template.sql` 與 `assets/module-script-template.sql`）。
  產出的 SQL 落在 `<sql_root>/<env>/<slug>/`，`<slug>` **有 git 就是當前 branch 名**（行為與
  先前相同、不會問你）；**沒有 git 才問**，而且是列出既有資料夾讓你選，不是給一個空白輸入框——
  手打會讓同一件事散進兩個名字相近的資料夾，而沒有任何東西會提醒。
- **可覆寫物件走固定檔名** — stored procedure / view / function / trigger 不落在 `<slug>/`，改落在
  `<sql_root>/<env>/_modules/<db>/{Procedures,Views,Functions,Triggers}/<schema>.<物件名>.sql`。
  用 branch 當分組鍵對「加欄位」「補資料」這種**累加型**動作是對的，但對「一改就是整個物件被取代」
  的東西會靜默出事：兩條分支各改同一支 SP，會是兩個**不同路徑**的新增檔——git 合併零衝突、兩支腳本
  都執行成功（`ALTER PROCEDURE` 覆寫既有 SP 完全合法）、沒有任何錯誤訊息，而**先跑的那份改動就沒了**。
  固定檔名讓它變成同一路徑的兩份內容，**git 必然衝突**，把資料庫層的靜默問題搬到 git 層變成吵鬧的問題。
  連帶：回滾腳本不用再寫（`git show <tag>:<path>` 就是前一版全文），「這次要跑哪幾支」也有了可靠來源
  （`git diff --name-only <tag>..HEAD`）。細節（判準、按需納管、基線必須來自目標環境）見 SKILL。
  只保證 SQL Server（靠 `CREATE OR ALTER`，2016 SP1+）。
- **SQL 落點的根目錄可自訂** — `.turbo-plugin/config.toml` 的 `[db] sql_root`。專案本來就有自己的
  慣例（`db/scripts`、`sql`、`database/migrations` …）時設它，就不必為了 turbo-plugin 多開一個
  `.turbo-plugin/sql/`。**沒設就是原本的 `.turbo-plugin/sql`，逐字元相同**，既有專案不受影響。
  底下的 `<slug>/` 那層不變。相對路徑的基準是**工作區根**（`config.toml` 那一層），
  **不接受絕對路徑**——那會讓一個進版控的檔案帶上機器路徑。換了落點時 skill 會先跑 `git check-ignore`
  確認新位置沒有被專案既有的 ignore 規則擋掉；被擋掉的話產出的 SQL 永遠不會出現在 `git status`，
  而那個失敗是完全靜默的。
- **環境名稱與數量也可自訂** — `.turbo-plugin/config.toml` 的 `[db] environments`，一個字串陣列，
  裡面的字串**就是** `<sql_root>` 底下那一層的資料夾名（原樣使用，不會再幫你加後綴）。
  **順序就是角色**：從開發端排到正式端——第一個是 `tp-dbhub` 連得到、可以自己唯讀查的那個，
  最後一個是 production（守門最嚴的一個）。數量**不限於三個**，兩層或多一層 staging 都可以，
  skill 的規則都是「對每一個環境各做一次」。

  **`dev-db` 取代了 `local-db`。** 新專案跑 `tp-setup` 會寫入 `["dev-db", "test-db", "main-db"]`。
  改這個字是因為在多數 .NET / SQL Server 團隊裡，這個環境指的是**內網的開發資料庫**，不是開發者
  本機——而本機那個概念是真的另外存在的（本機 IIS Express 站台、本機 worktree、本機設定覆蓋層），
  兩者撞在同一個詞上，每次講到 local 都要先確認是哪一個。

  **既有專案不會被動到。** 沒設這個 key 時預設仍是 `["local-db", "test-db", "main-db"]`，逐字元
  相同；`tp-setup` 也只有在 `<sql_root>` 底下**沒有**任何既有環境目錄時才寫入新的那一組。要改名
  的話有腳本代勞，它連 `.sql` 檔頭裡的環境名一起改（那些檔頭是判斷「這份基線來自哪個環境」的唯一
  線索，只改目錄名等於讓每個檔都在宣稱一件錯的事）:

  ```
  scripts/rename-db-environment.sh local-db dev-db        # Linux / macOS / Git Bash
  scripts/Rename-DbEnvironment.ps1 local-db dev-db        # Windows
  ```

  **預設是 dry run**，只印出會改什麼；確認無誤再加 `--apply` / `-Apply`。目標名稱已經存在時會停下來
  拒絕合併兩個環境。
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

1. 跑 `/tp-setup`：自動部署 `.turbo-plugin/dbhub.example.toml`（committed 範本）並提示你複製成 `.turbo-plugin/dbhub.local.toml`（gitignored）填入實際連線字串（credentials **永不**自動建立）。

> **範本原本叫 `dbhub.example.local.toml`。** 那個名字違反了「進版控的範本不用 `.local.` 命名」
> 這條規約，也害它被 `.turbo-plugin/**/*.local.*` 擋住、得靠一條 `!*.example.local.*` 放行才活得下來。
> **既有專案不必動**：SessionStart hook 兩個檔名都認，舊名照常運作；`tp-setup` 也**不會**自作主張
> 改名或多塞一份新檔名的範本（那只會讓「該複製哪一份」變成一個沒有答案的問題）。想跟上就自己
> `git mv .turbo-plugin/dbhub.example.local.toml .turbo-plugin/dbhub.example.toml`。
2. 填好之後**重開 session**，`tp-dbhub` 才會連上。

> `.turbo-plugin/` 為四個 turbo-plugin 共用的專案根設定目錄；本 plugin 的 `tp-setup` 先跑共用 base 段建立 concern-neutral 共用檔（用標記區塊),再只寫自己的 db 相關檔,不覆蓋其它 plugin 的區塊。**無 git repo 時照樣完成 setup**:它寫的東西**沒有一樣需要 git**。dbhub 本身跟版控沒有關係(不讀 branch、
不寫 repo,產出本來就 gitignored),而 `tp-db-management` 在這裡**兩半都能用**——唯讀查詢只需要 dbhub
MCP server(正是 setup 設定好的東西),產出 SQL 也照常,只是落點
`<sql_root>/<env>/<slug>/` 的 `<slug>` 會**問你**要用哪個,而不是像在 repo 裡直接拿當前
branch 名。

所以在非 repo 目錄——**多專案工作區的根正是這種形狀,而且正是最需要那份設定的地方**——setup 照常部署
範本、寫 `.gitignore` 與 `CLAUDE.md` 的 `base` 區塊、提示填 `dbhub.local.toml`、跑 node probe。
**唯一跳過的是一項驗證**:範本部署後的 `git check-ignore`(沒有 git 可問)。它**仍然不會** `git init`
(建 git/SVN 環境屬 `turbo-plugin-git-svn`)。

`.gitignore` 與 `CLAUDE.md` 的 `base` 區塊**在非 repo 目錄也會寫**,理由是同一個:兩者都是為了「哪天有人
在工作區根 `git init`」而存在——那本身是錯的,但**會發生**。`.gitignore` 在那一刻是**唯一**能擋住含
credentials 的 `dbhub.local.toml` 進版控的東西,而且必須已經就位;`CLAUDE.md` 那句「不得提交僅限本機之物」
管的則**不是這個資料夾**,是你在這裡工作時的行為——多專案工作區的根底下就是一堆 repo,你整天都在對它們
commit。

這件事由本 plugin 自己做而不外包給 `turbo-plugin-multi-repo-workspace`:非 repo 目錄不一定是多專案工作區,
而那個 plugin 也不一定有裝。

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
- 環境改名腳本測試：`tests/unit/scripts/{Rename-DbEnvironment.test.ps1,rename-db-environment.test.sh}`
  （dry run 不動任何東西 / 目錄與檔頭都改到 / 拒絕合併既有目標 / **詞邊界**——把 `test` 改名成
  `test-db` 不會把既有的 `test-db` 變成 `test-db-db`）。

## License

MIT — 見 [LICENSE](LICENSE)。
