---
name: tp-setup
description: 'Set up turbo-plugin-three-environment-db (dbhub / three database environments): shared base files, then the `dbhub.example.toml` template and a prompt to fill `dbhub.local.toml`. Run on explicit request; **do NOT auto-trigger**. Outside a git work tree it completes normally, skipping only one verification step; it never runs `git init`.'
argument-hint: ''
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup（turbo-plugin-three-environment-db）

## Purpose

`turbo-plugin-three-environment-db` 的設定入口。流程兩層:

1. **共用 base 段**(concern-neutral):pre-check + case 偵測 + 建 `.turbo-plugin/` 與共用檔骨架。見
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md`,**先讀並執行該檔**。
2. **db concern 段**(本檔):`dbhub.example.toml` 範本(進 git)、提示使用者複製填 `dbhub.local.toml`
   (gitignored,含 credentials)。`tp-db-management` **不**寫進 `conventions.md`,改靠 skill 自身 description 讓 agent 主動觸發。

> 本 plugin **不**處理 git↔SVN bridge(屬 `turbo-plugin-git-svn`)、IIS apphost(屬
> `turbo-plugin-dotnet-framework`)。三個 plugin 共用同一份 base 段、各寫自己的標記區塊,彼此不覆蓋。
> db 寫 `config.toml` 的 `db` 標記區塊(`[db] sql_root` 與 `[db] environments` 兩個 key)。
> `.mcp.json`(`tp-dbhub` MCP 宣告)隨**本 plugin** 出貨,不由 setup 寫進專案。

### 無 git 時照樣完成 setup,不整個停下

**setup 寫的東西沒有一樣需要 git,`tp-db-management` 兩半也都不需要。** 整支流程裡只有一個步驟會問
到 git:

| 誰 | 需要 git 嗎 | 為什麼 |
| --- | --- | --- |
| **setup 寫的全部檔案** | **不需要** | `.turbo-plugin/`、`.gitignore` 的 `base` 區塊、`CLAUDE.md` 的 `base` 區塊、`dbhub.example.toml`、node probe —— 全都只是寫檔案 |
| `tp-db-management` 的**唯讀查詢** | **不需要** | 它只需要 dbhub MCP server,而那正是 setup 設定好的東西 |
| `tp-db-management` 的 **SQL 產出** | **不需要** | 落點是 `<sql_root>/<env>/<slug>/`(`sql_root` 預設 `.turbo-plugin/sql`);有 git 時 `<slug>` 直接用當前 branch 名,**沒有 git 就問使用者**要用哪個 |
| 範本部署後的 `git check-ignore` | **需要** | 這是唯一一項,沒有 git 就跳過 |

dbhub 本身——一份連線設定加一個 MCP server——**跟版控沒有任何關係**:它不讀 branch、不寫 repo,
產出(`dbhub.local.toml`)依規定本來就是 gitignored 的。

**這條規則的由來**:整個 setup 原本一看到不是 repo 就停,理由是「`tp-db-management` 需要 git」——
當時 SQL 落點確實只拿得到 branch 名(現在沒有 git 就問使用者,所以連那個理由都不成立了)。而
**多專案工作區正是最需要根那份設定的形狀**——`start-dbhub.js` 的設定解析第一條就是為它設計的
(規則 c 找到多份時,要靠根那份指明用哪個)。plugin 知道那是正確落點,卻不讓你在那裡跑 setup。
**而被擋掉的那些動作,沒有一個真的需要 git。**

所以 case (a)(無 `.git/`)的行為是:

- **setup 該寫的全部照寫**,`.gitignore` 與 `CLAUDE.md` 的 `base` 區塊都不例外(理由見下)。
- **唯一跳過的是一項驗證**:範本部署後的 `git check-ignore`(沒有 git 可問)。
- **仍然不 `git init`** — 建 git repo / SVN bridge 屬 `turbo-plugin-git-svn`,這條沒變。
- 完成報告要說明 `tp-db-management` 在這裡**完全可用**,只是產出 SQL 時會**問你分組名**,
  不像在 repo 裡直接拿 branch 名。那是差異,不是限制。

> **例外:目錄不存在或不可寫** → 仍然 fail-loud 停止。「不是 repo」不是錯誤,「寫不進去」才是。

#### `.gitignore` 與 `CLAUDE.md` 的 `base` 區塊在 case (a) 一樣寫,理由是同一個

兩個檔案名字裡都帶著「版控」的味道,但它們在這裡都**不需要 git 才能寫**,而且都是為了**同一個時刻**
才存在的:哪天有人在工作區根 `git init`。那本身是個錯誤(`turbo-plugin-multi-repo-workspace` 明講
「事後沒有東西能還原」),但**它會發生**。

- **`.gitignore`**:非 repo 目錄裡的 `dbhub.local.toml` 今天不會被誤提交,單純因為那裡不是 repo。
  `git init` 的那一刻,一份含連線 credentials 的檔案就直接落在版控範圍內——而那份 `.gitignore`
  是**唯一**能擋住它的東西,且必須**已經就位**才有用。
- **`CLAUDE.md` 的 `base` 區塊**:它那句「不得提交僅限本機才有的東西」管的**不是這個資料夾**,
  是**你在這裡工作時的行為**。多專案工作區的根底下就是一堆 repo,你在那裡整天都在對子專案 commit
  ——規則完全適用,只是適用對象不是腳下這個目錄。

> 兩者用同一套邏輯,是刻意的。先前的版本只寫 `.gitignore`、跳過 `CLAUDE.md`,理由是「那句話在沒有
> 版控的地方沒有對象」——那是**把規則讀得太字面**,而且跟 `.gitignore` 的理由自相矛盾
> (同樣是「今天沒用、哪天有用」,卻做了相反的決定)。

**這件事由本 plugin 自己做,不外包。** 交給 `turbo-plugin-multi-repo-workspace` 看似合理(它有工作區
根的標記與 setup),但有兩個洞:非 repo 目錄**不一定**是多專案工作區,而那個 plugin **不一定有裝**——
本 plugin 並不相依於它。建立 credentials 檔的人負責保護它。

## Procedure

### Phase 1 — 偵測

讀並執行 base 段的 **Pre-check** 與 **Case 偵測**。**四個 case 都繼續**;case (a)(無 `.git/`)走上方
「無 git 時照樣完成 setup」。進 case 前依 base 段 Phase summary 規則報告 + `AskUserQuestion`
(執行 / 改 case / 取消);db 的動作都是 repo-only,無「動到外部」副作用。

**case (a) 的白話由本段自己供給,不要照搬 base 的說法。** base 那一列刻意只描述情境
(「這個資料夾還沒有版本控制」),因為各 concern 在 (a) 的動作是分岔的——git-svn 會建立版控,db 不會。
照搬會讓使用者在按下執行**之前**先被告知一件不會發生的事,而那正是 Phase summary 要防的。

db 在 case (a) 的白話用這句:

> 「這個資料夾還沒有版本控制——將部署 dbhub 設定,但**不會**為它建立版控」

**到此為止,不要再加限制的預告。** 這裡曾經接了一句「`tp-db-management` 只有唯讀查詢那半可用」——
那句話現在是假的:SQL 落點的分組名沒有 git 就問使用者,所以兩半都能用。Phase summary 的職責是
不讓使用者在按下執行之前相信一件假的事,多講一個不存在的限制跟少講一個真的限制一樣糟。

### Phase 2 — base 骨架 + db concern

先依 base 段建立 concern-neutral 共用檔骨架:`.turbo-plugin/` 目錄、`config.toml` 殼、`.gitignore` 的
`base` 標記區塊、`CLAUDE.md` base。**`.gitignore` / `CLAUDE.md` 這兩個標記區塊
要調和(找到就取代),不是「已存在就跳過」**——見 base 段開頭那兩種 idempotent 語意。再做 db concern:

> **case (a) 對這份骨架沒有例外**:`.gitignore` 與 `CLAUDE.md` 的 `base` 區塊照寫,理由見上方
> 「理由是同一個」。唯一跳過的是範本部署後那項 `git check-ignore` 驗證(沒有 git 可問)。

#### Case (a) 非 git repo

**跟 case (b)/(c) 幾乎一樣**,只有第 3 項的驗證步驟不同。

1. **`.turbo-plugin/`** — 建立(整檔層級 idempotent,存在就跳過)。
1b. **`.turbo-plugin/config.toml` 的 `db` 標記區塊** — 見下方「`[db]` 的兩個 key」。case (a) 沒有例外。
2. **`.gitignore` 與 `CLAUDE.md` 的 `base` 標記區塊** — **照樣調和**,理由見上方「理由是同一個」。
   `CLAUDE.md` 不存在就建立,與 case (b)/(c) 相同。
   **`CLAUDE.md` 的 `base` 是 tp-setup 家族共用的單一區塊**(不是各 concern 各一個 —— 那是
   `.gitignore` 才有的形狀):已經有一個(例如 git-svn 的 setup 先跑過)就**取代它的內容**,
   絕不要再加第二個。至於 `multi-repo-workspace` / `knowledge-placement` 那些是**不同的標記名**,
   各自獨立、互不相干,一律不要動。
3. **`.turbo-plugin/` 的 dbhub 範本** — 照 case (b)/(c) 那三選一的規則處理(含「只有舊檔名時什麼都
   不動」),但**不要**跑 `git check-ignore` 那項驗證(沒有 git 可問)。同時要講清楚它在這裡的角色
   **變了**:在 repo 裡它是「進 git、給同事看的範本」,在這裡它**傳不到任何人手上**,只是給你自己
   看的格式參考。
4. **`.turbo-plugin/dbhub.local.toml`** — 一樣**永不自動建立**,只提示複製後填。
5. **node probe** — 照跑,規則與下方相同。

#### Case (b) init-from-existing / Case (c) 主 worktree 補設定

1. **`.turbo-plugin/` 的 dbhub 範本**(db **owns**)— 依現況三選一:
   - **兩個檔名都不存在** → 複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/dbhub.example.toml`
     (此檔進 git,是給同事看的範本)。
   - **`dbhub.example.toml` 已存在** → **不覆寫**。
   - **只有改名前的 `dbhub.example.local.toml`** → **什麼都不動**,只在 Phase 4 講一句
     (見本項下方「舊範本檔名」那三條)。

   部署 / 確認之後,對**實際存在的那個檔名**跑一次 `git check-ignore`,**確認它真的沒有被 ignore**
   (應回非零)。**驗出來仍然被 ignore 就停下回報**,不要默默放過——範本被擋掉的話它永遠傳不到
   同事手上(issue #65)。
   > 新檔名不含 `.local.`,base 的 `.turbo-plugin/**/*.local.*` **碰不到它**,所以這項驗證在新專案
   > 上幾乎一定會過。留著它是因為它同時擋著另一半:**專案自己寫的** ignore 規則,而那個失敗一樣
   > 是靜默的。舊檔名則仍然要靠 base 骨架裡那條 `!*.example.local.*` 放行才不會被擋掉。

   **舊範本檔名:不改名,也不補一份新的。**
   - **不要**自己 `git mv`。版控裡的檔案改名是一次 commit,那是使用者的決定,不是 setup 的。
   - **也不要**再部署一份新檔名的範本。兩份內容相同、只有名字不同的範本擺在同一個資料夾裡,
     「我該複製哪一份」沒有答案——那正是這次改名要消滅的那類困惑。
   - **在完成報告講一句就好**:範本已改名成 `dbhub.example.toml`,舊檔名**仍然完全可用**
     (SessionStart hook 兩個名字都認),想跟上就自己 `git mv`。
2. **`.turbo-plugin/dbhub.local.toml`** — **永不自動建立**(避免使用者誤以為已 ready)。不存在則提醒:
   「dbhub 需要你自填 credentials:`cp .turbo-plugin/dbhub.example.toml .turbo-plugin/dbhub.local.toml`
   後編輯填入連線資訊」(`.gitignore` base 已排除 `*.local.*`,**真正含密碼的這一份不會進 git**)。
   專案若還在用舊範本檔名,`cp` 的來源就換成那一個。
3. **node probe**(僅提示,不阻塞):`node --version`。失敗 → Phase 4 記「dbhub MCP server 需要 Node.js;
   未偵測到,裝好後重開 session」。
   **這一項不能省。** `tp-dbhub` 的啟動器是 node 腳本(`.mcp.json` 的 `command` 是被**直接 spawn**
   的,不經過 shell,所以只能用三平台同名都在 PATH 上的指令),沒有 node 時它連一行錯誤都印不出來——
   使用者只會在 `/mcp` 看到一個紅叉,原因埋在 debug log 裡。**設定當下是唯一講得清楚的時機**;
   錯過就只剩本 plugin 的 SessionStart hook 會補講一次。

4. **`.turbo-plugin/config.toml` 的 `db` 標記區塊** — 見下方「`[db]` 的兩個 key」。

> `tp-db-management` 靠 skill 自身 description 讓 agent 主動觸發(`conventions.md` 機制已退役)。
> `CLAUDE.md` 由 base 段注入 base 區塊(「不得提交僅限本機之物」),db 不另加。

#### `[db]` 的兩個 key:`sql_root` 與 `environments`

用 base 段「更新自己區塊的通用程序」,**只**動 `# >>> turbo-plugin:db >>>` 區塊,內容是
`${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/config.toml` 裡那一段(`[db]` + 說明註解 +
被註解掉的 `sql_root` 範例 + `environments`)。

**取代之前先讀:區塊裡若已經有未被註解的 `sql_root` 或 `environments`,原樣寫回去。** 那是
**使用者填的值**,不是 setup 產生的骨架;照字面取代就是把它無聲刪掉,而且刪的時機(「他重跑了一次
setup」)跟那個設定毫無因果關係,幾乎不可能聯想回來。base 段的 marker 慣例對這件事有一條通則,
這裡是它的實例。

**不要問使用者要設什麼。** 絕大多數專案用預設就好,而 setup 已經夠長了;這兩個 key 的存在本身
(連同區塊裡那段說明)就是它們的發現途徑。要改的人自己改一行,不必被問。

##### `environments` 要**明確寫出來**,而且值取決於磁碟上已經有什麼

`sql_root` 留成註解就好（預設值從來沒變過）,但 `environments` **不一樣:它的預設值正在換代**——
新專案要用 `dev-db`,既有專案必須留在 `local-db`。兩者無法靠同一個「沒設定時的預設」表達,所以
setup **要寫一行未註解的 `environments`**,把這個專案屬於哪一代**釘在檔案裡**。

值這樣決定（先解析出 `sql_root`,再看那底下有什麼）:

| `<sql_root>` 底下的情況 | 寫入的值 | 為什麼 |
|---|---|---|
| 已經有 `local-db/` / `test-db/` / `main-db/` 之中**任何一個** | `["local-db", "test-db", "main-db"]` | 那棵樹已經在了。換名字會讓它**整棵變成孤兒**——檔案還在、git 也乾淨,只是 `tp-db-management` 從此不再看它一眼。 |
| 目錄不存在,或底下**沒有**任何環境目錄 | `["dev-db", "test-db", "main-db"]` | 沒有東西會變孤兒,直接用新的一代。`dev` 取代 `local`,因為這個環境指的是內網開發資料庫、不是開發者本機。 |

**寫的是舊清單時,順帶告訴使用者可以改名**,並給出那兩行指令（`scripts/rename-db-environment.sh` /
`scripts/Rename-DbEnvironment.ps1`,預設只印不動、加 `--apply` / `-Apply` 才真的改）。**只講,不要
自己去跑** —— 那會改動幾百個檔案的內容,是使用者的決定。

> **這一步不可以省成「一律寫新預設」。** 對既有專案那等於在他重跑一次 setup 的時候,把整棵 SQL 樹
> 換一個名字認不出來 —— 而過程中每一步都會成功,沒有任何一個地方會叫。

> **這裡跟 `tp-db-management` 在「沒有這個 key」時用的是同一個判準,兩邊必須一起改。** 不一致的話,
> 同一個專案在「跑過 setup」與「還沒跑過 setup」兩種狀態下會把 SQL 寫到不同的地方,而那個差異
> 沒有任何東西會提醒。`tests/unit/assets/db-assets.test.sh` 有一條檢查守著兩邊的敘述。

#### Case (d) peer-mode（per-peer dbhub.local.toml）

**前提**:當前非 main worktree,且 `.turbo-plugin/` marker **必須**存在。marker 不存在 → 拒跑,提示「請先在主
worktree 跑 `/tp-setup`」。

db 是唯一有 per-peer 專屬檔的 concern。`tp-dbhub` MCP server 鎖定 session 啟動位置,故 peer worktree 需自己的
`dbhub.local.toml`:

1. `.turbo-plugin/dbhub.local.toml` 在 peer 缺 → `AskUserQuestion`:
   - 「從主 worktree 複製過來(`cp <main>/.turbo-plugin/dbhub.local.toml ./.turbo-plugin/`)」
   - 「互動輸入新 credentials」
   - 「跳過(不用 dbhub MCP server)」
2. **不**碰任何 git-versioned shared file(`dbhub.example.toml` 等由主 worktree 管理)。

### Phase 4 — 完成報告

- **偵測結果**:case + 子流程。
- **寫入位置**:base 骨架 + db 項目(`dbhub.example.toml`)各標「新建 / 已存在 / 補設定」。
- **專案若還在用改名前的 `dbhub.example.local.toml`**:講明範本已改名、舊名仍可用、要不要 `git mv`
  由使用者決定。
- **使用者仍須手動處理**:
  - `dbhub.local.toml` credentials(複製 example 後填)。
  - node 未偵測到時的安裝提示。
  - 若要用 git↔SVN bridge / .NET Framework Web → 裝對應 plugin 並跑其 setup。
- **下一步**:「填好 `.turbo-plugin/dbhub.local.toml`、確認裝了 Node.js 之後**重開 session**,
  `tp-dbhub` 才會連上,接著可 `/tp-db-management`」。
- **case (a) 額外要報**(缺一項都會讓使用者誤判自己拿到了什麼):
  - **`tp-db-management` 完全可用**:**唯讀查詢照常**(它只需要 dbhub MCP server,而那已經設定好了);
    **產出 SQL 也照常**,只是落點 `.turbo-plugin/sql/<env>/<slug>/` 的 `<slug>` 會**問你**要用哪個
    (列出既有資料夾讓你選),而不是像在 repo 裡直接拿當前 branch 名。
    **不要講成「不可用」或「只有一半可用」** —— 兩種說法都會讓使用者放棄一個其實可用的功能。
  - **`dbhub.example.toml` 在這裡只是格式參考**,不會傳給任何人。
  - `.gitignore` 與 `CLAUDE.md` 的 `base` 區塊已寫入。前者在沒有 git 時是惰性的,存在是為了
    「哪天有人在這裡 `git init`」,**不是**暗示你該這麼做。

## Decision Rules

- **先跑共用 base 段、再做 db concern** — base 只建 concern-neutral 共用檔;dbhub 相關屬 db。
- **db 只寫 `config.toml` 的 `db` 區塊** — 兩個 key(`[db] sql_root` 與 `[db] environments`),其它
  concern 的區塊與標記外的內容一律不動。
- **無 `.git/` 時照跑,不整個停下** — setup 寫的東西沒有一樣需要 git,`tp-db-management` 兩半也都
  不需要(SQL 落點的 `<slug>` 沒有 git 就問使用者)。整支流程唯一要問 git 的是範本部署後那項
  `git check-ignore`,沒有 git 就跳過。仍然**不自行 `git init`**(建 git repo 屬
  `turbo-plugin-git-svn`),`.gitignore` 與 `CLAUDE.md` 的 `base` 區塊**都照寫**。
- **`dbhub.local.toml` 永不自動建立** — 只 prompt 使用者複製 example 後手動編輯(避免誤以為已 ready)。
- **既有的 `sql_root` / `environments` 要保值** — `db` 區塊是「找到就取代」的,但區塊裡那兩行是
  **使用者填的**。取代前先讀出來、原樣寫回;直接覆蓋等於在他重跑 setup 的時候無聲刪掉他的設定。
  (db-management 靠 skill description 觸發;`conventions.md` 機制已退役。)
- **沒有 `environments` 可保值時,依磁碟現況決定寫哪一組,不要一律寫新預設** — `<sql_root>` 底下
  已經有舊名環境目錄(`local-db/` 等)就寫舊清單並提一句改名腳本;什麼都沒有才寫
  `["dev-db", "test-db", "main-db"]`。一律寫新的等於讓既有那棵 SQL 樹在重跑 setup 時整棵變孤兒,
  而且每一步都會成功。
- **Case (b)/(c) idempotent**;**Case (d)** 只處理 per-peer `dbhub.local.toml`,不碰 git-versioned shared file。
- **不自動代填使用者設定 / credentials** — 缺漏一律先 `AskUserQuestion`。
- **Phase summary transparency**:db 動作皆 repo-only,summary 無外部副作用可列。

## Completion Checks

- `.turbo-plugin/` 存在;`config.toml` 含**恰好一組** `db` 標記區塊(不是零組,也不是兩組),區塊內有
  `[db]`,而且**其它 concern 的區塊與標記外的內容逐字未變**(亦不涉及 `conventions.md`——該機制已退役)。
- **重跑之後 `sql_root` 與 `environments` 還在**:區塊裡原本若有未被註解的 `sql_root` / `environments`,
  重跑 setup 後它們**逐字還在**。這一項是專門守著「取代」語意的——沒有它,那些設定會在某次重跑時
  無聲消失。
- **`environments` 寫的是對的那一組**:`<sql_root>` 底下原本就有 `local-db/` 之類的舊名目錄時,
  寫進去的是 `["local-db", "test-db", "main-db"]`(而且提過改名腳本);底下什麼環境目錄都沒有時,
  寫的才是 `["dev-db", "test-db", "main-db"]`。**既有的 SQL 樹在 setup 前後指向同一個地方。**
- `.turbo-plugin/` 底下有一個 dbhub 範本(新專案是 `dbhub.example.toml`;改名前設定的專案維持
  `dbhub.example.local.toml`,**不會**被改名、也**不會**多出第二份);`dbhub.local.toml` **未**被自動
  建立(只提示)。
- `.gitignore` 含 `base` 標記區塊(只有一組);`CLAUDE.md` 的 `base` 區塊開頭有「重跑會整段取代」的自我說明。
- 專案根若存在未被追蹤的 `TODO.md`,**使用者已被明確告知它不再被 base 區塊忽略**(見 base 段第 3 項)。
- Case (a)(無 `.git/`):`.turbo-plugin/`、`.gitignore` **與 `CLAUDE.md`** 的 `base` 區塊都已建立,
  dbhub 範本也已就位(原本什麼都沒有就是新的 `dbhub.example.toml`;原本只有舊檔名就維持舊的);
  **未** `git init`;**未**自動建 `dbhub.local.toml`。
- Case (a) 的 Phase summary **沒有**說「將建立版控」(那是 git-svn 的說法,對 db 是假的)。
- Case (a) 的完成報告**三項都在**——`tp-db-management` **完全可用**(唯讀查詢照常、產出 SQL 也照常,
  只是 `<slug>` 改用問的)、範本只是格式參考、兩個 `base` 區塊已寫入且 `.gitignore` 目前是惰性的。
  **逐項對照**:這三句的作用是同一件事(不讓使用者誤判自己拿到了什麼),少任何一句都會留下一個誤會。
- Case (a) 的報告**沒有**把 `tp-db-management` 講成「不可用」**或「只有一半可用」**——它兩半都能用,
  講小了會讓使用者放棄一個其實可用的功能。
- Case (b)/(c):跑兩次結果同跑一次(idempotent)。
- Case (d):只處理 `dbhub.local.toml`,未動 git-versioned shared file。

## Test Scenarios

- **無 git 照樣完成 setup**:在無 `.git/` 的空目錄跑 `/tp-setup`,確認建了 `.turbo-plugin/`、
  `.gitignore` **與 `CLAUDE.md`** 的 `base` 區塊、`dbhub.example.toml`,而**未** `git init`、
  **未**自動建 `dbhub.local.toml`。
- **非 repo 的完成報告不會讓人誤會**:同上情境,確認報告講的是「`tp-db-management` **完全可用**,
  只是產出 SQL 時會問你分組名」,而**不是**「不可用」或「只有一半可用」;並且有講「範本在這裡傳不
  出去」。前者講小了會讓使用者放棄一個可用的功能,後者漏掉會讓他以為範本已經交給同事了。
- **dbhub.local.toml 不自動建**:乾淨 sandbox 跑 case (c),確認只建 `dbhub.example.toml`、提示複製,但**未**自動建 `dbhub.local.toml`。
- **舊範本檔名不被動到**:sandbox 裡只放一個 `dbhub.example.local.toml` 再跑 case (c),確認 setup
  **沒有**改名、**沒有**多部署一份 `dbhub.example.toml`,而完成報告有講「已改名、舊名仍可用」。
- **db 只動自己那一塊**:跑 db setup 後,dbhub 檔已建 / 已提示,`config.toml` 多了一組 `db` 標記區塊,
  而其它 concern 的區塊(`git-svn` / `dotnet`)與標記外的內容**逐字未變**(`conventions.md` 機制已退役,不涉及)。
- **`sql_root` 保值**:在 `db` 區塊裡填一行 `sql_root = "db/scripts"`,再跑一次 setup,確認那一行還在。
  這是最容易做錯的一項——「找到就取代」照字面做就會把它洗掉,而且要等到重跑那一刻才發現。

## Tool Preference

所有檔案 read / write / search / edit 優先用 Read / Write / Edit / Glob / Grep / LSP,避開 Bash / PowerShell / Python /
Node.js 做檔案操作。shell 操作只限:`git` / `node --version` 等 probe / 跑 plugin script。
