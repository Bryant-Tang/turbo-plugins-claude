---
date: 2026-05-25
type: feat
origin: docs/brainstorms/2026-05-20-turbo-plugin-rewrite-requirements.md
status: active
---

# feat: turbo-plugin v0.2.4 acceptance test plan

## Summary

turbo-plugin v0.2.0 → v0.2.4 經 4 輪 ce-code-review + 1 輪實機 script-level
acceptance(在 `C:\Turbo\SampleGitWithSvn`)後,**SKILL agent-flow 部分**
仍須在真實 Claude Code session 由使用者驗。本 plan 列 11 個 Implementation
Unit 覆蓋 **12 個 SKILL**(全 13 個中 tp-svn-log 留 Deferred);優先驗「主 worktree 開 Claude → EnterWorktree 進
peer worktree → build/run」這個原 `tnf` plugin 帶來的 pain point 是否在
turbo-plugin 解決。

測試 fixture(SampleGit 含 MinimalWebApp .NET FW 4.8 + port 51999 + SVN
file:// repo)已備好;`.gitignore` union merge / `.pubxml` profile 已 commit
至 fixture repo;測試環境基線狀態見 §0。

**目前 plugin 版本**:v0.2.4(commit `4639b25` on
`worktree-turbo-plugin-brainstorm`)

---

## Problem Frame

- **Script-level autonomous 已驗**:agent 在 SampleGitWithSvn 直接 invoke
  20+ `.ps1` 跑通,**抓出 3 P0(PS 5.1 incompat)+ 2 P2(svn:ignore
  over-sensitive、PostToolUse off-by-N)+ docs**,全部修進 v0.2.1 ~ v0.2.4
- **SKILL agent-flow 未驗**:agent 對 SKILL.md 文字的解讀、SKILL 串多
  script + AskUserQuestion 的 choreography、PostToolUse 與 SessionStart 在
  真實 Claude Code session 觸發行為,**只有真實 session 跑得到**
- **使用者具體痛點**:之前用 `tnf` plugin,主 worktree 開 Claude → 用
  `EnterWorktree` tool 進 peer worktree → 跑 `/tnf:build` 卻 build 主
  worktree 內容。turbo-plugin v0.2.x 用 `(port + project identity)` 複合 key
  + PostToolUse EnterWorktree hook 自動 update apphost physicalPath 解此 bug,
  必須在真實 Claude Code session 驗證已修

---

## Scope Boundaries

### In scope

- 11 個 Implementation Unit 覆蓋:
  - tp-setup 三 case(主 worktree 補設定 / peer worktree / 全新環境)
  - 跨 worktree EnterWorktree 核心驗證(build / run / stop)
  - SessionStart hook 三分支
  - SVN bridge 完整 lifecycle(pull / push / create-remote-test /
    reset-remote-test / svn-ignore)
  - cleanup-orphan-iis 流程
- 各 Unit 含 precondition / action / expected / pass-fail / 觀察欄
- 失敗 fallback(SVN cleanup / git reset / iisexpress kill)
- 收尾 cleanup checklist

### Deferred to Follow-Up Work

- **CI 自動化**:`tools/lint-ps-compat.ps1` 已建,進 GitHub Actions
  workflow 留 cutover 後
- **5 工作日 dogfood 觀察**:cutover criteria 一部分,acceptance 通過後再算
- **tp-csharp-comment / tp-js-comment 真實 dev flow trigger 驗證**:屬
  dev flow 整合測試,留待跟 tdp 替代品(別的 dev workflow plugin)整合
  測試一起跑
- **tp-svn-log SKILL agent-flow 驗證**:script-level 已由 sibling plan
  `2026-05-25-002-...` U20 覆蓋(svn log render + 中文 commit + header strip 等)。SKILL agent-flow(invoke `/turbo-plugin:tp-svn-log` 走 SKILL.md Procedure)未直驗,但 SKILL body 本身只是 thin wrapper 呼叫 script,風險低,留 follow-up

### Outside this product's identity(carried verbatim from origin)

- 既有 4 plugin(tdp/tnf/tgs/tpi)acceptance:cutover 計畫 disable + 移除
  之,不需 acceptance test
- 生產 SVN repo 測試:本 plan 只用 fixture SampleSvnServer
- 自動化 GUI 互動(browser / IIS Express crash report)— 留 manual 觀察

---

## Key Technical Decisions

1. **fixture-based 測試,不動生產**:`C:\Turbo\SampleGitWithSvn` 是專屬
   測試環境,內容隨意改。SampleGit 已 commit MinimalWebApp(.NET FW 4.8
   minimal Web App)+ `.turbo-plugin/` config + `.pubxml` profile
2. **`.NET FW Web` skill 全 4 個都用 MinimalWebApp fixture**:build / run /
   stop / publish 都針對 `src/MinimalWebApp/MinimalWebApp.csproj`,site name
   `MinimalWebApp-0eb9b6ee`,port 51999
3. **VS 預跑 site bootstrap(必跑 prerequisite,不是 fallback)**:`.turbo-plugin/applicationhost.config`(source-of-truth template) **`<sites>` 內無任何 `<site>` element**(只 comment 跟 defaults),PostToolUse hook 預設 update 0 個 site → 不 emit `systemMessage`、IIS Express 也起不來。**在 U2 完成後、U5 開始前**,必須:
   1. 在 SampleGit/ 用 VS 開過一次 `MinimalWebApp.sln` 讓 VS 在 `.vs/MinimalWebApp/config/applicationhost.config` 寫入完整 `<site>` 條目
   2. 把 VS 生的 site name **手動 rename 成 `MinimalWebApp-0eb9b6ee`**(plan 預期值,對應 compute-project-identity hash)
   3. 把同樣的 `<site>` 條目 **copy 進 `.turbo-plugin/applicationhost.config`** 讓後續 PostToolUse hook 有東西可 update
   
   未做此 prerequisite,U5 B.1.1 + U6 全部 fail。**非 plugin bug,純 fixture 限制**
4. **`tp-setup case (c)` 整合驗證 tp-csharp-comment / tp-js-comment**:
   這兩個 SKILL 的本意是 dev flow 自動 trigger,使用者意圖透過 setup
   階段在 CLAUDE.md 加 reference 讓 agent 後續開發時遵守。**驗 tp-setup
   後 SampleGit CLAUDE.md 含 reference 條目**即視為已驗,不需單獨 invoke
5. **SVN test branch 用 `^/test3`**:`^/test2` 已 cleanup(r21),`^/test`
   保留為原存在 branch,新測 case 用 `test3` 避撞
6. **每 Unit 設明確 precondition + action + expected + 觀察欄**:讓使用者
   可一步一停 pass/fail,失敗時資訊夠 debug

---

## Output Structure

```
C:\Turbo\SampleGitWithSvn\                    # fixture 根目錄
├── SampleGit\                                # main worktree
│   ├── .turbo-plugin\                        # config + apphost source + dbhub.example
│   ├── .vs\MinimalWebApp\config\             # 由 tp-setup 或 VS 生成
│   │   └── applicationhost.config
│   ├── MinimalWebApp.sln
│   ├── src\MinimalWebApp\
│   │   ├── MinimalWebApp.csproj              # .NET FW 4.8 Web App, port 51999
│   │   ├── Default.aspx + .aspx.cs
│   │   ├── Web.config
│   │   └── Properties\
│   │       ├── AssemblyInfo.cs
│   │       └── PublishProfiles\
│   │           └── FileSystem.pubxml         # 測 tp-publish 用
│   ├── .gitignore                            # union of local + SVN
│   └── .claude\settings.json                 # marketplace-dev + plugin enabled
│
├── SampleGit.worktrees\
│   ├── dev-1\                                # peer worktree, feature/B branch
│   ├── remote-main\                          # SVN trunk 同步
│   ├── test-1\                               # 原存在 test/rc1
│   └── remote-test-3\                        # 由 U9 D.3 建立
│
└── SampleSvnServer\                          # 本機 SVN repo (file://)
    ├── main/                                  # rev 21
    ├── test/                                  # 原 test/rc1 對應
    └── test3/                                 # 由 U9 D.3 建立
```

`.turbo-plugin/applicationhost.config` 是 source-of-truth template;PostToolUse
hook 複製到 `.vs/<sln-stem>/config/applicationhost.config` 並 update
physicalPath。tp-setup 也走同邏輯。

---

## Implementation Units

**Note: tp-setup case ordering mapping**:origin 需求 R5 定義 4 個 case 順序為 `(a) 新建 → (b) 現有 git+SVN → (c) 已 setup 主 worktree 補設定 → (d) peer-mode`。本 plan 用 unit 順序 **U2(case c) → U3(case d) → U4(case a)**,**case (b) 屬 init-from-existing 大重組 Deferred**。U-IDs 與 case 字母不對應,跨 reference 時請對照本 mapping。

### U1. Pre-flight:install turbo-plugin v0.2.4 + disable 既有 4 plugin

**Goal**:確認 Claude Code session 看得到 v0.2.4,SKILL trigger 不會誤觸到
舊 plugin。

**⚠️ 重要**:本 plan 期間 `.claude-plugin/marketplace.json` `name` 暫改為 `turbo-plugins-claude-dev`(避免與 user-scope production marketplace 撞名)。**不要 commit 此變更** — 結尾 cleanup checklist「**必跑** 還原 marketplace name」一定要執行;否則 plugin production 安裝路徑會跑掉,既有使用者 update plugin 會壞。

**Dependencies**:無

**Files**:
- `SampleGit/.claude/settings.json`(marketplace `turbo-plugins-claude-dev`
  指 worktree 路徑、舊 4 plugin disable、`turbo-plugin@turbo-plugins-claude-dev`
  enable)

**Approach**:
1. 若先前已裝 v0.2.3 或更早,**reload Claude Code session** 拉到 v0.2.4
2. `/plugins` 確認 turbo-plugin v0.2.4 enabled
3. (選)跑 `tools/lint-ps-compat.ps1` 確認 turbo-plugin 0 違規

**Test scenarios**:
- `/plugins` 列表含 `turbo-plugin@turbo-plugins-claude-dev v0.2.4`
- `enabledPlugins` 4 個舊 plugin = `false`
- `tools/lint-ps-compat.ps1 -Path <turbo-plugin>` exit 0

**Verification**:可在後續 SKILL invocation 使用 `/turbo-plugin:tp-*` 觸發。

---

### U2. tp-setup case (c) — 主 worktree 補設定 ⭐(改動最多必驗)

**Goal**:驗 tp-setup 在 SampleGit/(主 worktree,已有 `.turbo-plugin/`
marker)做完所有 case (c) 該做的 augment:CLAUDE.md 加 SKILL reference、
`.vs/<sln>/config/applicationhost.config` bootstrap、`settings.local.json`
env + permissions allow、dbhub.local.toml 引導。

**Requirements**:U1

**Dependencies**:U1

**Files**:
- `SampleGit/CLAUDE.md`(預期被 augment)
- `SampleGit/.vs/MinimalWebApp/config/applicationhost.config`(預期被建)
- `SampleGit/.claude/settings.local.json`(env + permissions allow)

**Approach**:在 SampleGit/ 開新 Claude session,跑
`/turbo-plugin:tp-setup`。SKILL 應偵測 case (c) 並依序執行 augment 動作。

**Test scenarios**:

- **A.1.1 CLAUDE.md 注入 commit-type-convention 段**:`cat SampleGit/CLAUDE.md` 含
  - turbo-plugin marker 區段(`<!-- turbo-plugin:convention:start -->` … `:end`)
  - commit type 12 類 table(feat / fix / refactor / perf / revert / docs / test / chore / build / ci / style / spec)
  - **註**:目前 tp-setup 注入的 snippet(`assets/claudemd-convention-snippet.md`)只包含 commit-type-convention,**不含** tp-csharp-comment / tp-js-comment / tp-suggest-ignore / tp-build-dotnet-framework-web 等 SKILL reference。若期待後者,屬 SKILL 本體該加 feature,留 v0.3.0 規劃,**本 plan 只驗 commit-type-convention 注入**
- **A.1.2 apphost source-of-truth bootstrap**:
  - `Test-Path SampleGit/.turbo-plugin/applicationhost.config` → True(由 tp-setup 從 plugin default-files 複製)
  - **註**:tp-setup case (c) **不會主動建** `.vs/<sln>/config/applicationhost.config` — 那條路徑由 PostToolUse hook 在 EnterWorktree 觸發時自動建(或 VS 開過 .sln 時 VS 建)。詳見 §K3 第 3 條 VS site bootstrap prerequisite
  - **(已移除)**:本 plan 之前期待 A.1.2 驗 `.vs/MinimalWebApp/config/applicationhost.config` 存在;case (c) 不負責這條,改在 §K3 第 3 條當 prerequisite 處理
- **A.1.3 user-level env**:`cat ~/.claude/settings.json` `env` block 含 `TURBO_PLUGIN_MSBUILD_PATH` + `TURBO_PLUGIN_IIS_EXPRESS_PATH`(若 SKILL 找不到 default path 才 prompt 寫入);**寫 user-level 而非 repo-level** — Decision Rule:不要把這兩個 env 寫到 repo-level `.claude/settings.local.json`,會跨同事覆寫各自本機路徑
- **A.1.4 dbhub.local.toml 引導**:systemMessage 或 prompt 提示「複製
  `dbhub.example.local.toml` 為 `dbhub.local.toml` 並填 credentials」
- **(已刪 permissions allowlist 驗證)**:SKILL 目前不寫 `permissions.allow` 到 settings.local.json。若 user 跑時 sandbox 擋 `-ExecutionPolicy Bypass` 須自己加 allowlist,**屬 SKILL 該補 feature 但本 plan 不驗**(留 finding 記)

**Verification**:後續 SKILL invocation 不再被 sandbox 擋(解 v0.2.1 前
agent 報的 `-ExecutionPolicy Bypass` 被 sandbox 擋下問題);tp-run 可正常
拿到 apphost 跑(U6 前提)。

---

### U3. tp-setup case (d) — peer worktree(dev-1)

**Goal**:驗 tp-setup 在 peer worktree 把主 worktree env 複製過來、處理
dbhub.local.toml 三選一。

**Requirements**:U2(主 worktree 已先 bootstrap)

**Dependencies**:U2

**Files**:
- `SampleGit.worktrees/dev-1/.claude/settings.local.json`(預期跟主 worktree
  env keys 一致)
- `SampleGit.worktrees/dev-1/.turbo-plugin/dbhub.local.toml`(視選項建立)

**Approach**:**另開**新 Claude session 在 `dev-1/` 跑 `/turbo-plugin:tp-setup`。
SKILL 偵測 case (d)(peer + 主 worktree 已 bootstrap)。

**Test scenarios**:

- **A.2.1 env 複製**:`dev-1/.claude/settings.local.json` 的
  `TURBO_PLUGIN_*` env keys 跟 SampleGit/ 一致
- **A.2.2 dbhub 三選一 prompt**:SKILL `AskUserQuestion`:複製主的 / 互動
  填新 / 跳過
- **A.2.3 複製 path**:選複製 → `dev-1/.turbo-plugin/dbhub.local.toml` 出現,
  內容與 `SampleGit/.turbo-plugin/dbhub.local.toml` 一致

**Verification**:dev-1 取得跟主 worktree 對等的設定,可直接跑後續 SKILL
不再被 prompt。

---

### U4. tp-setup case (a) — 全新環境(throwaway,可選)

**Goal**:驗 tp-setup 在 brand-new git repo 引導 init + 建 marker + 複製
default-files。

**Requirements**:U2 已驗 case (c)

**Dependencies**:無

**Files**:`C:/tmp/throwaway-test/`(throwaway dir)

**Approach**:`mkdir C:/tmp/throwaway-test && cd && git init`,開新 Claude
session 跑 `/turbo-plugin:tp-setup`。

**Test scenarios**:

- **A.3.1 case (a) 偵測**:SKILL 認出 brand-new(無 marker、無 csproj)
- **A.3.2 marker + template copy**:throwaway dir 含 `.turbo-plugin/config.toml`
  + `applicationhost.config`(source-of-truth)+ `dbhub.example.local.toml`
- **A.3.3 引導 user 加 csproj 或選 init-from-existing**

**Verification**:throwaway 可成為一個 valid turbo-plugin project 雛形。

**Execution note**:可選,若時間緊跳。Case (a) 是首次使用者體感的關鍵,
建議仍跑一次。

---

### U5. 跨 worktree EnterWorktree build 驗證 ⭐⭐⭐(核心 pain point)

**Goal**:驗使用者描述的「主 worktree 開 Claude → EnterWorktree 進 peer
→ build/run 跑到 main worktree 內容」**在 turbo-plugin 不重現**。
script-level autonomous 已驗(build artifact 落 dev-1 bin/、main bin/
mtime 不變),此 Unit 補 SKILL agent-flow 完整鏈路。

**Requirements**:U2

**Dependencies**:U1, U2

**Files**:
- `SampleGit.worktrees/dev-1/.vs/MinimalWebApp/config/applicationhost.config`
  (PostToolUse hook fire 後被自動 update physicalPath)
- `SampleGit.worktrees/dev-1/src/MinimalWebApp/bin/MinimalWebApp.dll`(build
  artifact)
- `SampleGit/src/MinimalWebApp/bin/MinimalWebApp.dll`(預期 mtime **不變**)

**Approach**:
1. **Pre-step**(baseline):在 SampleGit/ session(U2 那個)先跑一次 `/turbo-plugin:tp-build-dotnet-framework-web` 生 main bin/dll;`(Get-Item SampleGit/src/MinimalWebApp/bin/MinimalWebApp.dll).LastWriteTime` 記為 `$mainBaselineMtime`(寫 `$env:TEMP/u5-main-mtime.txt`)。否則 B.1.4「mtime 不變」trivially true(檔不存在)
2. 用 `EnterWorktree` 工具切到 dev-1,跑 `/turbo-plugin:tp-build-dotnet-framework-web`
3. 比對:dev-1 bin/dll mtime 在 build 後更新(B.1.3)+ main bin/dll mtime == `$mainBaselineMtime`(B.1.4)

**Test scenarios**:

- **B.1.1 PostToolUse hook fire**:EnterWorktree 後 systemMessage 出現
  `turbo-plugin: refreshed applicationhost.config for 1 site(s) in c:\Turbo\SampleGitWithSvn\SampleGit.worktrees\dev-1`
  (**「1 site(s)」不是「4」— v0.2.3 P3 fix 驗證**)
  - **前提**:已依 §K3 第 3 條跑完 VS site bootstrap;否則 `.turbo-plugin/applicationhost.config` 無 site,hook update 0 個,**不會** emit systemMessage,B.1.1 必 fail
- **B.1.2 apphost physicalPath update**:
  ```powershell
  Select-Xml -Path 'C:/.../dev-1/.vs/MinimalWebApp/config/applicationhost.config' `
             -XPath "//virtualDirectory/@physicalPath"
  ```
  → 顯示 dev-1 path,**非 main path**
- **B.1.3 build 落 dev-1 bin/**:`(Get-Item dev-1/src/MinimalWebApp/bin/MinimalWebApp.dll).LastWriteTime`
  在 build 之後更新
- **B.1.4 main bin/ mtime 不變**:`(Get-Item SampleGit/src/MinimalWebApp/bin/MinimalWebApp.dll).LastWriteTime`
  在 build **前後相同**

**Verification**:✅ B.1.3 + B.1.4 兩條同時成立 = pain point 已解。

---

### U6. 跨 worktree run + stop

**Goal**:驗 tp-run 啟 dev-1 IIS、瀏覽器頁面顯示 dev-1 path、跨 session
tp-stop 仍能殺到。

**Requirements**:U5

**Dependencies**:U5(dev-1 apphost 已 ready)

**Files**:
- `SampleGit.worktrees/dev-1/src/MinimalWebApp/Default.aspx`(瀏覽器訪問)
- iisexpress 處理程序(transient)

**Approach**:U5 同 session,跑 `/turbo-plugin:tp-run-dotnet-framework-web`。
另開**新 session** 在 SampleGit/ 跑 `/turbo-plugin:tp-stop-dotnet-framework-web`。

**Test scenarios**:

- **B.2.1 IIS Express 啟動**:`Started IIS Express (site: MinimalWebApp-0eb9b6ee,
  PID: <n>)` + `Listening on http://localhost:51999/`
- **B.2.2 瀏覽器 MapPath**:`http://localhost:51999/` 頁面顯示 MapPath ==
  `C:\Turbo\SampleGitWithSvn\SampleGit.worktrees\dev-1\src\MinimalWebApp\`
  (**dev-1 path,非 main**)
- **B.2.3 跨 session stop**:從 SampleGit/ 主 session 跑 tp-stop →
  `Stopped IIS Express PID <n>`(殺到了 dev-1 啟的 — 因 site name 跨 worktree
  identical)
- **B.2.4 無 instance stop**:再跑 tp-stop → `No IIS Express process found
  for site 'MinimalWebApp-0eb9b6ee'.` exit 0(不是 error)

**Verification**:✅ B.2.3 = 兩個 design 同時成立:
  - (a) **site name 跨 worktree identical**:`/turbo-plugin:tp-compute-project-identity`(或讀 apphost site name)從 main 跟 dev-1 跑都得 `MinimalWebApp-0eb9b6ee`
  - (b) **Get-CimInstance Win32_Process 全機掃**:`stop-iis.ps1` 用 CommandLine match 不限 worktree path
  - 缺一不可(原 tnf 用 worktree path 為 key 跨 session 找不到 dev-1 啟的 iisexpress)。

**Execution note**:若 IIS Express 啟動失敗看
`~/AppData/Local/IISExpress/TraceLogFiles/`。我寫的 minimal apphost 可能
不夠 — 若 U2 tp-setup bootstrap 完整版仍失敗,**用 VS 開過一次
MinimalWebApp.sln 讓 VS 生成完整 apphost**,再回跑 U6。

---

### U7. SessionStart hook 三分支

**Goal**:驗 SessionStart hook 三個分支(主 worktree 無 marker / peer 無
marker / marker 在但 dbhub.local.toml 缺)在真實 session 啟動時觸發正確
prompt。

**Requirements**:U2(需 `SampleGit/.turbo-plugin/` marker 已建,C.1/C.2 才有東西可 Copy 備份);U3(需 `dev-1/.turbo-plugin/` marker 已建,C.1/C.3 才有東西可動)

**Dependencies**:U2、U3(雖然 sessionstart hook 本身不依賴它們,但 C.x test scenarios 用 backup-and-restore 模式,必須有 marker 才能 backup)

**Files**:`.turbo-plugin/` 暫時 Copy 為 `.turbo-plugin-original`(modeling 缺 marker 情況;Group 1 F7 修)

**Approach**:每分支關掉舊 session、暫時調整 fixture state、開新 session
觀察 systemMessage。

**Test scenarios**:

- **C.1 Branch (ii) peer 無 marker**:
  1. 關 dev-1 所有 session
  2. `Copy-Item -Recurse dev-1/.turbo-plugin dev-1/.turbo-plugin-original`(**備份不 rename**)
  3. `Remove-Item -Recurse dev-1/.turbo-plugin`(移走原)
  4. 開新 session 在 dev-1/
  5. **Expected**:systemMessage:「turbo-plugin: 偵測到本 worktree 尚未
     bootstrap,且這裡是 peer worktree。請到主 worktree
     (`C:\Turbo\SampleGitWithSvn\SampleGit`) 啟動 Claude 並執行 `/tp-setup`,
     完成 bootstrap 後再回此 worktree 工作。」
  6. **重點**:main path 是真實絕對路徑,**非字面 `$mainPath`**(v0.2.1 fix)
  7. Cleanup:`Move-Item dev-1/.turbo-plugin-original dev-1/.turbo-plugin`
  8. **Cleanup verification**(mandatory):`Test-Path dev-1/.turbo-plugin/config.toml` = True;否則 mark 整 C.1 FAIL,並手動還原 `.turbo-plugin-original` → `.turbo-plugin` 後重跑
- **C.2 Branch (i) main 無 marker**:
  1. 關 SampleGit 所有 session
  2. `Copy-Item -Recurse SampleGit/.turbo-plugin SampleGit/.turbo-plugin-original`
  3. `Remove-Item -Recurse SampleGit/.turbo-plugin`
  4. 開新 session 在 SampleGit/
  5. **Expected**:systemMessage 提示「主 worktree 尚未 bootstrap,請執行
     `/tp-setup`」
  6. Cleanup:`Move-Item SampleGit/.turbo-plugin-original SampleGit/.turbo-plugin`
  7. **Cleanup verification**(mandatory):`Test-Path SampleGit/.turbo-plugin/config.toml` = True 才算 PASS
- **C.3 Branch (iii) marker 在但 dbhub.local.toml 缺(只在 peer 觸發)**:
  1. **Pre-step**:確認 `dev-1/.turbo-plugin/dbhub.local.toml` 不存在(若 U3 已建過,先 `Move-Item dev-1/.turbo-plugin/dbhub.local.toml $env:TEMP/d-c3-dbhub.bak`)
  2. 開新 session 在 **dev-1/**(**不是 SampleGit/** — sessionstart.ps1 Pattern B 只在 peer worktree 且 dbhub.local 缺時 prompt;主 worktree 不發此訊息)
  3. **Expected**:systemMessage 提示「請複製 `dbhub.example.local.toml`
     為 `dbhub.local.toml` 並填 credentials」
  4. Cleanup:若 pre-step backup 了 → `Move-Item $env:TEMP/d-c3-dbhub.bak dev-1/.turbo-plugin/dbhub.local.toml`

**Verification**:三分支各自輸出對應 prompt,**Branch (ii) main path 是
實值非字面 `$mainPath`** = v0.2.1 fix 確認 land。

---

### U8. tp-pull-from-svn happy + conflict-rollback

**Goal**:驗 pull-from-svn 在 SVN already up-to-date / SVN 領先 / 衝突自動
rollback 三條 path 行為符合 SKILL spec。

**Requirements**:U2(SampleGit clean)

**Dependencies**:U2

**Files**:
- `SampleGit/`(主 worktree git state)
- `SampleGit.worktrees/remote-main/`(SVN sync bridge)
- `SampleSvnServer/main/`(SVN trunk)

**Approach**:在 main + remote-main 各做衝突 commit,跑 pull → 觀察 auto-rollback。

**Pre-condition**:`git log remote/main` HEAD = SVN r21(即 D.2 setup 前已 sync;script-level happy「Already up to date」已由 sibling plan 002 U14.1 涵蓋,本 unit 不重驗)。

**Test scenarios**:

- **D.2 conflict + rollback**:
  1. **Pre-step**:`git -C SampleGit rev-parse HEAD > $env:TEMP/d2-baseline-sha.txt`(記下 cleanup target SHA)
  2. Setup(main):`echo conflict-A > new-conflict.txt && git add . && git commit -m "feat: ..."`
  3. Setup(remote-main):`cd remote-main; echo conflict-B > new-conflict.txt;
     svn add new-conflict.txt; svn commit -m "test: conflict"`
  4. Action:在 main session 跑 `/turbo-plugin:tp-pull-from-svn --branch main`
  5. **Expected**:
     - 偵測衝突
     - 自動 `git merge --abort` + `git checkout main`
     - emit `Merge conflict detected. ... Conflicting files: new-conflict.txt`
     - 中文訊息**不亂碼**(v0.2.4 UTF-8 fix)
     - 主 worktree HEAD 回到 conflict-A commit、working tree clean
  6. Cleanup:`git reset --hard (Get-Content $env:TEMP/d2-baseline-sha.txt)`(**用絕對 SHA,不用 HEAD~1**;避免被中間其他 plan commit 干擾誤丟)
  7. **⚠️ SVN side-effect 警告**:remote-main 上 conflict-B 那次 `svn commit` 是**永久 SVN history**(不可逆)。D.2 跑完後,**main pull 永遠 fail** 直到:
     - 選項 a:D.6 push 把 conflict-A 推上 SVN(覆掉 conflict-B 的 file 但保留 history),或
     - 選項 b:手動 `cd remote-main; svn revert new-conflict.txt; svn delete new-conflict.txt; svn commit -m "revert D.2 fixture"`
     - 不處理 → 影響 §結尾 cleanup 後 next test cycle

**Verification**:D.2 完成 = Pass 4 B6 rollback + v0.2.4 UTF-8 console
output 同時驗證。

---

### U9. tp-create-remote-test happy / cancel / fail-rollback

**Goal**:驗 create-remote-test 三 path:happy(SVN copy + checkout + svn:ignore
propset)、cancel(AskUserQuestion 選 Cancel 不執行)、fail-rollback(無效
SVN URL → ERR-trap rollback git branches/worktree)。

**Requirements**:U2

**Dependencies**:U2(需 SVN setup 已 ready)

**Files**:
- `SampleGit/`(git branches)
- `SampleGit.worktrees/remote-test-3/`(新 worktree,由 happy path 建)
- `SampleSvnServer/test3/`(新 SVN branch)

**Approach**:
1. happy path:`/turbo-plugin:tp-create-remote-test --n 3 --svn-url
   file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/test3`,SKILL 走
   Step 2.5 AskUserQuestion → 選 Confirm
2. cancel path:同 happy 但 confirm 選 Cancel
3. fail path:`--svn-url file:///nonexistent/path` 觸發 ERR-trap rollback

**Test scenarios**:

- **D.3 happy path**:
  - SKILL Step 2.5 AskUserQuestion 出現(顯示 N=3 / branch / path / URL)
  - 選 Confirm → script 跑 svn copy + checkout + svn:ignore propset
  - **不再 throw `svn:ignore not found`**(v0.2.2 fix)
  - `git branch -a` 含 `test-3` + `remote/test-3`
  - `git worktree list` 含 `remote-test-3`
  - `svn ls file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/` 含 `test3/`
- **D.4 cancel path**(N=4):confirm 選 Cancel → branches/worktree/SVN
  都沒新東西
- **D.5 fail-rollback path**(N=5,無效 SVN URL):
  - SVN setup 失敗 → ERR trap fire
  - 訊息 `SVN setup failed; rolling back git state...`
  - `git branch -a` 不含 `test-5` 或 `remote/test-5`
  - `git worktree list` 不含 `remote-test-5`
  - (機率低)若 partial cleanup 失敗 emit `PARTIAL_ROLLBACK: ...` 訊息

**Verification**:D.3 PASS = v0.2.2 P0 fix 驗證(svn:ignore not found
不再 throw);D.5 PASS = Pass 3 WF1 + Pass 4 B5 ERR-trap 驗證。

---

### U10a. tp-push-to-svn happy lifecycle(commit type filtering + unknown prompt + UTF-8 中文)

**Goal**:驗 push-to-svn happy path:SKILL 走 prepare → 列 COMMITS/FILES → 篩選(kept-subset vs filtered)→ unknown type AskUserQuestion 三選一 → Step 5 confirm → commit + UTF-8 中文 commit subject 不亂碼 + SHA pin cleanup on success。

**Note**:SHA pin mismatch throw 行為(D.7)+ failure-retain pin(D.8)已由 sibling plan 002 U16.3/U16.5/U16.6 script-level 完整驗,本 unit 不重驗 script-level 邏輯,只收尾驗 pin file 在 happy path 結束被清(D.6 post-condition)。

**Requirements**:U9(D.3 已 land,有 `test-3` + `remote-test-3`)

**Dependencies**:U9

**Files**:
- `SampleGit/`(test-3 branch + commits)
- `SampleGit/.git/worktrees/remote-test-3/MERGE_HEAD.tp_branch_sha`(SHA pin file;**linked worktree 的 `.git` 是 pointer file 不是 dir**,真正的 gitdir 在 main 的 `.git/worktrees/<name>/`)
- `SampleSvnServer/test3/`(SVN history)

**Approach**:在 test-3 做 4 個 commit(feat/docs/fix/chore 各 1),跑
push-to-svn 觀察篩選 + lifecycle 各 step。

**Test scenarios**:

- **D.6 happy lifecycle**(含 unknown type prompt):
  - Setup:`git checkout test-3` + **5 個 commit**(feat / docs / fix / chore / **`update something`** ← unknown,無 conventional prefix)
  - Action:`/turbo-plugin:tp-push-to-svn --branch test-3`
  - SKILL prepare → 列 COMMITS/FILES → 篩選(feat/fix kept、docs/chore silent filtered)→ **unknown prompt fire**:`update something` 觸發 AskUserQuestion 三選一(`Keep / Filter / Abort`)
  - 三 path 各跑一次驗:
    - Keep → `update something` 進 SVN body
    - Filter → 不進 SVN body
    - Abort → push 中斷,branch 狀態不變
  - Final pass:選 Keep 走完 → Step 5 confirm → commit
  - **Expected**:
    - SVN body 只含 `feat: ...` + `fix: ...`(+ unknown 視 user 選 Keep / Filter)
    - **`<main>/.git/worktrees/remote-test-3/MERGE_HEAD.tp_branch_sha` push 過程中
      存在**(可在 prepare 完 commit 前查;**不是** `<remote-test-3>/.git/...`,因 linked worktree `.git` 是 pointer file)
    - **post-condition pin cleanup**:成功 push 後 `Test-Path <main>/.git/worktrees/remote-test-3/MERGE_HEAD.tp_branch_sha` = False(v0.2.1+v0.2.2 fix);若 happy 結束 pin 仍在 = FAIL
    - 中文 commit subject 在 SVN 顯示**不亂碼**(`svn log SampleGit.worktrees/remote-test-3 --limit 1`)
- **(已併入 D.6)D.7 SHA pin mismatch throw** — script-level deterministic 邏輯,由 sibling plan 002 U16.3 直驗,本 unit 不重跑「另開 terminal 加 commit」race-condition setup
- **(已砍)D.8 failure-retain pin** — 本來要 rename `SampleSvnServer/db` 模擬 SVN 失敗,但該目錄是 FSFS SVN repo 的 revision data 核心,rename 後 cleanup 漏跑會 corrupt 整 SVN repo。failure-retain pin 行為已由 sibling plan 002 U16.6 script-level 完整驗證

**Verification**:D.6 中文無亂碼 = v0.2.4 fix 驗證;pin file cleanup post-condition = v0.2.1+v0.2.2 fix。

---

### U10b. tp-push-to-svn PENDING_MERGE_DETECTED 三選一(SKILL choreography only)

**Goal**:驗 push-to-svn 唯一無法 script-level 涵蓋的 SKILL 行為 — PENDING_MERGE_DETECTED 三選一 AskUserQuestion(Abort+re-prepare / Continue / Cancel)。

**Requirements**:U10a 已 land(test-3 branch + remote-test-3 worktree 在,SVN history 有 D.6 push 後狀態)。

**Dependencies**:U10a。

**Files**:`SampleGit.worktrees/remote-test-3/`(staged merge state 暫時)。

**Approach**:中斷 prepare 留 staged merge → 重跑 push → SKILL 出現 3 選一,三 path 各跑一次。

**Test scenarios**:

- **D.9 PENDING_MERGE_DETECTED 三選一**:
  - Setup:在 test-3 加 1 個 commit → 跑 push-to-svn-prepare → **prepare 走到 svn rev check / merge staged 後中斷 SKILL**(Ctrl-C),留 `remote-test-3/` staged merge state(`git -C remote-test-3 status` 含 `Unmerged paths` 或 merge in progress)
  - Action:重跑 `/turbo-plugin:tp-push-to-svn --branch test-3`
  - **Expected**:script emit `PENDING_MERGE_DETECTED <path>` token + exit 0;SKILL parse token 後跳 AskUserQuestion 三選一
  - 三 path 各跑一次(每跑前重做 setup):
    - **Abort+re-prepare** → `git merge --abort` + 重跑 prepare → 正常 flow → commit 成功
    - **Continue** → 略過 prepare,直接 commit current staged merge → 成功
    - **Cancel** → 不動,branch 留 staged 狀態,使用者後續手動處理(`git -C remote-test-3 merge --abort`)

**Verification**:D.9 = Pass 2 F15 token-based 三選一 land。

---

### U11. tp-reset-remote-test 三步 + suggest-ignore + cleanup-orphan-iis

**Goal**:把剩 3 個 SKILL 一起驗 — 都是相對獨立的 SKILL,可順手跑完。

**Requirements**:U9(reset-remote-test 需 `test-3` 存在);U2(其他)

**Dependencies**:U9

**Files**:
- `SampleGit/` git state(reset)
- `SampleGit/.gitignore`(suggest-ignore)
- iisexpress 處理程序 + applicationhost.config(cleanup-orphan-iis)

**Approach**:三個獨立 sub-test。

**Test scenarios**:

- **D.10 tp-reset-remote-test 三步**(v0.2.3 B1 fix):
  - Action:`/turbo-plugin:tp-reset-remote-test --n 3`(reset-remote-test 只認 `-N <number>`,不認 `--branch`)
  - SKILL 應走:
    1. **Step 1** 跑 script 帶 `--diff-only` → 印 `LOSE: <N> commits` +
       `GAIN: <M> commits`
    2. **Step 2** AskUserQuestion confirm(顯示 LOSE/GAIN 數字)
    3. **Step 3** 跑 script(無 flag)→ `Reset test-3 to main`
  - Apply case:選 Apply → `test-3` SHA == `main` SHA
  - Cancel case:選 Cancel → `test-3` SHA 不動
- **D.11 tp-suggest-ignore analysis mode**:
  - Setup:`echo x > junk.tmp; echo x > debug.log`
  - Action:`/turbo-plugin:tp-suggest-ignore`
  - SKILL 走 Step 1-4,對 untracked candidates 各分類 AskUserQuestion
  - 選 add → `.gitignore` 更新 + git commit
  - Cleanup:`rm junk.tmp debug.log` + `git revert HEAD`(若 commit 了)
- **E cleanup-orphan-iis**(v0.2.0 WF4 + v0.2.3 P3F1 驗證):
  - Setup:製造兩個 orphan(可手動 hack apphost 加 site
    `MinimalWebApp-cafe1234` 跑 iisexpress)
  - Action:`/turbo-plugin:tp-cleanup-orphan-iis`
  - SKILL enumerate(列 `ORPHAN: <site> <kind> pid=<n>` 行)→ AskUserQuestion
    多選 → script 殺 process + remove site
  - 若任 step 失敗:`PARTIAL_FAILURE: failed=<n> sites=<list>` token + exit 2
- **E2 tp-csharp-comment / tp-js-comment throwaway invoke**(原 Deferred 提升為 sanity-check):
  - 對 `SampleGit/src/MinimalWebApp/Default.aspx.cs` 隨便加一行需要註解的 code(如 `var x = 1; // TODO`)
  - Action:`/turbo-plugin:tp-csharp-comment`
  - **Expected**:SKILL 真執行(改寫該行 comment 風格 / emit revised diff / 至少不 throw),確認 SKILL body 不只是 stub
  - 同樣對 `Default.aspx` `<script>` 區塊加一行 JS,跑 `/turbo-plugin:tp-js-comment` 驗
  - Cleanup:`git checkout Default.aspx Default.aspx.cs` 還原

**Verification**:D.10 三步流程 = v0.2.3 B1 Procedure rewrite 驗證;D.11
analysis 完整跑通;E PARTIAL_FAILURE token + exit 2 = v0.2.0 WF4 設計驗證。

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Minimal apphost.config 不足以讓 IIS Express 真實啟動 | U6 fallback:VS 開過 .sln 一次 |
| SVN file:// repo cleanup 不便(SVN history 永久) | 留 SVN 殘留(本 plan §結尾 cleanup)、新測 case 用未撞名 N |
| dev-1 worktree state 因前測殘留(`.turbo-plugin/applicationhost.config` 等 untracked) | 新 merge fail 時手動 rm seeded files |
| Claude Code session 多開 → resource 占用、log 雜訊 | 每 phase 後關掉不必要 session |
| 真實 IIS Express 啟動 port 51999 占用 | 跑 U6 前 `Get-NetTCPConnection -LocalPort 51999` 確認無人占 |

**Dependencies(unit 順序)**:U1 → U2 → U3 → {U4, U5, U7, U8, U9} → U6(依 U5)
→ U10a(依 U9)→ U10b(依 U10a)→ U11(依 U9)。U7 依 U2+U3(Copy backup 需要 marker)。

---

## System-Wide Impact

- **12/13 個 turbo-plugin SKILL** 被觸到(直接 invoke:tp-setup 在 U2/U3/U4、tp-build/tp-run/tp-stop 在 U5/U6、tp-pull-from-svn 在 U8、tp-create-remote-test 在 U9、tp-push-to-svn 在 U10、tp-reset-remote-test + tp-suggest-ignore 在 U11 = **9 個直驗**;+ tp-csharp-comment / tp-js-comment 透過 CLAUDE.md commit-type-convention 注入間驗(本 plan A.1.1 只驗 commit-type-convention 注入,不驗 SKILL 本體真執行)+ tp-publish-dotnet-framework-web 透過 fixture `.pubxml` 在 §Output Structure 預備但**本 plan 不直驗** = **3 個間驗** → 12 SKILL 共)
- **tp-svn-log Deferred**:本 plan 不覆蓋(留 follow-up,見 §Deferred to Follow-Up Work)
- **兩個 hook** 都跑:`PostToolUse EnterWorktree`(U5)+ `SessionStart`(U7)
- **fixture mutation**:SampleGit `main` 多 1-2 個 commit(D.2 conflict + D.11
  suggest-ignore);SampleSvnServer 多 `^/test3` SVN branch(D.3 land)+ test3
  上的 SVN commit(D.6 push)
- **SVN side-effect 不可逆**:任何 SVN commit、`svn copy ^/test3` 都是 server-side
  永久 history。`^/test2` 已 clean,`^/test3` cleanup 由本 plan 結尾處理

---

## 結尾 cleanup checklist

| 項目 | 動作 |
|---|---|
| SVN test3 殘留 | `svn delete file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/test3 -m "cleanup"` |
| git remote-test-3 worktree | `git -C SampleGit worktree remove --force SampleGit.worktrees/remote-test-3` |
| git branches `test-3` `remote/test-3` | `git -C SampleGit branch -D test-3 remote/test-3` |
| iisexpress 殘留 | `Get-Process iisexpress -ErrorAction SilentlyContinue \| Stop-Process -Force` |
| **必跑** 還原 marketplace name | `cd <worktree> && git checkout .claude-plugin/marketplace.json`;Pass criteria:`git diff --name-only .claude-plugin/marketplace.json` 空 |
| (可選)squash v0.2.x fix commits 為 1 個 | `git rebase -i` |

---

## 已知 issue(別當 bug)

- **D.1 svn-log r17 mojibake**:r17 是 pre-existing SVN data 用非 UTF-8
  codepage 推上去,turbo-plugin 救不了歷史資料。v0.2.4 fix 救未來新 commit
- **真實 IIS Express 啟動**:需 VS 開過 .sln 一次生成完整 applicationhost.config

---

## 進度追蹤(checkbox 給使用者自填)

- [ ] U1 Pre-flight
- [ ] **U2 tp-setup case (c) main worktree** ⭐(最該驗)
- [ ] U3 tp-setup case (d) dev-1
- [ ] U4 tp-setup case (a) throwaway(可選)
- [ ] **U5 跨 worktree EnterWorktree build** ⭐⭐⭐(pain point 核心)
- [ ] U6 跨 worktree run + stop
- [ ] U7 SessionStart hook 三分支
- [ ] U8 tp-pull-from-svn happy + conflict
- [ ] U9 tp-create-remote-test happy / cancel / fail
- [ ] U10a tp-push-to-svn happy lifecycle + commit type filter + unknown prompt + UTF-8 + pin cleanup
- [ ] U10b tp-push-to-svn PENDING_MERGE_DETECTED 三選一
- [ ] U11 tp-reset-remote-test + suggest-ignore + cleanup-orphan-iis + tp-csharp/js-comment throwaway

⭐ 標的是核心優先;其他若忙可省。發現問題隨時回報。
