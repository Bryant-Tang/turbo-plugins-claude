---
name: tp-setup
description: 'Set up turbo-plugin-three-environment-db (dbhub / three database environments): shared base files, then the `dbhub.example.local.toml` template and a prompt to fill `dbhub.local.toml`. Run on explicit request; **do NOT auto-trigger**. Outside a git work tree it still runs the dbhub half and skips only the git-dependent parts; it never runs `git init`.'
argument-hint: ''
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup（turbo-plugin-three-environment-db）

## Purpose

`turbo-plugin-three-environment-db` 的設定入口。流程兩層:

1. **共用 base 段**(concern-neutral):pre-check + case 偵測 + 建 `.turbo-plugin/` 與共用檔骨架。見
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md`,**先讀並執行該檔**。
2. **db concern 段**(本檔):`dbhub.example.local.toml` 範本(進 git)、提示使用者複製填 `dbhub.local.toml`
   (gitignored,含 credentials)。`tp-db-management` **不**寫進 `conventions.md`,改靠 skill 自身 description 讓 agent 主動觸發。

> 本 plugin **不**處理 git↔SVN bridge(屬 `turbo-plugin-git-svn`)、IIS apphost(屬
> `turbo-plugin-dotnet-framework`)。三個 plugin 共用同一份 base 段、各寫自己的標記區塊,彼此不覆蓋。
> db **不碰** `config.toml`(db 在 config.toml 無設定),base 段對 db 會跳過 config.toml 那一項。
> `.mcp.json`(`tp-dbhub` MCP 宣告)隨**本 plugin** 出貨,不由 setup 寫進專案。

### 無 git 時只跑 dbhub 段,不整個停下

**兩段的 git 需求不同,不要綁在一起**:

| 段 | 需要 git 嗎 | 內容 |
| --- | --- | --- |
| **dbhub 段** | **不需要** | `.turbo-plugin/` 目錄、`dbhub.example.local.toml` 範本、提示填 `dbhub.local.toml`、node probe |
| **需要 git 的段** | 需要 work tree | `.gitignore` / `CLAUDE.md` 的 `base` 標記區塊調和;以及 `tp-db-management`(它以當前 branch 名標準化 SQL 落點 `.turbo-plugin/sql/<env>-db/<branch>/`) |

dbhub 本身——一份連線設定加一個 MCP server——**跟版控沒有任何關係**:它不讀 branch、不寫 repo,
產出(`dbhub.local.toml`)依規定本來就是 gitignored 的。需要 git 的是 `tp-db-management`。

原本整個 setup 因為其中一支 skill 需要 git 就一起擋掉,而**多專案工作區正是最需要根那份設定的形狀**
——`start-dbhub.js` 的設定解析第一條就是為它設計的(規則 c 找到多份時,要靠根那份指明用哪個)。
plugin 知道那是正確落點,卻不讓你在那裡跑 setup。

所以 case (a)(無 `.git/`)的行為是:

- **跑 dbhub 段**,一切照常。
- **跳過需要 git 的段**,並在完成報告說明跳過了什麼、以及 `tp-db-management` 在這裡不可用。
- **仍然不 `git init`** — 建 git repo / SVN bridge 屬 `turbo-plugin-git-svn`,這條沒變。

> **例外:目錄不存在或不可寫** → 仍然 fail-loud 停止。「不是 repo」不是錯誤,「寫不進去」才是。

#### case (a) 仍然要寫一份 `.gitignore`,而且理由不是 git

非 repo 目錄裡的 `dbhub.local.toml` **今天不會被誤提交**,單純因為那裡不是 repo。但只要有人在工作區根
`git init`(那本身是個錯誤,只是會發生,而且 `turbo-plugin-multi-repo-workspace` 明講「事後沒有東西
能還原」),一份含連線 credentials 的檔案就**直接落在版控範圍內**。

所以 case (a) 一樣寫 `.gitignore` 的 `base` 標記區塊。它在沒有 git 的地方是**惰性的**——不做任何事、
也不代表這個目錄該變成 repo——但它是**唯一**能防這件事的東西,而且那天真的到來時它已經就位。

**這件事由本 plugin 自己做,不外包。** 交給 `turbo-plugin-multi-repo-workspace` 看似合理(它有工作區
根的標記與 setup),但有兩個洞:非 repo 目錄**不一定**是多專案工作區,而那個 plugin **不一定有裝**——
本 plugin 並不相依於它。建立 credentials 檔的人負責保護它。

## Procedure

### Phase 1 — 偵測

讀並執行 base 段的 **Pre-check** 與 **Case 偵測**。**四個 case 都繼續**;case (a)(無 `.git/`)走上方
「無 git 時只跑 dbhub 段」。進 case 前依 base 段 Phase summary 規則報告 + `AskUserQuestion`
(執行 / 改 case / 取消);db 的動作都是 repo-only,無「動到外部」副作用。

**case (a) 的白話由本段自己供給,不要照搬 base 的說法。** base 那一列刻意只描述情境
(「這個資料夾還沒有版本控制」),因為各 concern 在 (a) 的動作是分岔的——git-svn 會建立版控,db 不會。
照搬會讓使用者在按下執行**之前**先被告知一件不會發生的事,而那正是 Phase summary 要防的。

db 在 case (a) 的白話用這句:

> 「這個資料夾還沒有版本控制——將部署 dbhub 設定,但**不會**建立版控,也**不會**處理需要 git 的部分」

並接著明講會跳過什麼:`CLAUDE.md` 的 `base` 區塊不寫、`tp-db-management` 不可用。使用者要能在按下執行
之前就知道自己拿到的是哪一半。

### Phase 2 — base 骨架 + db concern

先依 base 段建立 concern-neutral 共用檔骨架(`.turbo-plugin/` 目錄、`.gitignore` 的 `base` 標記區塊、
`CLAUDE.md` base;**db 跳過 config.toml**)。**`.gitignore` / `CLAUDE.md` 這兩個標記區塊
要調和(找到就取代),不是「已存在就跳過」**——見 base 段開頭那兩種 idempotent 語意。再做 db concern:

#### Case (a) 非 git repo（只做 dbhub 段）

1. **`.turbo-plugin/`** — 建立(整檔層級 idempotent,存在就跳過)。
2. **`.gitignore` 的 `base` 標記區塊** — 照樣調和,理由見上方「理由不是 git」。
3. **`.turbo-plugin/dbhub.example.local.toml`** — 照 case (b)/(c) 的規則部署,但**不要**跑
   `git check-ignore` 那項驗證(沒有 git 可問)。同時要講清楚它在這裡的角色**變了**:
   在 repo 裡它是「進 git、給同事看的範本」,在這裡它**傳不到任何人手上**,只是給你自己看的格式參考。
4. **`.turbo-plugin/dbhub.local.toml`** — 一樣**永不自動建立**,只提示複製後填。
5. **node probe** — 照跑,規則與下方相同。
6. **`CLAUDE.md` 的 `base` 區塊不寫** — 那段講的是「不得提交僅限本機之物」,在沒有版控的地方
   沒有對象。工作區根的 `CLAUDE.md` 若已由別的 plugin 維護,更不要插進去。

#### Case (b) init-from-existing / Case (c) 主 worktree 補設定

1. **`.turbo-plugin/dbhub.example.local.toml`**(db **owns**)— 不存在則複製
   `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/dbhub.example.local.toml`(此檔進 git,是給同事看的範本);
   **已存在則不覆寫**。部署完**確認它真的沒有被 ignore**(`git check-ignore` 應回非零):base 的
   `.turbo-plugin/**/*.local.*` 會連範本一起擋掉,靠 base 骨架裡那條 `!*.example.local.*` 放行。
   舊版 `.gitignore` 缺那一行的情況,base 段的標記調和已經會補上(issue #65 之前不會,所以這裡才要
   自己驗一次);**驗出來仍然被 ignore 就停下回報**,不要默默放過——範本被擋掉的話它永遠傳不到同事手上。
2. **`.turbo-plugin/dbhub.local.toml`** — **永不自動建立**(避免使用者誤以為已 ready)。不存在則提醒:
   「dbhub 需要你自填 credentials:`cp .turbo-plugin/dbhub.example.local.toml .turbo-plugin/dbhub.local.toml`
   後編輯填入連線資訊」(`.gitignore` base 已排除 `*.local.*`,**真正含密碼的這一份不會進 git**;
   只有 `*.example.local.*` 範本被放行)。
3. **node probe**(僅提示,不阻塞):`node --version`。失敗 → Phase 4 記「dbhub MCP server 需要 Node.js;
   未偵測到,裝好後重開 session」。
   **這一項不能省。** `tp-dbhub` 的啟動器是 node 腳本(`.mcp.json` 的 `command` 是被**直接 spawn**
   的,不經過 shell,所以只能用三平台同名都在 PATH 上的指令),沒有 node 時它連一行錯誤都印不出來——
   使用者只會在 `/mcp` 看到一個紅叉,原因埋在 debug log 裡。**設定當下是唯一講得清楚的時機**;
   錯過就只剩本 plugin 的 SessionStart hook 會補講一次。

> db 在 `config.toml` 不寫入(db 在 config.toml 無設定);`tp-db-management` 改靠 skill 自身 description 讓 agent
> 主動觸發(`conventions.md` 機制已退役)。`CLAUDE.md` 由 base 段注入 base 區塊(「不得提交僅限本機之物」),db 不另加。

#### Case (d) peer-mode（per-peer dbhub.local.toml）

**前提**:當前非 main worktree,且 `.turbo-plugin/` marker **必須**存在。marker 不存在 → 拒跑,提示「請先在主
worktree 跑 `/tp-setup`」。

db 是唯一有 per-peer 專屬檔的 concern。`tp-dbhub` MCP server 鎖定 session 啟動位置,故 peer worktree 需自己的
`dbhub.local.toml`:

1. `.turbo-plugin/dbhub.local.toml` 在 peer 缺 → `AskUserQuestion`:
   - 「從主 worktree 複製過來(`cp <main>/.turbo-plugin/dbhub.local.toml ./.turbo-plugin/`)」
   - 「互動輸入新 credentials」
   - 「跳過(不用 dbhub MCP server)」
2. **不**碰任何 git-versioned shared file(`dbhub.example.local.toml` 等由主 worktree 管理)。

### Phase 4 — 完成報告

- **偵測結果**:case + 子流程。
- **寫入位置**:base 骨架 + db 項目(`dbhub.example.local.toml`)各標「新建 / 已存在 / 補設定」。
- **使用者仍須手動處理**:
  - `dbhub.local.toml` credentials(複製 example 後填)。
  - node 未偵測到時的安裝提示。
  - 若要用 git↔SVN bridge / .NET Framework Web → 裝對應 plugin 並跑其 setup。
- **下一步**:「填好 `.turbo-plugin/dbhub.local.toml`、確認裝了 Node.js 之後**重開 session**,
  `tp-dbhub` 才會連上,接著可 `/tp-db-management`」。
- **case (a) 額外要報**(缺一項都會讓使用者以為自己拿到的是完整設定):
  - **跳過了 `CLAUDE.md` 的 `base` 區塊**,因為這裡沒有版控。
  - **`tp-db-management` 在這裡不可用** — 它以當前 branch 名決定 SQL 落點。要用它請在**某個子專案裡**
    跑那支 skill,不是在這個目錄。
  - **`dbhub.example.local.toml` 在這裡只是格式參考**,不會傳給任何人。
  - `.gitignore` 已寫入且目前是惰性的 —— 它存在是為了「哪天有人在這裡 `git init`」,不是暗示你該這麼做。

## Decision Rules

- **先跑共用 base 段、再做 db concern** — base 只建 concern-neutral 共用檔;dbhub 相關屬 db。
- **db 不碰 config.toml** — base 段對 db 跳過 config.toml 那一項。
- **無 `.git/` 時只跑 dbhub 段,不整個停下** — dbhub 跟版控無關,需要 git 的是 `tp-db-management`。
  仍然**不自行 `git init`**(建 git repo 屬 `turbo-plugin-git-svn`),仍然寫 `.gitignore` 的 `base` 區塊
  (惰性,但那是 credentials 唯一的保護)。
- **`dbhub.local.toml` 永不自動建立** — 只 prompt 使用者複製 example 後手動編輯(避免誤以為已 ready)。
- **db 不寫 `config.toml` 的任何標記區塊** — base 段建立的共用檔維持原樣,db 只管自己的 dbhub 檔(db-management 靠 skill description 觸發;`conventions.md` 機制已退役)。
- **Case (b)/(c) idempotent**;**Case (d)** 只處理 per-peer `dbhub.local.toml`,不碰 git-versioned shared file。
- **不自動代填使用者設定 / credentials** — 缺漏一律先 `AskUserQuestion`。
- **Phase summary transparency**:db 動作皆 repo-only,summary 無外部副作用可列。

## Completion Checks

- `.turbo-plugin/` 存在;db 未在 `config.toml` 寫入任何內容(亦不涉及 `conventions.md`——該機制已退役)。
- `.turbo-plugin/dbhub.example.local.toml` 存在(進 git);`dbhub.local.toml` **未**被自動建立(只提示)。
- `.gitignore` 含 `base` 標記區塊(只有一組);`CLAUDE.md` 的 `base` 區塊開頭有「重跑會整段取代」的自我說明。
- 專案根若存在未被追蹤的 `TODO.md`,**使用者已被明確告知它不再被 base 區塊忽略**(見 base 段第 3 項)。
- Case (a)(無 `.git/`):`.turbo-plugin/`、`.gitignore` 的 `base` 區塊、`dbhub.example.local.toml` 都已建立;
  **未** `git init`;**未**寫 `CLAUDE.md` 的 `base` 區塊;**未**自動建 `dbhub.local.toml`。
- Case (a) 的 Phase summary **沒有**說「將建立版控」(那是 git-svn 的說法,對 db 是假的)。
- Case (a) 的完成報告**四項都在**——跳過 `CLAUDE.md` base、`tp-db-management` 不可用、範本只是格式參考、
  `.gitignore` 是惰性的。**逐項對照**,不要只確認前兩項:這四句的作用是同一件事(不讓使用者以為拿到的
  是完整設定),少任何一句都會留下一個誤會。
- Case (b)/(c):跑兩次結果同跑一次(idempotent)。
- Case (d):只處理 `dbhub.local.toml`,未動 git-versioned shared file。

## Test Scenarios

- **無 git 只跑 dbhub 段**:在無 `.git/` 的空目錄跑 `/tp-setup`,確認建了 `.turbo-plugin/`、
  `.gitignore` 的 `base` 區塊與 `dbhub.example.local.toml`,而**未** `git init`、**未**寫
  `CLAUDE.md` 的 `base` 區塊、**未**自動建 `dbhub.local.toml`。
- **非 repo 的完成報告不會讓人誤會**:同上情境,確認報告明講「`tp-db-management` 不可用」與
  「範本在這裡傳不出去」——少了這兩句,使用者會以為自己拿到的是完整設定。
- **dbhub.local.toml 不自動建**:乾淨 sandbox 跑 case (c),確認只建 `dbhub.example.local.toml`、提示複製,但**未**自動建 `dbhub.local.toml`。
- **db 只管 dbhub 檔**:跑 db setup 後,只建 / 提示 dbhub 檔,未寫入 `config.toml`(`conventions.md` 機制已退役,不涉及)。

## Tool Preference

所有檔案 read / write / search / edit 優先用 Read / Write / Edit / Glob / Grep / LSP,避開 Bash / PowerShell / Python /
Node.js 做檔案操作。shell 操作只限:`git` / `node --version` 等 probe / 跑 plugin script。
