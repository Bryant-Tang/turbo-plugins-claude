---
name: tp-build-dotnet-framework
description: 'MSBuild build for a .NET Framework project, web or console. You pick the csproj/`.sln` and configuration; omit what the user did not name. Run on request, or suggest it to verify a code change builds (reversible). Use this instead of invoking MSBuild yourself, including when you are only building to check your own edits mid-task.'
argument-hint: '[--configuration <name>] [--platform <name>] [--project <path-to-csproj-or-sln>] [--repo-root <path>]'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-build-dotnet-framework

## Purpose

給 agent 用的 VS 2022「Build」。你(agent)是腦:判斷要建哪個 `.csproj` / `.sln` 與
configuration/platform,把**明確參數**傳給變薄的 `Build-Web` 執行器。沒指定的 config 一律**省略**,
交 MSBuild / `.sln` / `Directory.Build.props` 解析(這就是 VS 的行為)。執行後回報固定模板,必要時把
這次的選擇記回專案記憶。

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

### Step 1.5 — 前端打包偵測(**沒設定就要問,不要默默略過**)

讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/frontend-pack-check.md`。

摘要:`Compress-Content` 在沒有前端設定時會**安靜跳過**,而那行 skip 訊息不在你會轉述的結果模板裡,
使用者只會看到「build 成功」、不會知道前端沒打包。所以由**你**在跑之前判斷——已設定 / 使用者已說過不用
→ 直接往下;都沒有且**目標專案目錄裡**找得到 `package.json` → 問一次(白話問句,別丟設定 key 名),
把答案寫進 `.turbo-plugin/config.toml`,之後不再重問。

**一個 repo 裡有多個 Web 專案時,設定是分組的**(`[frontend."<專案路徑>"]`),而且每一步都只針對**這次的
目標專案**。細節在那份共用片段裡,包含「有分組但沒有一組對應這個專案」這個**可疑**狀態要怎麼處理——
它跟「這個 repo 沒有前端」不是同一件事,不可以同樣地默默跳過。

### Step 2 — 執行 build

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Build-Web.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/build-web.sh`)帶你判斷出的明確參數:`-Project <csproj 或 .sln>`、(可選)`-Configuration <name>`、`-Platform <name>`。`.sh` 是 thin wrapper 轉呼叫 `.ps1`。

Script 會:解析 target(CLI `-Project` → `config.toml [build].project` → 清楚報錯,**不自動偵測**)、找 MSBuild(`config.local.toml [tools].msbuild_path` → 標準 VS 安裝路徑)、跑 `msbuild /restore /t:Build`(**有值才附** `/p:Configuration|Platform`;`.sln` 的 `SolutionDir` 由 `.sln` 所在目錄推導)、build 成功後跑 `Compress-Content`(**對應這個 target 的**那組 `[frontend]` 設定齊備才跑,否則 skip;target 由 Build-Web 自己轉交,你不必另外帶)。

### Step 3 — 回報結果模板

腳本結尾印一行 `BUILD_OUTPUT (...)` marker + 數行:**解析後的實際 target**、configuration、platform(未指定者標「未指定 (由 MSBuild / solution / Directory.Build.props 決定)」)、**Frontend**(有打包標「已執行 (<dir>)」、沒有標「未設定 (未執行前端打包)」)。把這些**逐字轉述**給使用者當結果,**一行都不要略過**,並把整段放進一個 **fenced code block**(三個反引號)——`Target:` 是 Windows 絕對路徑,而 Markdown 會把「`\` + ASCII 標點」當跳脫序列吃掉反斜線,經過 `.claude` / `.turbo-plugin` 這類隱藏目錄時就會少一個分隔符;code block 不做算繪,路徑才會逐字保留。

其中兩行各自是一道閘:「解析後 target」讓使用者確認建的是不是對的專案(建錯了就改 `-Project` 重跑);
「Frontend」讓「前端沒被打包」這件事**一定會被說出口**——那正是它會被漏掉的原因(Step 1.5)。

### Step 4 — 記憶存回(save-back)

build **成功後**,讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/memory-save-back.md`:比對這次選定的 target / configuration / platform 與已存記憶,有差異就問使用者要不要存(committed / local / 撤回省略 / 不存)。

## Decision Rules

- **build 兩種專案型別都適用,不必分流**:MSBuild 不在乎 `<OutputType>`,console 專案(`Exe` / `WinExe`)與 web 專案走的是同一條建置路徑,同一支腳本、同一組參數。要分流的是 **run / stop**(跑起來的方式完全不同),以及 **publish**(.NET Framework console 根本沒有發佈這個概念)。

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **TRUST_REQUIRED 處理**: 若 script stdout 含 `TRUST_REQUIRED hash=<h> install_command=<cmd> build_command=<cmd>`,用 `AskUserQuestion` 顯示實際指令並詢問:「即將執行以下 frontend 指令,確認允許?`install: <cmd>` / `build: <cmd>`」。使用者選 Yes → **附加**一筆到 script 緊接著印出的 `TRUST_FILE <絕對路徑>` 那個檔,再重新呼叫 script。**是附加,不是覆蓋**——一個 repo 裡每個有前端的專案各有一筆,覆蓋掉別人那筆會讓那個專案下次被重問。格式(`<g>` 是 script 印的 `TRUST_GROUP` 值,單一 `[frontend]` 時是空字串):

  ```toml
  [[approved]]
  group = "<g>"
  approved_hash = "<h>"
  ```

  **要用它給的路徑,不要自己組**——它指向主 worktree,所以同一個 repo 的其它 worktree 不必再問一次同樣的指令。使用者選 No → 終止 skill。
- **全權判斷 target,不靠 script 偵測**:要建哪個由你看 context / 記憶 / 必要時 `AskUserQuestion`;script 不再自動偵測單一 csproj、多個也不 throw,純吃你給的明確 target。
- **config 預設省略**:沒明確理由(使用者指定 / 記憶有值)就別帶 `/p:Configuration|Platform`,讓 MSBuild/.sln/props 決定——這是對齊 VS 的關鍵。
- **build 預設整方案、小改建單一**:見 Step 1;由你判斷,選錯可重跑。
- **MSBuild 找不到** → script fail loudly,提示在 `.turbo-plugin/config.local.toml` 的 `[tools]` 設 `msbuild_path`(forward slash + 雙引號)。
- **一整片 `CS0246`「找不到類型或命名空間名稱」→ 先當成套件沒還原,不要當成程式碼壞了**:
  缺的型別若來自第三方套件(`ILog`、`ISheet`、`JObject` 這類),幾乎可斷定是還原問題而非原始碼問題。
  script **已經**帶了 `/restore /p:RestorePackagesConfig=true`(後者是讓 NuGet 看得見 packages.config
  的關鍵),所以**不要建議使用者去抓 `nuget.exe` 手動還原**——那是繞過去,不是把問題修好。
  該做的是:讀 stdout 那行 `MSBuild args:` 確認兩個旗標真的帶上了,再確認 `packages\` 的位置跟
  csproj 裡 `<HintPath>` 的相對路徑對得上。
  **對不上的時候,下一個要看的是同一行的 `/p:SolutionDir=`**,不是 csproj:`<HintPath>..\packages\`
  是相對於 **solution 目錄**算的,所以 `SolutionDir` 指錯地方,還原就會落在別處。它應該是**這個
  專案所屬的那個 `.sln` 的目錄**;一個 repo 內有多個子專案、各自有 `.sln` 與 `packages\` 時,指到
  repo 根就是錯的。要臨時驗證,用 `--msbuild-property "SolutionDir=<正確目錄>/"` 重跑一次
  (**結尾用正斜線**——反斜線結尾在 `.sh` 那條路徑會把後面的引號跳脫掉)。
  **陷阱**:沒有 `EnsureNuGetPackageBuildImports` target 的舊 csproj **不會**印出「missing packages」
  那句友善提示,套件沒還原時直接就是幾百個 `CS0246`。別因為沒看到那句話就排除還原的可能。
- Build 失敗可逆(重跑即可),屬於 agent-proactive 觸發類別——偵測「剛改完程式碼」可建議跑。

## Completion Checks

- `msbuild` 結束 exit code 為 0,且 stdout 出現 `BUILD_OUTPUT` 模板、解析後 target 是預期的專案 / 方案。
- 產物落在 `<project>\bin\...`(實際 Configuration 由 MSBuild / solution 決定,**不假設** Debug)。
- 若 `[frontend]` 設定齊備:`<frontend.dir>/` 內 build 輸出齊備。
- **前端狀態有被說出口**:轉述的結果含 `Frontend:` 那一行。若它是「未設定」,而這個專案其實有
  `package.json`,代表 Step 1.5 沒做——回去補問,別讓使用者以為前端打包過了。
- save-back:若這次選擇與記憶不同,已問過使用者並寫對 `[build]` 的 per-op key(或使用者選不存)。

## Test Scenarios

- **[frontend] config absent**: 沒設 `[frontend]` 段 → /tp-build 略過 frontend 步驟、直接 MSBuild、`BUILD_OUTPUT` 模板出現,且模板含 `Frontend: 未設定 (未執行前端打包)`。
- **有 package.json 但沒設定**: 專案內有 `package.json`、`[frontend]` 未設且 `[frontend] enabled` 不是 `false` → Step 1.5 用 `AskUserQuestion` 主動問要不要打包前端,**不會**默默略過。
- **已表態不用**: `enabled = false` → 不再詢問,直接 build,模板顯示 `Frontend: 已停用`(與「未設定」分開,因為那是使用者的決定,不是缺漏)。
- **[frontend] config present**: 設 `[frontend] dir = "src/web/frontend"; install_command = "npm install"; build_command = "npm run build"` → /tp-build 先跑 frontend 兩個 command,再 MSBuild。
- **多專案、有對應分組**: 設 `[frontend."src/proj-1/Proj1.Web"]` 與 `[frontend."src/proj-2/Proj2.Web"] enabled = false` → 建 proj-1 跑 proj-1 那組、建 proj-2 完全不跑,兩者的模板各自說明。
- **多專案、沒對應分組**: 有帶鍵的分組但沒有一組是 proj-5 → 模板顯示「有分組但沒有一組對應這個專案」,**不是**單純的「未設定」;Step 1.5 要問,不要默默跳過。
- **單組 `[frontend]` 打到別的專案**: 只有不帶鍵的 `[frontend]`,而它的 `dir` 不在這次目標專案底下 → 仍然執行(維持既有行為),但模板明講這件事並建議改成分組。這一格原本是**完全沉默**的:兩個指令都成功、模板照樣寫「已執行」。
- **省略 config 對齊 VS**: 不傳 `--configuration` 且 `[build]` 無 configuration 記憶 → MSBuild 命令列**不含** `/p:Configuration`,讓 csproj 的 `<Configuration Condition>` 預設生效(非硬帶 Debug)。
- **多個 csproj、無記憶**: worktree 有多個 csproj 又沒設 `[build].project` → 你用 `AskUserQuestion` 列候選請使用者選(script 不會 throw「multiple」,而是在完全沒 target 時才清楚報錯)。
- **`.sln` 整方案 build**: 傳 `.sln` → 建整個方案、`/p:SolutionDir` 指向 `.sln` 所在目錄。
- **MSBuild 路徑無效**: `config.local.toml [tools].msbuild_path` 指不存在路徑 → fail loudly 訊息含該路徑與來源。

## Tool Preference

所有檔案 read / write / search / edit(含 save-back)優先用 Read / Edit / Write / Glob / Grep;shell 操作限 `msbuild` / 跑 plugin script。
