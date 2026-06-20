---
name: tp-publish-dotnet-framework-web
description: '對 .NET Framework Web 專案跑 MSBuild publish(含 frontend pack 步驟)。**publish 產出可能被 CD pipeline 消費,影響部署環境;必須使用者明確要求才執行**;agent 偵測到「完成一輪改動準備部署」時可建議,但需明確確認。'
argument-hint: '[--pubxml <path>] [--configuration <name>] [--platform <name>] [--project <path>]'
user-invocable: true
allowed-tools: Bash, Read, AskUserQuestion
---

# tp-publish-dotnet-framework-web

## Purpose

對 .NET Framework Web 專案跑 MSBuild publish:先跑 frontend pack(若 `[frontend]` 設定齊備),再用 `.pubxml` profile 跑 `msbuild /p:DeployOnBuild=true`,落地產出到 `<PublishUrl>`。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 執行 publish

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Publish-Web.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.sh`)帶 optional 參數。Script 會:
   - 偵測 `.csproj`(同 `tp-build`)
   - 偵測 MSBuild(同 `tp-build`)
   - 偵測 `.pubxml`(CLI arg → `config.toml [publish].default_pubxml` → 自動找 `<project>/Properties/PublishProfiles/` 單一 `.pubxml`)
   - 跑 `Compress-Content.ps1`(若 `[frontend]` 設定齊備)
   - 跑 `msbuild /p:DeployOnBuild=true /p:PublishProfile=<name> /p:PublishProfileRootFolder=<dir> /p:Configuration=<cfg> /p:Platform=<plat>`
   - 後處理:parse `.pubxml` 取 `<PublishUrl>` + `<WebPublishMethod>`,回報實際產出位置(`FileSystem` 落地路徑 / FTP URL 等)
2. 解讀輸出:腳本成功後印一行 `PUBLISH_OUTPUT (...)` marker,**緊接其後的兩行**即產出位置——第一行 raw Windows 絕對路徑、第二行 `file:///` URL(非 FileSystem 發佈方式則 marker 後只有一行 URL)。把那兩行(或一行)**逐字**呈現給使用者:**各自單獨成行、前後不接任何散文或標點**(不要包成「產出在:…」、也不要在行尾加句號),讓終端機能把路徑算成可點擊連結。**只轉述那兩行,不要轉述 marker 行本身。**

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **TRUST_REQUIRED 處理**: 若 script stdout 含 `TRUST_REQUIRED hash=<h> install_command=<cmd> build_command=<cmd>`,用 `AskUserQuestion` 顯示實際指令並詢問:「即將執行以下 frontend 指令,確認允許?`install: <cmd>` / `build: <cmd>`」。使用者選 Yes → 寫入 `.turbo-plugin/pack-content-trust.local.toml`(格式:`approved_hash = "<h>"`)並重新呼叫 script。使用者選 No → 終止 skill。
- 多個 `.pubxml` 又沒指定 → fail loudly 列出候選 + 建議設 `[publish].default_pubxml`。
- 內建 default:`Configuration = Release`,`Platform = Any CPU`(刻意不同於 `tp-build` 的 Debug default)。
- Frontend pack 是 publish 鏈的一部份(brainstorm R17:pack-content 邏輯併入 publish);**不要在 SKILL 內額外呼叫** `pack-content`,script 已包含。
- Publish 影響外部 artifact(可能被 CD pipeline 消費),屬 **proactive suggestion only** 類別 — agent 偵測到「使用者完成準備部署」時可建議,但需明確同意。

## Completion Checks

- `msbuild` 結束 exit code 為 0。
- `<PublishUrl>` 路徑含新 artifact。
- 若 frontend 設定齊備:`<PublishUrl>/<frontend-output-dir>/` 含 frontend build 結果。

## Tool Preference

shell 操作限 `msbuild` / 跑 plugin script;檔案讀寫用 Read / Edit / Write。

## Test Scenarios

- **No .pubxml found**: 在無 .pubxml 的 csproj 跑 /tp-publish → fail loudly 訊息含「No .pubxml found in .Properties\PublishProfiles\」並建議使用 VS 先建 publish profile。
- **Multiple .pubxml**: 有多個 .pubxml → fail loudly 列出所有 .pubxml path,要求加 `--profile <name>`。
- **發佈位置兩行模板 (U10 / AE4)**: publish 成功後 stdout 含 `PUBLISH_OUTPUT (...)` marker,緊接兩行——raw Windows 路徑 + `file:///` URL,**兩行皆無結尾標點**。agent 須**逐字、各自成行**轉述那兩行,前後不接散文/句號(不轉述 marker 行)。含空白的路徑仍須完整保留在單行。
- **TURBO_PLUGIN_MSBUILD_PATH invalid**: env 設不存在路徑 → fail loudly 訊息含該路徑。
