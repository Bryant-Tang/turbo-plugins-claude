---
name: tp-db-management
description: 'Use proactively for any database or SQL work: inspecting schema/data/objects, or preparing seed, migration or deployment SQL. Inspect read-only through the DBHub MCP server and write standardised SQL to `<sql_root>/<env>/<slug>/`, or to `<sql_root>/<env>/_modules/` under a fixed filename when the change replaces a whole stored procedure, view, function or trigger. Both sql_root and the environment list come from `[db]` in .turbo-plugin/config.toml, defaulting to `.turbo-plugin/sql` and to local-db/test-db/main-db. Do not bypass this skill by hand-writing SQL or querying another way.'
argument-hint: 'Optional: database name 或目標環境（取自 [db] environments）'
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, mcp__tp-dbhub__execute_sql, mcp__tp-dbhub__run_sql, mcp__tp-dbhub__search_objects, mcp__tp-dbhub__list_tables, mcp__tp-dbhub__list_schemas, mcp__tp-dbhub__get_table_schema
---

# tp-db-management

## Purpose

兩件事：

1. **唯讀檢視資料庫** — 透過 `tp-dbhub` DBHub MCP server 查 schema、資料、stored procedure、function、index 等，幫助理解結構後再改 code。**只讀不寫**。
2. **標準化 SQL 輸出** — 若工作需要任何寫入側的資料庫異動（補資料 / 改 schema / seed / backfill / migration），不直接透過 MCP 執行寫操作，而是產出標準化 `.sql` 檔，供使用者在各環境手動執行。落點有兩種:**累加型**變更落在 `<sql_root>/<env>/<slug>/`,**取代型**物件(stored procedure / view / function / trigger)落在 `<sql_root>/<env>/_modules/` 的固定檔名。判準見下方「可覆寫物件走固定檔名」。

本 skill 是從舊 dev-flow `db-management` 移植來的 **de-coupled 版本**：移除了所有 spec / work-item /
`finish-dev` 自動歸檔等 dev-flow 耦合,累加型變更只保留**單一分組鍵** `<slug>`——**有 git 就是當前
branch 名**,沒有才問使用者。第 1 件事(唯讀檢視)完全不需要 git;需要 git 的是分組鍵,以及固定檔那半的
基線驗證。

## DBHub MCP server（read-only）

- MCP server 名稱：`tp-dbhub`（宣告於 `plugins/turbo-plugin-three-environment-db/.mcp.json`：用 **node** 跑 `scripts/start-dbhub.js`，它找出設定檔位置後以 npm 套件 `@bytebase/dbhub`（釘死版本）啟動，config 來自 `.turbo-plugin/dbhub.local.toml`）。**需要本機有 Node.js**。
- 用 `tp-dbhub` 暴露的 **唯讀** MCP tool 查詢：執行查詢的 tool（execute / run SQL）、物件搜尋的 tool（search objects / list tables / get table schema 等）。實際 tool 名稱後綴可能依 DBHub 版本不同，先確認當前 session 暴露的 `tp-dbhub` tool 集再呼叫。
- **DBHub 連的是環境清單裡的第一個**（開發端那個，預設 `local-db`），不直接連後面任何一個。其餘環境的物件定義差異要靠使用者在目標環境跑你提供的最小唯讀查詢來確認（見下方 Fixed Constraints）。

## SQL 輸出落點（KTD10 — 關鍵 de-coupling）

**累加型**變更（新增欄位 / 新增表 / 新增索引 / 資料修正）落在：

```
<sql_root>/<env>/<slug>/<order>-<database>-<purpose>.sql
```

**取代型**物件（stored procedure / view / function / trigger）走另一個落點,見「可覆寫物件走固定檔名」。
下面這幾節先講兩者共用的 `<sql_root>` 與 `<env>`,以及只有累加型才用得到的 `<slug>`。

- `<sql_root>` = SQL 樹的根目錄。見下方「決定 `<sql_root>`」。
- `<env>` = 目標資料庫環境的資料夾名，**取自專案設定**。見下方「決定 `<env>`」。
  **它是完整的資料夾名,不要再加後綴** —— 預設清單是 `local-db` / `test-db` / `main-db`,
  所以路徑就是 `<sql_root>/local-db/…`，不是 `<sql_root>/local-db-db/…`。
- `<slug>` = 這批 SQL 屬於哪件事的分組鍵。**來源看有沒有 git,語意完全相同**——見下方「決定 `<slug>`」。
- `<order>` = 2 位數執行順序（`01` / `02` / `03`…）。
- `<database>` = 實際目標資料庫名。
- `<purpose>` = 簡短用途描述，建議繁體中文（如 `補資料` / `新增欄位` / `重建索引` / `建立測試資料`）。
- **同一個邏輯變更** 在各環境之間用 **相同 `<slug>` 子資料夾名 + 相同檔名**，方便對齊。

### 決定 `<sql_root>`

讀 `.turbo-plugin/config.toml` 的 `[db] sql_root`。

> **只讀這一個檔,不要去看 `config.local.toml`。** 別的設定確實有「local 逐 key 覆寫」那條鏈,但那是
> `Core.ps1` / `core.sh` **真的實作**出來的合併邏輯,而這支 skill 沒有任何 script——落點完全由你照這份
> 文件讀檔決定,沒寫進來的步驟就不會發生。
>
> 而且這個 key **不該**被單機覆寫:`config.local.toml` 是給機器差異用的(工具路徑、credentials),
> 但 `sql_root` 決定的是**進版控、要給全隊看的**產物落在哪裡。一個人在自己機器上改掉它,結果是同一個
> repo 裡長出兩棵平行的 SQL 樹、`<slug>` 再也對不齊——而且沒有任何東西會提醒,因為兩邊的檔案都正常
> 進了版控。這個值是專案慣例,不是機器設定。

**沒有這個 key、或值是空字串 → `.turbo-plugin/sql`。** 這是預設,而且**必須跟以前逐字元相同**——
沒設過這個 key 的專案不該察覺到任何差異。

有值的話,**先驗這四件事,任何一項不過就停下來報錯,不要自己改寫成一個看起來能用的路徑**:

| 拒絕 | 為什麼 |
|---|---|
| **絕對路徑**(`C:\...`、`/var/...`、`\\server\...`) | `config.toml` 進版控。一條機器路徑會讓同事 clone 下來就壞,而且違反本 repo「不得提交僅限本機才有的東西」。 |
| **跑到工作區根外面**(`../shared-sql` 這種) | SQL 之所以有價值是因為它跟專案一起進版控;跑到外面就兩者都失去。 |
| **含 `..` 的任何一段** | 就算最後沒跑出去,也讓落點難以一眼看懂。要哪個目錄就直接寫哪個。 |
| **空白開頭 / 結尾,或結尾是 `.`** | Windows 會**默默**把它去掉,於是設定字串與實際資料夾名不同。 |

**基準點是工作區根**——也就是 `.turbo-plugin/` 的上一層,**不是** agent 當下的工作目錄。這件事不講死,
在子目錄工作時會靜默落在錯的地方:`db/scripts` 會變成 `<子目錄>/db/scripts`,而且一路都不會報錯。
末尾的 `/` 有沒有都接受(去掉再用)。

**驗完之後、開始寫檔之前,對算出來的落點跑一次 `git check-ignore`**(在 git work tree 裡才跑)。
**被 ignore 就停下來講清楚**,不要照樣寫下去:專案可能本來就 ignore 了 `sql/` 或 `db/` 之類的目錄,
而那會讓產出的 SQL **永遠不出現在 `git status`**——檔案在硬碟上、內容也對,只是沒有人會看到它,
也永遠傳不到同事手上。這正是預設落點 `.turbo-plugin/sql/` 刻意不進 gitignore 的那個性質,換了地方
就得重新確認一次。

### 決定 `<env>`

讀 `.turbo-plugin/config.toml` 的 `[db] environments`,那是一個字串陣列。**跟 `sql_root` 同一個檔、
同一條理由:只讀 `config.toml`,不要去看 `config.local.toml`。** 環境清單決定的是進版控、要給全隊看的
產物落在哪裡,不是機器差異。

**沒有這個 key、或值是空陣列 → 看 `<sql_root>` 底下實際有什麼再決定,不要用一個寫死的清單:**

| `<sql_root>` 底下的情況 | 用哪一組 | 為什麼 |
|---|---|---|
| 已經有 `local-db/` / `test-db/` / `main-db/` 之中**任何一個** | `["local-db", "test-db", "main-db"]` | 那棵樹已經在了。換一個名字不會搬動它,只會讓新檔案落到旁邊,舊的整棵原地變孤兒。 |
| 一個環境目錄都沒有（或 `<sql_root>` 還不存在） | `["dev-db", "test-db", "main-db"]` | 沒有東西會變孤兒,直接用現行的一組。 |

**這跟 `tp-setup` 寫入 `environments` 時用的是同一個判準**,兩邊必須一致 —— 不一致的話,同一個專案
在「跑過 setup」與「還沒跑過 setup」兩種狀態下會把 SQL 寫到不同的地方,而那個差異沒有任何東西會提醒。

> **為什麼 fallback 不是單純寫死 `["local-db", …]`。** 那樣的話,一個裝了 plugin、跑過舊版 `tp-setup`
> （所以 config 裡沒有這個 key）、但**還沒產過任何 SQL** 的專案,會被推去建一棵全新的 `local-db/`
> ——它明明沒有任何既有落點要遷就。判準是「磁碟上有沒有既有的樹」,不是「跑沒跑過 setup」。
>
> **也不是單純寫死 `["dev-db", …]`。** 那會讓既有專案的落點在升級 plugin 的當下就改掉,而且是靜默的。

**清單裡的字串就是資料夾名,原樣使用。** 不要幫它加 `-db` 後綴、不要改大小寫、不要把 `/` 正規化掉。
設 `["dev", "test", "main"]` 的專案,落點就是 `<sql_root>/dev/<slug>/`。

#### 順序就是角色,沒有第二個 key 標記它

清單**從開發端排到正式端**。位置是唯一的標記,所以這幾條都靠它:

| 位置 | 角色 | 這份文件後面怎麼用它 |
|---|---|---|
| **第一個** | 你自己連得到、`tp-dbhub` 唯讀查得到的開發環境 | `SELECT OBJECT_ID(...)` 這類確認可以自己跑;只在開發環境驗證、測完回滾的腳本只落在這裡 |
| **中間每一個** | 過版路上的環境（測試 / staging …） | 連不到,要請使用者在該環境跑最小唯讀查詢 |
| **最後一個** | production | 連不到,而且是守門最嚴的一個:基線必須來自它自己、要驗基線 commit |

**只有一個環境的清單是合法的**(那就同時是第一個與最後一個,production 的守門照樣適用)。
**數量不限於三**：兩層、四層都可以,下面每一條規則都是「對清單裡的每一個環境各做一次」,
不假設數量——看到「各環境」「每一個環境」就是這個意思。

**排反了不會有任何錯誤訊息。** 沒有東西驗得出「這個名字聽起來像 production」,所以順序錯的後果是
守門保護錯對象:production 被當成開發端(於是你會拿它當可以隨便查的環境),開發端被當成 production
(於是你會為它要求基線 commit)。設定檔的註解有講,但**你讀到一個看起來可疑的順序時要說出來**
——例如清單是 `["main-db", "test-db", "dev-db"]`,那八成是反的。

#### 值不合法就停下來,不要自己修

任一項不過就報錯,說出哪裡不行、要使用者改 `config.toml`:

- **不是陣列**(寫成 `environments = "dev-db"` 這種單一字串)。
- **空字串成員**,或前後有空白 / 結尾是 `.` 的成員 —— Windows 會**默默**把結尾的空白與 `.` 去掉,
  於是設定字串跟實際資料夾名不同。
- **含路徑分隔符（`/`、`\`）或 `..` 的成員** —— 環境是 `<sql_root>` 底下的**一層**,不是一段路徑。
- **重複的成員** —— 兩個一樣的名字會讓「各環境各一份」變成同一個檔寫兩次,而且不會報錯。

#### 設定改了、目錄還沒改名 → 停下來,這是靜默失敗的入口

**開始寫檔之前,列一次 `<sql_root>` 底下實際有哪些目錄。** 出現**不在清單裡**的環境目錄時
（例如清單已經是 `dev-db` 而磁碟上還有 `local-db/`），**停下來講出來,不要照著新名字建新目錄**。

照著建的後果是:新檔案落進 `dev-db/`,舊的整棵 `local-db/` 樹原地變成孤兒 —— 檔案還在、git 也乾淨、
沒有任何一步報錯,只是這支 skill 從此再也不會看它一眼。而「同一件事在各環境用相同 `<slug>`」這個
對齊性質會從那一刻起悄悄失效。

正確的處理是先改名再繼續,而改名有腳本代勞（連 `.sql` 檔頭裡的環境名一起改）:

```
scripts/rename-db-environment.sh <舊名> <新名>      # Linux / macOS / Git Bash
scripts/Rename-DbEnvironment.ps1 <舊名> <新名>      # Windows
```

預設只印出會改什麼、不動任何檔案;確認無誤再加 `--apply` / `-Apply`。

> 反過來,清單裡有、磁碟上還沒有的目錄**是正常的** —— 那只表示那個環境還沒有任何腳本,
> 要寫的時候建起來就好。只有「磁碟上有、清單裡沒有」才是要停下來的那一種。

### 決定 `<slug>`

先判斷在不在 git work tree 裡:

```bash
git rev-parse --is-inside-work-tree
```

回 `true` 走下面第一條;**指令失敗或回 `false`** 走第三條(非 work tree)。不要用「有沒有 `.git` 資料夾」
自己判斷——linked worktree 的 `.git` 是一個檔案而不是目錄,而 bare repo 沒有 work tree。

**在 git work tree 裡 → 用當前 branch 名,不問使用者。** 這是絕大多數情況,行為與先前完全相同:

```bash
git rev-parse --abbrev-ref HEAD
```

然後 **把名稱中的所有 `/` 換成 `-`**（`feature/x` → `feature-x`、`bugfix/login-2` → `bugfix-login-2`）。
這維持單層分組鍵、避免巢狀路徑，也避免 `x` 與 `feature/x` 混淆。**不要因為底下多了「用問的」這條路
就開始問** —— branch 名的價值不只是自動,還有**唯一**:同一件事在不同 session 一定得到同一個字串。

**branch 名以底線開頭 → fail loudly**,請使用者改用不以底線開頭的分支名。底線開頭是保留給 `_modules/`
這種**不是分組鍵**的兄弟目錄的（見下方「可覆寫物件走固定檔名」），而 `git branch _modules` 是合法的。
不要自己改寫掉那個底線:改寫會讓使用者拿到一個跟分支名不同的資料夾名,而且下次同一條分支可能落到
另一個地方。

**`HEAD` 為 detached（指令回 `HEAD` 字面）→ 仍然 fail loudly**,請使用者先 checkout 一個具名 branch。
**不要**改用「問名字」補救:在 repo 裡處於 detached HEAD 通常代表使用者的狀態不對(為了看某個版本
checkout 了一顆 commit、忘了切回去),而在那裡做的 commit 很容易掉。擋下來是在**指出這件事**;
問一個名字則是把它蓋掉,讓人在危險的狀態下繼續。

**不在 git work tree 裡（例如多專案工作區的根）→ 問使用者。** 那裡從來就沒有分支這回事,跟上面那種
「在 repo 裡站錯地方」不是同一種情況。問法有規定:

1. **先列出既有的分組鍵讓使用者選**,「開一個新的」是另一個選項。

   **候選要掃所有環境目錄的聯集** —— 環境清單裡**每一個**環境底下**所有**既有資料夾名,
   **去重**後一起列出,**不是只看這次要寫入的那一個環境**。
   **但要濾掉底線開頭的目錄** —— `_modules/` 跟 `<slug>` 是同一層的兄弟,可是它**不是分組鍵**;
   把它列進候選會讓使用者選到一個保留目錄,而那之後寫進去的一次性腳本不會有任何東西攔。

   **濾掉的若不只 `_modules/`,要講出來,不要默默吞掉。** 底線開頭是**後來才加的**規則,所以有可能
   遇到規則上線前手建的底線開頭 `<slug>` 資料夾(當時完全合法)。它現在兩邊都進不去:候選清單濾掉它,
   黑名單也不讓人再打一次同樣的字串 —— 它變成一個這支 skill 再也寫不進去的孤兒目錄。
   **這個結果是刻意的**(規則要成立就不能有例外),但**不可以是無聲的**:遇到時要列出那些目錄、說明
   它們是舊規則下建的、這支 skill 不再寫入,並建議把它改名成不以底線開頭的名字。默默濾掉的話,
   使用者只會看到候選清單裡少了一個他記得存在的名字,然後開一個新的 —— 那正是「先列既有的讓人選」
   這條規則本來要防的事。
   > 這一點是這條規則能不能成立的關鍵。同一件事常常**跨 session、分次完成不同環境**(先在開發端
   > 驗證,之後才決定要不要往後面的環境推 —— 下方「環境資料夾」表格與 Decision Rules 明文支援這個
   > 流程)。只掃當前環境的話:第一次建了 `local-db/補資料/`,第二次要補 `main-db` 時 `main-db/` 底下
   > 還沒有那個名字,候選清單是**空的**,使用者又得手打——正好回到這裡要防的問題。
   > （這個例子用的是預設清單的名字;規則本身對任何清單都成立。）

   **不要只給一個空白輸入框。** 手打會讓同一件事變成「補會員資料」和「補會員資料v2」兩個資料夾,
   而**沒有任何東西會提醒**。既有資料夾就是這個專案的分組鍵清單,拿它當候選比任何提示都準,而且它是
   從現實推導出來的、不會過期。
2. 使用者選「開新的」而輸入的字串,**含不合法字元就拒絕並重問,不要默默改寫**。要擋掉:
   - **空字串**(直接送出空白)。
   - **底線開頭** —— 那是保留給 `_modules/` 這種非分組鍵目錄的,而且候選清單會把底線開頭的目錄濾掉,
     所以一個底線開頭的 `<slug>` 建出來之後**再也不會出現在候選裡**,下次同一件事必然又手打一個新的。
   - 路徑分隔符（`/`、`\`）、`..`、空白。
   - Windows 檔名不允許的字元（`: * ? " < > |`）。
   - **結尾是 `.` 或空白**的名稱 —— Windows 會**默默把它去掉**,於是使用者打的字串跟實際資料夾名不同,
     而那正是這條規則在防的事。
   - **Windows 保留裝置名**(`CON` / `PRN` / `AUX` / `NUL` / `COM1`–`COM9` / `LPT1`–`LPT9`,不分大小寫,
     含帶副檔名的形式如 `NUL.txt`)—— 用它們當資料夾名在 Windows 上會失敗或行為詭異。

   訊息要**說明哪裡不行**（例如「名稱不能含空白,請改用 `-`」），不要只回「無效」。
   - **為什麼不沿用 branch 名那套 `/` → `-` 的改寫**:那是**機器給的**輸入,使用者沒有機會重打;
     人打的字串應該要求打對。默默改寫會讓他拿到一個跟自己打的不一樣的資料夾名,而且下次打一個稍微
     不同的字可能落到**另一個**資料夾——那正是這裡要防的事。

`<sql_root>` **進 git 版控**（可分享的 SQL，與 gitignored 的 `.turbo-plugin/worktrees/` 區隔）。預設落點
`.turbo-plugin/sql/` 天生就滿足這件事:`.gitignore`（由 tp-setup 寫入）只忽略 `.turbo-plugin/worktrees/`
與 `*.local.*`，**不** 忽略它。**換到別的地方就不再是天生的**——所以上面那條 `git check-ignore` 是
必要的,不是保險。無論落在哪裡,產出的 SQL 檔都應正常出現在 `git status`。

## 可覆寫物件走固定檔名（`_modules/`）

### 為什麼落點要分兩種

`<slug>` 記的是**「哪一次異動」**。對**累加型**動作（新增欄位 / 新增表 / 新增索引 / 補資料）這是對的:
兩條分支各做各的,兩支都跑、兩件事都在;真的撞到（例如同名欄位）SQL Server 會**明確報錯**。

但 stored procedure / view / function / trigger 的變更語意是**取代** —— 整個物件被換掉。取代型動作的
身分是**被取代的那個東西**,不是「哪條分支改的」。用異動鍵當分組鍵會這樣壞:

```
feat/A 改了 USP_XXX  →  main-db/feat-A/01-<DB>-調整某某.sql
feat/B 也改了 USP_XXX →  main-db/feat-B/01-<DB>-調整另一件.sql
```

兩個**不同路徑**的新增檔。三個環節各自都沒有異狀,所以沒有任何一處會叫:① git 眼中它們毫無關係,
合併零衝突;② 兩支腳本在資料庫上都執行成功（`ALTER PROCEDURE` 覆寫一個已存在的 SP 完全合法）;
③ 結果沒有任何錯誤訊息,資料庫裡就是最後那一版。**先跑的那份改動就沒了**,而要發現它只能靠有人事後
回頭比對「我上次改的那幾行還在不在」—— 實務上不會有人這樣做。

固定檔名讓「兩條分支改同一個物件」變成**同一個路徑的兩份不同內容 → git 必然衝突**,把一個資料庫層的
靜默問題搬到 git 層變成一個吵鬧的問題。連帶拿到兩件事:回滾腳本不必再寫（`git show <tag>:<path>`
就是前一版全文）,以及「這次要跑哪幾支」有可靠來源（`git diff --name-only <tag>..HEAD -- <sql_root>/<env>/`）。

### 判準:SQL Server 有沒有 `CREATE OR ALTER`

**不要**去判斷「這個動作會不會蓋掉別人的」—— 那要拿捏,而拿捏錯不會報錯,等於把一個靜默失敗換成
另一個。判準是一份清單:

| 物件 | `CREATE OR ALTER` | 落點 |
|---|---|---|
| stored procedure / view / function / trigger | ✅ 有 | `_modules/` 固定檔名 |
| 其它一切（table / column / index / constraint / 資料） | ❌ 沒有 | `<slug>/` 維持現狀 |

四種,沒有第五種。判準跟 T-SQL 自己能不能表達「整份取代」對齊,所以不需要判斷力,只需要看清單。

**`ALTER TABLE … ALTER COLUMN` 刻意留在 `<slug>/`**,即使它也是取代型。兩個理由:

1. **固定檔在 table 這半會製造一個更常態的靜默失敗。** table 沒有 `CREATE OR ALTER`,固定檔裡只能放
   自製的冪等 guarded DDL,而 guard 條件必須涵蓋目標定義的**每一個**面向 —— 漏一項那一項就永遠跳過
   且無聲。實際會漏的至少有 `is_nullable`、`max_length`（是**位元組數**:`NVARCHAR(200)` 是 400、
   `NVARCHAR(MAX)` 是 -1）、以及 `ALTER COLUMN` 不帶 `COLLATE` 會**靜默套用資料庫預設 collation**
   （同一個 DB 裡混用多種 collation 是常見的,含 `_BIN` 的被換掉就是比對行為變了）。
   原本的病要「兩條分支在同一個窗口改同一個欄位」才發作;這個新病**每次執行都在**,而且錯的方向是
   「什麼都沒做卻報成功」。
2. **固定檔在這半沒有真的把問題搬到 git 層。** 它要成立得靠「就地改,不追加」,而那條約定**沒有任何
   東西擋得住**:兩條分支各在檔尾加一段 → 不同行不重疊 → git 又會自動合併 → 靜默覆蓋原封不動地活著,
   只是從兩個檔變成一個檔裡的兩段。SP 那半的保證是結構性的（同一路徑必然衝突）,這半是靠自律的,
   不是同一個東西。

改**既有**欄位 / 索引的風險改用**偵測**處理,見下方「改既有欄位 / 索引之前先掃」。

### 目錄形狀

```
<sql_root>/<env>/
├── <slug>/<order>-<database>-<purpose>.sql
└── _modules/<database>/{Procedures,Views,Functions,Triggers}/<schema>.<物件名>.sql
```

例:`main-db/_modules/AppDb/Procedures/dbo.USP_GetMember.sql`。

- **沒有 `<order>`**,固定檔不排序 —— 執行順序見下方「寫法」。
- **底線開頭的目錄不是 `<slug>`。** 這是一條規則,不是一個寫死的名字:`_modules/` 跟 `<slug>` 是同一層
  的兄弟,而 `<slug>` 來自 branch 名、**什麼字都可能**（`git branch _modules` 是合法的）。所以「決定
  `<slug>`」那節的候選清單濾掉底線開頭的目錄、黑名單也拒絕底線開頭的輸入。**底線本身只是給人看的
  標記,保證來自那兩條規則** —— 不要以為有底線就不會撞名。
- **`_modules` 這個名字取自 `sys.sql_modules`**,那個目錄檢視涵蓋的正好就是「有 T-SQL 定義本體的物件」
  = procedure / view / function / trigger = 有 `CREATE OR ALTER` 的那一組,跟上面的判準完全重合。
  **不要**改叫 `_objects`:table 也是 object,但它不在這裡面,那個名字會讓下一個人把 table 放進來。

### 每個環境各一份

`_modules/` **跟著環境清單分**,清單裡有幾個環境就有幾份,不共用一份。過版有時間差,某支 SP 上了測試
環境還沒上正式是常態;只留一份的話那一份必然含著還沒核准上正式的改動。而且 `git show <tag>:<path>`
要能取回「正式環境當時跑的那一版」,單一份檔案在 tag 當下裝的是開發端的內容。

改了其中一份之後,**回報其餘每一份的差異狀態**（哪幾份還沒跟上、差在哪裡）,但**不要自動複製過去**——
自動對齊正是「把未核准的改動推上正式」那條路徑。要不要跟進、什麼時候跟進是使用者的決定。

### 按需納管,而且是單向門

**不做全量匯出。** 一個庫可以有上千個 trigger（稽核鏡射常常每張表一個）、上百個 view,全抓進版控是
災難。**某個物件第一次被改到時才納管。**

`_modules/` 底下有沒有那個檔,**就是**「已納管」的登記簿。**物件一旦納管,之後所有對它的變更只能走
`_modules/`,不得再回到 `<slug>/`。** 所以在把任何 `ALTER PROCEDURE` / `ALTER VIEW` / `ALTER FUNCTION` /
`ALTER TRIGGER` / `CREATE OR ALTER` 寫進 `<slug>/` 之前,先確認 `_modules/` 底下沒有同名物件 —— 有的話
那支腳本放錯地方了,而放錯不會報錯。

### 首次納管:先分清楚「既有物件」還是「全新物件」

**這兩條路完全不同,而且走錯的那一邊不會卡在明顯的地方。** 先確認**該物件在這個環境到底存不存在**,
再決定走哪一條:

```sql
SELECT OBJECT_ID('<schema>.<物件名>');
```

清單裡的**第一個**環境可以自己用 `tp-dbhub` 唯讀查;**其餘每一個**環境都要**請使用者在該環境跑這句
回傳結果**（就是 Fixed Constraints 說的「最小唯讀查詢」）。

**這件事是逐環境判斷的,不是逐物件。** 同一支 SP 完全可能已經上了測試環境、還沒上正式 —— 那它在
測試那個環境是既有物件、在 production 那個環境是全新物件,兩份檔要走不同的路。

- **回傳非 NULL（既有物件）** → 走下面「既有物件」那條,基線必須從該環境抓。
- **回傳 NULL（全新物件）** → 走再下面「全新物件」那條,**不要**去 SSMS 抓基線:對一個不存在的物件
  做「編寫指令碼為 → CREATE 至」在 SSMS 裡做不到,流程會卡在那裡。**而卡住還算好的結果** —— 更糟的
  是繞過去:把這支全新 SP 改寫進 `<slug>/`（等於整個機制沒生效,而且不會報錯）,或是拿 local 的版本
  充當「正式環境的基線」（那正是下面要防的事）。

#### 既有物件:基線必須來自目標環境,而且要驗得到

**這是整個做法最危險的一步。** DBHub 只連清單裡的第一個環境（見 Fixed Constraints）,但 production
那個環境的 `_modules/` 那份基線**必須是正式環境當下的全文**。拿開發端的全文當基線的話,第一次全文
覆寫就會把開發中、還沒核准的改動整批推上正式 —— **而且腳本會執行成功,沒有任何警告**。

所以首次納管一個**既有**物件時,在**每一個**該物件已存在的環境都照這個順序,不要合併步驟:

1. **請使用者從該環境取全文**並貼回來。取得方式**必須**是 SSMS 物件總管 →「編寫指令碼為」→「CREATE 至」。
   > **不可以用 `SELECT OBJECT_DEFINITION(...)`**:它不含 `SET ANSI_NULLS` / `SET QUOTED_IDENTIFIER`
   > 兩行（那兩行跟著物件持久化,漏抄會改變物件行為）,而且在 SSMS 結果窗格會被**無聲截斷**
   > （grid 預設 65535 字元、文字模式 8192）—— 長 SP 被切一半,而切口不會報錯。
2. **原封不動寫成基線檔**（零改動）,填好檔頭的來源環境 / 取得方式 / 取得日期。
3. **請使用者把這顆基線 commit 掉**,然後跑 `git log --oneline -- <該檔路徑>` **確認那顆 commit 存在**。
   **驗不到就停在這裡,不要往下寫變更。**
4. 確認之後,才把這次的變更套進同一個檔。

這樣拆的兩個理由,少一個都不成立:

- **首次部署的回滾來源就是那顆基線 commit。** `git show <tag>:<path>` 只有在該物件**在那個 tag 時已經
  納管**才取得到前一版;首次納管那一次版控裡根本還沒有前一版,基線 commit 補的正是這個洞。
- **「基線 vs 我的改動」變成一個可審的 diff。** 混在同一顆 commit 裡的話,審的人看到的是一個 800 行的
  新檔,分不出哪四行是這次真正要改的。

**如果這個物件以前在 `<slug>/` 底下被改過**,檔頭補一行 `先前的一次性腳本: <slug>/<檔名>`,線索才不會
斷。既有專案**不遷移** —— 舊的一次性檔在原規則下本來就是不可變的歷史,搬動它反而破壞那條保證。

#### 全新物件:這個檔本身就是基線

物件在該環境不存在時,**沒有基線可抓,也沒有東西可比對** —— 直接用模板寫出完整的 `CREATE OR ALTER`,
那個檔本身就是第一版。

- **不做上面那道兩顆 commit 的門。** 那道門在防的是「拿 local 全文覆寫掉正式環境上別人的改動」,而全新
  物件底下沒有任何東西會被覆寫。硬要湊一顆「基線 commit」只會是一顆空的儀式。
- **檔頭那三欄照樣要填,填 `N/A（全新物件,無既有基線）`。** 不要留空、也不要刪掉那三行 —— 空白欄位
  看起來跟「忘了填」一模一樣,而那正是這三欄存在的理由:讓一份來源可疑的基線一眼看得出來。
- **回滾是 `DROP`,不是取前一版。** 這是全新物件唯一跟既有物件不同的回滾方式:`git show <tag>:<path>`
  在這個檔第一次進版控之前**取不到任何東西**。回報時要講明這一點。
- 之後這個物件在該環境就是**既有物件**了,再改就照一般流程直接改這個固定檔。

> **不要**因為「開發端已經有了」就把它的全文當成 production 那份的基線。同一支 SP 在開發端是既有、
> 在正式是全新,是**最常見**的情況（新功能本來就先寫在開發端）—— 而 production 那份走的是「全新物件」
> 這條,它的第一版就是要部署上去的內容,不是抄來的基線。這兩件事碰巧長得很像,但意義完全不同:
> 前者是「我知道正式環境現在長什麼樣」,後者是「正式環境還沒有這個東西」。

### 寫法（這幾條都不會報錯）

- **用 `CREATE OR ALTER`,不要 `DROP` + `CREATE`。** 後者會把物件上的 `GRANT` 一起清掉,而且
  DROP 成功 / CREATE 失敗時物件就不見了 —— 對 trigger 特別嚴重,稽核從那一刻起斷掉且不會有人發現。
- **`CREATE OR ALTER` 必須是批次裡的第一個陳述式**,所以 `USE [DB]` 之後一定要 `GO`,而且**不能**包在
  `BEGIN TRY` / 顯式交易裡。（這就是固定檔不共用 `<slug>/` 那份模板的原因:那份的版面是
  TRY/CATCH + TRANSACTION。）
- **`SET ANSI_NULLS ON` / `SET QUOTED_IDENTIFIER ON` 兩行不能漏**,各自後面接 `GO`,放在
  `CREATE OR ALTER` 之前。它們跟著物件持久化,漏抄會改變物件行為（影響索引檢視、計算欄位索引這種
  平常看不出來的地方）。
- **執行順序:`_modules/` 一律最後跑**,排在同一批 `<slug>/` 腳本之後。SP 可能引用同一批新增的欄位,
  而 `CREATE OR ALTER PROCEDURE` 有 deferred name resolution —— **建立時會成功,執行時才炸**。
- **解 `_modules/` 的 git 衝突時,兩邊的意圖都要保留。** 固定檔把靜默問題變吵鬧是進步,但如果解衝突的
  人直接挑一邊,損失跟原本一模一樣,只是這次他是知情的。看不出來能不能並存就**停下來問**,不要挑一邊。
- **只保證 SQL Server。** `CREATE OR ALTER` 是 SQL Server 2016 SP1+ 的語法。PostgreSQL 是
  `CREATE OR REPLACE`、MySQL 沒有對應語法（只能 `DROP` + `CREATE`,正是上面說不要做的）。目標不是
  SQL Server 就**停下來說明**,不要自己代換成別的寫法。

### 改既有欄位 / 索引之前先掃

`ALTER TABLE … ALTER COLUMN`、以及同名的 `DROP INDEX` + `CREATE INDEX`,留在 `<slug>/`;但**動手之前**
先掃一次 `<sql_root>/<env>/` 底下所有 `.sql`,看有沒有**別的**分組鍵動過同一個 `<表>.<欄位>` 或同一個
索引名。命中就**停下來讓使用者確認**兩邊的意圖能不能並存。

這是**偵測不是保證**:掃不到不代表沒有（寫法或格式不同就漏了）。但它的失敗方向是「多問一次」,不是
「靜默跳過」,而現況是**零偵測**。

## Fixed Constraints

- 本 repo 所有 DBHub MCP 存取 **皆唯讀**，**絕不** 透過 MCP tool 執行 `INSERT` / `UPDATE` / `DELETE` / `CREATE` / `ALTER` / `DROP` 等寫操作。
- **DBHub 連線範圍 = 環境清單裡的第一個（開發端，預設 `local-db`）only**，絕不直連它後面的任何一個；其餘環境的物件差異一律靠使用者在該環境跑最小唯讀查詢確認。
- 任何寫入側需求（資料修正 / schema 變更 / seed / backfill / migration）→ 產 `.sql` 檔到 `<sql_root>/<env>/<slug>/`，**不** 直接寫資料庫。
- **不要假設各環境結構一致**：欄位、view、stored procedure、function、trigger 都可能依環境不同。
- 若**第一個環境以外**的腳本依賴某物件定義，而該定義在那個環境可能不同 → 先給使用者一個 **最小唯讀查詢**（最好是簡單 `SELECT`），請他在目標環境跑完回傳結果，再據此 finalize 對應 SQL。**不要** 假裝 DBHub 能檢視那些環境。
- **已發佈的 SQL 視為不可變**：已透過 `tp-push-to-svn` 推到 `remote-svn/*` 且已打過 release tag 的 `.sql`，**不得**再編輯舊檔——要修正改走**新檔**（遞增 `<order>` 的新 `.sql`）。SVN history 與 release tag 是永久紀錄，改舊檔會讓已部署環境與版控對不上。
  - **`_modules/` 底下是這條的唯一例外**,固定檔的本質就是一直改同一個檔。這條規則真正的目的（讓
    已部署環境與版控對得上）在固定檔下由別的機制達成:每一版都完整留在 git / SVN history 裡,
    `git show <tag>:<path>` 隨時取得任一版本的全文。
  - **但那個替代機制綁著 tag 紀律** —— 它成立的前提是**每次部署都打了 release tag**。沒有 tag 就沒有
    「當時跑的是哪一版」這個問題的答案,於是這條規則被破例了、而替代品是空的。所以在 `_modules/`
    底下工作時,若發現上一次部署沒有對應的 tag,**要講出來**。
  - `<slug>/` 底下的一次性檔**仍然適用原規則**,不受這個例外影響。
- **版控 SQL 不得含敏感資料**：`<sql_root>`（進 git）裡的 `.sql` **不得**包含字面憑證、含密碼的連線字串、或超出該 schema 遷移所需的 PII。連線資訊一律走 gitignored 的 `.turbo-plugin/dbhub.local.toml`；SQL 內需要範例值時用 placeholder，不要寫真實機密 / 個資。

| 環境資料夾（位置 → 角色） | 用途 |
|---|---|
| **第一個**（預設 `local-db`）的 `<slug>/` | 開發環境驗證、暫時測試資料、或驗證後會回滾的腳本 |
| **中間每一個**（預設只有 `test-db`）的 `<slug>/` | 過版路上的環境部署腳本（客戶測試環境等） |
| **最後一個**（預設 `main-db`）的 `<slug>/` | production 部署腳本 |
| `<sql_root>/<env>/_modules/` | 該環境已納管的 procedure / view / function / trigger 全文（固定檔名） |

- 環境資料夾、`<slug>` 子資料夾或 `_modules/` 底下的物件類別資料夾不存在時，先建再放腳本。
- 純開發環境驗證（測完回滾）的腳本只放**第一個**環境的 `<slug>/`。
- 最終發佈版若 production 也要改 → 在**每一個**環境各備一份對齊的腳本；
  `_modules/` 同樣每個環境各一份，但每一份的基線各自來自**該環境**（見「首次納管」）。

## SQL Template

**兩份模板,對應兩種落點,不要混用:**

| 落點 | 模板 |
|---|---|
| `<slug>/` 一次性腳本 | [assets/sql-script-template.sql](./assets/sql-script-template.sql) |
| `_modules/` 固定檔 | [assets/module-script-template.sql](./assets/module-script-template.sql) |

固定檔**不能**沿用 `<slug>/` 那份:那份的版面是 TRY/CATCH + 顯式交易,而 `CREATE OR ALTER` 必須是批次
裡的第一個陳述式,包不進去。

### `<slug>/` 一次性腳本

- 用共用模板 [assets/sql-script-template.sql](./assets/sql-script-template.sql)。
- 把同一個版面複製進每個環境的 SQL 檔，讓 local / test / production 腳本保有相同的 header、執行順序、pre-check、main change、post-check 段落。
- 只在開發環境驗證的腳本沿用同模板，但只放**第一個**環境的 `<slug>/` 並填好 rollback 段落。
- production-bound 變更先為**每個**環境各建一份檔，再讓各份的註解與段落順序對齊。

### `_modules/` 固定檔

- 用 [assets/module-script-template.sql](./assets/module-script-template.sql)。
- 檔頭的**基線來源環境 / 取得方式 / 取得日期**三欄一定要填實 —— 一個放在 `main-db/_modules/` 底下、
  檔頭卻寫著來源是 local 的檔案,是肉眼看得出來的缺陷,這三欄的存在就是為了讓它看得出來。
- **沒有 rollback 段落**,那是刻意的:回滾來源是 git（`git show <tag>:<path>`),不是寫在檔案裡的一段
  反向 SQL。首次納管那一次的回滾來源則是基線 commit。

## Procedure

0. 先確認 `tp-dbhub` 的 MCP tool 這個 session 有沒有暴露出來。**沒有也照樣往下做**：跳過所有查詢步驟，依 repo 內既有的結構定義（`db/*.sql`、migration、entity 類別等）產出 SQL，並在腳本與回報裡標明「未經實際資料庫驗證」。詳見 Decision Rules 的「連不到資料庫時」。
1. 釐清本次工作相關的是哪個 connected 資料庫。
2. 若 table / column / procedure / function / index 名稱不確定，先用 `tp-dbhub` 的物件搜尋 MCP tool。
3. 用 `tp-dbhub` 的查詢 MCP tool **只查最小必要資料**（唯讀）。
4. 把資料庫查到的事實轉成需要的 code 變更或實作決策。
5. 若需要任何寫入側資料庫動作，先決定目標環境範圍：只在開發環境驗證 / 推到中途某個環境為止 /
   含 production 的完整發佈。
6. **決定落點的兩個變數 `<sql_root>` 與 `<env>`,兩件都做完再建任何資料夾**——落點錯了，後面每一件
   事都落在錯的地方。
   - `<sql_root>`，依「決定 `<sql_root>`」那一節：讀 `[db] sql_root`，沒有就用預設
     `.turbo-plugin/sql`；有值就先驗（拒絕絕對路徑 / 跑出工作區根 / 含 `..` / 前後空白或結尾 `.`），
     基準點是**工作區根**而不是當下目錄，再對算出來的落點跑 `git check-ignore` 確認它沒被擋掉。
   - `<env>` 清單，依「決定 `<env>`」那一節：讀 `[db] environments`，沒有就用預設
     `["local-db", "test-db", "main-db"]`；驗過每個成員（是陣列、成員非空、無路徑分隔符 / `..`、
     無前後空白或結尾 `.`、不重複）。**順序就是角色**：第一個是你查得到的開發端，最後一個是
     production。接著列一次 `<sql_root>` 底下的實際目錄，**出現清單裡沒有的環境目錄就停下來**
     （多半是改了設定還沒跑改名腳本），不要照著新名字建新目錄、讓舊的那棵樹變成孤兒。
7. **先分落點,再決定分組鍵。** 逐一看這次要做的每一件變更,問一句「SQL Server 對這種物件有沒有
   `CREATE OR ALTER`」：procedure / view / function / trigger **有** → 走 `_modules/`（第 9 步起）；
   其它一切（含 `ALTER TABLE … ALTER COLUMN`）**沒有** → 走 `<slug>/`（第 8 步）。一次工作可能兩種
   都有,那就兩邊都產,不要把整批塞進同一種。
8. **走 `<slug>/` 的部分** —— 決定 `<slug>` 分組鍵，依「決定 `<slug>`」那一節：**在 git work tree 裡**跑
   `git rev-parse --abbrev-ref HEAD` 把 `/` 換成 `-`（detached HEAD → fail loudly，請使用者先 checkout
   具名 branch；branch 名以底線開頭同樣 fail loudly）；**不在 work tree 裡**則列出既有資料夾讓使用者選
   （**濾掉底線開頭的目錄**），輸入不合法就拒絕重問。
   - 若 SQL 只供開發環境驗證且測完回滾 → 只建**第一個**環境的 `<sql_root>/<env>/<slug>/`。
   - 若是最終發佈且 production 也要改 → 在**每一個**環境各建一份對齊腳本。
   - 每個檔用 `<order>-<database>-<purpose>.sql` 命名，從
     [assets/sql-script-template.sql](./assets/sql-script-template.sql) 起手。
   - 含 `ALTER TABLE … ALTER COLUMN` 或同名 `DROP INDEX` + `CREATE INDEX` 時，**動手前先掃**
     `<sql_root>/<env>/` 底下所有 `.sql`，看有沒有別的分組鍵動過同一個 `<表>.<欄位>` / 索引名；
     命中就停下來讓使用者確認兩邊能不能並存。
9. **走 `_modules/` 的部分** —— 先確認這個物件在該環境**是不是第一次納管**（`_modules/<database>/<類別>/`
   底下有沒有那個檔）。反過來也要查：要寫進 `<slug>/` 的腳本裡若出現 `ALTER PROCEDURE` /
   `ALTER VIEW` / `ALTER FUNCTION` / `ALTER TRIGGER` / `CREATE OR ALTER`，而該物件**已經納管**，
   那支腳本放錯地方了。
10. **首次納管 —— 先分岔,再動手。** 用 `SELECT OBJECT_ID('<schema>.<物件名>')` 確認該物件**在這個環境**
    存不存在（**第一個**環境自己用 `tp-dbhub` 查；**其餘每一個**請使用者在該環境跑並回傳結果）。
    **逐環境判斷** —— 同一支 SP 可能在測試環境是既有、在正式是全新。
    - **既有物件**（非 NULL，每個環境各做一次，不要合併步驟）：請使用者用 SSMS「編寫指令碼為 →
      CREATE 至」從**該環境**取全文（**不可**用 `SELECT OBJECT_DEFINITION(...)`）→ 原封不動寫成基線檔
      並填好檔頭的來源環境 / 取得方式 / 取得日期 → 請使用者 commit → 跑
      `git log --oneline -- <該檔路徑>` **確認那顆 commit 存在**，**驗不到就停在這裡** → 確認之後才把
      變更套進同一個檔。
    - **全新物件**（NULL）：**不要**去 SSMS 抓基線（對不存在的物件做不到，流程會卡死，而繞過去的兩條
      路——寫進 `<slug>/`、或拿 local 版本充當正式基線——都不會報錯）。直接用模板寫出完整的
      `CREATE OR ALTER`，這個檔本身就是第一版；檔頭三欄填 `N/A（全新物件,無既有基線）`；**不做**兩顆
      commit 那道門（沒有東西會被覆寫）；回報時講明**回滾是 `DROP` 不是取前一版**。
11. **已納管**的物件直接改那個固定檔，用
    [assets/module-script-template.sql](./assets/module-script-template.sql) 的版面：`USE [DB]` + `GO`、
    `SET ANSI_NULLS ON` + `GO`、`SET QUOTED_IDENTIFIER ON` + `GO`、`CREATE OR ALTER …`（**必須是批次
    第一個陳述式**，不包 TRY/CATCH、不包交易）。**絕不**用 `DROP` + `CREATE`。
12. 改完 `_modules/` 的其中一份，**回報其餘每一個環境那幾份的差異狀態**（哪幾份還沒跟上、差在哪），
    但**不要自動複製過去**。
13. finalize **第一個環境以外**的腳本前，確認相關欄位 / view / procedure / function / trigger 在該環境是否已知相同；若不確定，給使用者最小驗證查詢並等結果。
14. 目標環境範圍從需求不明顯時，先問再建檔。
15. 每支腳本適當時加 `USE [DatabaseName]`，statement 依執行順序排，加足夠註解說明特殊步驟 / 回滾預期 / 環境差異。
16. 多個邏輯變更時優先拆成多支 SQL 檔，除非步驟必須一起執行。
17. 回報兩部分結果：唯讀檢視驗證到什麼、使用者還需要在 test / production 自行驗證什麼（若有）、以及準備了哪些 SQL 供手動執行（含落點路徑）。**同一批裡有 `_modules/` 檔時，回報要明講執行順序:
    `<slug>/` 先跑、`_modules/` 最後跑。**

## Decision Rules

- **唯讀存取**：DBHub MCP 只用來查，**永不** 透過 MCP 改資料庫。把 MCP 唯讀存取當成「可以查」不等於「可以略過 SQL 檔交付」。
- **有 git 就不要問**：在 work tree 裡,分組鍵一律是 `git rev-parse --abbrev-ref HEAD` 的結果把 `/` 換 `-`。
  branch 名的價值不只是自動,還有**唯一**——同一件事在不同 session 一定得到同一個字串,問使用者做不到。
- **detached HEAD 仍然 fail loudly**,不用「問名字」補救:那是使用者在 repo 裡的狀態不對,擋下來是在指出它。
  非 repo 目錄是另一回事(從來就沒有分支),那裡才問。
- **問的時候先列既有資料夾讓人選**,而且是**所有環境的聯集去重**,
  不是只看當前環境——同一件事常常跨 session 分次完成不同環境,只看一個環境會讓候選是空的。
  不要只給空白輸入框;輸入含不合法字元**拒絕重問,不默默改寫**。
- **底線開頭的目錄不是 `<slug>`**:候選清單要濾掉它們,黑名單也要拒絕底線開頭的輸入,branch 名以底線
  開頭則 fail loudly。底線只是給人看的標記,**保證來自這三條規則** —— `git branch _modules` 是合法的,
  不要以為有底線就不會撞名。
- **濾掉的若不只 `_modules/` 就要講出來**:這條規則是後加的,規則上線前手建的底線開頭 `<slug>` 資料夾
  會變成兩邊都進不去的孤兒。那個結果是刻意的,但**無聲的話**使用者只會發現候選少了一個名字然後開新的
  —— 正是「先列既有的讓人選」要防的事。
- **不依賴 dev-flow**：沒有 spec / work-item 概念,累加型變更的分組鍵只有 `<slug>` 一個;不做
  `finish-dev` 式自動歸檔。
- **可自訂的是 `<sql_root>` 與環境清單這兩層,再往下不行**:`<env>/<slug>/` 與 `<env>/_modules/` 的
  形狀固定。各環境對齊、`<slug>` 的推導規則、以及固定檔的「同一路徑必然衝突」都是上面一整組
  Decision Rules 與 Completion Checks 的依據,開放整段 pattern 自訂會讓它們全部失去意義。
- **環境清單讀設定,不要從磁碟上有哪些目錄反推**:目錄可能還沒建（那個環境還沒有腳本）,也可能是
  改名前留下的舊目錄。設定是唯一的來源;磁碟只用來做下面那條偵測。
- **磁碟上有、清單裡沒有的環境目錄 → 停下來**,那多半是改了設定卻還沒跑改名腳本。照著新名字建新目錄
  不會報錯,但舊的那棵樹會就地變成這支 skill 再也不看的孤兒。反過來（清單有、磁碟還沒有）是正常的。
- **落點判準只看「有沒有 `CREATE OR ALTER`」**,不要判斷「這會不會蓋掉別人的」。後者要拿捏,而拿捏錯
  不會報錯 —— 那只是把一個靜默失敗換成另一個。procedure / view / function / trigger 走 `_modules/`,
  其它一切走 `<slug>/`,清單就四個,沒有第五個。
- **`ALTER TABLE … ALTER COLUMN` 留在 `<slug>/`**,不要「順手」比照 procedure 搬進 `_modules/`:table
  沒有 `CREATE OR ALTER`,固定檔只能放自製 guarded DDL,而 guard 漏一個面向就是**每次執行都永遠靜默
  跳過** —— 比它要治的病更常態。那半的風險改用「動手前先掃同一個 `<表>.<欄位>`」偵測。
- **`_modules/` 每個環境各一份,而且每一份的基線各自來自該環境。** 拿開發端的全文當 production 那份的
  基線,會把還沒核准的改動整批推上正式,**而且腳本會執行成功、沒有任何警告**。這是這套做法最危險的一步。
- **首次納管的基線 commit 是一道可驗的門,不是建議**:寫變更之前跑 `git log --oneline -- <該檔路徑>`,
  驗不到 commit 就停。它同時是首次部署唯一的回滾來源（那個 tag 上還沒有前一版可以 `git show`）。
- **但那道門只適用於「既有物件」。** 動手之前先用 `SELECT OBJECT_ID(...)` 分清楚,而且是**逐環境**分
  （同一支 SP 在 test 是既有、在 main 是全新,是新功能過版時的常態）。全新物件沒有基線可抓:去 SSMS
  「編寫指令碼為」一個不存在的物件做不到,流程會卡死 —— 而**卡住還算好的**,更糟的是繞過去,把它寫進
  `<slug>/`（機制沒生效,不報錯）或拿 local 版本充當正式環境的基線（正是這一整套要防的事）。
  全新物件直接寫 `CREATE OR ALTER`,那個檔就是第一版,檔頭三欄填 `N/A`,**回滾是 `DROP`**。
- **`_modules/` 一律最後跑。** `CREATE OR ALTER PROCEDURE` 有 deferred name resolution,引用了同一批
  才要新增的欄位時**建立會成功、執行才炸**,所以順序不能靠運氣。
- **解 `_modules/` 衝突時不要挑一邊**:兩邊的意圖都要保留,看不出來能不能並存就停下來問。挑一邊的
  損失跟原本的靜默覆蓋一模一樣,只是這次是知情的。
- **只保證 SQL Server**:目標不是 SQL Server（PostgreSQL 的 `CREATE OR REPLACE`、MySQL 沒有對應語法）
  就停下來說明,不要自己代換成別的寫法 —— MySQL 那條代換就是 `DROP` + `CREATE`,正是要避免的。
- **`sql_root` 不合法就停下來報錯,不要自己修**:改寫成一個看起來能用的路徑會讓使用者以為自己設對了,
  然後檔案落在他沒預期的地方。說出哪裡不行、要他改 `config.toml`。
- **沒設 `sql_root` 的專案不該察覺到任何差異**:預設就是原本的 `.turbo-plugin/sql`,逐字元相同。
- **SQL 目錄進版控**：產出的 SQL 是可分享、可 commit 的；不要把它跟 gitignored 的 `.turbo-plugin/worktrees/` 混淆。預設落點不在 gitignore,**換了落點就要用 `git check-ignore` 重新確認一次**。
- 純調查（不需寫入）→ 不建 SQL 檔。
- 需要 schema discovery → 先用 `tp-dbhub` 物件搜尋 tool 再寫廣泛 `SELECT`。
- 只在開發環境的變更只放**第一個**環境的 `<slug>/`；只推到中途某個環境就放到那個環境為止；要上 production 則**每個**環境都備。
- 明顯不只在開發環境、但沒講清楚要推到哪一個環境為止 → 先問環境矩陣再寫 SQL。
- 開發端查到的結果可能與後面環境的物件定義不符 → 停止假設一致，請使用者在目標環境跑最小驗證查詢回傳結果。
- 多個資料庫要改 → 依資料庫或執行步驟拆檔。
- 腳本依賴手動後處理 / trigger 重建 / 環境特定 review → 在 SQL 註解明寫。
- **連不到資料庫時，先產腳本、不要停下來問**：當前 session 沒有 `tp-dbhub` MCP tool 時，**照樣把 SQL 產出來**，依據改成 repo 內既有的 `db/*.sql` 等結構定義。理由：這支 skill 的定位是「SQL 腳本撰寫」，而表結構通常在 repo 裡就有；停下來等連線會讓它在最常見的情境下直接不可用。
- **但要說得出「為什麼連不到」**：`tp-dbhub` 起不來時使用者只會在 `/mcp` 看到一個紅叉，原因埋在 debug log 裡。所以順帶點出最可能的三個原因，**依這個順序**檢查（都不必真的去修，講清楚即可）：
  1. **本機沒有 Node.js** — 啟動器是 node 腳本，沒有 node 它一行錯誤都印不出來。`node --version` 一測便知。
  2. **`.turbo-plugin/dbhub.local.toml` 還沒建或沒填** — 只有 `dbhub.example.toml` 範本不算數
     (改名前設定的專案叫 `dbhub.example.local.toml`,一樣不算數)。
  3. **多專案工作區裡有好幾個專案各有設定** — 這時它會刻意停下來要你在工作區根放一份指明用哪個，而不是替你猜。
  - 產出的腳本開頭與回報裡都要明寫一行：**未經實際資料庫驗證，依據是 repo 內的 `<實際依據的檔案>`**。
  - 一併說明這代表什麼風險（例如查不到現有索引 / 欄位型別可能已在該環境改過），並提議「要接上連線驗證嗎」讓使用者決定，但**不要**把它當成前置條件。
  - 這**不是**放寬唯讀原則：連得上時一樣只讀不寫。也**不是**允許猜測——猜不出來的就在 SQL 註解裡明寫不確定處，不要編造欄位。
- **逐步執行 side-effect 指令**：需要 terminal 指令時，每個會改狀態的步驟（建資料夾、寫檔、cleanup）分開跑，**不** 用單一多行 shell block 或 `&&` 串接。

## Completion Checks

- 資料庫檢視只用了 `tp-dbhub` 的唯讀 MCP tool，**沒有** 透過 MCP 執行任何寫 SQL。
- 任何寫入側資料庫工作都落成 `<sql_root>/<env>/` 底下的 `.sql` 檔（`<env>` 取自 `[db] environments`，
  沒設就是預設的 local-db / test-db / main-db）：累加型在 `<slug>/`，procedure / view / function /
  trigger 在 `_modules/`。
- **落點分對了,而且是照清單分的**:`<slug>/` 底下的 `.sql` 裡**沒有** `ALTER PROCEDURE` / `ALTER VIEW` /
  `ALTER FUNCTION` / `ALTER TRIGGER` / `CREATE OR ALTER`（grep 得到就是放錯）；反過來,`_modules/`
  底下**沒有** `ALTER TABLE`、`CREATE TABLE`、`CREATE INDEX` 或資料 DML。
- **`_modules/` 的檔案形狀對**：路徑是 `_modules/<database>/{Procedures,Views,Functions,Triggers}/<schema>.<物件名>.sql`；
  內容依序有 `USE` + `GO`、`SET ANSI_NULLS ON` + `GO`、`SET QUOTED_IDENTIFIER ON` + `GO`，然後
  `CREATE OR ALTER` 是該批次的**第一個**陳述式；**沒有** `DROP PROCEDURE` / `DROP VIEW` / `DROP FUNCTION` /
  `DROP TRIGGER`，**沒有**把 `CREATE OR ALTER` 包進 `BEGIN TRY` 或顯式交易。
- **首次納管前分過岔**：用 `SELECT OBJECT_ID(...)` 逐環境確認過該物件存不存在，沒有對一個**全新**物件
  要求「從該環境抓基線」（那在 SSMS 做不到），也沒有拿開發端的版本充當 production 那份的基線。
- **既有物件走完了那道門**：基線檔的檔頭三欄（來源環境 / 取得方式 / 取得日期）填實且來源環境**等於
  該檔所在的環境**；`git log --oneline -- <該檔路徑>` 驗得到基線那顆 commit,而且它**先於**含變更的那顆。
- **全新物件的檔頭三欄填的是 `N/A（全新物件,無既有基線）`**，不是留空（留空跟「忘了填」看起來一樣）；
  沒有為它硬湊一顆空的基線 commit；回報講明了**回滾是 `DROP` 不是取前一版**。
- **`_modules/` 每個環境的份數與差異都回報過**,而且沒有自動把某一份複製到其它份。
- **`<slug>/` 裡有 `ALTER COLUMN` / `DROP INDEX` 時,掃過** `<sql_root>/<env>/` 找同一個
  `<表>.<欄位>` / 索引名；命中時停下來問過使用者。
- **同一批交付裡同時有兩種檔時,回報講明了執行順序**（`<slug>/` 先、`_modules/` 後）。
- **`<sql_root>` 是解析出來的,不是假設的**:`[db] sql_root` 沒設 → 落點就是 `.turbo-plugin/sql`;
  有設 → 落點在**工作區根**底下的那個相對路徑(不是當下目錄底下),而且它通過了那四項檢查。
- **在 git work tree 裡**：分組鍵是當前 branch 名且已套用 slash→dash 轉換（如 `feature/x` → `feature-x`）；
  **沒有問過使用者**（有 branch 卻去問,就是把「唯一」這個性質丟掉了）；沒有用 detached `HEAD` 當分組鍵,
  也沒有底線開頭的分組鍵。
- **不在 git work tree 裡**：使用者是從**既有資料夾清單**裡選的,或明確選了「開新的」；他輸入的字串
  **原封不動**成為資料夾名（沒有被默默改寫）,含不合法字元時被**拒絕並重問**過。
- **那份候選清單涵蓋所有環境**（清單裡每一個環境去重),不是只有這次要寫入的那一個
  ——只看一個環境的話,「先在開發端驗證、之後才補正式」這種跨 session 流程會拿到空清單；而且它**濾掉了
  底線開頭的目錄**（`_modules/` 沒有混進候選）。若濾掉的**不只** `_modules/`,那些舊的底線開頭資料夾
  **被列出來講過**（它們是這支 skill 不再寫入的孤兒,不能無聲消失）。
- **`<sql_root>/<env>/` 底下不存在只差一點點的兩個資料夾**（`補會員資料` 與 `補會員資料v2`
  這種）——若出現,代表「先列既有的讓人選」那一步被跳過了。
- 只在開發環境驗證的腳本只在**第一個**環境的 `<sql_root>/<env>/<slug>/`；production-bound 變更**每一個**環境都備齊。
- **`<env>` 是從 `[db] environments` 讀來的**,沒設就是預設的三個,而且**沒有**自己幫環境名加後綴；
  寫檔前列過 `<sql_root>` 底下的實際目錄，沒有出現「磁碟上有、清單裡沒有」卻照樣建新目錄的情況。
- `<slug>/` 產出檔遵循 [assets/sql-script-template.sql](./assets/sql-script-template.sql) 的版面，檔名遵循
  `<order>-<database>-<purpose>.sql`；`_modules/` 產出檔遵循
  [assets/module-script-template.sql](./assets/module-script-template.sql)，檔名遵循 `<schema>.<物件名>.sql`。
- 產出的 SQL 出現在 `git status`,而且那是**驗過的**——落點在 git work tree 裡時跑過 `git check-ignore`
  並確認沒有被擋。預設落點天生滿足這件事,自訂落點不一定。落點與命名可重現。
- 最終回報清楚區分「唯讀檢視驗證到的事實」與「準備供手動執行的 SQL 變更」。
- 沒有連線就產出的腳本，其開頭與回報**都**帶了「未經實際資料庫驗證」以及實際依據的檔案。

## Tool Preference

檔案 read / write / search / edit 一律用 Read / Write / Edit / Glob / Grep —— 包含「掃有沒有別的分組鍵動過
同一個欄位」與「查 `_modules/` 底下有沒有這個物件」這兩項,用 Grep / Glob 而不是 shell。資料庫查詢只走
`tp-dbhub` 唯讀 MCP tool。shell 操作限 `git`（取 branch 名 / 判斷在不在 work tree / `git check-ignore` /
驗基線 commit 的 `git log --oneline -- <path>`）與建立資料夾，逐步執行不串接。
