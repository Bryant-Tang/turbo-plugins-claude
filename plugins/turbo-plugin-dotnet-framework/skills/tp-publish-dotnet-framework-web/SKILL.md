---
name: tp-publish-dotnet-framework-web
description: 'MSBuild publish for a .NET Framework WEB project (frontend pack included). You pick the csproj and `.pubxml`. **Publish output can reach a deployed environment: run ONLY on explicit request**; may be suggested, but requires explicit confirmation. Console projects publish via ClickOnce, which this does not do.'
argument-hint: '[--pubxml <path>] [--configuration <name>] [--platform <name>] [--project <path-to-csproj>] [--repo-root <path>] [--msbuild-property Name=Value,Name2=Value2]'
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

### Step 1.5 — 前端打包偵測(**沒設定就要問,不要默默略過**)

讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/frontend-pack-check.md`。

publish 這條路徑比 build 更要緊:發佈產出會送到**部署環境**,「前端沒被打包」卻沒人吭聲,
代價是把缺件的東西發出去。已設定 / 使用者已說過不用 → 直接往下;都沒有且專案裡找得到
`package.json` → 問一次再繼續。

### Step 2 — 執行 publish

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Publish-Web.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.sh`)帶明確參數:`-Project <csproj>`、(可選)`-Pubxml <path>`、(可選)`-Configuration`/`-Platform`、(逃生口,平常不用)`-MsBuildProperty Name=Value,Name2=Value2`。Script 會:解析 csproj target(CLI → `[publish].project` → 清楚報錯;**收到 `.sln` 報錯**)、找 MSBuild、解析 pubxml(CLI → `[publish].default_pubxml` → `Properties/PublishProfiles/` 單一)、跑 frontend pack(若 `[frontend]` 齊備)、跑 `msbuild /restore /p:DeployOnBuild=true /p:PublishProfile=<name>`、後處理 parse `<PublishUrl>` + `<WebPublishMethod>` 回報產出位置。

**configuration / platform 各有兩層 pubxml fallback**:`/p:Configuration` 取「你傳的值 → pubxml 的 `<Configuration>` → `<LastUsedBuildConfiguration>`」,`/p:Platform` 取「你傳的值 → `<Platform>` → `<LastUsedPlatform>`」,全都沒有才省略。**`LastUsed*` 那層是必要的**——Visual Studio 產生的 FileSystem profile 往往只有 `LastUsed*`、沒有 `<Configuration>` / `<Platform>`,少了這層就會悄悄落回 csproj 的 `Debug|AnyCPU`,和使用者在 VS 裡看到的選擇相反。

### Step 3 — 回報結果(逐字、路徑可點擊)

腳本成功後印一行 `PUBLISH_OUTPUT (...)` marker,**緊接其後數行**即結果模板,把它們**逐字**轉述給使用者(與 build/run/stop 同一套):

- `Target: <csproj>`、`Profile: <pubxml>` ——**糾錯閘**,讓使用者確認發佈的是不是對的專案 / profile(尤其 target 來自記憶、你沒明傳 `-Project` 時)。這兩行是標籤、照常轉述即可。
- `Frontend: 已執行 (<dir>)` 或 `Frontend: 未設定 (未執行前端打包)` ——讓「這次發佈有沒有帶前端」**一定會被說出口**。同樣照常轉述,不要因為它看起來像雜訊就略過:發佈缺前端資產正是靠這行才看得見。
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
- **console 專案不走這一支**:`<OutputType>` 是 `Exe` / `WinExe` 時不要跑 publish。
  **不要說「主控台專案沒有發佈」——那是錯的。** VS 右鍵那個「發行」對 .NET Framework 主控台專案
  走的是 **ClickOnce**:產生 `.application` 資訊清單與 `setup.exe`,是給桌面安裝／自動更新用的部署
  機制,跟 web 的 `.pubxml` + `WebPublishMethod` 是兩套完全不同的 MSBuild target。**本 plugin 只做
  web 那一套,不做 ClickOnce**——要照實這樣講。
  而使用者要的通常也不是 ClickOnce,而是「把建置產物交出去」:直接複製 `bin\<Configuration>\`
  底下的內容即可,並提議用 build 指定 Release 重建一次。**不要**硬跑任何 MSBuild publish target。
- **config 以 pubxml 為準,但由執行器讀出來明確傳**:你預設不傳 `--configuration`,執行器會從 pubxml 取 `<Configuration>` 帶進 MSBuild;只有使用者明確要求才由你覆蓋。**不要**把它改回「省略讓 profile 決定」——那樣發出來的是 Debug。
- **pubxml 由你判斷**:多個 profile 無從判斷就 `AskUserQuestion`,別硬猜。
- Frontend pack 是 publish 鏈的一部份;**不要在 SKILL 內額外呼叫** `pack-content`,script 已包含。
- **MSBuild 找不到** → script fail loudly,提示在 `.turbo-plugin/config.local.toml` 的 `[tools]` 設 `msbuild_path`。
- **一整片 `CS0246`「找不到類型或命名空間名稱」→ 先當成套件沒還原**:`/p:DeployOnBuild=true` 會**建置**
  專案,所以 publish 也吃得到還原問題。script 已帶 `/restore /p:RestorePackagesConfig=true`,
  **不要建議使用者手動跑 `nuget.exe`**;讀 stdout 的 `MSBuild args:` 那行確認旗標帶上了即可。
  詳細判準見 `tp-build-dotnet-framework` 的同名規則。
- **`ASPNETCOMPILER : error ASPCONFIG` + 「試圖載入格式錯誤的程式」→ 32/64 位元不合,不是程式碼壞了**。
  那句話是 `BadImageFormatException`,發生在**預先編譯**階段(pubxml 開了
  `<PrecompileBeforePublish>true</PrecompileBeforePublish>`)。**同一個症狀有兩個不同的根因**,
  分辨清楚再動手:
  1. **建置產物是 MSIL,但相依的互通組件是 x64。** 先看 stdout 的 `MSBuild args:` 有沒有
     `/p:Platform=x64`;沒有通常是 pubxml 沒有可讀的平台設定 → 傳 `--platform x64` 重跑。
     **不要改用 `PlatformTarget`**:實測 `PlatformTarget=x64` 能消掉 MSB3270 架構警告但預先編譯
     **仍然失敗**,只有 `Platform=x64` 會過(兩者中繼目錄不同,走的是不同建置路徑)。
  2. **平台已經對了,是預先編譯器本身的位元不對。** MSBuild 的 `AspNetCompiler` task 預設用 32 位元的
     `aspnet_compiler.exe`,載不動 x64-only 的組件 → 用
     `--msbuild-property AspnetCompilerPath=$(MSBuildFrameworkToolsPath64)` 重跑
     (那是 MSBuild 內建屬性,不是寫死的機器路徑)。

  兩者都**不需要繞過 plugin 自己打 msbuild**——那樣會連帶失去前端打包與產出位置回報。
- **`--msbuild-property` 是逃生口,不是常態**:格式 `Name=Value`,多個用逗號分隔,附加在**最後**
  (所以會覆蓋 script 自己算出來的同名屬性)。用它之前先確認不是上面兩條規則能解的情況;若某個屬性
  變成每次都要傳,那是「該把它記進專案設定或提 issue」的訊號,不是繼續手動傳。
- Publish 影響外部 artifact(可能被 CD pipeline 消費),屬 **proactive suggestion only** 類別——agent 偵測到「使用者完成準備部署」時可建議,但需明確同意。

## Completion Checks

- `msbuild` 結束 exit code 為 0、stdout 含 `PUBLISH_OUTPUT` 模板(`Target:` / `Profile:` + 產出位置路徑/URL)。
- `<PublishUrl>` 路徑含新 artifact。
- 若 frontend 設定齊備:`<PublishUrl>/<frontend-output-dir>/` 含 frontend build 結果。
- **前端狀態有被說出口**:轉述的結果含 `Frontend:` 那一行。若它是「未設定」,而這個專案其實有
  `package.json`,代表 Step 1.5 沒做——**發佈前**回去補問,別讓缺前端資產的產出送到部署環境。
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
