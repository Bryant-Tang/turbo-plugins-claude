# turbo-plugin v0.2.4 — Manual Verification Test Plan

**測試環境**:`C:\Turbo\SampleGitWithSvn`(專為測試準備,內容可隨意改)
**目標**:驗證 SKILL agent-flow 行為(script-level 已由 agent autonomous 跑過)
**目前 plugin 版本**:v0.2.4(commit `4639b25` on `worktree-turbo-plugin-brainstorm`)

---

## 0. 目前環境基線狀態(已準備好)

### SampleGit/(main worktree)

- branch `main`,HEAD `d9dae2d`
- 含 fixture:`MinimalWebApp.sln` + `src/MinimalWebApp/MinimalWebApp.csproj`(.NET FW 4.8 Web App,port 51999)
- `src/MinimalWebApp/Properties/PublishProfiles/FileSystem.pubxml`(供 tp-publish 測試)
- `.turbo-plugin/config.toml` + `dbhub.example.local.toml`(committed,供 tp-setup case (c) 測試)
- `.gitignore` 已 union merge(含本地 + SVN 條目)
- 已含過 SVN sync 的 r17 + r21 commit

### SampleGit.worktrees/dev-1/(peer worktree)

- branch `feature/B`,已 merge main
- 含同樣 fixture + .turbo-plugin/ + .pubxml
- `.vs/MinimalWebApp/config/applicationhost.config` 是我手寫 minimal 版(只夠 cross-worktree physicalPath 測試),**真實 IIS 啟動需 VS 先 open .sln 生成完整 apphost**
- 已 seeded `.turbo-plugin/applicationhost.config`(也是 minimal,源自 plugin default-files)

### SampleGit.worktrees/test-1/, remote-main/(其他 peer worktree)

未動,維持原狀

### SampleSvnServer/(本機 SVN repo)

- `^/main` rev 21
- `^/test`(原 test/rc1 對應)
- (`^/test2` 已清除,測 D.1 / D.2 時會建 `^/test3`)

### Claude Code 設定

`SampleGit/.claude/settings.json`(已設定):
- marketplace `turbo-plugins-claude-dev` 指向 worktree path
- 舊 4 plugin disable
- `turbo-plugin@turbo-plugins-claude-dev` enable

---

## 1. Pre-flight(已完成)

| Step | Status |
|---|---|
| 安裝 turbo-plugin v0.2.4 | ☐ 若你裝的是 v0.2.3 或更早,**重 reload Claude Code session**(我剛 commit v0.2.4)|
| 4 個舊 plugin disable | ✅ |
| Lint clean | ✅(turbo-plugin 0 違規) |

---

## Phase A — `/tp-setup` 系列(**最該測 — 之前漏的**)

> tp-setup 是 plugin entry point,改動最多,案例最複雜,你之前提到 A.9/A.10 該由它在 CLAUDE.md 加 reference 也是這裡驗。

### A.1 `/tp-setup` case (c) — 主 worktree 補設定(`SampleGit/` 已有 `.turbo-plugin/` marker)

**Precondition**:在 `SampleGit/` 開新 Claude session

**Action**:
```
/turbo-plugin:tp-setup
```

**Expected**:

SKILL 應該偵測到 case (c)(主 worktree + 已有 marker),然後做:

1. **Augment `SampleGit/CLAUDE.md`** 加 turbo-plugin convention reference 條目,類似:
   - 「C# 程式碼修改前先 invoke `/turbo-plugin:tp-csharp-comment`」
   - 「JS/TS / `.vue` / `.cshtml` `<script>` 修改前先 invoke `/turbo-plugin:tp-js-comment`」
   - 「新 untracked 檔出現時可建議 `/turbo-plugin:tp-suggest-ignore`」
   - 「Web 專案 build / run / publish 用 `/turbo-plugin:tp-build-dotnet-framework-web` 等 SKILL」
2. **Bootstrap `.vs/MinimalWebApp/config/applicationhost.config`** — 從 `.turbo-plugin/applicationhost.config` template copy 並 update physicalPath 為 `SampleGit/src/MinimalWebApp/`
3. **`.claude/settings.local.json`** 補 env(若 user-level 沒設):
   - `TURBO_PLUGIN_MSBUILD_PATH`
   - `TURBO_PLUGIN_IIS_EXPRESS_PATH`
4. **`.claude/settings.local.json`** 補 permissions allowlist 讓後續 SKILL invocation 不再 prompt:
   ```
   "permissions": { "allow": ["Bash(powershell -NoProfile -ExecutionPolicy Bypass -File:*)", "Bash(powershell -ExecutionPolicy Bypass -File:*)"] }
   ```
5. **dbhub.local.toml 引導**:提示「複製 dbhub.example.local.toml 為 dbhub.local.toml 並填 credentials」

**驗**:
- `cat SampleGit/CLAUDE.md` 含 turbo-plugin SKILL reference 段
- `Test-Path SampleGit/.vs/MinimalWebApp/config/applicationhost.config` → True
- 該 apphost 內 site name == `MinimalWebApp-0eb9b6ee`,physicalPath == `C:\Turbo\SampleGitWithSvn\SampleGit\src\MinimalWebApp\`
- `cat SampleGit/.claude/settings.local.json` 含 env block + permissions allow
- 後續任何 `/turbo-plugin:tp-*` SKILL 不再被 sandbox 擋(解 A.2)

**Pass / Fail / 觀察**:

---

### A.2 `/tp-setup` case (d) — peer worktree(`dev-1`)

**Precondition**:**另開新 Claude session 在 `dev-1`**

**Action**:
```
/turbo-plugin:tp-setup
```

**Expected**:
SKILL 偵測 case (d)(peer worktree + 主 worktree 已 bootstrap)。應該做:
1. **複製主 worktree env** 到 dev-1 的 `.claude/settings.local.json`(`TURBO_PLUGIN_*` + permissions allowlist)
2. **dbhub.local.toml 處理**(三選一 prompt:複製主的 / 互動填新 / 跳過)
3. **可能 augment dev-1 CLAUDE.md**(若 dev-1 沒繼承)

**驗**:
- `cat dev-1/.claude/settings.local.json` 內容跟主 worktree 一致
- `cat dev-1/.turbo-plugin/dbhub.local.toml`(若你選複製)有 credentials

**Pass / Fail / 觀察**:

---

### A.3 `/tp-setup` case (a) — 全新環境(**可選**,需 throwaway dir)

**Precondition**:`mkdir C:/tmp/throwaway-test && cd C:/tmp/throwaway-test && git init`

**Action**:在新 cwd 開 Claude session → `/turbo-plugin:tp-setup`

**Expected**:SKILL 偵測 case (a)(新 repo,無 marker,無 csproj),引導 init + 建 `.turbo-plugin/` marker + 複製 default-files + 引導 user 加 .csproj 或選 init-from-existing

**驗**:throwaway dir 含完整 `.turbo-plugin/` + 引導訊息合理

**Pass / Fail / 觀察**:

---

## Phase B — 跨 worktree EnterWorktree 核心 bug 驗證

> **這是你 tnf 那個 pain point 對應的測試**。前提:Phase A.1 已跑完(主 worktree 的 .vs/applicationhost.config 已 bootstrap)。

### B.1 — 主 worktree session,EnterWorktree 到 dev-1

**Precondition**:
- 在 `SampleGit/` 已有的 Claude session(同 Phase A.1 那個,別關)
- 主 worktree 有 .vs/applicationhost.config(A.1 已 bootstrap)

**Action**:
1. 在 session 中對 dev-1 用 `EnterWorktree` 工具切過去
2. 觀察 PostToolUse hook 訊息

**Expected**:
- session cwd 變 `SampleGit.worktrees/dev-1`
- systemMessage 出現:`turbo-plugin: refreshed applicationhost.config for 1 site(s) in c:\Turbo\SampleGitWithSvn\SampleGit.worktrees\dev-1`(**「1 site(s)」不是「4 site(s)」 — v0.2.3 P3 fix 驗證**)
- `dev-1/.vs/MinimalWebApp/config/applicationhost.config` 內 physicalPath 自動 update 為 dev-1 path

**Pass / Fail / 觀察**:

---

### B.2 — 在 dev-1(EnterWorktree 後)跑 build

**Action**:
```
/turbo-plugin:tp-build-dotnet-framework-web
```

**Expected**:
- MSBuild 編譯 `dev-1/src/MinimalWebApp/MinimalWebApp.csproj`(非 main 的)
- `dev-1/src/MinimalWebApp/bin/MinimalWebApp.dll` mtime 更新
- `SampleGit/src/MinimalWebApp/bin/MinimalWebApp.dll` mtime **不變**

**驗**:
```bash
ls -l --time-style=full SampleGit/src/MinimalWebApp/bin/MinimalWebApp.dll
ls -l --time-style=full SampleGit.worktrees/dev-1/src/MinimalWebApp/bin/MinimalWebApp.dll
```
dev-1 的 mtime 應該比 main 的 mtime 新。

**Pass / Fail / 觀察**:

> 🎯 **這就是 tnf 那個 bug「build 跑到 main」在 turbo-plugin 不重現的證明**

---

### B.3 — 在 dev-1 跑 run + 瀏覽器驗 MapPath

**Action**:
```
/turbo-plugin:tp-run-dotnet-framework-web
```

**Expected**:
- `Started IIS Express (site: MinimalWebApp-0eb9b6ee, PID: <n>)`
- `Listening on http://localhost:51999/`

**驗**:
- 瀏覽器 `http://localhost:51999/` 顯示「MinimalWebApp running」
- 頁面內 MapPath = **`C:\Turbo\SampleGitWithSvn\SampleGit.worktrees\dev-1\src\MinimalWebApp\`**(**dev-1 路徑**,不是 main)

**Pass / Fail / 觀察**:

> ⚠ 若 IIS Express 啟動失敗看 `~/AppData/Local/IISExpress/TraceLogFiles/`。我手寫的 minimal apphost 可能不夠 — Phase A.1 tp-setup 若 bootstrap 完整 apphost 應可解,否則需 **先用 VS 開過一次 MinimalWebApp.sln** 讓 VS 生成完整 apphost。

---

### B.4 — 跨 worktree stop(從**另**個 session)

**Precondition**:B.3 IIS Express 正在跑(dev-1 啟的)

**Action**:
1. **新開**一個 Claude session 在 `SampleGit/`(主)— **跟 B.1 那個 session 是不同的**
2. 跑:
```
/turbo-plugin:tp-stop-dotnet-framework-web
```

**Expected**:
- `Stopped IIS Express PID <n>`(殺到了 dev-1 啟的那個 — 因為 site name `MinimalWebApp-0eb9b6ee` 跨 worktree identical)

**驗**:回 dev-1 session 或任一處 `Get-Process iisexpress -ErrorAction SilentlyContinue` 為空

**Pass / Fail / 觀察**:

> 🎯 **這就是「stop-iis 跨 worktree 找得到」的證明(原 tnf 是用 worktree path 為 key 所以找不到)**

---

### B.5 — 無 instance 時 stop

**Action**(任一 session):
```
/turbo-plugin:tp-stop-dotnet-framework-web
```

**Expected**:`No IIS Express process found for site 'MinimalWebApp-0eb9b6ee'.` exit 0(不是 error)

**Pass / Fail / 觀察**:

---

## Phase C — SessionStart hook 三分支

> hook 在 session 啟動時自動 fire,所以每個分支都要**開新 Claude session** 才會觸發。

### C.1 — Branch (ii):peer worktree 無 marker(已 script-level 驗,SKILL flow 補驗)

**Precondition**:
1. **關掉** dev-1 上的 Claude session
2. `mv dev-1/.turbo-plugin dev-1/.turbo-plugin.bak`
3. 開新 Claude session 在 `dev-1/`

**Expected**:session 啟動瞬間出現 systemMessage:
> turbo-plugin: 偵測到本 worktree 尚未 bootstrap,且這裡是 peer worktree。請到主 worktree (`C:\Turbo\SampleGitWithSvn\SampleGit`) 啟動 Claude 並執行 `/tp-setup`,完成 bootstrap 後再回此 worktree 工作。

**驗**:**main path 是 SampleGit 真實絕對路徑,不是字面 `$mainPath`**(v0.2.1 fix 驗證)

**Cleanup**:`mv dev-1/.turbo-plugin.bak dev-1/.turbo-plugin`

**Pass / Fail / 觀察**:

---

### C.2 — Branch (i):主 worktree 無 marker

**Precondition**:
1. 關掉 SampleGit 所有 session
2. `mv SampleGit/.turbo-plugin SampleGit/.turbo-plugin.bak`
3. 開新 Claude session 在 `SampleGit/`

**Expected**:systemMessage 提示「主 worktree 尚未 bootstrap,請執行 `/tp-setup`」

**Cleanup**:`mv SampleGit/.turbo-plugin.bak SampleGit/.turbo-plugin`

**Pass / Fail / 觀察**:

---

### C.3 — Branch (iii):marker 在但 dbhub.local.toml 缺(預設狀態)

**Precondition**:目前 SampleGit 就是這狀態(`.turbo-plugin/` 在,沒 dbhub.local.toml)

**Action**:開新 Claude session 在 `SampleGit/`

**Expected**:systemMessage 提示「請複製 `dbhub.example.local.toml` 為 `dbhub.local.toml` 並填 credentials」

**Pass / Fail / 觀察**:

---

## Phase D — SVN bridge 完整 lifecycle

### D.1 `/tp-pull-from-svn` happy path

**Action**:
```
/turbo-plugin:tp-pull-from-svn --branch main
```
(SKILL 會 translate 成 PowerShell `-Branch main`)

**Expected**:`Already up to date.` 或 fast-forward `Pulled SVN r<n>`(目前 SVN r21 已 sync,應該 already up to date)

**Pass / Fail / 觀察**:

---

### D.2 `/tp-pull-from-svn` 衝突 + rollback(v0.2.x 改善:UTF-8 對中文 error 訊息)

**Setup**(在 main):
```bash
cd SampleGit
echo "conflict-source" > new-conflict.txt
git add new-conflict.txt && git commit -m "feat: add conflict-source"
```
**Setup**(in remote-main):
```bash
cd SampleGit.worktrees/remote-main
echo "different-content" > new-conflict.txt
svn add new-conflict.txt
svn commit -m "test: conflict-source from SVN"
```

**Action**(在 main session):
```
/turbo-plugin:tp-pull-from-svn --branch main
```

**Expected**:
- script 偵測衝突
- 自動 `git merge --abort` + `git checkout main`
- emit `Merge conflict detected. ... Conflicting files: new-conflict.txt`
- 主 worktree 回 `main` 乾淨狀態

**Cleanup**:`git -C SampleGit reset --hard HEAD~1`(放棄本地 conflict-source commit)+ `svn revert SampleGit.worktrees/remote-main/new-conflict.txt` + `svn delete` 那筆 SVN commit(實際做不到 — SVN 永久 history。也可以接受)

**Pass / Fail / 觀察**:

---

### D.3 `/tp-create-remote-test` happy path(v0.2.2 fix 驗證)

**Action**:
```
/turbo-plugin:tp-create-remote-test --n 3 --svn-url file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/test3
```

**Expected**:SKILL 走:
1. Step 1 resolve worktree path / branch name
2. Step 2 計算 SVN URL
3. **Step 2.5 AskUserQuestion confirmation gate**(v0.2.0 F10 fix)— 顯示 N / branch / path / URL → 你選 Confirm
4. Step 3 跑 script(svn copy + checkout + propset svn:ignore)

**驗**:
- `git branch -a` 含 `test/rc3` + `remote/test-3`
- `git worktree list` 含 `remote-test-3` at `SampleGit.worktrees/remote-test-3`
- `svn ls file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/` 含 `test3/`
- **不再 throw `svn:ignore not found`**(v0.2.2 fix 驗證)

**Pass / Fail / 觀察**:

---

### D.4 `/tp-create-remote-test` Cancel path

**Action**:重跑 D.3 但 Step 2.5 confirm 時選 Cancel

**Expected**:branches / worktree / SVN 都沒新東西

**Pass / Fail / 觀察**:

---

### D.5 `/tp-create-remote-test` 失敗 rollback(v0.2.0 WF1 + v0.2.0 B5 驗證)

**Action**:
```
/turbo-plugin:tp-create-remote-test --n 4 --svn-url file:///nonexistent/path
```
(故意傳無效 SVN URL)

**Expected**:
- svn copy 失敗 → ERR trap fire(或 try/catch)
- 訊息含 `SVN setup failed; rolling back git state...`
- `git branch -a` **不**含 `test/rc4` 或 `remote/test-4`
- `git worktree list` 不含 `remote-test-4`
- 若 partial rollback emit `PARTIAL_ROLLBACK: ...` 訊息(機率低,看哪步驟失敗)

**Pass / Fail / 觀察**:

---

### D.6 `/tp-push-to-svn` 完整 lifecycle(SHA pin 機制驗證)

**Setup**:
```bash
cd SampleGit
git checkout test/rc3  # 剛建好的(D.3 land)
echo "feat-test-1" > feat-1.txt && git add . && git commit -m "feat: 加 feature 1"
echo "docs-test" > doc-1.md && git add . && git commit -m "docs: 加文件"
echo "fix-test" > fix-1.txt && git add . && git commit -m "fix: 修一個 bug"
echo "chore-test" > chore-1.txt && git add . && git commit -m "chore: 雜務"
```

**Action**:
```
/turbo-plugin:tp-push-to-svn --branch test-3
```

SKILL flow:prepare → 列 COMMITS / FILES → 過濾分類(feat/fix kept,docs/chore filtered)→ unknown type prompt(此測無)→ Step 5 confirm → commit

**Expected**:
- SVN body 只含 `feat: 加 feature 1` + `fix: 修一個 bug`(過濾 docs/chore)
- **`<remote-test-3>/.git/.../MERGE_HEAD.tp_branch_sha` push 過程中存在**(可在 prepare 完成、commit 前查)
- push 成功後 pin file 被清(v0.2.1 + v0.2.2 fix)
- 中文 commit subject 在 SVN 顯示不亂碼(`svn log SampleGit.worktrees/remote-test-3 --limit 1`)
- UTF-8 console output 中文不亂碼(v0.2.4 fix)

**Pass / Fail / 觀察**:

---

### D.7 `/tp-push-to-svn` SHA pin guard 觸發(v0.2.1 F1 driving fix 驗證)

**Action**:
1. 跑 `/tp-push-to-svn --branch test-3`(再做幾個 commit 先)
2. SKILL 走到 Step 5 confirm 前,**另開 terminal** 對 test/rc3 加新 commit:
```bash
cd SampleGit
git checkout test/rc3
echo "race" > race.txt && git add . && git commit -m "fix: race condition test"
```
3. 回 SKILL 按 Accept

**Expected**:
- commit-phase script throw `Branch 'test-3' has new commits since prepare (pinned: <8hex>, current: <8hex>)`
- abort 訊息含正確 SHA short forms(v0.2.0 AF3 short-pin guard 驗證)

**Cleanup**:`git -C SampleGit.worktrees/remote-test-3 merge --abort`

**Pass / Fail / 觀察**:

---

### D.8 `/tp-push-to-svn` failure-retain pin(v0.2.2 P1F1 + v0.2.0 WF2 驗證)

複雜,**可選**。需臨時停 SVN server(file:// 沒 server process,可能要把 SampleSvnServer/db rename 暫時隱藏)。

**Pass / Fail / 觀察**:

---

### D.9 `/tp-push-to-svn` PENDING_MERGE_DETECTED 三選一(v0.2.0 F15 驗證)

**Setup**:跑 `/tp-push-to-svn` 到 prepare 完(remote-test-3 內有 staged merge),**中斷不 commit**(`Ctrl+C` SKILL)。

**Action**:重跑 `/tp-push-to-svn --branch test-3`

**Expected**:SKILL 出現 3 選一(Abort+re-prepare / Continue / Cancel)。三 path 各試一次。

**Pass / Fail / 觀察**:

---

### D.10 `/tp-reset-remote-test`(v0.2.3 B1 fix 驗證 — Procedure 三步)

**Action**:
```
/turbo-plugin:tp-reset-remote-test --branch test-3
```

**Expected**:SKILL 走:
1. **Step 1** 跑 script 帶 `--diff-only` → 印 `LOSE: <N> commits ...` + `GAIN: <M> commits ...`
2. **Step 2** AskUserQuestion confirm(顯示 LOSE/GAIN 數)
3. **Step 3** 跑 script(no flag)→ `Reset test-3 to main`

**Pass case**:選 Apply → `test/rc3` SHA == `main` SHA
**Cancel case**:選 Cancel → `test/rc3` SHA 不動

**Pass / Fail / 觀察**:

---

### D.11 `/tp-suggest-ignore` analysis mode

**Setup**(在 SampleGit):
```bash
echo x > junk.tmp
echo x > debug.log
```

**Action**:
```
/turbo-plugin:tp-suggest-ignore
```

**Expected**:SKILL 走 Step 1-4,對 untracked candidates 各分類 AskUserQuestion。你選 add → `.gitignore` 更新 + git commit。

**Cleanup**:`rm junk.tmp debug.log` + 可選 `git revert HEAD`

**Pass / Fail / 觀察**:

---

## Phase E — `/tp-cleanup-orphan-iis`

**Setup**:需要兩個 orphan instance(同 csproj-stem 不同 hash)。

```bash
# 製造 process orphan(假 site name)
& "C:\Program Files\IIS Express\iisexpress.exe" /config:SampleGit/.vs/MinimalWebApp/config/applicationhost.config /site:MinimalWebApp-deadbeef &
```
(會 fail 因 site 不存在於 apphost,但 process 短暫存在;改用更可靠法:在 apphost 加一個 `<site name="MinimalWebApp-cafe1234">...</site>` 條目暫時啟用)

**Action**:
```
/turbo-plugin:tp-cleanup-orphan-iis
```

**Expected**:
- SKILL enumerate(列 `ORPHAN: <site> <kind> pid=<n>` 行)
- AskUserQuestion 多選讓你勾要清的 orphan
- script 殺 process + remove site
- 若部分失敗:`PARTIAL_FAILURE: failed=<n> sites=<list>` token + exit 2(v0.2.0 WF4 + v0.2.3 P3F1 驗證)

**Pass / Fail / 觀察**:

---

## Phase F — 額外項目(原 A.9/A.10 — 由 Phase A.1 順帶驗)

| 項目 | 驗 |
|---|---|
| **tp-csharp-comment 整合**:tp-setup case (c) 應加 CLAUDE.md 條目「修 .cs 前 invoke `/tp-csharp-comment`」 | 看 `SampleGit/CLAUDE.md`(已在 A.1 驗) |
| **tp-js-comment 整合**:同上 | 同上 |
| 後續 dev flow 自動 trigger | 留待之後跑 dev flow 一起 |

---

## 已知 issue(別當 bug)

- **A.1 r17 mojibake**:r17 是 pre-existing SVN data 用非 UTF-8 codepage 推上去,turbo-plugin 救不了歷史資料。v0.2.4 fix 救未來新 commit。
- **真實 IIS Express 啟動**:需 VS 開過 .sln 一次生成完整 applicationhost.config。Phase A.1 若 tp-setup 沒 bootstrap 完整版,需 VS 補。

---

## 出問題的 fallback

### 完全清除重來(會洗掉 fixture)
```bash
cd SampleGit && git reset --hard 50248e1   # 回到 init.txt 之前
# 重 commit 所有 fixture / 跑 tp-setup
```
(別這樣做,代價太高 — 先試其他 fallback)

### git 卡 conflict 或 partial state
```bash
cd SampleGit && git merge --abort 2>/dev/null
cd SampleGit && git reset --hard HEAD
# 若 worktree 卡:git -C SampleGit worktree prune
```

### SVN 卡 stale lock
```bash
svn cleanup SampleGit.worktrees/remote-main
svn cleanup SampleGit.worktrees/remote-test-3   # 若有
```

### iisexpress 卡
```powershell
Get-Process iisexpress -ErrorAction SilentlyContinue | Stop-Process -Force
```

### marketplace 沒看到 plugin
- 確認 `SampleGit/.claude/settings.json` 的 marketplace path 是 `C:/Turbo/turbo-plugins-claude/.claude/worktrees/turbo-plugin-brainstorm`(指 worktree 不是 main repo)
- 重 reload Claude Code session

---

## 全部測完後 — 收尾 cleanup 清單

| 項目 | 動作 |
|---|---|
| SVN test3 殘留 | `svn delete file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/test3 -m "cleanup"` |
| git remote-test-3 worktree | `git -C SampleGit worktree remove --force SampleGit.worktrees/remote-test-3` |
| git branches `test/rc3` `remote/test-3` | `git -C SampleGit branch -D test/rc3 remote/test-3` |
| (可選)還原 marketplace name | `cd C:/Turbo/turbo-plugins-claude/.claude/worktrees/turbo-plugin-brainstorm && git checkout .claude-plugin/marketplace.json` |
| (可選)squash 4 個 v0.2.x fix commits 為一個 | git rebase -i,squash |

---

## 進度追蹤

依序 tick:

- [ ] **Phase A.1** /tp-setup case (c) main worktree
- [ ] Phase A.2 /tp-setup case (d) dev-1
- [ ] Phase A.3 /tp-setup case (a) throwaway(可選)
- [ ] **Phase B.1** EnterWorktree → systemMessage 顯 1 site
- [ ] **Phase B.2** dev-1 build → dev-1 bin/ 更新 + main bin/ 不變 ⭐(pain point 核心)
- [ ] Phase B.3 dev-1 run → 瀏覽器看 dev-1 path MapPath
- [ ] Phase B.4 主 session stop → 殺到 dev-1 IIS
- [ ] Phase B.5 無 instance stop → 友善 message
- [ ] Phase C.1 SessionStart (ii) peer no marker
- [ ] Phase C.2 SessionStart (i) main no marker
- [ ] Phase C.3 SessionStart (iii) dbhub missing
- [ ] Phase D.1 pull happy
- [ ] Phase D.2 pull conflict + rollback
- [ ] Phase D.3 create-remote-test happy
- [ ] Phase D.4 create-remote-test cancel
- [ ] Phase D.5 create-remote-test fail rollback
- [ ] Phase D.6 push full lifecycle
- [ ] Phase D.7 push SHA pin guard
- [ ] Phase D.8 push pin retain(可選)
- [ ] Phase D.9 push PENDING_MERGE 3 選一
- [ ] Phase D.10 reset-remote-test 三步
- [ ] Phase D.11 suggest-ignore analysis
- [ ] Phase E cleanup-orphan-iis

⭐ 標的是核心,優先這幾項。其他發現問題回報。
