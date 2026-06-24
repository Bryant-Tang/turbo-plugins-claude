---
name: tp-stop-dotnet-framework-web
description: '停止某個 .NET Framework Web 專案對應的 IIS Express instance(透過 project identity 匹配 site name,跨 worktree 都能找到)——「給 agent 用的 VS 2022」:由你(agent)判斷要停哪個 csproj 對應的站台。使用者明確要求 stop 時執行;agent 偵測「使用者結束驗證、port 不再需要」時可建議。'
argument-hint: '[--project <path-to-csproj>]'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-stop-dotnet-framework-web

## Purpose

給 agent 用的 VS 2022「Stop」。你(agent)判斷要停哪個 `.csproj` 對應的 IIS Express instance,把明確
target 傳給變薄的 `Stop-Iis` 執行器;即使該 instance 是在別 worktree 啟的也能殺到(brainstorm 動機 bug 的
核心 fix)。stop 是 idempotent 操作,**只回報、永不 save-back**。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 判斷要停哪個 csproj

由你決定 stop 的對象,**不靠 script 自動偵測**。

- stop 一律針對**單一 csproj**的站台,**不接受 `.sln`**。
- 先查記憶 `[run].project`(無值時 fallback `[build].project`)。有值且檔在 → 用它。
- 沒記憶時用 Glob 找 `*.csproj`(跳過 `bin/`、`obj/`、`node_modules/`、`.vs/`、`.git/`);多個合理且無從判斷 → `AskUserQuestion` 請使用者選(或就是你剛 run 起來的那個)。

### Step 2 — 停止 IIS Express

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Stop-Iis.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.sh`)帶 `-Project <csproj>`。Script 流程:

- 解析 target(CLI → `[run].project` → fallback `[build].project` → 清楚報錯;**收到 `.sln` 報錯**)
- 計算 project identity + site name(內嵌 hash,跨 worktree 都能對上)
- 用 `Get-CimInstance Win32_Process` 找 `iisexpress.exe`,filter commandLine 含 `/site:<name>`
- 找到 → `Stop-Process -Force`;沒找到 → 印 `No IIS Express process found for site '<name>'.` 並 exit 0(不是 error,可能順帶提示同 stem 但不同 hash 的 orphan)

### Step 3 — 回報結果模板

腳本結尾印一行 `STOP_OUTPUT (...)` marker + 數行:這次 stop 針對的 **target 與 site name**(不論有沒有真的停到 process 都會印,告訴使用者鎖定的是哪個站台——糾錯閘)。把這些**逐字轉述**給使用者。**stop 不做 save-back**(只回報,不動記憶)。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **target 由你判斷、不靠 script 偵測**:要停哪個由你看 context / 記憶 / 必要時 `AskUserQuestion`;收到 `.sln` 報錯。
- **跨 worktree 識別**:site name 內嵌 project identity hash,不依賴 worktree 路徑;同 project 從任一 worktree 跑 stop 都能殺到。
- **別 project 不誤殺**:site name match 才殺,別 project 同 port 但 site name 不同 → 不殺。
- **無 instance 不報錯**:exit 0 + info message(stop 是 idempotent 操作)。
- **stop 永不 save-back**:只回報,不比對 / 不寫記憶。

## Completion Checks

- 對應 site 的 iisexpress.exe process 不再存在;`STOP_OUTPUT` 模板出現且 site/target 是預期專案。
- 別 project 的 iisexpress instance(若有)仍存在。
- 該 port `netstat -ano | findstr :<port>` 不再有 LISTENING(可能需 1-2 秒)。

## Test Scenarios

- **Cross-worktree stop**: 主 worktree 啟 iisexpress → 切到 peer worktree 跑 /tp-stop,確認該 PID 不見、`Get-Process iisexpress` 在主 worktree 也撈不到。
- **No-op when not running**: 沒 iisexpress 跑時 /tp-stop,輸出 `No IIS Express process found for site '<name>'.` + `STOP_OUTPUT` 模板、exit 0、無 error。
- **不誤殺別 project**: project A iisexpress 跑在 port X、project B 在 port Y → /tp-stop project A 只殺 A,B 仍 LISTENING。
- **`.sln` 被拒**: 傳 `-Project <.sln>` → script 報錯(stop 需 csproj)。

## Tool Preference

所有檔案 read / search 優先用 Read / Glob / Grep;shell 操作限 `Get-CimInstance` / `Stop-Process` / `netstat` / 跑 plugin script。
