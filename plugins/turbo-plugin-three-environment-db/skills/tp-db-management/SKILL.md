---
name: tp-db-management
description: '做任何資料庫 / SQL 相關工作時主動使用:查 schema、查資料、查物件,或準備 seed / migration / 部署 SQL,或任何需要先理解資料庫結構才能改 code 的情況。用 DBHub MCP server（read-only）檢視,並把標準化 SQL 寫到 .turbo-plugin/sql/<env>-db/<branch>/*.sql（<branch> 取自當前 git branch,斜線換短橫）。不要繞過本 skill 直接手寫 SQL 或用其它方式查資料庫。'
argument-hint: 'Optional: database name 或 target environment（local-db / test-db / main-db）'
user-invocable: true
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, mcp__tp-dbhub__execute_sql, mcp__tp-dbhub__run_sql, mcp__tp-dbhub__search_objects, mcp__tp-dbhub__list_tables, mcp__tp-dbhub__list_schemas, mcp__tp-dbhub__get_table_schema
---

# tp-db-management

## Purpose

兩件事：

1. **唯讀檢視資料庫** — 透過 `tp-dbhub` DBHub MCP server 查 schema、資料、stored procedure、function、index 等，幫助理解結構後再改 code。**只讀不寫**。
2. **標準化 SQL 輸出** — 若工作需要任何寫入側的資料庫異動（補資料 / 改 schema / seed / backfill / migration），不直接透過 MCP 執行寫操作，而是產出標準化 `.sql` 檔，落在 `.turbo-plugin/sql/<env>-db/<branch>/`，供使用者在各環境手動執行。

本 skill 是從舊 dev-flow `db-management` 移植來的 **de-coupled 版本**：移除了所有 spec / slug / `finish-dev` 自動歸檔等 dev-flow 耦合，改以「**當前 git branch 名**」作為單一分組鍵。

## DBHub MCP server（read-only）

- MCP server 名稱：`tp-dbhub`（宣告於 `plugins/turbo-plugin/.mcp.json`，docker 跑 `bytebase/dbhub`，config 來自 `.turbo-plugin/dbhub.local.toml`）。
- 用 `tp-dbhub` 暴露的 **唯讀** MCP tool 查詢：執行查詢的 tool（execute / run SQL）、物件搜尋的 tool（search objects / list tables / get table schema 等）。實際 tool 名稱後綴可能依 DBHub 版本不同，先確認當前 session 暴露的 `tp-dbhub` tool 集再呼叫。
- **DBHub 在本 repo 連的是 local 資料庫**，不直接連 test / production。test / main 的物件定義差異要靠使用者在目標環境跑你提供的最小唯讀查詢來確認（見下方 Fixed Constraints）。

## SQL 輸出落點（KTD10 — 關鍵 de-coupling）

標準化 SQL **一律** 落在：

```
.turbo-plugin/sql/<env>-db/<branch>/<order>-<database>-<purpose>.sql
```

- `<env>` = 目標資料庫環境，固定三選一：`local-db` / `test-db` / `main-db`（與舊 skill 同一組）。
- `<branch>` = **當前 git branch 名**，取得方式：

  ```bash
  git rev-parse --abbrev-ref HEAD
  ```

  然後 **把名稱中的所有 `/` 換成 `-`**，例如 `feature/x` → `feature-x`、`bugfix/login-2` → `bugfix-login-2`。這維持單層分組鍵、避免巢狀路徑，也避免 `x` 與 `feature/x` 混淆。此 branch 名 **取代舊 dev-flow 的 `<slug>`**。
  - 若 `HEAD` 為 detached（`git rev-parse --abbrev-ref HEAD` 回 `HEAD`）→ fail loudly，請使用者先 checkout 一個具名 branch 再跑（不要用 `HEAD` 當分組鍵）。
- `<order>` = 2 位數執行順序（`01` / `02` / `03`…）。
- `<database>` = 實際目標資料庫名。
- `<purpose>` = 簡短用途描述，建議繁體中文（如 `補資料` / `新增欄位` / `重建索引` / `建立測試資料`）。
- **同一個邏輯變更** 在 `local-db` / `test-db` / `main-db` 之間用 **相同 branch 子資料夾名 + 相同檔名**，方便對齊。

`.turbo-plugin/sql/` **進 git 版控**（可分享的 SQL，與 gitignored 的 `.turbo-plugin/worktrees/` 區隔）。`.gitignore`（由 tp-setup 寫入）只忽略 `.turbo-plugin/worktrees/` 與 `*.local.*`，**不** 忽略 `.turbo-plugin/sql/`。產出的 SQL 檔應正常出現在 `git status`。

## Fixed Constraints

- 本 repo 所有 DBHub MCP 存取 **皆唯讀**，**絕不** 透過 MCP tool 執行 `INSERT` / `UPDATE` / `DELETE` / `CREATE` / `ALTER` / `DROP` 等寫操作。
- **DBHub 連線範圍 = local 資料庫（`local-db`）only**，絕不直連 test / production；test / main 的物件差異一律靠使用者在目標環境跑最小唯讀查詢確認。
- 任何寫入側需求（資料修正 / schema 變更 / seed / backfill / migration）→ 產 `.sql` 檔到 `.turbo-plugin/sql/<env>-db/<branch>/`，**不** 直接寫資料庫。
- **不要假設 local / test / production 結構一致**：欄位、view、stored procedure、function、trigger 都可能依環境不同。
- 若 `test-db` / `main-db` 腳本依賴某物件定義，而該定義在非 local 環境可能不同 → 先給使用者一個 **最小唯讀查詢**（最好是簡單 `SELECT`），請他在目標環境跑完回傳結果，再據此 finalize 對應 SQL。**不要** 假裝 DBHub 能檢視 test / production。
- **已發佈的 SQL 視為不可變**：已透過 `tp-push-to-svn` 推到 `remote-svn/*` 且已打過 release tag 的 `.sql`，**不得**再編輯舊檔——要修正改走**新檔**（遞增 `<order>` 的新 `.sql`）。SVN history 與 release tag 是永久紀錄，改舊檔會讓已部署環境與版控對不上。
- **版控 SQL 不得含敏感資料**：`.turbo-plugin/sql/`（進 git）裡的 `.sql` **不得**包含字面憑證、含密碼的連線字串、或超出該 schema 遷移所需的 PII。連線資訊一律走 gitignored 的 `.turbo-plugin/dbhub.local.toml`；SQL 內需要範例值時用 placeholder，不要寫真實機密 / 個資。

| 環境資料夾 | 用途 |
|---|---|
| `.turbo-plugin/sql/local-db/<branch>/` | local 驗證、暫時測試資料、或本地驗證後會回滾的腳本 |
| `.turbo-plugin/sql/test-db/<branch>/` | 客戶測試環境部署腳本 |
| `.turbo-plugin/sql/main-db/<branch>/` | production 部署腳本 |

- 環境資料夾或 branch 子資料夾不存在時，先建再放腳本。
- 純 local 驗證（測完回滾）的腳本只放 `local-db/<branch>/`。
- 最終發佈版若 production 也要改 → 在三處 `local-db` / `test-db` / `main-db` 各備一份對齊的腳本。

## SQL Template

- 用共用模板 [assets/sql-script-template.sql](./assets/sql-script-template.sql)。
- 把同一個版面複製進每個環境的 SQL 檔，讓 local / test / production 腳本保有相同的 header、執行順序、pre-check、main change、post-check 段落。
- local-only 驗證腳本沿用同模板，但只放 `local-db/<branch>/` 並填好 rollback 段落。
- production-bound 變更先建三份檔，再讓三份的註解與段落順序對齊。

## Procedure

1. 釐清本次工作相關的是哪個 connected 資料庫。
2. 若 table / column / procedure / function / index 名稱不確定，先用 `tp-dbhub` 的物件搜尋 MCP tool。
3. 用 `tp-dbhub` 的查詢 MCP tool **只查最小必要資料**（唯讀）。
4. 把資料庫查到的事實轉成需要的 code 變更或實作決策。
5. 若需要任何寫入側資料庫動作，先決定目標環境範圍：local-only 驗證 / test 部署 / 含 production 的完整發佈。
6. 算出 branch 分組鍵：跑 `git rev-parse --abbrev-ref HEAD`，把 `/` 換成 `-`（detached HEAD → fail loudly，請使用者先 checkout 具名 branch）。
7. 若 SQL 只供 local 驗證且測完回滾 → 只建 `.turbo-plugin/sql/local-db/<branch>/`。
8. 若是最終發佈且 production 也要改 → 在 `.turbo-plugin/sql/local-db/<branch>/`、`.turbo-plugin/sql/test-db/<branch>/`、`.turbo-plugin/sql/main-db/<branch>/` 建對齊腳本。
9. finalize `test-db` / `main-db` 腳本前，確認相關欄位 / view / procedure / function / trigger 在該環境是否已知相同；若不確定，給使用者最小驗證查詢並等結果。
10. 目標環境範圍從需求不明顯時，先問再建檔。
11. 每個 SQL 檔用 `<order>-<database>-<purpose>.sql` 命名。
12. 從 [assets/sql-script-template.sql](./assets/sql-script-template.sql) 起手，讓產出檔共用同結構。
13. 每支腳本適當時加 `USE [DatabaseName]`，statement 依執行順序排，加足夠註解說明特殊步驟 / 回滾預期 / 環境差異。
14. 多個邏輯變更時優先拆成多支 SQL 檔，除非步驟必須一起執行。
15. 回報兩部分結果：唯讀檢視驗證到什麼、使用者還需要在 test / production 自行驗證什麼（若有）、以及準備了哪些 SQL 供手動執行（含落點路徑）。

## Decision Rules

- **唯讀存取**：DBHub MCP 只用來查，**永不** 透過 MCP 改資料庫。把 MCP 唯讀存取當成「可以查」不等於「可以略過 SQL 檔交付」。
- **branch 名 slash→dash 轉換**：分組鍵一律 `git rev-parse --abbrev-ref HEAD` 的結果把 `/` 換 `-`；不接受 detached HEAD（`HEAD` 字面）當分組鍵 → fail loudly。
- **不依賴 dev-flow**：沒有 spec / slug / work-item 概念，分組鍵只看 branch 名；不做 `finish-dev` 式自動歸檔。
- **SQL 目錄進版控**：`.turbo-plugin/sql/` 不在 gitignore，產出的 SQL 是可分享、可 commit 的；不要把它跟 gitignored 的 `.turbo-plugin/worktrees/` 混淆。
- 純調查（不需寫入）→ 不建 SQL 檔。
- 需要 schema discovery → 先用 `tp-dbhub` 物件搜尋 tool 再寫廣泛 `SELECT`。
- local 變更只放 `local-db/<branch>/`；只進 test 不進 production 放 `test-db/<branch>/`；要上 production 三處都備。
- 明顯不是 local-only 但沒講清楚 test-db only 還是含 main-db → 先問環境矩陣再寫 SQL。
- local 查到的結果可能與 test / production 物件定義不符 → 停止假設一致，請使用者在目標環境跑最小驗證查詢回傳結果。
- 多個資料庫要改 → 依資料庫或執行步驟拆檔。
- 腳本依賴手動後處理 / trigger 重建 / 環境特定 review → 在 SQL 註解明寫。
- **dbhub MCP 不可用時 fail loudly**：若當前 session 沒有 `tp-dbhub` MCP tool（未跑 `/tp-setup` 設好 `dbhub.local.toml`、或 docker 未起）→ 明確告知使用者「dbhub MCP server 不可用，請先跑 `/tp-setup` 設定 `.turbo-plugin/dbhub.local.toml` 並確認 docker 在跑」，**不** 靜默改用猜測或其它方式假裝查到資料庫。
- **逐步執行 side-effect 指令**：需要 terminal 指令時，每個會改狀態的步驟（建資料夾、寫檔、cleanup）分開跑，**不** 用單一多行 shell block 或 `&&` 串接。

## Completion Checks

- 資料庫檢視只用了 `tp-dbhub` 的唯讀 MCP tool，**沒有** 透過 MCP 執行任何寫 SQL。
- 任何寫入側資料庫工作都落成 `.turbo-plugin/sql/<env>-db/<branch>/` 下的 `.sql` 檔（`<env>` ∈ {local-db, test-db, main-db}）。
- 分組鍵是當前 git branch 名且已套用 slash→dash 轉換（如 `feature/x` → `feature-x`）；沒有用 detached `HEAD` 當分組鍵。
- local-only 驗證腳本只在 `.turbo-plugin/sql/local-db/<branch>/`；production-bound 變更三處 `local-db` / `test-db` / `main-db` 都備齊。
- 產出檔遵循 [assets/sql-script-template.sql](./assets/sql-script-template.sql) 的版面，檔名遵循 `<order>-<database>-<purpose>.sql`。
- 產出的 SQL 出現在 `git status`（`.turbo-plugin/sql/` 非 gitignored），落點與命名可重現。
- 最終回報清楚區分「唯讀檢視驗證到的事實」與「準備供手動執行的 SQL 變更」。

## Tool Preference

檔案 read / write / search / edit 一律用 Read / Write / Edit / Glob / Grep。資料庫查詢只走 `tp-dbhub` 唯讀 MCP tool。shell 操作限 `git`（取 branch 名）與建立資料夾，逐步執行不串接。
