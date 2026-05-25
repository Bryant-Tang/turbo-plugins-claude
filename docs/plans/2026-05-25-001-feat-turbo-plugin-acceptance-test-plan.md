---
date: 2026-05-25
type: feat
origin: docs/brainstorms/turbo-plugin-requirements.md
status: active
---

# feat: turbo-plugin v0.2.4 acceptance test plan

## Summary

turbo-plugin v0.2.0 → v0.2.4 經 4 輪 ce-code-review + 1 輪實機 script-level
acceptance(在 `C:\Turbo\SampleGitWithSvn`)後,**SKILL agent-flow 部分**
仍須在真實 Claude Code session 由使用者驗。本 plan 列 11 個 Implementation
Unit 覆蓋 14 個 SKILL,優先驗「主 worktree 開 Claude → EnterWorktree 進
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
3. **真實 IIS Express 啟動 fall-back**:若 minimal `applicationhost.config`
   不足以讓 IIS Express 真實啟動,先用 VS 開過一次 `.sln` 讓 VS 生成完整
   apphost,再回來跑 tp-run。**非 plugin bug,純 fixture 限制**
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

### U1. Pre-flight:install turbo-plugin v0.2.4 + disable 既有 4 plugin

**Goal**:確認 Claude Code session 看得到 v0.2.4,SKILL trigger 不會誤觸到
舊 plugin。

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

- **A.1.1 CLAUDE.md 加 SKILL reference**:`cat SampleGit/CLAUDE.md` 含
  - 「修 `.cs` 前 invoke `/turbo-plugin:tp-csharp-comment`」
  - 「修 `.js`/`.ts`/`.vue`/`.cshtml` `<script>` 前 invoke `/turbo-plugin:tp-js-comment`」
  - 「新 untracked 檔出現可建議 `/turbo-plugin:tp-suggest-ignore`」
  - 「Web 專案 build/run/publish 用 `/turbo-plugin:tp-build-dotnet-framework-web` 等」
- **A.1.2 apphost bootstrap**:
  - `Test-Path SampleGit/.vs/MinimalWebApp/config/applicationhost.config` → True
  - 該檔內 `<site name="MinimalWebApp-0eb9b6ee">`,physicalPath ==
    `C:\Turbo\SampleGitWithSvn\SampleGit\src\MinimalWebApp\`
- **A.1.3 settings.local.json env**:含 `TURBO_PLUGIN_MSBUILD_PATH` +
  `TURBO_PLUGIN_IIS_EXPRESS_PATH`(若 user-level 沒設)
- **A.1.4 permissions allowlist**(解 sandbox 擋 SKILL invocation):
  ```json
  "permissions": { "allow": [
    "Bash(powershell -NoProfile -ExecutionPolicy Bypass -File:*)",
    "Bash(powershell -ExecutionPolicy Bypass -File:*)"
  ] }
  ```
- **A.1.5 dbhub.local.toml 引導**:systemMessage 或 prompt 提示「複製
  `dbhub.example.local.toml` 為 `dbhub.local.toml` 並填 credentials」

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

**Approach**:在 SampleGit/ 已有的 Claude session(U2 那個,別關),用
`EnterWorktree` 工具切到 dev-1,跑 `/turbo-plugin:tp-build-dotnet-framework-web`。

**Test scenarios**:

- **B.1.1 PostToolUse hook fire**:EnterWorktree 後 systemMessage 出現
  `turbo-plugin: refreshed applicationhost.config for 1 site(s) in c:\Turbo\SampleGitWithSvn\SampleGit.worktrees\dev-1`
  (**「1 site(s)」不是「4」— v0.2.3 P3 fix 驗證**)
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

**Verification**:✅ B.2.3 = stop-iis 跨 worktree key 設計 work(原 tnf
用 worktree path 為 key 跨 session 找不到)。

**Execution note**:若 IIS Express 啟動失敗看
`~/AppData/Local/IISExpress/TraceLogFiles/`。我寫的 minimal apphost 可能
不夠 — 若 U2 tp-setup bootstrap 完整版仍失敗,**用 VS 開過一次
MinimalWebApp.sln 讓 VS 生成完整 apphost**,再回跑 U6。

---

### U7. SessionStart hook 三分支

**Goal**:驗 SessionStart hook 三個分支(主 worktree 無 marker / peer 無
marker / marker 在但 dbhub.local.toml 缺)在真實 session 啟動時觸發正確
prompt。

**Requirements**:無

**Dependencies**:無(獨立)

**Files**:`.turbo-plugin/` 暫時 rename(modeling 缺 marker 情況)

**Approach**:每分支關掉舊 session、暫時調整 fixture state、開新 session
觀察 systemMessage。

**Test scenarios**:

- **C.1 Branch (ii) peer 無 marker**:
  1. 關 dev-1 所有 session
  2. `mv dev-1/.turbo-plugin dev-1/.turbo-plugin.bak`
  3. 開新 session 在 dev-1/
  4. **Expected**:systemMessage:「turbo-plugin: 偵測到本 worktree 尚未
     bootstrap,且這裡是 peer worktree。請到主 worktree
     (`C:\Turbo\SampleGitWithSvn\SampleGit`) 啟動 Claude 並執行 `/tp-setup`,
     完成 bootstrap 後再回此 worktree 工作。」
  5. **重點**:main path 是真實絕對路徑,**非字面 `$mainPath`**(v0.2.1 fix)
  6. Cleanup:`mv dev-1/.turbo-plugin.bak dev-1/.turbo-plugin`
- **C.2 Branch (i) main 無 marker**:
  1. 關 SampleGit 所有 session
  2. `mv SampleGit/.turbo-plugin SampleGit/.turbo-plugin.bak`
  3. 開新 session 在 SampleGit/
  4. **Expected**:systemMessage 提示「主 worktree 尚未 bootstrap,請執行
     `/tp-setup`」
  5. Cleanup:`mv SampleGit/.turbo-plugin.bak SampleGit/.turbo-plugin`
- **C.3 Branch (iii) marker 在但 dbhub.local.toml 缺**(預設狀態):
  1. 開新 session 在 SampleGit/
  2. **Expected**:systemMessage 提示「請複製 `dbhub.example.local.toml`
     為 `dbhub.local.toml` 並填 credentials」

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

**Approach**:
1. happy path:當前狀態 `git log remote/main` HEAD = SVN r21,跑 pull →
   `Already up to date`
2. conflict path:在 main + remote-main 各做衝突 commit,跑 pull → 觀察
   auto-rollback

**Test scenarios**:

- **D.1 happy path**:`/turbo-plugin:tp-pull-from-svn --branch main` →
  `Already up to date.` 或 fast-forward
- **D.2 conflict + rollback**:
  1. Setup(main):`echo conflict-A > new-conflict.txt && git add . && git commit -m "feat: ..."`
  2. Setup(remote-main):`cd remote-main; echo conflict-B > new-conflict.txt;
     svn add new-conflict.txt; svn commit -m "test: conflict"`
  3. Action:在 main session 跑 `/turbo-plugin:tp-pull-from-svn --branch main`
  4. **Expected**:
     - 偵測衝突
     - 自動 `git merge --abort` + `git checkout main`
     - emit `Merge conflict detected. ... Conflicting files: new-conflict.txt`
     - 中文訊息**不亂碼**(v0.2.4 UTF-8 fix)
     - 主 worktree HEAD 回到 conflict-A commit、working tree clean
  5. Cleanup:`git reset --hard HEAD~1`(放棄 conflict-A)

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
  - `git branch -a` 含 `test/rc3` + `remote/test-3`
  - `git worktree list` 含 `remote-test-3`
  - `svn ls file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/` 含 `test3/`
- **D.4 cancel path**(N=4):confirm 選 Cancel → branches/worktree/SVN
  都沒新東西
- **D.5 fail-rollback path**(N=5,無效 SVN URL):
  - SVN setup 失敗 → ERR trap fire
  - 訊息 `SVN setup failed; rolling back git state...`
  - `git branch -a` 不含 `test/rc5` 或 `remote/test-5`
  - `git worktree list` 不含 `remote-test-5`
  - (機率低)若 partial cleanup 失敗 emit `PARTIAL_ROLLBACK: ...` 訊息

**Verification**:D.3 PASS = v0.2.2 P0 fix 驗證(svn:ignore not found
不再 throw);D.5 PASS = Pass 3 WF1 + Pass 4 B5 ERR-trap 驗證。

---

### U10. tp-push-to-svn 完整 lifecycle(含 SHA pin / PENDING_MERGE / failure-retain)

**Goal**:驗 push-to-svn 整條 lifecycle:commit type 篩選 / SHA pin guard
觸發 / failure path pin retain / PENDING_MERGE_DETECTED 三選一。

**Requirements**:U9(D.3 已 land,有 `test/rc3` + `remote-test-3`)

**Dependencies**:U9

**Files**:
- `SampleGit/`(test/rc3 branch + commits)
- `SampleGit.worktrees/remote-test-3/.git/MERGE_HEAD.tp_branch_sha`(SHA pin
  file)
- `SampleSvnServer/test3/`(SVN history)

**Approach**:在 test/rc3 做 4 個 commit(feat/docs/fix/chore 各 1),跑
push-to-svn 觀察篩選 + lifecycle 各 step。

**Test scenarios**:

- **D.6 happy lifecycle**:
  - Setup:`git checkout test/rc3` + 4 個 commit(feat/docs/fix/chore)
  - Action:`/turbo-plugin:tp-push-to-svn --branch test-3`
  - SKILL prepare → 列 COMMITS/FILES → 篩選(feat/fix kept、docs/chore
    filtered)→ unknown prompt(無)→ Step 5 confirm → commit
  - **Expected**:
    - SVN body 只含 `feat: ...` + `fix: ...`
    - **`<remote-test-3>/.git/.../MERGE_HEAD.tp_branch_sha` push 過程中
      存在**(可在 prepare 完 commit 前查)
    - 成功 push 後 pin file 被清(v0.2.1 + v0.2.2 fix)
    - 中文 commit subject 在 SVN 顯示**不亂碼**(`svn log
      SampleGit.worktrees/remote-test-3 --limit 1`)
- **D.7 SHA pin guard 觸發**:
  - 跑 `/turbo-plugin:tp-push-to-svn --branch test-3` 到 Step 5 confirm 前
  - **另開** terminal 在 test/rc3 加新 commit
  - 回 SKILL 按 Accept
  - **Expected**:commit-phase throw `Branch 'test-3' has new commits since
    prepare (pinned: <8hex>, current: <8hex>)`
- **D.8 failure-retain pin**(可選,複雜):
  - 跑 push 到 commit 階段中斷 SVN(rename SampleSvnServer/db 暫時隱藏)
  - **Expected**:push 失敗,**pin file 仍存在**(v0.2.2 P1F1 fix)
- **D.9 PENDING_MERGE_DETECTED 三選一**:
  - 中斷 prepare 留 staged merge
  - 重跑 push → SKILL 出現 3 選一(Abort+re-prepare / Continue / Cancel)
  - 三 path 各跑一次

**Verification**:D.6 中文無亂碼 = v0.2.4 fix 驗證;D.7 throw = v0.2.1 F1
SHA pin gitdir 修法驗證;D.8 pin retain = v0.2.2 P1F1 驗證;D.9 = Pass 2
F15 token-based 三選一 land。

---

### U11. tp-reset-remote-test 三步 + suggest-ignore + cleanup-orphan-iis

**Goal**:把剩 3 個 SKILL 一起驗 — 都是相對獨立的 SKILL,可順手跑完。

**Requirements**:U9(reset-remote-test 需 `test/rc3` 存在);U2(其他)

**Dependencies**:U9

**Files**:
- `SampleGit/` git state(reset)
- `SampleGit/.gitignore`(suggest-ignore)
- iisexpress 處理程序 + applicationhost.config(cleanup-orphan-iis)

**Approach**:三個獨立 sub-test。

**Test scenarios**:

- **D.10 tp-reset-remote-test 三步**(v0.2.3 B1 fix):
  - Action:`/turbo-plugin:tp-reset-remote-test --branch test-3`
  - SKILL 應走:
    1. **Step 1** 跑 script 帶 `--diff-only` → 印 `LOSE: <N> commits` +
       `GAIN: <M> commits`
    2. **Step 2** AskUserQuestion confirm(顯示 LOSE/GAIN 數字)
    3. **Step 3** 跑 script(無 flag)→ `Reset test-3 to main`
  - Apply case:選 Apply → `test/rc3` SHA == `main` SHA
  - Cancel case:選 Cancel → `test/rc3` SHA 不動
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

**Dependencies(unit 順序)**:U1 → U2 → {U3, U4, U5, U7, U8, U9} → U6(依 U5)
→ U10(依 U9)→ U11(依 U9)。

---

## System-Wide Impact

- **全 14 個 turbo-plugin SKILL** 都被觸到(U2 / U5 / U6 / U7 / U8 / U9 /
  U10 / U11 = 11 個 user-invocable SKILL + tp-csharp-comment / tp-js-comment
  / tp-publish-dotnet-framework-web 透過 CLAUDE.md reference 與 fixture 驗)
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
| git branches `test/rc3` `remote/test-3` | `git -C SampleGit branch -D test/rc3 remote/test-3` |
| iisexpress 殘留 | `Get-Process iisexpress -ErrorAction SilentlyContinue \| Stop-Process -Force` |
| (可選)還原 marketplace name | `cd <worktree> && git checkout .claude-plugin/marketplace.json` |
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
- [ ] U10 tp-push-to-svn lifecycle + SHA pin + PENDING_MERGE
- [ ] U11 tp-reset-remote-test + suggest-ignore + cleanup-orphan-iis

⭐ 標的是核心優先;其他若忙可省。發現問題隨時回報。
