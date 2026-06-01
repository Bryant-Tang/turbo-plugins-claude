---
date: 2026-05-20
topic: turbo-plugin-rewrite
---

# turbo-plugin Rewrite

## Summary

把現有 `tdp` / `tnf` / `tgs` / `tpi` 四個 turbo-* plugin 收成單一 `turbo-plugin`、全 skill 介面、`tp-*` 命名,定位縮回「Web 開發雜務工具集」——只整合 IIS Express、SVN、dbhub 三個外部系統,加上跟 SVN 推送篩選硬綁的 commit type 約定與程式碼註解風格。最終 skill 數從現有 22 skill + 21 command 收斂到 13 個 skill;開發流程整段撤退,交由使用者自選的開發流程 plugin(建議搭配 `compound-engineering` 或其他類似 plugin)處理,turbo-plugin 不綁定特定 plugin。既有 4 個 plugin 在測試過渡期保留;待 turbo-plugin 驗證 OK 後使用者會移除既有 plugin。

---

## Problem Frame

過去一年實際使用既有四個 turbo-* plugin 後浮現兩類痛點。

**第一類:自製開發流程的維護成本太高。** `tdp` 嘗試把 Web 專案開發流程(goal → plan → implement-task → testing-and-proof → finish-dev)做成 skill 鏈,實際跑下來產出的程式碼仍有不少 bug,且其中許多 bug 在 goal 或 plan 階段就已寫錯。但這次撤退的主要動機**不是**「別的開源 plugin 解決了這個失敗模式」——而是「自己維護一套開發流程的成本超過個人能投入的時間」。GitHub 上有多個開發流程 plugin(compound-engineering 是其中一個),使用者可依喜好自選;turbo-plugin 不再 own 此責任。

**第二類:操作摩擦與真實 bug。** 既有四個 plugin 各自獨立 setup,加上每個 git worktree 也獨立保存 `.claude/settings.local.json`,導致在 main worktree 的 Claude session 無法處理 peer worktree——必須退出 Claude、`cd` 到 peer worktree、再重新啟動 Claude。另一個更具體的問題是 `tnf` 的 `stop-iis`:因為 IIS Express 實例是以 worktree 為識別單位,所以 worktree A 跑 `stop-iis` 殺不到 worktree B 啟的 IIS。但同一個專案的多個 worktree 共用同一個 port(port 由 .csproj 決定),結果 worktree A 的 `run-iis` 雖然回報「啟動成功」實際上沒新起一個 instance——這是一個會悄悄發生的真實 bug。

四個 plugin 的職責拆分(`tdp` / `tnf` / `tgs` / `tpi`)原本是為了清楚邊界,但實際使用時這四個邊界對使用者沒有意義——使用者要的是「裝一個東西、它就會做對」。每個 skill 也都要先理解、決定何時呼叫——skill 多 = 學習負擔。

---

## Actors

- A1. **使用者**:你 + 同事。Windows 環境為主,Claude Code 常自選 Git Bash 而非 PowerShell;未來可能切到 Unix。開發 .NET Framework Web + git+SVN bridged 專案。
- A2. **Claude Code agent**:根據 skill description 觸發 `turbo-plugin` 的 skill,可能 agent 主動執行、可能 agent 主動建議由使用者確認執行(視 skill trigger mode 而定,見 R2),也可能僅在使用者明確要求時執行。
- A3. **開發流程 plugin(使用者自選)**:接手所有開發流程相關責任——brainstorm、plan、implement、commit message 撰寫、code review 等。`turbo-plugin` 不再 own 此責任。建議搭配 `compound-engineering`,但任何提供類似能力的 plugin 都可。turbo-plugin 透過 `.commitlintrc.json`(machine-readable)+ `CLAUDE.md` 注入的 commit type convention 段(human / agent-readable)提供**純諮詢**約定;**不裝 husky / 不裝 commit-msg hook、不在提交時 enforce**,實際強制力在 `tp-push-to-svn` 的 push 階段 parse subject(見 R12)。

---

## Key Flows

- F1. **新環境 onboarding**
  - **Trigger:** 使用者第一次在一台機器(或一個 workspace)啟用 `turbo-plugin`
  - **Actors:** A1, A2
  - **Steps:** 使用者觸發 `tp-setup` → skill 依現有狀態(`.git` 存在 / `.svn/` 在 `<proj>.worktrees/remote-main/` 偵測 / `.turbo-plugin/` 資料夾是否已存在等訊號)分辨自己處在「新建專案 / 接管現有 / 補設定」三場景並執行對應路徑 → 建立 `.turbo-plugin/` 資料夾(marker + 集中目錄,內含 `applicationhost.config` 共享版、`dbhub.toml` 預設值等)→ 寫入 `.gitignore` 與 `svn:ignore` 預設 patterns → 寫 repo root 的 `.commitlintrc.json` 與 `CLAUDE.md` 的 commit type convention 段落(純文件約定,不裝 husky / 不裝 commit-msg hook)→ init-from-existing 場景下: (a) 偵測既有 git-svn 設定(`git config --get svn-remote.svn.url`)若有 → 警告「turbo-plugin 不相容 git-svn,請移除 git-svn 設定」並等使用者確認;(b) prompt 使用者輸入 SVN URL;(c) 建立 `remote/main` orphan branch + `<proj>.worktrees/remote-main/` worktree;(d) 在該 worktree 跑 `svn checkout <url> .`(SVN URL 由 svn checkout 寫進該 worktree 的 `.svn/` 目錄,後續用 `svn info` 取得,不寫 env / 不寫 git config)→ 檢查外部依賴(msbuild / IIS Express / svn CLI / Docker for dbhub)可用性並回報缺失;偵測不到 IIS Express / MSBuild 標準位置時 prompt 使用者設 user-level `TURBO_PLUGIN_IIS_EXPRESS_PATH` / `TURBO_PLUGIN_MSBUILD_PATH`
  - **Outcome:** 所有 turbo-plugin 功能就緒;後續任一 worktree 開啟時 `PostToolUse EnterWorktree` hook 自動補 applicationhost.config(其他設定 env-free 後無動作),`SessionStart` hook 偵測到當前 worktree 未補時提示使用者手動跑 `/tp-setup`;`.commitlintrc.json` + `CLAUDE.md` 純諮詢、不在提交時 enforce,強制力由 `tp-push-to-svn` 在 push 階段 parse subject 提供
  - **Covered by:** R5, R6, R7, R8, R9

- F2. **日常開發 → 提交 → 推送 SVN**
  - **Trigger:** 使用者完成一輪改動,準備提交
  - **Actors:** A1, A2, A3
  - **Steps:** 使用者用任何 commit 工具寫 commit message(A3 提供的 commit skill、IDE 內 git commit、或手動 `git commit -m`)→ commit type 建議從 conventional commits 11 類加上 `db`(turbo-plugin 自訂)總共 12 類中選一(`.commitlintrc.json` + `CLAUDE.md` 約定,但不在提交時強制) → commit 成功進 git history → 使用者觸發 `tp-push-to-svn` → skill 從 main 取出待推送 commit → **逐 commit parse subject**:`feat` / `fix` / `refactor` / `perf` / `revert` 保留進 SVN message,`Merge ` / `docs` / `test` / `chore` / `style` / `build` / `ci` / `db` 篩除,**unknown type prompt 使用者選保留 / 篩除 / 取消** → 將篩選後的 commit body 組裝為 SVN commit message → 提交給 SVN
  - **Outcome:** SVN 收到的是程式碼變更紀錄;本地保留完整 commit history(含文件、SQL、test 等 commit);tp-push-to-svn 的 subject parsing 是 SVN bridge 篩選的 source of truth,使用者寫錯 type 在 push 階段被攔下
  - **Covered by:** R8, R10, R12, R18

- F3. **IIS Express 啟動 → 同 project 跨 worktree 衝突自癒 → 停止**
  - **Trigger:** 使用者要 build / run 一個 .NET Framework Web 專案
  - **Actors:** A1, A2
  - **Steps:** 使用者觸發 `tp-build-dotnet-framework-web` → skill 從 .csproj/.sln 自動解析 build 設定(無需使用者輸入)→ build 完成 → 觸發 `tp-run-dotnet-framework-web` → skill 從 .csproj 解析 IIS port → 檢測該 port + project root path 組合是否已被某個 IIS Express 佔用 → 若是「同 project 不同 worktree」的 instance,自動停掉舊 instance 後再啟動新 instance;若是「別 project」佔同 port,prompt 使用者讓他選擇(殺掉那個 instance / 選別 port / 取消)→ 啟動新 instance → 跑 listening 健康檢查確認啟動成功 → 開發中可隨時用 `tp-stop-dotnet-framework-web` 以「port + project root path」為 key 殺掉 instance
  - **Outcome:** 同一專案在不同 worktree 切換時不會殘留舊 IIS instance;run 不再會「假回報成功」;跨 project 同 port 衝突不會被誤殺
  - **Covered by:** R13, R14, R15, R16, R17

---

## Requirements

**Skill set 與介面(共用約定)**

- R1. 全部以 skill 介面提供(**不寫獨立 `commands/<name>.md` files**;skill 一律設 `user-invocable: true` 提供 `/tp-<skill>` 觸發入口,讓使用者可手動觸發 + Claude 可依 description 自動建議,兩條觸發路徑共用同一份 skill 實作)。命名前綴 `tp-`,最終 skill 數為 13 個。

  | Skill | 群組 | R-ID | Trigger mode |
  |---|---|---|---|
  | `tp-setup` | 設定 | R5-R9 | agent-proactive |
  | `tp-pull-from-svn` | SVN | R10 | proactive suggestion only |
  | `tp-push-to-svn` | SVN | R10 / R12 | proactive suggestion only |
  | `tp-svn-log` | SVN | R10 | agent-proactive |
  | `tp-create-remote-test` | SVN | R11 | proactive suggestion only |
  | `tp-reset-remote-test` | SVN | R11 | proactive suggestion only |
  | `tp-build-dotnet-framework-web` | .NET FW Web | R13 | agent-proactive |
  | `tp-run-dotnet-framework-web` | .NET FW Web | R13-R17 | agent-proactive |
  | `tp-stop-dotnet-framework-web` | .NET FW Web | R13 / R14 / R16 | agent-proactive |
  | `tp-publish-dotnet-framework-web` | .NET FW Web | R13 / R17 | proactive suggestion only |
  | `tp-suggest-ignore` | Ignore / 註解 | R19 | agent-proactive |
  | `tp-csharp-comment` | Ignore / 註解 | R20 | agent-proactive |
  | `tp-js-comment` | Ignore / 註解 | R20 | agent-proactive |

- R2. 每個 skill 的 description 需依其 trigger mode 設計。**判準是「做錯好不好救」**(可逆性),不是單純「動到 state 嗎」:
  - **agent-proactive** — 做錯可逆(再跑一次相反操作就回原狀,例如 build / run / stop / svn-log / setup / suggest-ignore / csharp-comment / js-comment / commit-msg(已砍但概念保留))。description 包含「何種狀態下 agent 應主動執行此 skill」,agent 偵測到狀態即主動執行(個別工具仍受 Claude Code permission 機制保護)。
  - **proactive suggestion only** — 做錯難救(上 SVN history 永久留下、產出 artifact 可能被 CD pipeline 消費、創建 remote-test branch 影響 SVN 遠端、reset-test 殺掉 SVN 上的 test 分支等;例如 publish / push-to-svn / pull-from-svn / create-remote-test / reset-remote-test)。description 包含「何種狀態下 agent 應**建議**使用者執行此 skill」,但 agent **不**直接執行——只在使用者明確同意後才執行。
  - **pure user-invocable**(目前無 skill 屬於此類)— 僅在使用者明確以 `/tp-<skill>` 觸發時執行,description 不含主動觸發訊號。
  - **未來新 skill 分類規則**:問「做錯只要一個指令能回原狀嗎?」是 → agent-proactive;否 → proactive suggestion only。
- R3. `.NET Framework Web` 系列以 `.ps1` 為原生實作(Windows-only target tech);**`.sh` 為 thin wrapper 轉呼叫 `.ps1`**(`powershell -NoProfile -ExecutionPolicy Bypass -File <script>.ps1 "$@"`,跟既有 tgs/tnf scripts 同款 powershell 而非 pwsh — Windows-default 環境只有 Windows PowerShell 5.1,沒 PowerShell Core 7+)讓 Git Bash on Windows 用戶仍可用 `/tp-build` 等觸發(避免 cygpath + wmic 完整 bash 重寫負擔)。其他 skill 提供 `.ps1` + `.sh` 雙原生版本。
- R4. 既有四個 turbo-* plugin(`tdp` / `tnf` / `tgs` / `tpi`)在 turbo-plugin 完成並驗證 OK 前保留為**測試過渡期備案**。turbo-plugin 為全新 plugin,與既有四個短期並存於同一 marketplace。**Cutover criteria 見 Success Criteria 對應條目**;並存期間 turbo-plugin 的 dbhub MCP server 命名為 `tp-dbhub`(避免與 `tdp` 內既有 `dbhub` server 碰撞);**使用者依 cutover criteria 驗證 turbo-plugin 涵蓋所需後 disable / remove 既有 4 plugin**——並存不是長期狀態。

**設定(`tp-setup`)**

- R5. `tp-setup` 為唯一設定入口,整合四種場景:(a) 新建 turbo-plugin 用的專案、(b) 在現有 git+SVN 專案上初始化 turbo-plugin、(c) 在已 setup 過的主 worktree 補/更新設定、(d) **peer-mode**(從 peer worktree 跑,主要服務 Pattern B 補建 peer-local 檔)。場景偵測訊號:
  - 偵測 `.git` 目錄是否存在 → 區分新建(無)vs 現有(有)
  - 偵測 SVN remote URL 是否已設定 → 區分 git-only vs git+SVN bridged
  - 偵測 `.turbo-plugin/` marker 是否已存在 → 區分初次 setup vs 補設定
  - 偵測 `git rev-parse --show-superproject-working-tree`(空 = 非 submodule;非空 = 在 submodule 內,turbo-plugin **不適用**,tp-setup 拒跑並提示「submodule 不在 turbo-plugin 管理範圍內」、SessionStart hook 在 pre-check 階段 silent exit)
  - 確認非 submodule 後,再偵測 `dirname(git rev-parse --path-format=absolute --git-common-dir) == git rev-parse --show-toplevel` → 區分主 worktree(true)vs peer worktree(false);peer 上跑進 case (d)。**路徑比較走 R14 同款 normalize**(Windows 環境須 lowercase drive letter + Resolve-Path 解析 junction / symlink / 8.3 short name,否則 `C:\proj` vs `c:\proj` 等價路徑被視為不等)
  - **case (d) peer-mode 行為**:**只**處理 per-peer non-shared files——(1) 若 peer 內缺 `.turbo-plugin/dbhub.local.toml` 則 prompt 使用者複製主 worktree 那份或互動填值、(2) 改寫 peer 的 `applicationhost.config` physicalPath(若 PostToolUse hook 沒跑過或漏掉);**不碰**任何 git-versioned shared files(`.turbo-plugin/config.toml` / `.turbo-plugin/applicationhost.config` source-of-truth / `.turbo-plugin/dbhub.example.local.toml` 範本 / `.commitlintrc.json` / `CLAUDE.md` commit convention 段);若 marker (`.turbo-plugin/`) 不存在,peer-mode 拒跑並提示「請先在主 worktree 跑 tp-setup case (a)/(b) 完成 bootstrap」。
- R6. setup 從現有 git+SVN 環境自動偵測必要資訊(branch / remote URL / SVN 對應 / project layout),不要求使用者手動輸入可偵測的值。
- R7. setup 處理 `.gitignore` + `svn:ignore` 兩側的預設忽略 patterns(含 `.claude/**/*.local.*` 等已知必須忽略項;**亦含 `.turbo-plugin/**/*.local.*` 用以排除含 credentials 的本機檔**)。`.turbo-plugin/` 資料夾本身加 git 版控、加 svn:ignore;但**資料夾內檔案分兩類**:`*.local.*` 後綴的檔案(含 DB 連線字串等 secret 的 `dbhub.local.toml` 等)gitignored、跨 worktree / 跨同事不共享(`tp-setup` 預設只在主 worktree 建 `dbhub.local.toml`,Pattern A 使用者無需 peer 各建一份);其他檔案(`applicationhost.config` / `config.toml` / `dbhub.example.local.toml` 範本)進 git、跨 worktree / 跨同事共享。
- R8. setup 透過 plugin 內建的 `.mcp.json` 宣告 dbhub MCP server,其設定檔路徑以 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml` 形式宣告(已實機驗證:Claude Code 會展開為 session 啟動當下的 worktree 路徑且 session 開始後鎖定;**推薦 Pattern A — 從主 worktree 啟動 Claude + 用 `EnterWorktree` 進 peer**,跨所有 worktree 共用主 worktree 一份 dbhub.local.toml,免 env;`.local.toml` 為 gitignored 含 credentials,使用者由 `dbhub.example.local.toml` 範本複製填入);寫入 `.commitlintrc.json` 作為**純文件約定**(允許 type:conventional commits 11 類 + 自訂 `db`),在 repo 的 `CLAUDE.md` 注入「Commit Type Convention」段落讓 dev flow plugin 看得到約定。**不安裝 husky / 不裝 commit-msg hook、不在提交時強制 enforce**——commit format 的「強制力」由 R12 的 `tp-push-to-svn` 在 push 時 parse subject 提供(見 R12)。檢查外部依賴(msbuild / IIS Express / svn CLI / Docker for dbhub)可用性,缺失時清楚 fail with 詳細錯誤訊息(不靜默 fallback)。
- R9. **新 worktree 自動補設定機制(env-free)**:
  - **沒有 per-worktree env block**: turbo-plugin 設計上**消除絕大多數 env**——SVN URL 存在 `<proj>.worktrees/remote-main/.svn/` 由 svn 自己管(後續用 `svn info` 取得,不存 git config / 不存 env;turbo-plugin **不用 git-svn**,用「雙 worktree + svn checkout + git merge」橋接);branch 對應走 `<branch>` ↔ `remote/<branch>` naming convention;repo-level 設定走 `.commitlintrc.json` / `.turbo-plugin/config.toml` / `.turbo-plugin/applicationhost.config`;含 credentials 的 secret-bearing 設定走 `.turbo-plugin/dbhub.local.toml`(gitignored, `.local.*` pattern);per-worktree 動態值(worktree 路徑、.csproj 路徑)走 `git rev-parse` / `find` 即時取得;machine-level 工具(svn CLI / Docker)走 PATH / 系統設定。
  - **唯一保留的 env(user-level optional)**:
    - `TURBO_PLUGIN_IIS_EXPRESS_PATH` — tp-setup 偵測不到 IIS Express 標準位置(`${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe`)時 prompt 使用者設
    - `TURBO_PLUGIN_MSBUILD_PATH` — tp-setup 偵測不到 MSBuild 標準位置(VS 標準安裝路徑)時 prompt 使用者設
    - 兩者都放 **user-level** `~/.claude/settings.json` env block(不放 repo-level 的 settings.local.json),一次設定跨所有 repo / worktree 共用
    - 命名前綴一律 `TURBO_PLUGIN_*` 避免跟其他 plugin / 系統 env 衝突
  - **turbo-plugin-managed repo marker + 集中目錄**: git root 下有一個名為 `.turbo-plugin/` 的資料夾,集中存放所有 turbo-plugin 獨有的檔案,不分散在 repo 各處。資料夾本身存在就是 marker(由 tp-setup 跑完後 mkdir)——所有 hook 第一件事檢查 `[ -d .turbo-plugin ]`,沒有就 silent exit,避免在無關專案誤觸發。資料夾加入 git 版控(跨 worktree 共用),加入 svn:ignore(SVN 不收)。內容:
    - `.turbo-plugin/config.toml` — **per-project 設定檔**(build / frontend / publish 偏好),取代 11 個既有 env(BUILD_DEFAULT_CONFIGURATION / BUILD_DEFAULT_PLATFORM / BUILD_FRONTEND_DIR_PATH / BUILD_NODE_VERSION / BUILD_FRONTEND_INSTALL_COMMAND / BUILD_FRONTEND_BUILD_COMMAND / PUBLISH_PUBXML_PATH / PUBLISH_DEFAULT_CONFIGURATION / PUBLISH_DEFAULT_PLATFORM 等)。Commit 進 repo,跨 worktree / 跨同事自動共用。Skill 跑時讀取,argument 可 override 一次性需求。**頂層 `schema_version` 欄位用於未來跨版本 migration(本份 doc 對應 schema_version = 1)**。結構範例:
      ```toml
      schema_version = 1               # turbo-plugin config.toml schema version

      [build]
      configuration = "Debug"          # MSBuild configuration default
      platform = "Any CPU"             # MSBuild platform default

      [frontend]
      # 整段省略 → 沒有前端 build 步驟
      dir = "ClientApp"
      install_command = "yarn install" # 非標準命令(例如 yarn / pnpm)
      build_command = "yarn dev-build" # 非標準 script 名稱
      node_version = "18"

      [publish]
      configuration = "Release"
      platform = "x64"                 # 非預設 platform
      default_pubxml = "Properties/PublishProfiles/Prod.pubxml"  # 多 .pubxml 時的預設

      [run]
      listening_timeout_seconds = 30   # IIS Express 啟動後 listening 健康檢查 timeout(冷啟可調至 90)
      ```
    - `.turbo-plugin/applicationhost.config` — 共享 IIS Express 設定 source of truth(見 R9 Peer worktree 自動補設定路徑)
    - `.turbo-plugin/dbhub.example.local.toml` — dbhub MCP server 設定**範本**(進 git,不含 credentials,使用者複製為 `dbhub.local.toml` 後填值)
    - `.turbo-plugin/dbhub.local.toml` — dbhub MCP server **實際設定**(gitignored、`.local.*` pattern 匹配,含 DB 連線字串等 secret);**已驗證 `${CLAUDE_PROJECT_DIR}` 鎖定為 session 啟動位置**(見 Resolve Before Planning Resolved 條目)。**推薦 Pattern A**:使用者從主 worktree 啟動 Claude + 用 `EnterWorktree` 進入 peer → MCP server 跨所有 worktree 共用主 worktree 這一份。**Pattern B** (直接在 peer 啟動 Claude) → 該 peer 需有自己的 `dbhub.local.toml`,SessionStart hook 偵測缺失時提示使用者複製主的或自填。`tp-setup` 預設只在主 worktree 建,peer 不主動建。
    - 未來其他 turbo-plugin 獨有檔案都放這裡(secret-bearing 一律走 `*.local.*` 後綴)。
  - **Skill 跑時設定值查找優先順序(4 層)**:(1) skill argument 一次性 override → (2) `.turbo-plugin/config.toml` 對應欄位 → (3) 預設值(`Debug` / `Any CPU` 等 turbo-plugin 內建)→ (4) 找不到必要值且無 skill argument 且無合理 default → fail with 清楚錯誤訊息。**例外**:IIS port 不走此 chain,改由 R14 規定的 `.csproj` 解析路徑取得(它是 IIS-specific 的設定,不像 build configuration 那樣可有 default)。**設計選擇**:不在 lookup chain 中加「從專案檔自動偵測」這層——理由是 tp-setup 初次跑時就會把 config.toml 寫齊,自動偵測層在正常運作中是 dead path,只增加 implementation 複雜度(.sln / .csproj / package.json / pubxml 多種檔案格式解析)而無 ongoing 收益。
  - **`hooks/hooks.json`(turbo-plugin 自帶,安裝即 active,不需 tp-setup 跑過)**:
    - **`PostToolUse` matcher `EnterWorktree` — 自動跑**: Claude 跑 `EnterWorktree` tool 進入新 worktree 後觸發。hook 檢查 marker 存在 → 自動跑 applicationhost.config 改寫 physicalPath(其他 setup 動作 env-free 後沒了)。理由:使用者透過 Claude tool 開 worktree 是「明確 turbo-plugin 意圖」,設定可在使用者預期的「Claude 切到新 worktree」過程中完成。
    - **`SessionStart` matcher `*` — 只提示,不自動寫**: 任何 Claude session 啟動時觸發(因為 hook 寫在 plugin 內,只有安裝並啟用 turbo-plugin 才會 load — 不需擔心「無關 repo 污染」,reach 到 hook 的本身就是「使用者已選擇用 turbo-plugin」)。hook 先做 pre-check:**非 git working tree(`git rev-parse --is-inside-work-tree` 失敗)→ silent exit;在 submodule 內(`git rev-parse --show-superproject-working-tree` 非空)→ silent exit(turbo-plugin 不適用 submodule,見 R5 同款判定)**。通過 pre-check 後分三條分支:(i) `.turbo-plugin/` 存在 + 當前 worktree 的 applicationhost.config 未補(physicalPath 不對)→ **以 system message 提示「請手動執行 `/tp-setup` 完成本 worktree 設定」**,不自動寫;(ii) `.turbo-plugin/` 存在 + 當前 worktree **不是**主 worktree(判定:`dirname(git rev-parse --path-format=absolute --git-common-dir) != git rev-parse --show-toplevel`,路徑比較走 R14 同款 normalize)+ 當前 worktree 內沒有 `dbhub.local.toml` → **Pattern B 偵測,以 system message 提示「若要在此 worktree 直接啟動 Claude 使用 dbhub,請複製主 worktree 的 `.turbo-plugin/dbhub.local.toml` 過來或執行 `/tp-setup` 互動式建檔(case d, peer-mode);若慣用 Pattern A(從主 worktree 啟動 + EnterWorktree)則忽略此提示。注意:Pattern 由 session 啟動位置鎖定,mid-session EnterWorktree 不改 Pattern——若打算之後 EnterWorktree 到主 worktree 使用 dbhub,仍會用此 peer 當下的 `dbhub.local.toml`」**;(iii) `.turbo-plugin/` 不存在 → **以 system message 提示;hook 先算主 worktree 路徑 `MAIN_PATH = dirname(git rev-parse --path-format=absolute --git-common-dir)` 與當前 `CUR_PATH = git rev-parse --path-format=absolute --show-toplevel`(路徑比較走 R14 同款 normalize),再分兩變體:(iii-a) `MAIN_PATH == CUR_PATH`(當前就是主 worktree)→ 提示「turbo-plugin 已安裝但本 repo 尚未 setup,請在此目錄執行 `/tp-setup` 完成 bootstrap」;(iii-b) `MAIN_PATH != CUR_PATH`(當前是 peer worktree)→ 提示「turbo-plugin 已安裝但本 repo 尚未 setup;請到 `<MAIN_PATH 的實際值>` 啟動 Claude 並執行 `/tp-setup` 完成 bootstrap」**(因為 hook 跑表示 plugin enabled,marker 不存在 = bootstrap 沒做完成 或 marker 誤刪需修復,使用者依情境判斷;具體路徑比「主 worktree」抽象術語更直觀)。**設計簡化說明**:`.turbo-plugin/` 為 sole marker,不需在 `.commitlintrc.json` 加 `_tp_marker` 等 signature key(避免 editor JSON-schema warning / config-rewriting tool 砍 unknown key 風險);user-scope 全域安裝 turbo-plugin 而在無關 repo 開 Claude 的邊緣場景會吃到分支 (iii) 提示一次,使用者可忽略或改 project-scope 安裝。
  - 雙 hook 設計與覆蓋面:`PostToolUse EnterWorktree` 自動補設定**只** cover「Claude 透過原生 `EnterWorktree` tool 進 worktree」一條路徑;**Bash 自跑 `git worktree add` + cd、`/ce-worktree` 等用 Bash 包裝 worktree-manager.sh 的 plugin、shell 手建 worktree 後開 Claude、Claude session 重啟 / context compact 都不觸發 `PostToolUse EnterWorktree`**——這些路徑統統走 `SessionStart` 提示路徑:使用者要手動跑一次 `tp-setup`,但被 SessionStart 主動提示,不會忘記。**不需要 git hook、不依賴 CLAUDE.md 文字提醒、不依賴 LLM 判斷**。
  - **Peer worktree 自動補設定路徑**(R5 case (d))在 PostToolUse hook 觸發時做:
    - **applicationhost.config rewriting**(唯一動作,因為 env 鏡像 / npm install 都已 dissolves):
      - **來源**: `.turbo-plugin/applicationhost.config`(git 版控的 source of truth,跨所有 worktree 共用同一份起點;VS-generated 的 `.vs/<solution>/config/applicationhost.config` 不碰)
      - **產出**: 複製到當前 worktree 的對應位置(由 .csproj / .sln 決定,通常為 `.vs/<solution>/config/applicationhost.config`)後改寫
      - **rewriting 範圍**: **只動對應當前 worktree .csproj 的 site** 的 `<application physicalPath>` 與 `<virtualDirectory physicalPath>`,透過 `<site name>` 跟 .csproj 名稱 match;不動其他 site(本機其他 IIS Express site 不被誤觸)
      - **如何取得「當前 worktree 路徑」**: hook 從 stdin JSON 讀 `tool_response.worktreePath` 欄位(實機驗證確認可用、為展開後絕對路徑);**不能用 `$CLAUDE_PROJECT_DIR`**——它停留在 Claude session 啟動時的原始路徑而非新 worktree。`pwd` / `cwd` 也指向新 worktree 可作備援讀取點
      - **match 算法**: XML parse(不用 string find/replace,避免「main worktree path 是別人路徑 prefix」誤觸);改完寫回
      - **寫入需 atomic + idempotent**: 寫入時先寫 temp 檔 + rename 替換(避免中途失敗留 corrupted XML);寫前先讀回當前內容比對,若已為目標狀態則 skip 寫(避免多 Claude session 同 worktree race 時重複寫)
  - **其他設定檔內 absolute path(`appsettings.json` / `launchSettings.json` / `Web.config` 等)turbo-plugin 不碰**,由使用者自行處理。

**SVN 操作**

- R10. 保留 `tp-pull-from-svn` / `tp-push-to-svn` / `tp-svn-log` 為基本 SVN bridge 操作。`tp-pull-from-svn` 與 `tp-push-to-svn` 為 proactive suggestion only 模式(影響本地 working tree / 外部 SVN state)。
- R11. 保留 `tp-create-remote-test` / `tp-reset-remote-test` 管理 test 分支的 git-svn 同步機制(兩者都是 proactive suggestion only,因為影響外部 SVN state);worktree 模型保留 main + `remote-main` + `remote-test-<n>`,移除 `dev-<n>`(原本服務 tdp 開發流程,流程砍了 → 隔離 worktree 由開發流程 plugin 的 worktree 機制如 `ce-worktree`、或使用者手動 `git worktree add` 提供)。`remote-*` worktree 跟 main worktree 一樣會被 plugin 的 `SessionStart` hook 觸發 tp-setup case (c)——R8 的 commitlint exception 規則確保 git-svn 同步的自動 commit 不會被 hook reject。
- R12. `tp-push-to-svn` 在組裝 SVN commit message 時,**自己 parse 每個待推送 commit 的 subject**:
  - 保留:`feat` / `fix` / `refactor` / `perf` / `revert` 開頭的 commit body 進入 SVN message
  - 篩除:`Merge ` / `docs` / `test` / `chore` / `style` / `build` / `ci` / `db` 開頭的 commit
  - **遇到 unknown type 或無 conventional commits prefix 的 commit**(因為使用者沒 commitlint hook 強制,可能漏寫):prompt 使用者選擇「(1) 保留進 SVN / (2) 篩除 / (3) 取消 push 讓使用者先 amend commit message」,不靜默猜測。
  - 自動產生的 commit(`git-svn-id:` trailer / `Merge ` 開頭):按上述規則自然處理,不需特殊 exception。

**.NET Framework Web**

- R13. 提供 4 個 skill:`tp-build-dotnet-framework-web` / `tp-run-dotnet-framework-web` / `tp-stop-dotnet-framework-web` / `tp-publish-dotnet-framework-web`。所有設定(port、IIS URL、build configuration、publish target、framework version、output path、frontend build 命令、.pubxml 選哪份等)依 R9 「Skill 跑時設定值查找優先順序」4 層處理:skill argument → `.turbo-plugin/config.toml` → 預設值 → fail。**IIS port 為例外**,依 R14 從 `.csproj` 解析。使用者無需手動配置 env;`config.toml` commit 進 repo 跨同事共用,首次設定由 tp-setup 寫齊。
- R14. IIS Express 實例以 **(port + project identity)** 為複合識別 key(不以 worktree、不以 PID list、不以啟動參數)。port 從 `.csproj` 的 IIS 設定區段(`IISExpressSSLPort` / `IISUrl` / `DevelopmentServerPort` 等)解析。**project identity 的定義(讓同 repo 跨 worktree match、不同 repo 不誤殺)**:`git rev-parse --path-format=absolute --git-common-dir` 的回傳值(Git ≥ 2.31)+ `.csproj` 對當前 worktree top-level 的相對路徑,組成複合 id(例如 `c:/proj/.git#src/MyApi/MyApi.csproj`)。**重要 normalization 要求**:(a) 必須用 `--path-format=absolute` flag——bare `git rev-parse --git-common-dir` 在 main worktree 回相對路徑 `.git`、在 linked worktree 回絕對路徑,直接 string-compare 不會 match;(b) Windows 環境 path 要 case-normalize(統一 lowercase drive letter + Resolve-Path 解析 symlink/junction/short-name)避免 `C:\proj` vs `c:\proj` 等價路徑被視為不同 repo;(c) Git < 2.31 fallback(若有相容需求)defer to planning。**理由**:同 repo 的所有 worktree 共用同一個 `git common-dir` 的同一絕對路徑(經正規化後 string 完全相同),且 worktree 是 repo checkout copy 故 csproj 相對路徑亦相同 → 同 project 跨 worktree 必 match;不同 repo 的 `git common-dir` 不同 → 不誤殺。port 必須能從 checked-in `.csproj` 解析;若值僅存在於 `.csproj.user` 或 user-level `applicationhost.config`,`tp-setup` 階段 prompt 使用者補進 `.csproj` 或明確 fail 報錯,不靜默 fallback。**Implementation detail(這個 project identity 如何寫進 IIS Express 啟動 process 讓 query 撈得到 — 例如 site name suffix / env var / command line marker)defer to planning。**
- R15. 當 `tp-run-dotnet-framework-web` 偵測到 port 已被 IIS Express 佔用:
  - 若佔住的是**同 project 不同 worktree** 的 instance(port + project identity 都 match)→ 自動停掉舊 instance 後啟動新 instance,不要求使用者手動處理。
  - 若佔住的是**別 project**(port match 但 project identity 不 match)→ prompt 使用者選擇:殺掉那個 instance / 選別 port / 取消。
- R16. `tp-stop-dotnet-framework-web` 殺掉「指定 (port + project identity) 上的 IIS Express」,不論該 instance 是由哪個 worktree(或哪個 PID)啟動;不誤殺別 project 同 port 的 instance。
- R17. `tp-publish-dotnet-framework-web` 內含 pack-content 邏輯;`tp-run-dotnet-framework-web` 內含 listening 健康檢查(確認 port 真的可連線後才回報成功)。

**Commit / ignore / 註解**

- R18. **(移除)** tp-commit-msg 已不存在。Commit type 約定的 source of truth 由 `.commitlintrc.json`(machine-readable,給 dev flow plugin 或第三方工具讀)+ `CLAUDE.md` 注入的 convention 段(human / agent-readable)提供——這兩份是**純諮詢文件**,不在提交時強制 enforce。實際的 enforcement 在 `tp-push-to-svn` 的 subject parsing 階段(R12):unknown type 會被 prompt 攔下,使用者要明確選保留 / 篩除 / 取消修正,避免 SVN history 漏網。
- R19. `tp-suggest-ignore` 看到新 untracked 檔(或新建檔)符合「不應入版」特徵時主動建議 ignore;同時處理 git `.gitignore` 與 SVN `svn:ignore` 兩側。
- R20. `tp-csharp-comment` / `tp-js-comment` 維持既有程式碼註解風格約定 skill,僅改名加 `tp-` 前綴。包含於 turbo-plugin 內部的 inclusion principle 見 Key Decisions「inclusion principle」項。

---

## Acceptance Examples

- AE1. **Covers R15, R16.** Given worktree B 已用 `tp-run-dotnet-framework-web` 啟動專案 X 的 IIS Express(佔用 port 44300),when 使用者切到 worktree A 並要 run 同一專案,then `tp-run-dotnet-framework-web` 偵測 `(port 44300 + 專案 X project identity)` 已被佔用——project identity = `git common-dir` + `.csproj` 相對路徑,worktree A 和 B 在同 repo 故 identity 完全相同——自動停掉 worktree B 啟的 instance 後啟動新 instance;不需要使用者先到 worktree B 跑 stop。
- AE2. **Covers R15, R16.** Given worktree A 已用 `tp-run-dotnet-framework-web` 啟動專案 X(佔用 port 44300),when 使用者要 run 專案 Y(也用 port 44300),then `tp-run-dotnet-framework-web` 偵測 port 44300 被佔但 project identity 不 match(專案 Y 在不同 repo,`git common-dir` 不同),prompt 使用者選擇:「殺掉專案 X 的 instance / 給專案 Y 選別 port / 取消」;不自動誤殺專案 X。
- AE3. **Covers R12.** Given 一輪改動包含 5 個 commit:`feat: add user table query`、`db: add migration script`、`docs: update README`、`fix: handle null in parser`、`test: add unit test for parser`,when 使用者觸發 `tp-push-to-svn`,then SVN 收到的 commit message 只包含 `feat` + `fix` 兩個 commit 的 body;`db` / `docs` / `test` 三個 commit 被篩除(本地 git history 保留全部 5 個 commit)。
- AE3b. **Covers R12.** Given 一輪改動含一個 commit `update parser logic`(使用者忘記加 conventional commits prefix),when 使用者觸發 `tp-push-to-svn`,then skill 偵測到 unknown type → prompt 使用者:「(1) 保留進 SVN / (2) 篩除 / (3) 取消 push 讓使用者先 amend commit message」;使用者選 (3) → push 中止,使用者 `git commit --amend` 改成 `fix: update parser logic` 後再 push。
- AE4. **Covers R19.** Given 使用者在現有專案新增了一個 `local-config.json`(明顯個人設定,不該入版),when Claude 偵測到此 untracked 新檔案,then `tp-suggest-ignore` 主動建議加入 `.gitignore` 與 `svn:ignore`,使用者確認後兩側都更新。
- AE5. **Covers R11.** Given 使用者需要隔離 branch 開發第二階段功能,when 使用者用 `ce-worktree`(或手動 `git worktree add`)開新 worktree,then 新 worktree 與 turbo-plugin 的 SVN bridge worktree(`remote-main` / `remote-test-<n>`)並存不互相干擾。
- AE6. **Covers R9.** Given main worktree 已跑過 tp-setup,when 使用者跟 Claude 說「開個 feature-x worktree」、Claude 跑**原生** `EnterWorktree` tool 建立新 worktree 並 enter,then plugin 自帶的 `PostToolUse` hook(matcher `EnterWorktree`)在新 worktree cwd 下觸發 → 偵測 `.turbo-plugin/` marker 存在 → 從 `.turbo-plugin/applicationhost.config` 複製到當前 worktree 對應位置 + XML parse 改寫對應 site 的 physicalPath;使用者**無需手動跑任何指令**就能在 new-worktree 內使用 turbo-plugin 的 .NET FW Web skill(其他 skill 依 config.toml + 自動偵測 env-free 運作)。
- AE6b. **Covers R9.** Given 使用者**不**透過 Claude 原生 `EnterWorktree`(改用 shell `git worktree add ../new-worktree -b feature-x` 後 cd / 用 `/ce-worktree` 等用 Bash 包裝 worktree-manager 的 plugin)建 worktree 後開 Claude,when Claude session 啟動,then **`PostToolUse EnterWorktree` 不觸發**(因為沒跑該 tool);plugin 自帶的 `SessionStart` hook 觸發 → 偵測 `.turbo-plugin/` marker 存在但當前 worktree 的 applicationhost.config 未補 → 以 system message 提示使用者手動跑 `/tp-setup`;使用者跑完後狀態同 AE6。
- AE7. **(移除)** 原 AE7 測 commitlint hook 對 git-svn 自動 commit 的 exception 規則,Round 2 後 commitlint+husky 已降版為純諮詢、沒裝 hook,此 AE 不再相關。
- AE8. **Covers R5, R6, F1.** Given 使用者在現有 git+SVN 專案(尚未由 turbo-plugin 管理)觸發 `tp-setup`,when `tp-setup` 偵測到 `.git/config` 含 `[svn-remote "..."]` 區段(既有 git-svn 設定),then `tp-setup` 警告「turbo-plugin 不相容 git-svn,請先移除 git-svn 設定再繼續」並暫停,等使用者確認後才往後走。
- AE9. **Covers R8, R9, F1.** Given 使用者在新環境觸發 `tp-setup`,when `tp-setup` 偵測不到 IIS Express 標準位置(`${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe` 不存在)或 MSBuild 標準位置(VS 標準安裝路徑不存在),then `tp-setup` prompt 使用者設 user-level `TURBO_PLUGIN_IIS_EXPRESS_PATH` 或 `TURBO_PLUGIN_MSBUILD_PATH`(寫到 `~/.claude/settings.json` 而非 repo-level `settings.local.json`),設好後繼續完成 setup。
- AE10. **Covers R5, R7, F1.** Given 使用者在新建 git+SVN 專案場景觸發 `tp-setup`,when `tp-setup` 偵測到無 `.git` 也無 `.turbo-plugin/`,then `tp-setup` 從零建立:(1) git repo + main worktree、(2) `.turbo-plugin/` 集中目錄含 `applicationhost.config` / `config.toml` / `dbhub.example.local.toml` 範本、(3) `.gitignore` + `svn:ignore` 預設 patterns、(4) `.commitlintrc.json`(含 `db` type)+ `CLAUDE.md` 注入「Commit Type Convention」段、(5) prompt SVN URL 後建立 `remote/main` orphan branch + `<proj>.worktrees/remote-main/` worktree 跑 `svn checkout`;結束時 `.turbo-plugin/` marker 已存在、後續任一 worktree 開啟即被 hook 識別為 turbo-plugin-managed。

---

## Success Criteria

- 使用者在新環境(或新 worktree)安裝 turbo-plugin 並開始使用任一 skill 的時間,從目前的「裝 4 個 plugin + setup 各自的 env」縮短到「裝 1 個 plugin + 跑一次 `tp-setup`」。
- 場景 3(worktree A 跑 stop 殺不到 worktree B 的 IIS)不會再發生;任一 worktree 的 stop / run 都能處理同 project 同 port 的所有 instance,且不誤殺別 project 同 port 的 instance。
- 使用者用 Claude 原生 `EnterWorktree` tool 開新 worktree 後**無需手動跑任何指令**——`PostToolUse` hook 自動補 applicationhost.config physicalPath(其他設定 env-free 後不需動作)。**此路徑覆蓋面狹義**:Bash 自跑 `git worktree add` / `/ce-worktree` 等 Bash 包裝的 plugin / shell 手建 worktree 不會觸發 `PostToolUse EnterWorktree`,統統走 `SessionStart` 提示路徑——hook 主動提示「請執行 `/tp-setup`」,使用者多一個明確動作但不會忘記;不會在無關專案誤觸發(靠 `.turbo-plugin/` 資料夾當 marker)。
- 跨 worktree 操作的限制誠實表達:env-依賴的 skill(查 dbhub / 解析路徑 settings 等)在任一 worktree 都正常運作;但綁 cwd / 檔案上下文的 skill(read 當前 worktree 的 .csproj / 操作當前 git working tree)仍需 Claude session 在該 worktree 內(這是 Claude 本身限制,turbo-plugin 無法 work around)。
- 開發流程相關需求由使用者自選的開發流程 plugin 接手;turbo-plugin 不再有 goal / plan / implement / testing-and-proof / write-test-plan / finish-dev 類 skill。
- **對於透過 `tp-push-to-svn` 的路徑**,unknown type 不會靜默漏網——`tp-push-to-svn` 自己 parse subject 是該路徑下 SVN bridge 篩選的 source of truth;使用者用任何 commit 工具寫的 commit 在這個 push 階段都會被檢查。**`tp-push-to-svn` 不約束 raw `svn commit` / TortoiseSVN 等繞道路徑**(見 Dependencies/Assumptions 對應條目)。`.commitlintrc.json` + `CLAUDE.md` convention 段是純諮詢文件,不在提交時 enforce(避免 husky / npm 工具鏈依賴)。
- **Cutover criteria(既有 4 plugin 退場標準)**:turbo-plugin 完成 R1 表列的 13 個 skill 全部實作 + F1 / F2 / F3 三條 flow 各完整跑通一輪 + 連續 5 個工作日日常使用無 blocker → 立刻 disable / remove 既有 4 plugin(`tdp` / `tnf` / `tgs` / `tpi`)。並存期間若 dbhub MCP 行為異常,於 Claude session 中以 `mcp__<server>__` tool 命名前綴辨識實際在跑的版本。為避免過渡期 dbhub MCP server 名稱碰撞,turbo-plugin 過渡期內 dbhub MCP server 命名為 `tp-dbhub`(cutover 後可選擇是否 rename 回 `dbhub`)。
- 一個 ce-plan 接手這份文件後,可以直接進入「該 plugin 的 13 個 skill 各自實作」的規劃,無需回頭問 product behavior、scope、commit type 規則、IIS 識別策略等問題。Brainstorm 階段已完成 Claude Code 行為實機驗證(2026-05-22 — `${CLAUDE_PROJECT_DIR}` 展開 + PostToolUse cwd),結果定案寫進 doc;Deferred to Planning 列出 6 條 technical implementation details(`.csproj` IIS port parser、config.toml schema migration、`tp-suggest-ignore` 偵測規則、worktree primitive 邏輯共用等)由 planning 階段處理。

---

## Scope Boundaries

### Platform support 限制(已知產品邊界)

- **`.NET FW Web` 系列(4 skill,`tp-build-dotnet-framework-web` / `tp-run-...` / `tp-stop-...` / `tp-publish-...`)僅 Windows**(R3 規定無 `.sh`)。Unix 環境下 turbo-plugin 縮減為 9 skill(設定 + SVN + Ignore / 註解)。**A1 actor 若主要使用者切到 Unix,turbo-plugin 對該使用者價值大幅縮減**;此時應重新評估是否值得整合 .NET Core 支援(目前 Deferred)。本 limit 是技術現實(.NET Framework Windows-only)的直接後果,不是設計選擇。

### Deferred for later

- .NET Core 支援。當前無 .NET Core 專案需求;未來真的有時再為 `tp-*-dotnet-core-web` 開新一組 skill(命名已預留差異)。
- 跨 SVN 以外的 VCS bridge(如 Perforce、Mercurial)。turbo-plugin 的 SVN bridge 與 SVN 特性硬綁,其他 VCS 需求出現時再評估。
- DB 三層命名(`local-db` / `test-db` / `main-db`)相關的 skill 強制。當前保留為純文件約定,靠使用者自律遵守;未來若需求出現可考慮做 `tp-suggest-ignore` 的變體或新 skill 主動辨識 SQL 檔該放哪一層。

### Outside this product's identity

**Inclusion principle**(兩層判準,**必要條件 + 充分條件**,非單純 OR):
- **必要條件**(必須滿足才能在 turbo-plugin 內):實際有人在用 + 使用者希望 agent 主動 enforce。
- **充分條件**(決定是否該 expand scope 到新領域):整合 turbo-plugin 才能整合的外部系統(IIS Express / SVN / dbhub)。
- **既有 skill 豁免充分條件僅限本份 doc R1 明確列入的 13 個 skill(視為一次性歷史例外)**;後續任何新增 skill 一律 enforce 完整雙條件,不適用「既有」豁免——避免「先暗暗加進來 → 變成既有 → 永久豁免」的 scope drift。

對既有 skill 的應用:
- SVN / IIS / dbhub 系列:必要 ✓ + 充分 ✓ → 留
- `csharp-comment` / `js-comment`:必要 ✓(你跟同事實際在用、希望 agent enforce)+ 充分 ✗(屬內部約定,不整合外部系統,但既有不適用 expand 判準)→ 留
- `frontend-standard`:必要 ✗(實際沒在用)→ 砍(不論充分條件如何)

對未來新 skill 候選的應用:
- 必要 ✗ → 砍(不論充分條件)
- 必要 ✓ + 充分 ✗(要往非外部系統整合的新領域擴張)→ 慎重評估,優先考慮其他 plugin 擔此責任
- 必要 ✓ + 充分 ✓ → 留

下列項目都是按此 principle 排除。

- 自己嘗試設計開發流程(goal / plan / implement / testing-and-proof / finish-dev 等)。撤退的主要動機是「自己維護成本太高」,且 GitHub 上有多個開發流程 plugin(compound-engineering 是其中之一)可自選。turbo-plugin 不綁特定 plugin,使用者依喜好搭配。
- 通用 commit message 撰寫工具與提交時 commit format 強制 enforcement(原 tp-commit-msg + husky + commitlint hook)。turbo-plugin 不裝 husky 或 commit-msg hook,不在提交時 reject——強制力在 `tp-push-to-svn` 的 push 階段 parse subject(R12)。`.commitlintrc.json` + `CLAUDE.md` convention 段是純諮詢文件,給願意配合的工具讀(例如 dev flow plugin)。commit message 撰寫由使用者自選的 commit 工具(ce-commit / IDE / 手動)處理。
- 文件轉換工具(markitdown 之類)。獨立需求,使用者自行 MCP 接,不是 turbo-plugin 的責任。
- 通用 memory 機制。Claude Code auto-memory 與多數開發流程 plugin 已涵蓋。
- 既有四個 plugin 對應但已棄用的功能:`archive` / `merge-main-into-all` / `release` / `cleanup-remote-test` / `tag-release` / `create-project` / `init-from-existing`(後兩者併入 `tp-setup`)/ `create-dev-worktree`(隔離開發 worktree 由 ce-worktree 或手動 `git worktree add` 提供)/ `create-branch`(`git checkout -b` 即可)/ `apply-local-test-stash` / `revert-local-test-stash`(開發流程支援工具)/ `pack-content`(併入 publish)/ `check-iis-listening`(併入 run)/ `frontend-standard`(實際沒在使用 — 砍它的理由是「使用狀況」非 architectural,與 inclusion principle 第 (2) 條一致)/ `db-management` / `teach-me` / `dependency-check` / `setup-all`(後三者 tpi 的編排功能,單一 plugin 不需要)。
- **同事 onboarding skill / 教學流程**:本次 rewrite 不做,留待未來以新 skill 形式新增(例如 `tp-teach-me` 之類)。本次 rewrite 範圍是「把 13 個核心功能 skill 做好」;同事 onboarding 由使用者本人帶或未來新 skill 處理,planning 階段不應投資源到自助安裝 / 教學文件 / 多人協作驗證等場景。
- **「Pattern B 首次 bootstrap」(在 peer worktree 沒 marker 的情況下從零跑 tp-setup)**:本次 rewrite 不支援自動化。首次 tp-setup 必須在主 worktree 跑(case (a)/(b));peer-mode (case d) 只服務「主 worktree 已 setup 過、peer 補建 per-peer 檔」場景。若同事 day 1 直接在 peer 開 Claude,SessionStart hook 分支 (iii) 會主動提示「請到主 worktree 執行 `/tp-setup`」引導使用者切到主 worktree 完成 bootstrap,再回 peer 用——不在 peer 本身做 bootstrap-from-peer 自動化(工作量大且邊緣,留 future feature 評估)。
- `specs/<type>/<slug>/` 資料夾 convention。原本服務 tdp 的 goal / plan / implement 流程;流程砍了,convention 一併砍。開發文件放於使用者選用的開發流程 plugin 約定的位置(例如 `docs/brainstorms/`)。
- `archives/` 機制。做完的開發成果留在原地(spec 檔案、SQL 檔案),不再搬家——與多數開發流程 plugin 的 brainstorm/plan 文件留原地一致。

---

## Key Decisions

- **激進縮減(Approach 2)over 單純搬家(Approach 1)**:每個 skill 都要為 trigger mode 寫精準 description,保留將要砍的 skill = 浪費設計成本。
- **三層 trigger mode(agent-proactive / proactive suggestion only / pure user-invocable)**:不是「全 skill 都要 agent 主動觸發」也不是「全 skill 都 user-invocable」。destructive / 影響外部 state 的 skill 走 proactive suggestion only(agent 建議但需使用者同意才執行),其他依本質判斷。代價是每個 skill description 的觸發策略要花時間調精準。
- **13 個 skill 的目標**:使用者不用一個一個了解,而是知道「四個群組(設定 / SVN / IIS / Ignore-註解)」即可。
- **IIS Express 用 (port + project identity) 識別**:project identity = `git rev-parse --path-format=absolute --git-common-dir` + `.csproj` 對 worktree top-level 的相對路徑(複合 id;Windows 須 lowercase drive letter + Resolve-Path normalize);解決 worktree A 跑 stop 殺不到 worktree B 的真實 bug,同時不誤殺別 project 同 port 的 instance(不同 repo `git common-dir` 不同)。port 從 `.csproj` 解析,使用者無需手動配置。Implementation detail(這個 identity 寫進 IIS Express 啟動 process 哪裡讓 query 撈得到)defer to planning。
- **`tp-push-to-svn` 自己 parse subject 作為 SVN bridge 篩選的 source of truth(取代原本的 commitlint + husky 強制 enforce)**:Round 2 review 評估 commitlint + husky 對 .NET Framework 專案是不成比例的 JS 工具鏈依賴(npm install 30s+、husky version drift、worktree-local node_modules、tp-push-to-svn 跟 hook 交互邊界等),改成「`.commitlintrc.json` + `CLAUDE.md` convention 純諮詢、`tp-push-to-svn` 自己 parse、unknown type prompt 使用者」。零 JS 依賴、更簡單,trade-off 是錯誤格式 commit 進 git history 但 push 時被攔。
- **commit type 列表為 conventional commits 11 類 + `db`**:`db` 是 turbo-plugin 自訂,服務「SQL 變更 commit 不上 SVN 但本地保留」的核心需求。R12 篩選保留 `feat` / `fix` / `refactor` / `perf` / `revert`,過濾其他。原 `tdp` 的 `spec` type 隨開發流程 retreated 而砍。
- **R9 worktree 補設定機制定案為「env-free + per-project config.toml + 雙 Claude hook + marker」**:
  - **env-free**: 消除既有 11 個 plugin env(BUILD_* / PUBLISH_* / TEST_* / TDP_*)——前 9 個移到 `.turbo-plugin/config.toml`(commit 進 repo / 跨同事共用 / skill argument 可 override),後 2 個對應 skill 已砍。只保留 `TURBO_PLUGIN_IIS_EXPRESS_PATH` / `TURBO_PLUGIN_MSBUILD_PATH` 兩個 user-level optional env。
  - **Hook 機制**: `PostToolUse EnterWorktree` 自動跑 applicationhost.config physicalPath 改寫;`SessionStart` 只提示使用者跑 `/tp-setup`(不自動寫,避免無關專案污染)。
  - **Marker + 集中目錄**: `.turbo-plugin/` 資料夾當 turbo-plugin-managed repo marker(內含 `config.toml` / `applicationhost.config` / `dbhub.example.local.toml` 範本進 git;`dbhub.local.toml` 含 credentials gitignored),hook 第一件事檢查 `[ -d .turbo-plugin ]`,沒有就 silent exit。
  - **不需要 git hook、不依賴 CLAUDE.md 文字提醒、不依賴 LLM 判斷**。
- **commitlint 規則 + husky enforce 全砍**(原 Round 1 設計):無 husky hook → 沒有 git-svn 自動 commit 被 reject 的 risk、沒有 husky 版本 drift、沒有 worktree-local node_modules 問題。`tp-push-to-svn` 看到 `Merge ` / `git-svn-id:` trailer 等自動 commit 走「**篩除**」分支(本來就不該上 SVN)。
- **既有四個 plugin 為測試過渡期備案,非長期並存**:使用者驗證 turbo-plugin 涵蓋所需後會 disable / remove 既有 4 plugin。所以 dbhub MCP 名稱碰撞之類「並存問題」短期內可忍、長期不存在。
- **.NET Framework Web `.ps1` 為原生實作 + `.sh` 為 thin wrapper 轉呼叫 `.ps1`**:Windows-only 是指 *target tech*(.NET Framework 跑在 Windows),不是 *script 不能 bash*;thin wrapper 保留 Git Bash on Windows 用戶 `/tp-build` 等觸發路徑(實際內部跨 PowerShell)。避免 cygpath + wmic 完整 bash 重寫,`.ps1` 仍為 single source of truth。
- **其他 9 skill 保留 .ps1 + .sh 雙原生版本**:Claude Code 在 Windows 常自選 Git Bash 而非 PowerShell;同事或使用者未來可能切 Unix。
- **Inclusion principle: 必要條件(實際在用 + agent enforce 需求)+ 充分條件(整合外部系統)**:既有 skill 必須滿足必要條件才在 turbo-plugin 內(csharp/js-comment 留是因為實際在用、frontend-standard 砍是因為實際沒在用)。未來 expand scope 到新領域時需同時滿足充分條件(整合外部系統)——避免把任何「實際有需求」的 skill 都塞進 turbo-plugin。

---

## Dependencies / Assumptions

- 假設使用者會搭配一個開發流程 plugin(建議 compound-engineering,但任何同類的都可)。turbo-plugin 不綁定特定 plugin,也不依賴特定版本;commit 格式約定由 `.commitlintrc.json` + `CLAUDE.md` 注入段提供(**純諮詢、提交時不 enforce**),實際強制力由 `tp-push-to-svn` 在 push 階段 parse subject 提供(R12)。
- **假設 A3 開發流程 plugin 的 commit 工具會讀 repo 的 `CLAUDE.md` 內 commit convention 段或 `.commitlintrc.json`,並依此產生符合 11+1 類的 commit subject**(已驗證 `compound-engineering` 的 `ce-commit` 滿足:其 SKILL.md Step 2 明說「先讀 AGENTS.md / CLAUDE.md 找 convention 約定」)。若使用者選的 plugin 不讀這份約定,使用者需手動 align(否則 `tp-push-to-svn` 在 push 階段會反覆 prompt unknown type)。
- **假設使用者一致走 `tp-push-to-svn` 推 SVN**,不繞道 raw `svn commit` / TortoiseSVN 等 GUI client(這些路徑不在 turbo-plugin 約束範圍內)。若使用者真有繞道需求,需在 commit 階段自律遵守 type convention,turbo-plugin 不會主動偵測。
- **假設同 project 跨 worktree 使用同一個 DB(同一份 `dbhub.local.toml`)**。Pattern A 設計核心是「主 worktree 一份 dbhub config 跨 EnterWorktree 進入的所有 peer 共用」,前提是各 branch / worktree 連的 DB 相同。**例外情況**:若 feature branch 需連別的 test DB(例如 migration branch 用獨立 test DB 避免污染主流 test DB),該 branch 的 worktree 必須切到 Pattern B(直接 peer 啟動 Claude)+ 在該 peer 自備 `dbhub.local.toml`。turbo-plugin 不主動偵測「branch 該連哪個 DB」,由使用者自行判斷選 pattern。
- 假設 `.csproj` 已包含 IIS port(`IISExpressSSLPort` / `IISUrl` / `DevelopmentServerPort` 之一),且該設定是 checked-in 不在 `.csproj.user` / user-level `applicationhost.config`;若不在 checked-in 位置,`tp-setup` 應 prompt 使用者補進 `.csproj` 或明確 fail 報錯。
- 假設 `.csproj` / `.sln` / `web.config` 已包含 IIS port / build profile / publish target 等所有 turbo-plugin 需要的設定;若有專案缺失,`tp-setup` 階段應能偵測並回報,但「補齊」不是 turbo-plugin 的職責。
- 假設 dbhub MCP server 可透過 `.mcp.json` 標準宣告方式正常啟動(具體 server 名稱、版本、傳輸方式為 planning 階段確認)。
- **假設使用者環境 Git ≥ 2.31**(2021-03 釋出)。`git rev-parse --path-format=absolute --git-common-dir` flag 在 2.31 引入,R14 project identity 比對 + R5 主 worktree 偵測 + SessionStart hook 分支判斷皆依賴。**tp-setup 應 probe `git --version`,< 2.31 直接 fail loudly + 提示升級**,不靜默 fallback(否則 R14 string-compare 不會 match,worktree A stop 殺不到 worktree B 的 IIS 這個原 bug 會回來)。Windows 公司凍結環境 Git for Windows 老版本不少見,需主動檢查。
- ~~假設使用者環境已有 node + npm~~ — Round 2 後 commitlint + husky 降版為純諮詢、不裝 hook,turbo-plugin 不再需要 node + npm 作為硬依賴。Claude Code 本身仍是 npm 套件,但 turbo-plugin 內部不依賴 node 工具鏈。
- **已實機驗證**(2026-05-22):Claude Code 的 `PostToolUse` hook 在 matcher `EnterWorktree` 時於**新 worktree** 的 cwd 下執行;`$CLAUDE_PROJECT_DIR` 停留在 session 啟動時的原始路徑(舊),所以 hook script 須從 stdin JSON 的 `tool_response.worktreePath` 取新路徑。
- **已實機驗證**(2026-05-22):turbo-plugin 自帶的 `hooks/hooks.json` 中的 `SessionStart` hook 會在每個 Claude session 啟動時於**當前 worktree** cwd 跑 shell command(`pwd` / `$CLAUDE_PROJECT_DIR` / stdin `cwd` 三者一致都指向當前 worktree)。
- **已實機驗證**(2026-05-22):`.mcp.json` 內 `${CLAUDE_PROJECT_DIR}` 變數會展開為 session 啟動當下的路徑,且 session 開始後鎖定不變(EnterWorktree 不會改它,MCP server 也不會 relaunch)。這影響 R8 / R9 dbhub.local.toml 設計:**推薦 Pattern A**(從主 worktree 啟動 + EnterWorktree → 跨 worktree 共用主 worktree 那份);Pattern B(直接 peer 啟動)則需該 peer 自有一份。
- **驗證範圍 caveat**:probe 只覆蓋 single fresh-session lifecycle(session 從零啟動 + EnterWorktree)。**未驗證**:(a) `/compact` 觸發 context compact 後 MCP server 是否 relaunch、用什麼 cwd / `${CLAUDE_PROJECT_DIR}` 值;(b) session crash / 重啟 / resume 後的 MCP behavior;(c) Claude Code update 期間 session active 時的 MCP reconnect。若這些 lifecycle event 真會 relaunch MCP 而以 EnterWorktree 後的 peer 路徑展開,Pattern A 會 silent break(peer 沒 `dbhub.local.toml`)。planning 階段需設計 fallback(MCP server 找不到 dbhub.local.toml 時 fail loudly + 提示使用者)並補完 probe(見 Deferred to Planning 對應條目)。
- 假設使用者願意接受「每個 skill 的 description 需精準調 trigger mode」這個 description 設計成本(已在對話中確認)。
- 假設既有 4 plugin 的並存只在測試過渡期;使用者驗證 turbo-plugin OK 後會移除,所以 dbhub MCP server 命名碰撞之類「並存問題」可以容忍短期 transitional pain。

---

## Outstanding Questions

### Resolve Before Planning

_本份 doc 在 brainstorm 階段已實機驗證以下 Claude Code 行為(2026-05-22)。原 Outstanding Questions 解果定案,planning 階段直接採用。_

- [Resolved][Affects R8, R9] **`.mcp.json` `${CLAUDE_PROJECT_DIR}` 變數展開** — **變數真的會展開**;**展開值是 session 啟動當下的路徑,session 開始後鎖定,後續 `EnterWorktree` 不會改它**(實測:session 從主 worktree 啟動後 EnterWorktree 進 peer,`$CLAUDE_PROJECT_DIR` 仍是主 worktree;直接從 peer worktree 啟動 session,`$CLAUDE_PROJECT_DIR` 才是 peer)。MCP server 只在 session 啟動時一次性 launch,讀到的 dbhub.local.toml 路徑也是當下鎖定的那份。**設計結論**:**Pattern A/B 由 session 啟動 cwd 決定、mid-session EnterWorktree 不改 Pattern**。**推薦 Pattern A(從主 worktree 啟動 Claude session + 用 `EnterWorktree` tool 進入 peer worktree,對應 AE6 pattern)**——只需主 worktree 一份 `.turbo-plugin/dbhub.local.toml`,跨所有 EnterWorktree 進入的 peer 共用同一 db credentials。**例外情況**:使用者直接在 peer worktree 啟動 Claude(對應 AE6b pattern),則需該 peer 自己有 `dbhub.local.toml`——`SessionStart` hook 偵測此情況提示使用者(複製主 worktree 那份或自填)。`tp-setup` 預設只在主 worktree 建一份 `dbhub.local.toml`;peer worktree 不主動建,等使用者實際選 Pattern B 時再補。**Hybrid 警告**:若使用者在 peer 啟動(Pattern B)後 mid-session 用 `EnterWorktree` 進主 worktree,MCP server 仍 reading peer 那份 `dbhub.local.toml`(若 peer 沒這份 → dbhub 失敗),反之亦然——使用者要意識到 Pattern 在 session 啟動就鎖死,中途切 worktree 不改 Pattern。
- [Resolved][Affects R9, AE6] **`PostToolUse` matcher `EnterWorktree` hook 的 cwd 行為** — **hook 在新 worktree 的 cwd 下執行**(`pwd` 與 stdin JSON 的 `cwd` 欄位都指向新 worktree);**但 `$CLAUDE_PROJECT_DIR` 仍停留在 Claude session 啟動時的原始路徑(舊 worktree)**,所以 hook script **必須用 `pwd` 或從 stdin JSON 的 `cwd` / `tool_response.worktreePath` 欄位讀新 worktree 路徑,不能用 `$CLAUDE_PROJECT_DIR`**。stdin 包含 `tool_input.path`(EnterWorktree 的相對路徑)與 `tool_response.worktreePath`(展開後絕對路徑),兩者可交叉確認。**設計結論**:R9 的 PostToolUse hook 設計成立;applicationhost.config 改寫的「當前 worktree 路徑」一律從 stdin JSON 的 `tool_response.worktreePath` 讀(最 explicit 不依賴 cwd 慣例)。

### Deferred to Planning
- [Affects R5, R8][Needs research] **dbhub MCP server 的最終 `.mcp.json` config** — 具體 server 套件名稱、版本、是否需 Docker、傳輸方式 stdio / SSE / HTTP。
- [Affects R14][Technical] **`.csproj` IIS port 設定的可能格式組合** — VS-generated 的 `<DevelopmentServerPort>`、`<IISExpressSSLPort>`、`<IISUrl>`、舊版 `applicationhost.config` 引用等需窮舉並寫 parser。
- [Affects R9][Technical] **`config.toml` schema 跨版本演進策略** — `schema_version` 欄位已預留,但 turbo-plugin 升版改 schema(rename field / 加 required field / 改 type)時的處理路徑要在 planning 階段三選一:(a) tp-setup 偵測舊版自動 migration、(b) tp-setup 提示使用者執行手動 migration command、(c) skill 跑時偵測到舊版直接 fail with「請升 plugin 或跑 migration」指引。
- [Affects R8, R9][Needs verification] **Claude Code MCP server lifecycle 行為實機驗證** — Round 3 probe 只測 single fresh-session 啟動,未測:(a) `/compact` 後 MCP relaunch / `${CLAUDE_PROJECT_DIR}` 重展開行為、(b) session crash / resume 後行為、(c) Claude Code update 期間 MCP reconnect 行為。**驗證步驟**:建探針 plugin 帶 MCP server 印 launch argv;在 main worktree 開 session → EnterWorktree 進 peer → 跑 `/compact` → 觀察 mcp.log 是否有新 launch + argv 路徑。**結果寫回 doc**:若 relaunch 拿到 peer 路徑而非 session 啟動的主 worktree → Pattern A 的「跨 worktree 共用」假設破,需設計 fallback(例如 MCP server 找不到 dbhub.local.toml 時 fail loudly + 提示使用者複製主 worktree 那份過來)或調整 Pattern A 適用條件。
- [Affects R2][Technical] **13 個 skill 的 description 觸發文字** — 各依 trigger mode(agent-proactive / proactive suggestion only)寫對應的觸發時機文字並評估精準度。
- [Affects R19][Technical] **`tp-suggest-ignore` 偵測規則** — 看副檔名、檔名 pattern、檔案內容、還是檔案位置;git/SVN 兩側 ignore 機制(line-based vs property-based)的同步策略。
- [Affects R11][Technical] **`tp-create-remote-test` / `tp-reset-remote-test` 與既有 `tgs` plugin 是否可共用 worktree primitive 邏輯** — 邏輯重複可考慮複製貼上。
