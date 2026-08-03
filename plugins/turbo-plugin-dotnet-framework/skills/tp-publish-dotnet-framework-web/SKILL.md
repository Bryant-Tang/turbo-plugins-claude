---
name: tp-publish-dotnet-framework-web
description: '對 .NET Framework Web 專案跑 MSBuild publish(含 frontend pack)——「給 agent 用的 VS 2022」:由你(agent)判斷要發佈哪個 csproj 與哪個 `.pubxml`,configuration 以 pubxml 內嵌值為準。**publish 產出可能被 CD pipeline 消費,影響部署環境;必須使用者明確要求才執行**;agent 偵測到「完成一輪改動準備部署」時可建議,但需明確確認。'
argument-hint: '[--pubxml <path>] [--configuration <name>] [--platform <name>] [--project <path-to-csproj>] [--repo-root <path>]'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-publish-dotnet-framework-web

## Purpose

給 agent 用的 VS 2022「Publish」。你(agent)判斷要發佈哪個 `.csproj` 與哪個 `.pubxml` profile,把
明確參數傳給變薄的 `Publish-Web` 執行器;configuration **以 pubxml 內嵌 `<Configuration>` 為準**——
你預設不傳,執行器會把它讀出來明確帶給 MSBuild。發佈完逐字轉述產出位置,必要時記回記憶。

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

### Step 1 — 判斷要發佈什麼(target csproj + pubxml)

你是這個專案的 VS,由你決定發佈對象,**不靠 script 自動偵測**。

**Target(發佈哪個 csproj):**

- publish 一律是**單一 csproj**,**不接受 `.sln`**(發佈是針對一個 web 專案,不是整個方案)。
- 先查記憶 `[publish].project`(只能是 csproj)。有值且檔在 → 用它。
- 沒記憶時用 Glob 找 `*.csproj`(跳過 `bin/`、`obj/`、`node_modules/`、`.vs/`、`.git/`),判斷哪個是要部署的 web 專案;多個合理且無從判斷 → `AskUserQuestion` 請使用者選。

**Pubxml(用哪個 publish profile):**

- 先查記憶 `[publish].default_pubxml`。有值且檔在 → 用它(`-Pubxml`)。
- 否則看該 csproj 的 `Properties/PublishProfiles/` 下有幾個 `.pubxml`:剛好一個 → 直接用(script 會自動取單一);多個 → 由你依 context 判斷,無從判斷就 `AskUserQuestion` 列出請使用者選,把選的當 `-Pubxml` 傳。

**Configuration(預設不指定,由執行器從 pubxml 讀):**

- 預設**不要**傳 `--configuration` / `--platform`——執行器會自己去 pubxml 讀 `<Configuration>` 並明確帶給 MSBuild。
- 只有使用者明確指定或 `[publish].configuration` 記憶有值時才傳;你傳的值一律蓋過 pubxml。
- **注意**:這裡不能只靠「不傳就讓 profile 決定」。實測(2026-07-31)證實,走 `/p:PublishProfile` 時
  profile 裡的 `<Configuration>` **不會**影響建置階段——csproj 自己的 `Debug` 預設值會贏,結果是把一份
  Debug 組建放進 `bin\Release\Publish\`。所以執行器改成讀出來明確傳。

### Step 2 — 執行 publish

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Publish-Web.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.sh`)帶明確參數:`-Project <csproj>`、(可選)`-Pubxml <path>`、(可選)`-Configuration`/`-Platform`。Script 會:解析 csproj target(CLI → `[publish].project` → 清楚報錯;**收到 `.sln` 報錯**)、找 MSBuild、解析 pubxml(CLI → `[publish].default_pubxml` → `Properties/PublishProfiles/` 單一)、跑 frontend pack(若 `[frontend]` 齊備)、跑 `msbuild /p:DeployOnBuild=true /p:PublishProfile=<name>`(`/p:Configuration` 取「你傳的值 → pubxml 的 `<Configuration>`」,兩者都沒有才省略;`/p:Platform` 仍是**有值才附**)、後處理 parse `<PublishUrl>` + `<WebPublishMethod>` 回報產出位置。

### Step 3 — 回報結果(逐字、路徑可點擊)

腳本成功後印一行 `PUBLISH_OUTPUT (...)` marker,**緊接其後數行**即結果模板,把它們**逐字**轉述給使用者(與 build/run/stop 同一套):

- `Target: <csproj>`、`Profile: <pubxml>` ——**糾錯閘**,讓使用者確認發佈的是不是對的專案 / profile(尤其 target 來自記憶、你沒明傳 `-Project` 時)。這兩行是標籤、照常轉述即可。
- 接著是產出位置:第一行 raw Windows 絕對路徑、第二行 `file:///` URL(非 FileSystem 發佈方式則只有一行 URL)。這(些)路徑/URL 行必須**各自單獨成行、前後不接任何散文或標點**(不要包成「產出在:…」、也不要在行尾加句號),終端機才會把它算成可點擊連結。

**不要轉述 marker 行本身**;`Target:` / `Profile:` 照常轉述,只有路徑/URL 那幾行要保持光禿可點擊。

### Step 4 — 記憶存回(save-back)

publish **成功後**,讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/memory-save-back.md`:比對這次選定的 csproj target / pubxml / configuration 與已存記憶(`[publish]` 的 key),有差異就問使用者要不要存。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **TRUST_REQUIRED 處理**: 若 script stdout 含 `TRUST_REQUIRED hash=<h> install_command=<cmd> build_command=<cmd>`,用 `AskUserQuestion` 顯示實際指令並詢問:「即將執行以下 frontend 指令,確認允許?`install: <cmd>` / `build: <cmd>`」。使用者選 Yes → 寫入 `.turbo-plugin/pack-content-trust.local.toml`(格式:`approved_hash = "<h>"`)並重新呼叫 script。使用者選 No → 終止 skill。
- **target 只能 csproj**:publish 收到 `.sln` 會報錯;發佈是針對單一 web 專案。
- **console 專案沒有發佈**:`<OutputType>` 是 `Exe` / `WinExe` 時不要跑 publish。Visual Studio 對 .NET Framework console **沒有** publish 這個概念(右鍵選單那個 Publish 是 ClickOnce,跟 web 的 Publish 是兩回事)。使用者要的通常是「把建置產物交出去」——直說:直接複製 `bin\<Configuration>\` 底下的內容即可,並提議用 build 指定 Release 重建一次。**不要**硬跑任何 MSBuild publish target。
- **config 以 pubxml 為準,但由執行器讀出來明確傳**:你預設不傳 `--configuration`,執行器會從 pubxml 取 `<Configuration>` 帶進 MSBuild;只有使用者明確要求才由你覆蓋。**不要**把它改回「省略讓 profile 決定」——那樣發出來的是 Debug。
- **pubxml 由你判斷**:多個 profile 無從判斷就 `AskUserQuestion`,別硬猜。
- Frontend pack 是 publish 鏈的一部份;**不要在 SKILL 內額外呼叫** `pack-content`,script 已包含。
- **MSBuild 找不到** → script fail loudly,提示在 `.turbo-plugin/config.local.toml` 的 `[tools]` 設 `msbuild_path`。
- Publish 影響外部 artifact(可能被 CD pipeline 消費),屬 **proactive suggestion only** 類別——agent 偵測到「使用者完成準備部署」時可建議,但需明確同意。

## Completion Checks

- `msbuild` 結束 exit code 為 0、stdout 含 `PUBLISH_OUTPUT` 模板(`Target:` / `Profile:` + 產出位置路徑/URL)。
- `<PublishUrl>` 路徑含新 artifact。
- 若 frontend 設定齊備:`<PublishUrl>/<frontend-output-dir>/` 含 frontend build 結果。
- save-back:若這次選擇與記憶不同,已問過使用者並寫對 `[publish]` 的 per-op key。

## Test Scenarios

- **No .pubxml found**: 在無 .pubxml 的 csproj 跑 /tp-publish(傳明確 `-Project`)→ fail loudly 訊息含「No .pubxml found」,建議先用 VS 建 publish profile。
- **Multiple .pubxml**: 該 csproj 有多個 .pubxml 且沒指定 → script fail loudly 列候選;你應改用 `AskUserQuestion` 選一個再傳 `-Pubxml`。
- **config 從 pubxml 讀出來傳**: pubxml 有 `<Configuration>Release</Configuration>` 且不傳 `--configuration` → MSBuild 命令列**含** `/p:Configuration=Release`,產出是 Release 組建。
- **兩邊都沒有才省略**: pubxml 沒有 `<Configuration>` 且不傳 `--configuration` → 命令列不含 `/p:Configuration`。
- **`.sln` 被拒**: 傳 `-Project <.sln>` → script 報錯(publish 需 csproj)。
- **結果模板**: publish 成功後 stdout 含 `PUBLISH_OUTPUT (...)` marker,緊接數行——`Target: <csproj>` / `Profile: <pubxml>`(糾錯閘)+ raw Windows 路徑 + `file:///` URL(非 FileSystem 則只有 URL 一行)。路徑/URL 行**無結尾標點**、各自成行,agent 須**逐字**轉述(不轉述 marker 行)。含空白的路徑仍須完整保留在單行。

## Tool Preference

所有檔案 read / write / search / edit(含 save-back)優先用 Read / Edit / Write / Glob / Grep;shell 操作限 `msbuild` / 跑 plugin script。
