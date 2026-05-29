---
name: tp-stop-dotnet-framework-web
description: '停止當前 project 對應的 IIS Express instance(透過 project identity 匹配 site name,跨 worktree 都能找到)。使用者明確要求 stop 時執行;agent 偵測「使用者結束驗證、port 不再需要」時可建議。'
argument-hint: '[--project <path>]'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-stop-dotnet-framework-web

## Purpose

停止當前 project 對應的 IIS Express instance,即使該 instance 是在別 worktree 啟動的也能殺到(brainstorm 動機 bug 的核心 fix)。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 停止 IIS Express

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Stop-Iis.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/stop-iis.sh`)帶 optional `-Project <path>`。Script 流程:
   - 偵測 `.csproj`(同 `tp-build`)
   - 計算 project identity + site name
   - 用 `Get-CimInstance Win32_Process` 找 `iisexpress.exe` instance,filter commandLine 含 `/site:<name>`
   - 找到 → `Stop-Process -Force`
   - 沒找到 → 印 `No IIS Express process found for site '<name>'.` 並 exit 0(不是 error)

## Decision Rules

- **跨 worktree 識別**:site name 內嵌 project identity hash(`<csproj-stem>-<sha256前8字元>`),不依賴 worktree 路徑。同 project 從任一 worktree 跑 stop 都能殺到。
- **別 project 不誤殺**:site name match 才殺,別 project 同 port 但 site name 不同 → 不殺。
- **無 instance 不報錯**:exit 0 + info message(stop 是 idempotent 操作)。

## Completion Checks

- 對應 site 的 iisexpress.exe process 不再存在(`Get-Process iisexpress -ErrorAction SilentlyContinue` 確認)。
- 別 project 的 iisexpress instance(若有)仍存在(verify by listing all iisexpress processes before & after)。
- 該 port `netstat -ano | findstr :<port>` 不再有 LISTENING(可能需要 1-2 秒才反映)。

## Test Scenarios

- Manual: 主 worktree 跑 `Get-ProjectIdentity.ps1` 記下 IDENTITY_HASH → 切到 peer worktree 跑同一個 → 兩值完全相同。不同 → 先修 Get-NormalizedAbsolutePath / git-common-dir 處理再跑後續 stop 測試(AE1)。
- **Cross-worktree stop**: 主 worktree 啟 iisexpress → 切到 peer worktree 跑 /tp-stop,確認該 PID 不見、`Get-Process iisexpress` 在主 worktree 也撈不到。
- **No-op when not running**: 沒 iisexpress 跑時呼叫 /tp-stop,輸出 `No IIS Express process found for site '<name>'.`、exit 0、無 error。
- **不誤殺別 project**: project A iisexpress 跑在 port X、project B iisexpress 跑在 port Y → /tp-stop project A 只殺 A,B 仍 LISTENING port Y。

## Tool Preference

shell 操作限 `Get-CimInstance` / `Stop-Process` / `netstat` / 跑 plugin script。
