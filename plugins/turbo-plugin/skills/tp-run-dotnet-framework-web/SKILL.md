---
name: tp-run-dotnet-framework-web
description: '在本機啟動 IIS Express 跑當前 .NET Framework Web 專案,內含 listening 健康檢查與跨 worktree self-heal(發現同 project 在別 worktree 已啟 → 自動停舊 instance 並重啟)。使用者明確要求 run 時執行;agent 偵測「準備手動驗證、需要本機跑起 IIS」時可建議。'
argument-hint: '[--project <path>] [--timeout <seconds>]'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-run-dotnet-framework-web

## Purpose

啟動 IIS Express 跑當前 .NET Framework Web 專案,自動處理跨 worktree project identity matching 與 listening 健康檢查。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 啟動 IIS Express

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/start-iis.{ps1,sh}` 帶 optional `-Project <path>` / `-Timeout <seconds>`。Script 流程:
   - 偵測 `.csproj`(同 `tp-build`)
   - parse `<IISUrl>` 取 port / scheme
   - 計算 project identity hash + site name(`<csproj-stem>-<sha256前8字元>`)
   - 找應該寫入 applicationhost.config 的目標(`.vs/<sln-stem>/config/applicationhost.config`)
   - 找已執行的 iisexpress.exe instance:
     - **同 port + site name 也 match(同 project,可能在別 worktree 啟動)** → 自動 `Stop-Process` 舊 instance,繼續啟新
     - **同 port + site name 不 match(別 project 撞 port)** → fail loudly,提示使用者停掉別 project 的 instance 或改 port
     - **無佔用** → 直接啟
   - 啟動前用 `Update-ApplicationhostConfig` refresh 當前 worktree 的 physicalPath(若 applicationhost.config 已存在 site)
   - `Start-Process iisexpress.exe /config:<apphost> /site:<name>`(若有 apphost target)或 `/path:<root> /port:<n>`(legacy mode)
   - polling `netstat` 直到 port LISTENING 或超時(R9 4 層 lookup:`-Timeout` arg → `[run].listening_timeout_seconds` → default 30)
2. 失敗時 fail loudly + 提示調 `listening_timeout_seconds` 或 check applicationhost.config。

## Decision Rules

- **跨 worktree self-heal(R15a)**:同 project 在別 worktree 已啟 → 自動停舊 instance,**不**詢問使用者(這是 brainstorm 動機 bug fix)。
- **別 project 撞 port(R15b)**:fail loudly,**不**自動停別 project 的 instance。
- **不直接寫 applicationhost.config 的 site 結構**:只 update 既有 site 的 physicalPath。若 site 不存在(VS 首次啟動會建)→ 跳過 update,start-iis 仍嘗試啟動,讓 IIS Express 自己處理。
- **listening 健康檢查 incorporated 進 run**(R17):啟完一定要驗 port 真的 LISTENING,不寫「Started PID xxx」就結束。
- **timeout 預設 30s**,可調(冷啟 + first-request JIT 場景使用者可在 `[run].listening_timeout_seconds` 設 90s)。

## Completion Checks

- `Started IIS Express (site: <name>, PID: <pid>)` 與 `Listening on <url>` 兩行都出現。
- `netstat -ano | findstr :<port>` 顯示 `LISTENING` 狀態。
- 如果有跨 worktree self-heal 觸發,輸出含 `Stopping previous instance(s)`。
- Manual: 兩次連續觸發 EnterWorktree 進同 worktree → `(Get-Item <apphost-target>).LastWriteTime` 兩次相同(idempotent skip 驗證;若有 Write-Verbose 輸出可見「idempotent skip: applicationhost.config already correct」)。
- Manual: 設 `[run] listening_timeout_seconds = 0` 於 .turbo-plugin/config.toml → /tp-run 應採用 0 為值(立即 timeout),**不**退回 default 30。驗 ps1 + sh 兩條路徑行為一致。
- Manual: 主 worktree 跑 `compute-project-identity.ps1` 記下 IDENTITY_HASH → 切到 peer worktree 跑同一個 → 兩值完全相同。不同 → 先修 Get-NormalizedAbsolutePath / git-common-dir 處理再跑 AE1。

## Test Scenarios

- **Cross-worktree self-heal (R15a)**: 主 worktree 跑 /tp-run 啟 iisexpress → 切到 peer worktree 跑 /tp-run,確認 (a) 舊 instance(主 worktree PID)被 Stop-Process、(b) 新 instance 啟在 peer worktree path、(c) `Started IIS Express` + `Listening on` 兩行都出現。
- **Port collision different project (R15b)**: 啟 project A → 另開 project B 設同 port `<IISUrl>` → /tp-run project B fail loudly,訊息含「別 project 撞 port」、不殺 A 的 instance、netstat A's port 仍 LISTENING。
- **Listening timeout**: 設 `.turbo-plugin/config.toml` `[run] listening_timeout_seconds = 1` → /tp-run 對啟動較慢 project(冷啟 + JIT)應在 1s 退,顯示 timeout 訊息建議調 timeout(.ps1 + .sh 兩條都驗)。

## Tool Preference

shell 操作限 `iisexpress.exe` / `netstat` / 跑 plugin script。
