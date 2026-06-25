---
name: tp-run-dotnet-framework-web
description: '在本機啟動 IIS Express 跑某個 .NET Framework Web 專案——「給 agent 用的 VS 2022」:由你(agent)判斷要跑哪個 csproj。內含 listening 健康檢查與跨 worktree self-heal(發現同 project 在別 worktree 已啟 → 自動停舊 instance 並重啟)。使用者明確要求 run 時執行;agent 偵測「準備手動驗證、需要本機跑起 IIS」時可建議。'
argument-hint: '[--project <path-to-csproj>] [--timeout <seconds>]'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-run-dotnet-framework-web

## Purpose

給 agent 用的 VS 2022「Run」。你(agent)判斷要跑哪個 `.csproj`,把明確 target 傳給變薄的 `Start-Iis`
執行器;它啟動 IIS Express 服務該專案上次的 build 產物,並處理跨 worktree project identity matching 與
listening 健康檢查。run **不涉 configuration**(服務的是已建好的產物)。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 判斷要跑哪個 csproj

你是這個專案的 VS,由你決定 run 的對象,**不靠 script 自動偵測**。

- run 一律是**單一 csproj**(IIS Express 跑一個 web 專案),**不接受 `.sln`**。
- 先查記憶 `[run].project`(無值時 fallback 讀 `[build].project`)。有值、檔在、**且是 csproj** → 用它。
- **fallback 撈到的 `[build].project` 可能是 `.sln`(整個方案)**——run 跑的是單一 web 專案、不能跑方案。這時**別把 `.sln` 當 target**,改走下面的探索(跟「沒記憶」一樣),由你自己判斷出該跑的 web csproj。
- 沒記憶(或 fallback 撈到 `.sln`)時用 Glob 找 `*.csproj`(跳過 `bin/`、`obj/`、`node_modules/`、`.vs/`、`.git/`),判斷哪個是要在本機跑起來的 web 專案;多個合理且無從判斷 → `AskUserQuestion` 請使用者選。
- run **不要**傳 configuration——它服務的是上次 build 的產物。

### Step 2 — 啟動 IIS Express

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Start-Iis.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/start-iis.sh`)帶 `-Project <csproj>`、(可選)`-Timeout <seconds>`。Script 流程:

- 解析 target(CLI → `[run].project` → fallback `[build].project` → 清楚報錯;**收到 `.sln` 報錯**)
- parse `<IISUrl>` 取 port / scheme;計算 project identity hash + site name(`<csproj-stem>-<sha256前8字元>`)
- 找已執行的 iisexpress.exe instance:
  - **同 port + site name 也 match(同 project,可能在別 worktree 啟)** → 自動 `Stop-Process` 舊 instance,繼續啟新
  - **同 port + site name 不 match(別 project 撞 port)** → fail loudly,提示停掉別 project 的 instance 或改 port
  - **無佔用** → 直接啟
- 渲染 per-launch temp applicationhost.config(canonical 不變,替換 physicalPath 為當前 worktree)、`Start-Process iisexpress.exe`、polling `netstat` 直到 port LISTENING 或超時(`-Timeout` → `[run].listening_timeout_seconds` → default 30)

### Step 3 — 回報結果模板

腳本結尾印 `Listening on <url>` 與一行 `RUN_OUTPUT (...)` marker + 數行:**解析後的實際 target** 與 web URL(run 不涉 configuration)。把這些**逐字轉述**給使用者;URL 那行保持原樣(不接散文/句號)讓它可點擊。「解析後 target」是糾錯閘——確認跑的是不是對的專案。

### Step 4 — 記憶存回(save-back)

run 成功後,讀並遵循 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/memory-save-back.md`:比對這次選定的 target 與已存記憶,有差異就問使用者要不要存。**run 存回寫 `[run].project`**(不寫 `[build]`)。run 不涉 configuration,故 save-back 只比對 target。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **target 由你判斷、不靠 script 偵測**:要跑哪個 csproj 由你看 context / 記憶 / 必要時 `AskUserQuestion`;收到 `.sln` 報錯。
- **跨 worktree self-heal**:同 project 在別 worktree 已啟 → 自動停舊 instance,**不**詢問使用者(這是 brainstorm 動機 bug fix)。
- **別 project 撞 port**:fail loudly,**不**自動停別 project 的 instance。
- **listening 健康檢查 incorporated 進 run**:啟完一定要驗 port 真的 LISTENING,不寫「Started PID xxx」就結束。
- **timeout 預設 30s**,可調(冷啟 + first-request JIT 場景使用者可在 `[run].listening_timeout_seconds` 設 90s)。
- run **不涉 configuration**:服務上次 build 的產物,save-back 也只記 target。

## Completion Checks

- `Started IIS Express (site: <name>, PID: <pid>)`、`Listening on <url>`、`RUN_OUTPUT` 模板都出現,且解析後 target 是預期專案。
- `netstat -ano | findstr :<port>` 顯示 `LISTENING` 狀態。
- 如果有跨 worktree self-heal 觸發,輸出含 `Stopping previous instance(s)`。
- save-back:若 target 與記憶不同,已問過使用者並寫對 `[run].project`。
- Manual: 主 worktree 跑 `Get-ProjectIdentity.ps1` 記下 IDENTITY_HASH → 切到 peer worktree 跑同一個 → 兩值完全相同。

## Test Scenarios

- **Cross-worktree self-heal**: 主 worktree 跑 /tp-run 啟 iisexpress → 切到 peer worktree 跑 /tp-run,確認 (a) 舊 instance 被 Stop-Process、(b) 新 instance 啟在 peer worktree path、(c) `Started IIS Express` + `Listening on` + `RUN_OUTPUT` 都出現。
- **Port collision different project**: 啟 project A → 另開 project B 設同 port `<IISUrl>` → /tp-run project B fail loudly,不殺 A 的 instance、netstat A's port 仍 LISTENING。
- **`.sln` 被拒**: 傳 `-Project <.sln>` → script 報錯(run 需 csproj)。
- **多個 csproj、無記憶**: worktree 多個 csproj 又沒 `[run].project`/`[build].project` → 你用 `AskUserQuestion` 列候選請使用者選。
- **Listening timeout**: 設 `[run] listening_timeout_seconds = 1` → /tp-run 對啟動較慢 project 在 1s 退並提示調 timeout(.ps1 + .sh 兩條都驗)。
- **併發 run 各自站台**: 兩個不同 csproj 各自 /tp-run → 兩站台共存、各自 LISTENING。

## Tool Preference

所有檔案 read / write / search / edit(含 save-back)優先用 Read / Edit / Write / Glob / Grep;shell 操作限 `iisexpress.exe` / `netstat` / 跑 plugin script。
