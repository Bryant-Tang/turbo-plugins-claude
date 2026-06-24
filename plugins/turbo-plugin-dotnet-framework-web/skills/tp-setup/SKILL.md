---
name: tp-setup
description: '設定 turbo-plugin-dotnet-framework-web 環境(.NET Framework Web / IIS Express)。使用者明確要求 setup 時執行;**不要自動觸發**。先跑共用 base 段(建 .turbo-plugin/ + concern-neutral 共用檔),再做 dotnet concern:config.toml 的 [iis]/[build]/[publish] 區塊、applicationhost.config bootstrap、.gitignore 的 .NET 產物區塊。需要 git repo / git↔SVN bridge 而不存在時 fail-loud(不自行 git init)。'
argument-hint: ''
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup（turbo-plugin-dotnet-framework-web）

## Purpose

`turbo-plugin-dotnet-framework-web` 的設定入口。流程兩層:

1. **共用 base 段**(concern-neutral):pre-check + case 偵測 + 建 `.turbo-plugin/` 與共用檔骨架。見
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md`,**先讀並執行該檔**。
2. **dotnet concern 段**(本檔):`config.toml` 的 `dotnet` 標記區塊(`[iis]` 開關 + `[build]/[publish]/
   [frontend]/[run]` 範例)、`applicationhost.config` bootstrap、`.gitignore` 的 .NET 產物區塊。

> 本 plugin **不**處理 git↔SVN bridge(屬 `turbo-plugin-git-svn`)、dbhub(屬
> `turbo-plugin-three-environment-db`)。三個 plugin 共用同一份 base 段、各寫自己的標記區塊,彼此不覆蓋。

> **MSBuild / IIS Express 路徑**:不在 setup 詢問。`tp-build` / `tp-run` 等 skill 會自動探測標準 VS 安裝路徑;
> 探測不到時 `Find-MSBuild` / `Find-IisExpressPath` 會 throw 並引導你手動在 `.turbo-plugin/config.local.toml`
> 的 `[tools]` 加 `msbuild_path` / `iis_express_path`。

### fail-loud 前置（無 git / 無 bridge 時不自行 bootstrap）

dotnet 的 skill(build / run / stop / publish / cleanup-orphan-iis)需在 git work tree 內運作(以
`Get-MainWorktree` 解析路徑)。setup 前置:

- **`.git/` 不存在**(base case 偵測為 (a))→ **fail-loud**,**不** `git init`(建 git repo / SVN bridge 屬
  `turbo-plugin-git-svn`)。訊息:「此目錄不是 git repo。請先裝 `turbo-plugin-git-svn` 跑其 `/tp-setup` 建立
  git+SVN 環境,或自行 `git init` 後再跑本 setup。」然後停止。
- 有 `.git/` 但無 `remote-svn/main` bridge:dotnet **不需要** bridge(build/run 不碰 SVN),正常繼續。

## Procedure

### Phase 1 — 偵測

讀並執行 base 段的 **Pre-check** 與 **Case 偵測**。接著套用上方 fail-loud 前置:case (a)(無 `.git/`)→ 停止並提示。
case (b)/(c)/(d) → 繼續。

進 case 前依 base 段 Phase summary 規則平實白話報告 + `AskUserQuestion`(執行 / 改 case / 取消)。dotnet 的
unconditional 「動到外部」動作**幾乎沒有**(apphost bootstrap、config 寫入都是 repo-only),故 summary 通常只說明
即將補的設定、無外部副作用。

### Phase 2 — base 骨架 + dotnet concern

先依 base 段建立 concern-neutral 共用檔骨架(`.turbo-plugin/` 目錄、`config.toml` 殼、`.gitignore` base、
`CLAUDE.md` base)。再做 dotnet concern(case (b)/(c) 都做;case (d) 見下;case (a) 已 fail-loud):

1. **`config.toml` 的 `dotnet` 標記區塊**(用 base 段「更新自己區塊」程序,只動
   `# >>> turbo-plugin:dotnet >>>` 區塊):
   ```
   [iis]
   # 預設啟用;沒有 .NET Framework Web 需求可設 enabled = false,
   # tp-run / tp-stop / tp-build / tp-publish / tp-cleanup-orphan-iis 會 fail-loudly 跳過。
   enabled = true

   # [build] / [run] / [publish] 的 section header 先 seed(啟用但空),讓 tp-build/run/publish 執行後的
   # 記憶存回(save-back)直接在既有 section 下填 key,不必冷合成 header。欄位一律註解(不預填值)。

   [build]                                 # tp-build 用
   # project       = "src/Web/Web.csproj"  # 明確 target(csproj 或 .sln,相對 worktree root);
   #                                       # 不設則由 agent 每次判斷 / 詢問,不自動偵測
   # configuration = "Debug"               # 省略 → 交 MSBuild / .sln / Directory.Build.props 決定(對齊 VS)
   # platform      = "Any CPU"             # 同上,省略即不帶 /p:Platform

   [publish]                               # tp-publish 用
   # project        = "src/Web/Web.csproj" # publish 目標 csproj(不可為 .sln)
   # default_pubxml = "src/Web/Properties/PublishProfiles/Production.pubxml"
   # configuration  = "Release"            # 省略 → 由 pubxml 內嵌 <Configuration> 決定

   [run]                                   # tp-run / tp-stop 用
   # project                   = "src/Web/Web.csproj"  # run/stop 目標 csproj;不設則 fallback [build].project
   # listening_timeout_seconds = 30                    # 冷啟 + first-request JIT 可調高至 90

   # [frontend]                            # 整段省略則 build/publish 不跑前端 build
   # dir             = "src/Web/ClientApp"
   # install_command = "yarn install"
   # build_command   = "yarn dev-build"
   ```

2. **`.gitignore` 的 .NET 產物追加**(idempotent,缺則加,用 base 的標記/區塊原則或直接 append 一個帶註解的區塊):
   ```
   # .NET Framework Web 產物(Visual Studio)
   .vs/
   bin/
   obj/
   *.user
   packages/
   ```
   > 此區塊是合理預設,非窮舉(使用者可補 `*.suo` / `TestResults/` 等)。

3. **applicationhost.config bootstrap**(見下方 §apphost-bootstrap)。**case (d) peer-mode 不執行**。

> dotnet 在 `CLAUDE.md` 無 concern-specific 內容要追加(build/run 不是「改某類檔前要遵守的慣例」);
> `conventions.md` 機制已退役,dotnet 不碰。base 段注入的 `CLAUDE.md` base 區塊(「不得提交僅限本機之物」)即足夠。

#### Case 差異

- **Case (b) init-from-existing / Case (c) 補設定**:跑上述 1-3(idempotent)。
- **Case (d) peer-mode**:**不**做 apphost bootstrap — canonical(`.turbo-plugin/applicationhost.config`)在主
  worktree 已存在,跨 worktree 由 git 共享;peer 的 IIS Express 啟動由 `start-iis` runtime 自動讀 canonical 並
  渲染 temp file。dotnet 在 peer 無其它 per-peer 檔,故 case (d) 實際無動作,回報即可。

#### §apphost-bootstrap — applicationhost.config 三選一

只在 case (b)/(c) 結尾觸發,case (d) 不執行。

```
if test -f <repo>/.turbo-plugin/applicationhost.config:
  → pass(canonical 已存在,不動)
elif test -f <repo>/.vs/<sln>/config/applicationhost.config:
  → 從 VS 複製進來並把 physicalPath 替換成佔位符:
     1. cp .vs/<sln>/config/applicationhost.config → .turbo-plugin/applicationhost.config
     2. XML parse + 把每個 <site>/<application>/<virtualDirectory> 的 physicalPath 屬性值
        替換為 "__TURBO_PLUGIN_PHYSICAL_PATH__"
     3. 避免機器-specific 絕對路徑進版控;runtime 由 start-iis 在 temp file 替換為實際 worktree 路徑
     4. Phase 4 報告「已從 VS 複製 apphost.config」
else:
  → AskUserQuestion 三選一:
    (1) 暫停 setup:請使用者開 Visual Studio 載入 .sln 一次(VS 會把 applicationhost.config 寫到
        .vs/<sln>/config/),完成後重跑 /tp-setup → setup 走上面 from-VS 分支。
        (preview:無外部動作 — 只是請你開 VS 後重跑)
    (2) 在 .turbo-plugin/config.toml 的 dotnet 區塊寫 [iis] enabled = false,跳過 IIS skill。
        (preview:無外部動作 — 只是寫設定)
    (3) 取消 setup。(preview:取消,不做後續)
```

### Phase 4 — 完成報告

- **偵測結果**:case + 子流程。
- **寫入位置**:base 骨架 + dotnet 項目(`config.toml` dotnet 區塊、`.gitignore` .NET 產物區塊、
  `applicationhost.config`)各標「新建 / 已存在 / 補設定」。
- **apphost bootstrap 結果**:跳過(canonical 已存在)/ 已從 VS 複製(列 physicalPath 佔位符替換)/ 使用者選 (1) 暫停 / (2) 寫 `[iis] enabled = false`。
- **使用者仍須手動處理**:
  - `tp-build` / `tp-run` 找不到 MSBuild / IIS Express 時 → 在 `.turbo-plugin/config.local.toml` 的 `[tools]`
    手動設 `msbuild_path` / `iis_express_path`(forward slash + 雙引號)。
  - 若要用 git↔SVN bridge / 三環境 DB → 裝 `turbo-plugin-git-svn` / `turbo-plugin-three-environment-db` 並跑其 setup。
- **下一步**:「設定就緒,可 `/tp-build-dotnet-framework-web` / `/tp-run-dotnet-framework-web`」。

## Decision Rules

- **先跑共用 base 段、再做 dotnet concern** — base 只建 concern-neutral 共用檔;`[iis]` / apphost / .NET ignore 屬 dotnet。
- **無 `.git/` 時 fail-loud,不自行 `git init`** — 建 git repo / SVN bridge 屬 `turbo-plugin-git-svn`。
- **標記區塊只動自己 concern 的**(config.toml 的 `dotnet` 區塊);不碰 `git-svn` 區塊或標記外內容。
- **Case (b)/(c) idempotent**;**Case (d) 不做 apphost bootstrap**(canonical 在主 worktree,peer 跨 worktree 共享)。
- **apphost canonical 必須帶 physicalPath 佔位符** — 從 VS 複製時把每個 `<site>`/`<application>`/`<virtualDirectory>`
  的 `physicalPath` 替換為 `__TURBO_PLUGIN_PHYSICAL_PATH__`,避免機器-specific 絕對路徑進版控。
- **不自動代填使用者設定** — 缺漏一律先 `AskUserQuestion`。
- **MSBuild / IIS Express 路徑不在 setup 詢問** — 靠 skill 自動探測 + throw 引導手動設 config.local.toml `[tools]`。
- **Phase summary transparency**:只列「會動到外部」的 unconditional 動作(dotnet 幾乎沒有);repo-only 寫入不列。
- 不裝 .NET workload / VS / IIS Express 本身 — 使用者本機環境責任。

## Completion Checks

- `.turbo-plugin/` 存在,`config.toml` 的 `dotnet` 標記區塊含 `[iis] enabled`(預設 true)。
- `.gitignore` 含 .NET 產物區塊(`.vs/` / `bin/` / `obj/` / `*.user` / `packages/`)。
- apphost bootstrap 終態(case (b)/(c)):canonical 已存在未動 / 從 VS 複製且 physicalPath = `__TURBO_PLUGIN_PHYSICAL_PATH__` / 使用者選暫停 / 寫 `[iis] enabled = false`。
- Case (a)(無 `.git/`):setup fail-loud 停止,**未** `git init`、**未**建任何檔。
- Case (b)/(c):跑兩次結果同跑一次(idempotent)。
- Case (d):未做 apphost bootstrap、未動 git-versioned shared file。

## Test Scenarios

- **無 git fail-loud**:在無 `.git/` 的空目錄跑 `/tp-setup`,確認停止並提示裝 git-svn / 自行 git init,且**未** `git init`、**未**建 `.turbo-plugin/`。
- **標記區塊不互蓋**:在已有 `git-svn` 標記區塊的 `config.toml` 上跑 dotnet setup,只更新 `dotnet` 區塊,`git-svn` 區塊與標記外內容不變。
- **apphost from-VS**:備一個含 `.vs/<sln>/config/applicationhost.config` 的 fixture,跑 setup,確認 canonical 被建立且 physicalPath 為佔位符。

## Tool Preference

所有檔案 read / write / search / edit 優先用 Read / Write / Edit / Glob / Grep / LSP,避開 Bash / PowerShell / Python /
Node.js 做檔案操作。shell 操作只限:`git` / 跑 plugin script、`Get-Command` 等 probe。
