---
name: tp-cleanup-orphan-iis
description: '清除殘留的孤兒 IIS Express process 及 applicationhost.config site 條目,通常在 worktree rename 或 project 搬移後出現。使用者明確要求清除時執行;tp-stop 偵測到同 csproj-stem 但不同 hash 的 orphan instance 時建議。'
argument-hint: '[--project <path>]'
user-invocable: true
allowed-tools: Bash, Read, Grep, AskUserQuestion
---

# tp-cleanup-orphan-iis

## Purpose

清除因 worktree rename / project 搬移留下的孤兒 IIS Express instance 與 applicationhost.config `<site>` 條目。turbo-plugin 以 `<csproj-stem>-<sha256前8字元>` 格式命名 site,hash 改變後舊條目 / 舊 process 不會自動清除。

實際掃描與移除動作都在 `${CLAUDE_PLUGIN_ROOT}/scripts/Remove-OrphanIis.ps1`(Windows-only;非 Windows 沒有 IIS Express)。Skill 只負責呼叫 script、解析輸出、跟使用者確認後再次呼叫 script 執行刪除。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 枚舉孤兒

執行(無刪除參數;若使用者帶 `--project <path>` 則一併轉發 `-Project <path>`):

```
${CLAUDE_PLUGIN_ROOT}/scripts/Remove-OrphanIis.ps1 [-Project <path>]
```

stdout 會是以下其中之一:

- `No orphan IIS Express instances or applicationhost.config sites found.` → 沒有孤兒,直接結束,告知使用者「未發現孤兒」即可。
- 一行或多行 `ORPHAN: <site_name> <kind> pid=<n|->`,其中 `<kind>` 是 `process` / `xml` / `both`,`pid` 在 `xml` 類為 `-`。

**Parse rule**: each ORPHAN: line has shape `ORPHAN: <site_name> <kind> pid=<value>` where:
- `<kind>` is one of `process` / `xml` / `both`
- `<value>` is an integer PID when kind is `process` or `both`
- `<value>` is the literal string `-` when kind is `xml` (no running process)

Parse into `{ site_name: string, kind: 'process'|'xml'|'both', pid: number|null }`, mapping `-` to `null`。進入 Step 2。

### Step 2 — 使用者確認

用 `AskUserQuestion` 列出 Step 1 收到的孤兒,讓使用者多選要清除的項目(可全選 / 部分選 / 取消):

```
偵測到下列孤兒,選擇要清除的項目:
  <site_name_1>  [<kind>]  pid=<n>
  <site_name_2>  [<kind>]  pid=<n>
  ...
```

提供選項:
- 全部清除(對應 `-RemoveAll`)
- 各 site 各自一個 checkbox(對應對該 site 呼叫一次 `-RemoveSite <name>`)
- 取消

若使用者取消,直接結束、不執行任何刪除。

### Step 3 — 執行清除

- 若使用者選「全部清除」,執行:`${CLAUDE_PLUGIN_ROOT}/scripts/Remove-OrphanIis.ps1 -RemoveAll`
- 否則對每個被勾選的 site 依序執行:`${CLAUDE_PLUGIN_ROOT}/scripts/Remove-OrphanIis.ps1 -RemoveSite <site_name>`

把 script 的 stdout / stderr 直接呈現給使用者。

**Exit codes after -RemoveSite / -RemoveAll**:
- 0 = all selected orphans cleaned cleanly
- 1 = unrecoverable upstream error (Resolve-IisSettings failed, etc.)
- 2 = partial failure — at least one orphan failed. stdout contains `PARTIAL_FAILURE: failed=<n> sites=<comma-list>`. stderr contains per-site reason. Re-run enumerate to see remaining orphans.

Both `-RemoveSite` and `-RemoveAll` honor the same exit code contract. For the agent looping over multiple `-RemoveSite` calls, treat exit 2 as "continue with remaining selections, surface this site's reason to the user".

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **只處理 turbo-plugin 格式的 site name**(`<stem>-<8hex>`);script 本身已過濾,Skill 無需重複判斷。
- **不自動清除**:Step 2 的使用者確認不可跳過;絕不在沒有明確選擇下呼叫 `-RemoveAll`。
- **不嘗試重建正確 site 條目**:清除後,使用者應重跑 `/tp-setup` 或用 Visual Studio 開啟 .sln 讓 VS 重建正確條目。
- **stop-iis 的提示路徑**:`tp-stop` 偵測到同 stem-不同 hash 的 instance 時會建議使用者跑 `/tp-cleanup-orphan-iis`,本 skill 就是該流程的目的地。

## Completion Checks

- 對使用者選擇要刪除的每個 site:再跑一次 `Remove-OrphanIis.ps1`(不帶刪除參數)的 stdout 應不再包含對應 `ORPHAN:` 行。
- 未被選到的孤兒應仍出現在重跑後的列表中(只移除使用者明確選擇的項目)。

## Test Scenarios

- **Process orphan only**: launch a dummy IIS Express with `/site:<csproj-stem>-deadbeef`(隨意 hash),確認 enumerate-only 模式輸出 `ORPHAN: <name> process pid=<n>`、kind 是 `process`、pid 是整數。`-RemoveSite <name>` 後 `Get-Process iisexpress` 確認該 PID 不見。
- **XML orphan only**: 手動編輯 applicationhost.config 加 `<site name="<csproj-stem>-cafe1234">...</site>`,enumerate 應顯示 `ORPHAN: <name> xml pid=-`、kind 是 `xml`、pid 是字面 `-`。`-RemoveSite <name>` 後該 site node 從 XML 移除。
- **Both kinds**: 同 site name 同時有 process + XML node,enumerate 顯示 `ORPHAN: <name> both pid=<n>`。`-RemoveSite` 同時殺 process 並移除 XML。
  - Post-removal: `Get-Process iisexpress | Where-Object { $_.CommandLine -match '/site:<that-name>' }` 為空。
  - Re-run enumerate 不再列該 ORPHAN 行。
  - `Select-Xml -Path <apphost> -XPath "//site[@name='<that-name>']"` 為空。
- **Cancel path**: enumerate 後使用者選 Cancel,確認 script 沒被以 `-RemoveAll` / `-RemoveSite` 模式呼叫、applicationhost.config + iisexpress process list 都沒改。
- **Idempotency**: 連跑 enumerate 兩次,輸出穩定;`-RemoveAll` 兩次,第二次顯示 `No orphan IIS Express instances or applicationhost.config sites found.` 並 exit 0。
- **Partial selection**: 3 個 orphan,只選 1 個 → 該 site 不見、其餘 2 個 enumerate 仍出現。
- **Partial failure**: 在 second terminal 用 PowerShell 開 `[System.IO.File]::Open($apphostPath, 'Open', 'Read', 'None')` 取得獨佔讀取鎖。先 terminal 跑 `-RemoveAll` 對 2 個 orphan,Stop-Process 應全成功,但 Remove-ApplicationhostSite 在第二個 site 上 Move-Item 失敗(file locked)。確認 exit code 為 2、stdout 含 `PARTIAL_FAILURE: failed=1 sites=<that-name>`、stderr 含 per-site reason。釋放鎖後 re-run enumerate,確認剩該 1 個 orphan(其他都清掉)。

## Tool Preference

呼叫 script 用 Bash / PowerShell tool;讀取 / 解析 stdout 用 Read / Grep。其它檔案操作優先使用 Read / Write / Edit。
