---
name: tp-setup
description: '設定 turbo-plugin-three-environment-db 環境(dbhub / 三環境 DB)。使用者明確要求 setup 時執行;**不要自動觸發**。先跑共用 base 段(建 .turbo-plugin/ + concern-neutral 共用檔),再做 db concern:dbhub.example.local.toml 範本、提示填 dbhub.local.toml。需要 git repo 而不存在時 fail-loud(不自行 git init)。'
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

### fail-loud 前置（無 git 時不自行 bootstrap）

`tp-db-management` 以當前 git branch 名標準化 SQL 落點(`.turbo-plugin/sql/<env>-db/<branch>/`),需在 git work
tree 內運作。setup 前置:

- **`.git/` 不存在**(base case 偵測為 (a))→ **fail-loud**,**不** `git init`(建 git repo / SVN bridge 屬
  `turbo-plugin-git-svn`)。訊息:「此目錄不是 git repo。請先裝 `turbo-plugin-git-svn` 跑其 `/tp-setup`,或自行
  `git init` 後再跑本 setup。」然後停止。

## Procedure

### Phase 1 — 偵測

讀並執行 base 段的 **Pre-check** 與 **Case 偵測**。套用上方 fail-loud 前置:case (a)(無 `.git/`)→ 停止並提示。
case (b)/(c)/(d) → 繼續。進 case 前依 base 段 Phase summary 規則報告 + `AskUserQuestion`(執行 / 改 case / 取消);
db 的動作都是 repo-only,無「動到外部」副作用。

### Phase 2 — base 骨架 + db concern

先依 base 段建立 concern-neutral 共用檔骨架(`.turbo-plugin/` 目錄、`.gitignore` base、`CLAUDE.md` base;
**db 跳過 config.toml**)。再做 db concern:

#### Case (b) init-from-existing / Case (c) 主 worktree 補設定

1. **`.turbo-plugin/dbhub.example.local.toml`**(db **owns**)— 不存在則複製
   `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/dbhub.example.local.toml`(此檔進 git,是給同事看的範本);
   **已存在則不覆寫**。
2. **`.turbo-plugin/dbhub.local.toml`** — **永不自動建立**(避免使用者誤以為已 ready)。不存在則提醒:
   「dbhub 需要你自填 credentials:`cp .turbo-plugin/dbhub.example.local.toml .turbo-plugin/dbhub.local.toml`
   後編輯填入連線資訊」(`.gitignore` base 已排除 `*.local.*`,不會進 git)。
3. **docker probe**(僅提示,不阻塞):`docker --version`。失敗 → Phase 4 記「dbhub MCP server 需要 docker;
   未偵測到,請確認 docker 已安裝並在跑」。

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
  - docker 未偵測到時的安裝提示。
  - 若要用 git↔SVN bridge / .NET Framework Web → 裝對應 plugin 並跑其 setup。
- **下一步**:「填好 `.turbo-plugin/dbhub.local.toml`、確認 docker 在跑後,可 `/tp-db-management`」。

## Decision Rules

- **先跑共用 base 段、再做 db concern** — base 只建 concern-neutral 共用檔;dbhub 相關屬 db。
- **db 不碰 config.toml** — base 段對 db 跳過 config.toml 那一項。
- **無 `.git/` 時 fail-loud,不自行 `git init`** — 建 git repo 屬 `turbo-plugin-git-svn`。
- **`dbhub.local.toml` 永不自動建立** — 只 prompt 使用者複製 example 後手動編輯(避免誤以為已 ready)。
- **db 不寫 `config.toml` 的任何標記區塊** — base 段建立的共用檔維持原樣,db 只管自己的 dbhub 檔(db-management 靠 skill description 觸發;`conventions.md` 機制已退役)。
- **Case (b)/(c) idempotent**;**Case (d)** 只處理 per-peer `dbhub.local.toml`,不碰 git-versioned shared file。
- **不自動代填使用者設定 / credentials** — 缺漏一律先 `AskUserQuestion`。
- **Phase summary transparency**:db 動作皆 repo-only,summary 無外部副作用可列。

## Completion Checks

- `.turbo-plugin/` 存在;db 未在 `config.toml` 寫入任何內容(亦不涉及 `conventions.md`——該機制已退役)。
- `.turbo-plugin/dbhub.example.local.toml` 存在(進 git);`dbhub.local.toml` **未**被自動建立(只提示)。
- Case (a)(無 `.git/`):setup fail-loud 停止,**未** `git init`、**未**建任何檔。
- Case (b)/(c):跑兩次結果同跑一次(idempotent)。
- Case (d):只處理 `dbhub.local.toml`,未動 git-versioned shared file。

## Test Scenarios

- **無 git fail-loud**:在無 `.git/` 的空目錄跑 `/tp-setup`,確認停止並提示,且**未** `git init`、**未**建 `.turbo-plugin/`。
- **dbhub.local.toml 不自動建**:乾淨 sandbox 跑 case (c),確認只建 `dbhub.example.local.toml`、提示複製,但**未**自動建 `dbhub.local.toml`。
- **db 只管 dbhub 檔**:跑 db setup 後,只建 / 提示 dbhub 檔,未寫入 `config.toml`(`conventions.md` 機制已退役,不涉及)。

## Tool Preference

所有檔案 read / write / search / edit 優先用 Read / Write / Edit / Glob / Grep / LSP,避開 Bash / PowerShell / Python /
Node.js 做檔案操作。shell 操作只限:`git` / `docker --version` 等 probe / 跑 plugin script。
