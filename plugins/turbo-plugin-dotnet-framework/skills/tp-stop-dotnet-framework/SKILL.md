---
name: tp-stop-dotnet-framework
description: 'Stop what tp-run started. You pick the csproj, then dispatch on `<OutputType>`: a web project''s IIS Express instance is matched by project identity across worktrees; a console project is stopped by PID, only if this tool started it. Run on request, or suggest when the port is no longer needed.'
argument-hint: '[--project <path-to-csproj>] [--repo-root <path>]'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-stop-dotnet-framework

## Purpose

給 agent 用的 VS 2022「Stop」。你(agent)判斷要停哪個 `.csproj` 對應的 IIS Express instance,把明確
target 傳給變薄的 `Stop-Iis` 執行器;即使該 instance 是在別 worktree 啟的也能殺到(brainstorm 動機 bug 的
核心 fix)。stop 是 idempotent 操作,**只回報、永不 save-back**。

## Procedure

> **先決定要對哪個專案動手。** 讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`。
> 摘要:單一專案的 session 不必傳 `--repo-root`(維持既有行為,當前目錄就是那個專案);
> session 開在「並排放著多個獨立專案」的資料夾時,**問使用者要動哪一個、用 `--repo-root`
> 指名**,不要用 `cd` 切過去——`cd` 會把「動了誰」藏在 shell 指令裡。下面每一步的
> `.turbo-plugin/` 與 csproj 解析都以這個目標為準。

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

> **這道閘只管 IIS。** `[iis] enabled = false` 的意思是「這台機器不跑 IIS Express」,與 console 專案無關——console 不碰 IIS。所以若 Step 1.5 判定是 console 專案,**忽略這道閘**繼續往下。

### Step 1 — 判斷要停哪個 csproj

由你決定 stop 的對象,**不靠 script 自動偵測**。

- stop 一律針對**單一 csproj**的站台,**不接受 `.sln`**。
- 先查記憶 `[run].project`(無值時 fallback `[build].project`)。有值、檔在、**且是 csproj** → 用它。
- **fallback 撈到的 `[build].project` 可能是 `.sln`**——stop 是針對單一 csproj 的站台、不對應整個方案。這時**別把 `.sln` 當 target**,改走下面的探索,由你自己判斷出要停哪個 csproj 的站台。
- 沒記憶(或 fallback 撈到 `.sln`)時用 Glob 找 `*.csproj`(跳過 `bin/`、`obj/`、`node_modules/`、`.vs/`、`.git/`);多個合理且無從判斷 → `AskUserQuestion` 請使用者選(或就是你剛 run 起來的那個)。

### Step 1.5 — 這是 web 專案還是 console 專案?

**先分流,再往下走。** 這個 plugin 服務兩種 .NET Framework 專案,兩種的「跑起來」是完全不同的事。

判準:讀那個 csproj 的 `<OutputType>`。

| `<OutputType>` | 是什麼 | 走哪條 |
|---|---|---|
| `Exe` / `WinExe` | console 專案 | **console 路徑**(執行建置出來的 exe) |
| `Library` | 類別庫或 web 專案 | web 專案 → **IIS Express 路徑**;純類別庫 → 跑不起來,直說 |

`Library` 還要再分:web 專案的 csproj 會有 web 專案型別 GUID(`<ProjectTypeGuids>` 含
`349C5851-65DF-11DA-9384-00065B846F21`)或 `<IISUrl>` / `<DevelopmentServerPort>` 這類設定;
兩者都沒有的 `Library` 就是純類別庫,沒有東西可以跑。

**判不出來就問使用者,不要猜。** 猜錯的兩個方向都很糟:對 console 專案起 IIS 會拿到看不懂的錯誤,
對 web 專案找 exe 則永遠找不到。

### Step 2 — 停止 IIS Express(web 專案)

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Stop-Iis.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.sh`)帶 `-Project <csproj>`。Script 流程:

- 解析 target(CLI → `[run].project` → fallback `[build].project` → 清楚報錯;**收到 `.sln` 報錯**)
- 計算 project identity + site name(內嵌 hash,跨 worktree 都能對上)
- 用 `Get-CimInstance Win32_Process` 找 `iisexpress.exe`,filter commandLine 含 `/site:<name>`
- 找到 → `Stop-Process -Force`;沒找到 → 印 `No IIS Express process found for site '<name>'.` 並 exit 0(不是 error,可能順帶提示同 stem 但不同 hash 的 orphan)

### Step 2b — console 專案:停止

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Stop-Console.ps1`(或 `.../stop-console.sh`)。

它**只**停「本工具啟動、而且還在跑」的那一個,按 PID(並比對啟動時間,避免 PID 被作業系統重用時
誤殺別的程序)。**沒有孤兒清理**,這是刻意的:VS 對 Ctrl+F5 起的 console 也不追蹤,對齊 VS 就是
連它不做的事也不做。

**「沒有東西在跑」是正常結果、不是錯誤**——一次性的 console 早就自己結束了。照實轉述即可,不要
包裝成失敗。

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

- **一次性 console 早已結束**:stop 回報「沒有東西在跑」並正常結束——這是**正常結果不是錯誤**。
- **常駐 console**:stop 按 PID 停掉本工具啟動的那一個,不影響其它程序。
- **PID 被重用**:紀錄裡的 PID 現在屬於別的程序(啟動時間對不上)→ **不得**停掉它,回報「沒有東西在跑」。
- **web 專案回歸**:web 專案的 stop 行為完全不變。

- **Cross-worktree stop**: 主 worktree 啟 iisexpress → 切到 peer worktree 跑 /tp-stop,確認該 PID 不見、`Get-Process iisexpress` 在主 worktree 也撈不到。
- **No-op when not running**: 沒 iisexpress 跑時 /tp-stop,輸出 `No IIS Express process found for site '<name>'.` + `STOP_OUTPUT` 模板、exit 0、無 error。
- **不誤殺別 project**: project A iisexpress 跑在 port X、project B 在 port Y → /tp-stop project A 只殺 A,B 仍 LISTENING。
- **`.sln` 被拒**: 傳 `-Project <.sln>` → script 報錯(stop 需 csproj)。

## Tool Preference

所有檔案 read / search 優先用 Read / Glob / Grep;shell 操作限 `Get-CimInstance` / `Stop-Process` / `netstat` / 跑 plugin script。
