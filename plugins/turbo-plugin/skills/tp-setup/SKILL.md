---
name: tp-setup
description: '設定 turbo-plugin 環境。使用者明確要求 setup 時執行;agent 偵測到 .turbo-plugin/ marker 不存在 / SessionStart 提示需 setup 時可建議使用者執行,**不要自動觸發**。處理四 case:(a) 新建 git+SVN 專案 / (b) 接管既有 git+SVN 專案 / (c) 主 worktree 補設定 / (d) peer worktree per-peer 設定。'
argument-hint: 'optional: --svn-url <url>'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup

## Purpose

turbo-plugin 唯一設定入口,自動偵測當前狀態並進入對應的 case:

| Case | 觸發條件 | 主要動作 |
|---|---|---|
| (a) 新建 | `.git/` 不存在 | `git init` → 寫 ignore + commitlintrc + CLAUDE.md → 建 `.turbo-plugin/` → prompt SVN URL → 建 `remote/main` orphan branch + worktree → svn checkout |
| (b) init-from-existing | `.git/` 存在 + `.turbo-plugin/` 不存在 + git-svn 設定可能存在 | 警告 git-svn 不相容 → prompt SVN URL → 建 `remote/main` + worktree + svn checkout → 寫 `.turbo-plugin/` + ignore + convention |
| (c) 主 worktree 補設定 | `.turbo-plugin/` 存在 + 在主 worktree | idempotent 補缺失項目(`dbhub.local.toml`、外部依賴可用性、user-level env) |
| (d) peer-mode | `.turbo-plugin/` 存在 + 在 peer worktree | 只處理 per-peer non-shared files(複製 `dbhub.local.toml`、改寫 applicationhost.config) |

## Procedure

### Step 0 — Pre-check

依以下順序,任一失敗就停下並回報:

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.ps1`(PowerShell)或 `common.sh`(Bash)的 `Probe-GitVersion` / `probe_git_version`。Git < 2.31 → fail loudly 帶升級提示。
2. 跑 `git rev-parse --show-superproject-working-tree`。非空 → 拒跑,提示「submodule 不在 turbo-plugin 管理範圍內,請在 superproject root 設定」。

### Step 0.5 — Encoding support check(v0.2.7+)

跑 `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/check-encoding-support.ps1"` 偵測當前 PowerShell + Windows codepage 是否支援中文檔名 SVN 操作。

parse stdout 取 `ARGV_SAFE_FOR_UNICODE` 值:
- `True` → 略過此 step
- `False` → 進入 codepage remediation。**用 `AskUserQuestion` 問 user 的實際情境**(不要用技術術語,用具體場景):

  **Question text**(對 user 顯示):
  > 偵測到你用 PowerShell 5.1 + 中文 Windows。**SVN 操作含中文檔名**可能有問題。請問你的實際情況?
  >
  > (按一下對應選項,plugin 會自動處理或告訴你下一步)

  **Options**:

  | 選項 label | description | 動作 |
  |---|---|---|
  | **(a) 我跟同事都用中文 Windows,沒人用 Mac/Linux** | 你的 SVN repo 同事都用中文 Windows 開發,沒有 Mac/Linux 同事用 svn checkout。 **plugin 會處理**:含中文檔名的 SVN 操作自動走 Git Bash(`.sh`)版本,你不用換工具。後續 tp-push-to-svn / tp-create-remote-test 都會自動選對。 **代價**:SVN repo 裡中文檔名存的是 Big5 編碼(你跟同事看都正確,Mac/Linux 同事如果加入會看到亂碼)。 | 在 `.turbo-plugin/encoding-status.local.md` 寫:「Profile: zh-TW-only team. SVN ops with Chinese filenames will be routed through .sh siblings (Big5 bytes in SVN repo).」並在 `.turbo-plugin/config.toml` 的 `[svn]` section 寫入 `force_bash = true`(若 config.toml 不存在先複製 default-files template)。**不再**寫 `TURBO_PLUGIN_SVN_FORCE_BASH` 進 settings.local.json。 |
  | **(b) 我有 Mac/Linux 同事會 svn checkout(他們會看到亂碼)** | 跨 OS 團隊。為了讓 Mac/Linux 同事 checkout 看到的是正常中文,SVN repo 必須存 UTF-8 編碼,要把你的 PowerShell 升級或改 Windows 編碼設定。 | nested `AskUserQuestion` 二選一:**(b1) 安裝 PowerShell 7+(Recommended,不用重開機)**:跑 `winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements`(若 winget 不存在 → 提示從 https://aka.ms/powershell 下載 MSI 手動裝);完成後在 `.claude/settings.local.json` 加 `{"env":{"TURBO_PLUGIN_SHELL_HINT":"pwsh"}}`;告知 user「裝好了!請關掉這個 Claude Code session,改用 pwsh.exe 啟動 Claude Code(不是 powershell.exe)」。**(b2) 改 Windows 系統編碼設定(要重開機)**:`Start-Process intl.cpl -Verb RunAs`;emit 訊息「會幫你打開 Windows 設定。請點『系統管理』→『變更系統地區設定...』→ 勾『Beta:使用 Unicode UTF-8 提供全球語言支援』→ 確定 → **重新開機**生效。重開後 SVN 中文檔名會以 UTF-8 存。」 |
  | **(c) 我不會用中文檔名,維持現狀就好** | 你的 SVN 操作不會有中文檔名(或會避免)。plugin 其它功能(build / run / publish 等)不受影響。 | 在 `.turbo-plugin/encoding-status.local.md` 寫:「Profile: ASCII-only filenames. User declined encoding remediation. SVN ops with non-ASCII filenames will fail.」 |

**Note for SKILL implementer**:不要在 question/options 文字裡用 CP_ACP / CreateProcessA / DBCS / MSYS2 等術語 — user 看不懂。用「中文 Windows」「Git Bash」「PowerShell 7」「UTF-8 設定」這類具體名詞。

**完成後**:plugin 印一句確認(例如「OK,已記載你選了選項 (a) — 後續 SVN 中文檔名操作會自動走 .sh」),繼續跑 tp-setup 後續 step(remediation 不阻塞 setup)。

### Step 1 — Case detection

依以下優先序判斷,**第一個 match 的 case 即為當前 case**:

```
if not exist .git:
  → case (a) 新建
elif not Test-IsMainWorktree:
  → case (d) peer-mode
elif not exist .turbo-plugin:
  → case (b) init-from-existing
else:
  → case (c) 主 worktree 補設定
```

進 case 之前**先報告**:「偵測為 case (X) <短說明>,即將執行:<該 case 的高階步驟>」,然後用 `AskUserQuestion` 給使用者選擇:

- **執行偵測到的 case (X)** **(Recommended)**
- 改執行 case (a) — 新建 git+SVN 專案
- 改執行 case (b) — init-from-existing(接管既有 git+SVN)
- 改執行 case (c) — 主 worktree 補設定
- 改執行 case (d) — peer-mode

(偵測到的那個 case 不重複列在 override 選項中,只列其餘四個)

依使用者選擇進對應 case 的後續 Step 2/3/4/5。這讓使用者可以覆蓋自動偵測(例如手動測試 case (b) on a worktree 被偵測為 (d) 的情況)。

### Step 2 — Case (a):新建 git+SVN 專案

**順序敏感,以下 6 個 sub-step 不可重排**(SVN obstruction 避免):

1. `git init` 在當前目錄
2. 寫入 `.gitignore` 含以下 pattern(若 `.gitignore` 已存在則 idempotent merge,不重複追加):

   ```
   # turbo-plugin
   .claude/**/*.local.*
   .turbo-plugin/**/*.local.*
   ```

3. 建 `.turbo-plugin/` 集中目錄(複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/` 全部 template),複製出來的內容:`config.toml`、`applicationhost.config`、`dbhub.example.local.toml`(此三檔進 git,跨同事共用)。

4. 注入 `.commitlintrc.json` + `CLAUDE.md` convention 段:
   - `.commitlintrc.json`:若**不存在**則直接複製 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/commitlintrc-template.json`;若**已存在**則 JSON parse + merge `rules.type-enum[2]` array(將模板 12 類 union 進去,保留使用者既有 rules,不覆寫整檔)
   - `CLAUDE.md`:若**不存在**則建立含 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/claudemd-convention-snippet.md` 的內容;若**已存在**則用 marker `<!-- turbo-plugin:begin commit-type-convention -->` / `<!-- turbo-plugin:end commit-type-convention -->` 包夾的區段進行 idempotent 替換或追加,不影響其它段落

5. `AskUserQuestion`(自由文字)收集 **SVN URL**(若 argument 沒帶 `--svn-url`)。空值或格式不對(非 http(s) / svn / file)→ 重問或取消。

6. **建 `remote/main` orphan branch + worktree**(sub-step 順序 6a-6f 不可重排):
   - 6a. `git worktree add --detach --no-checkout "<proj>.worktrees/remote-main"`(`--no-checkout` 確保 dir 為空,svn checkout 不被 obstruction)
   - 6b. cd 進新 worktree
   - 6c. `git checkout --orphan remote/main`
   - 6d. `git rm -rf --cached .`,然後 `git commit --allow-empty -m "init: remote/main branch"`(初始 empty commit,讓 remote/main 為 proper branch,後續 pull-from-svn merge 不會撞 unrelated histories error;與既有 tgs `init-from-existing.md` line 139-153 一致)
   - 6e. `svn checkout <url> .`(此時 dir 空 svn 可進)
   - 6f. 寫入 `svn:ignore` 預設 patterns(同 `.gitignore` 的 turbo-plugin 條目),`svn propset svn:ignore --file <utf8-no-bom-tmp> .`

   **Step 6 rollback notes** — 若 6e (`svn checkout`) 失敗,手動還原步驟:
   1. `git worktree remove --force <proj>.worktrees/remote-main`
   2. `git branch -D remote/main`
   3. 確認清理完成後重跑 `/tp-setup`

7. 跑外部依賴可用性檢查 → Step 4

8. user-level env prompt → Step 5

### Step 3 — Case (b):接管既有 git+SVN

1. 檢查 `git config --get svn-remote.svn.url`。非空 → 警告:「偵測到 git-svn 設定(`<url>`)。turbo-plugin 不相容 git-svn,請手動移除設定後再繼續:`git config --unset-all svn-remote.svn.url` + 移除 `.git/svn/`。」`AskUserQuestion` 讓使用者確認:已移除 / 取消 setup。
2. 跑 case (a) 的 step 4(寫 `.commitlintrc.json` + `CLAUDE.md`)、step 2(寫 `.gitignore`)、step 3(建 `.turbo-plugin/`)。
3. 跑 case (a) 的 step 5-6(SVN URL + remote/main orphan worktree + svn checkout),**外加** `git merge --allow-unrelated-histories -m "chore: connect SVN via turbo-plugin (r<rev>)" remote/main` 把 SVN content 合進當前主 branch(同 tgs `init-from-existing.md` Phase 6)。merge 衝突 → 列出衝突檔,提示使用者手動解,**不自動 abort**。
4. 跑外部依賴可用性檢查 → Step 4
5. user-level env prompt → Step 5

### Step 4 — Case (c):主 worktree 補設定(idempotent)

順序檢查並補建,每個 sub-step **idempotent**:

1. `.turbo-plugin/config.toml` 不存在 → 複製 default-files template;**已存在則不覆寫**。
2. `.turbo-plugin/applicationhost.config` 不存在 → 複製 default-files template;**已存在則不覆寫**。
3. `.turbo-plugin/dbhub.example.local.toml` 不存在 → 複製 default-files template;**已存在則不覆寫**。
4. `.turbo-plugin/dbhub.local.toml` 不存在 → 提醒使用者「dbhub 需要使用者自填 credentials,請 `cp .turbo-plugin/dbhub.example.local.toml .turbo-plugin/dbhub.local.toml` 後編輯」,**不自動建立**(避免假裝有效設定)。
5. `.gitignore` 缺 turbo-plugin patterns → idempotent append。
6. `.commitlintrc.json` 缺 → 複製 template;**已存在則 JSON merge `rules.type-enum[2]` 不覆寫整檔**。
7. `CLAUDE.md` 缺 turbo-plugin convention 段 → 注入;**已存在則用 marker 區段比對,內容相同則 skip**。
8. 跑外部依賴可用性檢查 → Step 6
9. user-level env prompt → Step 7

### Step 5 — Case (d):peer-mode

**前提**:當前 worktree 不是 main worktree,且 `.turbo-plugin/` marker **必須**存在。若 marker 不存在 → 拒跑,提示「請先在主 worktree 跑 `/tp-setup` 完成 bootstrap」。

只處理 per-peer non-shared files(**不碰**任何 git-versioned shared files):

1. `.turbo-plugin/dbhub.local.toml` 在 peer 缺 → `AskUserQuestion`:
   - 「從主 worktree 複製過來(`cp <main>/.turbo-plugin/dbhub.local.toml ./.turbo-plugin/`)」
   - 「互動輸入新 credentials」
   - 「跳過(不用 dbhub MCP server)」

2. `applicationhost.config` 在 peer `.vs/<sln-stem>/config/` 缺或 physicalPath 不對 → 跑 `Update-ApplicationhostConfig`(`scripts/lib/applicationhost-helpers.ps1`)針對當前 worktree 的所有 csproj。

3. **不**重寫 `.commitlintrc.json` / `CLAUDE.md` / `.turbo-plugin/config.toml` / `.turbo-plugin/applicationhost.config` / `.turbo-plugin/dbhub.example.local.toml`(這些是 git-versioned shared files,只由主 worktree 管理)。

### Step 6 — 外部依賴可用性檢查

對每個依賴跑 probe;缺失則記錄為 missing dependency:

| 依賴 | Probe 指令 | Missing 時的動作 |
|---|---|---|
| MSBuild | `msbuild --version` 或 `Get-Command msbuild` | prompt user-level env `TURBO_PLUGIN_MSBUILD_PATH`(指向絕對路徑) |
| IIS Express | 試 `${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe` 存在 | prompt user-level env `TURBO_PLUGIN_IIS_EXPRESS_PATH`(指向絕對路徑) |
| SVN CLI | `svn --version` | fail loudly:「請安裝 SVN CLI(`apt install subversion` / `choco install svn` / `brew install subversion`)」 |
| Docker | `docker --version` | warn:「dbhub MCP server 需要 Docker。若不用 dbhub 可忽略;否則請安裝 Docker Desktop。」(不 fail) |
| Git | `git --version` | `Probe-GitVersion` 已驗 — skip |

**MSBuild / IIS Express 標準位置**:
- MSBuild:`${env:ProgramFiles}\Microsoft Visual Studio\<year>\<edition>\MSBuild\Current\Bin\MSBuild.exe`(VS 2019/2022)、`${env:ProgramFiles(x86)}\Microsoft Visual Studio\<year>\<edition>\MSBuild\Current\Bin\MSBuild.exe`(VS 2017/2019 32-bit edition)
- IIS Express:`${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe`(預設安裝)

### Step 7 — User-level env prompt

只在 Step 6 偵測 MSBuild 或 IIS Express 缺失才跑。寫進 **user-level `~/.claude/settings.json`**(不是 repo-level),env key 命名前綴 `TURBO_PLUGIN_*`:

- `TURBO_PLUGIN_MSBUILD_PATH` — MSBuild.exe 絕對路徑
- `TURBO_PLUGIN_IIS_EXPRESS_PATH` — iisexpress.exe 絕對路徑

寫入時 idempotent merge `env` block,不覆寫其它 key。

### Step 8 — Completion report

報告:
- 偵測到的 case
- 新建 / 已存在 / 補設定 的項目清單
- Missing dependencies 與已 prompt 的 user-level env keys
- 使用者**仍需手動處理**的事項(編輯 `dbhub.local.toml`、安裝 Docker 等)
- 下一步建議:「現在可執行 `/tp-pull-from-svn --branch main` 拉初次 SVN 內容」(case (a)/(b))或「設定已就緒,可開始開發」(case (c)/(d))。

## Decision Rules

- Case 偵測**順序固定**(submodule → no .git → not main worktree → no .turbo-plugin → else),不要更改邏輯。
- Case (a) 的 sub-step 6 **內部順序 6a-6f 不可重排** — 6a `--no-checkout`、6e svn checkout、6d empty commit 都是 SVN obstruction 與後續 merge 的 load-bearing 步驟。
- Case (c) 與 case (d) 必須 **idempotent**:跑兩次的結果與跑一次相同,不重複追加 `CLAUDE.md` 區段、不覆寫已存在的 shared file。
- `dbhub.local.toml` **永不自動建立**(避免使用者誤以為已 ready)。只 prompt 使用者複製 example 後手動編輯。
- 寫 `.commitlintrc.json` 用 JSON parse + array merge(`rules.type-enum[2]`),不要用 string 替換 — 使用者既有的其他 rules 必須保留。
- `CLAUDE.md` 用 marker `<!-- turbo-plugin:begin commit-type-convention -->` / `<!-- turbo-plugin:end commit-type-convention -->` 包夾 — 注入 / 更新 / 移除都以這對 marker 為錨。
- **不裝** husky、不裝 commit-msg hook、**不執行** `npm install` 或任何 npm 工具鏈。`.commitlintrc.json` 純諮詢,enforce 由 `tp-push-to-svn` 自 parse 完成。
- Git Bash 路徑(`/c/Users/...`)若使用者輸入,寫進 `~/.claude/settings.json` 前轉成 Windows 格式(`C:/Users/...`)。
- 不要把 user-level env(`TURBO_PLUGIN_*`)寫到 repo-level `.claude/settings.json` — 那會跨同事覆寫各自本機路徑。
- **不**裝 .NET FW workload / SVN / Docker 本身 — 這些是使用者本機環境責任,只 prompt 設 env 指向已安裝的 exe。
- 建議或執行**任何修改**前,先 `AskUserQuestion` 確認(尤其 case (b) 偵測 git-svn 的處置、SVN URL、user-level env 寫入)。

## Completion Checks

- `.turbo-plugin/` marker 目錄存在,內含 `config.toml`、`applicationhost.config`、`dbhub.example.local.toml`(三件 git-versioned)。
- `.gitignore` 含 `turbo-plugin` 相關 patterns(`.claude/**/*.local.*` / `.turbo-plugin/**/*.local.*`)。
- `.commitlintrc.json` 含 `rules.type-enum[2]` ⊇ 12 類預設;`CLAUDE.md` 含 turbo-plugin convention 段(由 marker 包夾)。
- Case (a)/(b):`git branch -a` 含 `remote/main`,`git worktree list` 含 `<proj>.worktrees/remote-main`,該 worktree 內含 `.svn/`。
- Missing dependencies 已 `AskUserQuestion` 提示;若 MSBuild / IIS Express 需要,user-level env 已寫入 `~/.claude/settings.json`。
- Case (d):未動到任何 git-versioned shared file;`dbhub.local.toml` 與 `applicationhost.config` 已處理完畢。
- 跑兩次 `/tp-setup` case (c) / (d):結果與跑一次相同(idempotent 驗證)。

## Test Scenarios

- **sessionstart.sh ERR trap**: 在 `scripts/hooks/sessionstart.sh` 的 trap 宣告之後暫時插入 `false` 一行,開新 Claude session。確認 (a) session 正常啟動沒 block、(b) stderr 沒漏出 trap 之外的錯誤訊息(`{}` 是預期 fallback)、(c) 沒 systemMessage prompt 出現。驗完拔掉 `false`。

## Tool Preference

所有檔案 read / write / search / edit 優先使用 Read / Write / Edit / Glob / Grep / LSP tool,避開 Bash / PowerShell / Python / Node.js 做檔案操作。呼叫 subagent 時也要傳遞此規則。

shell 操作只限:`git` / `svn` / 跑 `tp-setup` plugin script(`${CLAUDE_PLUGIN_ROOT}/scripts/...`)、`Get-Command` 等 probe 指令。
