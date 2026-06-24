---
name: tp-build-dotnet-framework-web
description: '對 .NET Framework Web 專案跑 MSBuild build——「給 agent 用的 VS 2022」:由你(agent)判斷要建哪個 csproj / `.sln` 與 configuration/platform,沒指定的 config 省略交 MSBuild 決定。使用者明確要求 build 時執行;agent 偵測到「程式碼變更後驗證可建置」需求時也可建議執行(build 失敗可重跑,可逆操作)。'
argument-hint: '[--configuration <name>] [--platform <name>] [--project <path-to-csproj-or-sln>]'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-build-dotnet-framework-web

## Purpose

給 agent 用的 VS 2022「Build」。你(agent)是腦:判斷要建哪個 `.csproj` / `.sln` 與
configuration/platform,把**明確參數**傳給變薄的 `Build-Web` 執行器。沒指定的 config 一律**省略**,
交 MSBuild / `.sln` / `Directory.Build.props` 解析(這就是 VS 的行為)。執行後回報固定模板,必要時把
這次的選擇記回專案記憶。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 判斷要建什麼(target + configuration/platform)

你是這個專案的 VS:由你決定 build 的對象,**不靠 script 自動偵測**。

**Target(要建哪個):**

- 先查記憶:`.turbo-plugin/config.toml` / `config.local.toml` 的 `[build].project`(可為 `.sln`)。有值且該檔還在 → 直接用它。
- 沒記憶時自己探索 + 判斷:用 Glob 在 worktree 找 `*.csproj` / `*.sln`,跳過 `bin/`、`obj/`、`node_modules/`、`.vs/`、`.git/`;必要時讀 `.sln` 看它含哪些專案。
  - **預設建整個方案**:有 `.sln` 且這次是「大改 / 不確定動到哪些專案」→ 傳該 `.sln`(MSBuild 自行編排各專案)。
  - **建單一**:context 明顯只動某一個 web 專案(例如剛改它底下的檔)→ 傳那個 `.csproj`。
  - **多個都合理、無從判斷** → 用 `AskUserQuestion` 列候選請使用者選。別硬猜、別假裝 script 會自己挑——但也別過度謹慎:**建錯專案不會怎樣,糾正後重跑一次即可**。

**Configuration / Platform(預設不指定):**

- 預設**不要**傳 `--configuration` / `--platform`——讓 MSBuild / `.sln` / `Directory.Build.props` 自己決定(對齊 VS,VS 也沒要你選 config 才能 build)。
- 只有使用者明確指定、或記憶(`[build].configuration` / `[build].platform`)有值時才傳。

### Step 2 — 執行 build

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Build-Web.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/build-web.sh`)帶你判斷出的明確參數:`-Project <csproj 或 .sln>`、(可選)`-Configuration <name>`、`-Platform <name>`。`.sh` 是 thin wrapper 轉呼叫 `.ps1`。

Script 會:解析 target(CLI `-Project` → `config.toml [build].project` → 清楚報錯,**不自動偵測**)、找 MSBuild(`config.local.toml [tools].msbuild_path` → 標準 VS 安裝路徑)、跑 `msbuild /restore /t:Build`(**有值才附** `/p:Configuration|Platform`;`.sln` 的 `SolutionDir` 由 `.sln` 所在目錄推導)、build 成功後跑 `Compress-Content`(`[frontend]` 設定齊備才跑,否則 skip)。

### Step 3 — 回報結果模板

腳本結尾印一行 `BUILD_OUTPUT (...)` marker + 數行:**解析後的實際 target**、configuration、platform(未指定者標「未指定 (由 MSBuild / solution / Directory.Build.props 決定)」)。把這些**逐字轉述**給使用者當結果。其中「解析後 target」是**糾錯閘**——讓使用者確認建的是不是對的專案;若建錯了,改 `-Project` 重跑。

### Step 4 — 記憶存回(save-back)

build **成功後**,讀並遵循 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/memory-save-back.md`:比對這次選定的 target / configuration / platform 與已存記憶,有差異就問使用者要不要存(committed / local / 撤回省略 / 不存)。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **TRUST_REQUIRED 處理**: 若 script stdout 含 `TRUST_REQUIRED hash=<h> install_command=<cmd> build_command=<cmd>`,用 `AskUserQuestion` 顯示實際指令並詢問:「即將執行以下 frontend 指令,確認允許?`install: <cmd>` / `build: <cmd>`」。使用者選 Yes → 寫入 `.turbo-plugin/pack-content-trust.local.toml`(格式:`approved_hash = "<h>"`)並重新呼叫 script。使用者選 No → 終止 skill。
- **全權判斷 target,不靠 script 偵測**:要建哪個由你看 context / 記憶 / 必要時 `AskUserQuestion`;script 不再自動偵測單一 csproj、多個也不 throw,純吃你給的明確 target。
- **config 預設省略**:沒明確理由(使用者指定 / 記憶有值)就別帶 `/p:Configuration|Platform`,讓 MSBuild/.sln/props 決定——這是對齊 VS 的關鍵。
- **build 預設整方案、小改建單一**:見 Step 1;由你判斷,選錯可重跑。
- **MSBuild 找不到** → script fail loudly,提示在 `.turbo-plugin/config.local.toml` 的 `[tools]` 設 `msbuild_path`(forward slash + 雙引號)。
- Build 失敗可逆(重跑即可),屬於 agent-proactive 觸發類別——偵測「剛改完程式碼」可建議跑。

## Completion Checks

- `msbuild` 結束 exit code 為 0,且 stdout 出現 `BUILD_OUTPUT` 模板、解析後 target 是預期的專案 / 方案。
- 產物落在 `<project>\bin\...`(實際 Configuration 由 MSBuild / solution 決定,**不假設** Debug)。
- 若 `[frontend]` 設定齊備:`<frontend.dir>/` 內 build 輸出齊備。
- save-back:若這次選擇與記憶不同,已問過使用者並寫對 `[build]` 的 per-op key(或使用者選不存)。

## Test Scenarios

- **[frontend] config absent**: 沒設 `[frontend]` 段 → /tp-build 略過 frontend 步驟、直接 MSBuild、`BUILD_OUTPUT` 模板出現。
- **[frontend] config present**: 設 `[frontend] dir = "src/web/frontend"; install_command = "npm install"; build_command = "npm run build"` → /tp-build 先跑 frontend 兩個 command,再 MSBuild。
- **省略 config 對齊 VS**: 不傳 `--configuration` 且 `[build]` 無 configuration 記憶 → MSBuild 命令列**不含** `/p:Configuration`,讓 csproj 的 `<Configuration Condition>` 預設生效(非硬帶 Debug)。
- **多個 csproj、無記憶**: worktree 有多個 csproj 又沒設 `[build].project` → 你用 `AskUserQuestion` 列候選請使用者選(script 不會 throw「multiple」,而是在完全沒 target 時才清楚報錯)。
- **`.sln` 整方案 build**: 傳 `.sln` → 建整個方案、`/p:SolutionDir` 指向 `.sln` 所在目錄。
- **MSBuild 路徑無效**: `config.local.toml [tools].msbuild_path` 指不存在路徑 → fail loudly 訊息含該路徑與來源。

## Tool Preference

所有檔案 read / write / search / edit(含 save-back)優先用 Read / Edit / Write / Glob / Grep;shell 操作限 `msbuild` / 跑 plugin script。
