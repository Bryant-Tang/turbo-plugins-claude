---
name: tp-setup
description: '設定 turbo-plugin 環境。使用者明確要求 setup 時執行;agent 偵測到 .turbo-plugin/ marker 不存在 / SessionStart 提示需 setup 時可建議使用者執行,**不要自動觸發**。流程分四個 Phase:Phase 1 偵測 / Phase 2 case-specific bootstrap(含 applicationhost.config bootstrap)/ Phase 3 環境配置 / Phase 4 完成報告。涵蓋四個 case:(a) 新建 git+SVN 專案 / (b) 接管既有 git+SVN 專案 / (c) 主 worktree 補設定 / (d) peer worktree per-peer 設定。'
argument-hint: 'optional: --svn-url <url>'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup

## Purpose

turbo-plugin 唯一設定入口,自動偵測當前狀態並進入對應的 case。流程以 4 個 Phase 串成一條主線:

| Phase | 內容 |
|---|---|
| **Phase 1 — 偵測** | Pre-check(Git version / submodule)+ Encoding profile detect(zh-TW Windows 中文檔名 SVN 相容性)+ Case detect(a/b/c/d)+ Phase summary(只列「會動到外部」的 unconditional 動作)+ AskUserQuestion 讓使用者繼續 / 取消 / 改執行其他 case |
| **Phase 2 — Case-specific bootstrap** | 進對應 case 後執行該 case 的動作序列,加 `applicationhost.config` bootstrap(R1 三選一,只在 case (a)/(b)/(c) 觸發,case (d) peer-mode 不做) |
| **Phase 3 — 環境配置** | 偵測 Claude Code 既有設定 + 外部工具 → 列出已啟用 / 尚未配置 → 互動式詢問是否啟用 LSP / compound-engineering / agent teams / TUI fullscreen 等(本 Phase 內容由後續 unit 填入) |
| **Phase 4 — 完成報告** | 偵測結果 / 寫入位置 / 外部安裝成功與失敗清單 / 使用者仍須手動處理事項 / 若 Phase 3 動到 `~/.claude/settings.json` 提示重啟 Claude Code / 下一步建議 |

各 case 的觸發條件與主要動作:

| Case | 觸發條件 | 主要動作 |
|---|---|---|
| (a) 新建 | `.git/` 不存在 | `git init -b main` → 寫 ignore(turbo-plugin + .NET 產物)+ commitlintrc + CLAUDE.md → 建 `.turbo-plugin/` → 確認 git 身分後建初始 commit → prompt SVN URL → 建 `remote-svn/main` orphan branch + worktree → svn checkout → 連接 main↔remote-svn/main 歷史 → apphost bootstrap |
| (b) init-from-existing | `.git/` 存在 + `.turbo-plugin/` 不存在 + git-svn 設定可能存在 | 警告 git-svn 不相容 → prompt SVN URL → 建 `remote-svn/main` + worktree + svn checkout → `git merge --allow-unrelated-histories` 合 SVN content → 寫 `.turbo-plugin/` + ignore + convention → apphost bootstrap |
| (c) 主 worktree 補設定 | `.turbo-plugin/` 存在 + 在主 worktree | idempotent 補缺失項目(`dbhub.local.toml`、shared file 缺項補建)→ apphost bootstrap |
| (d) peer-mode | `.turbo-plugin/` 存在 + 在 peer worktree | 只處理 per-peer non-shared files(複製 `dbhub.local.toml`);**不**做 apphost bootstrap(canonical 在主 worktree,跨 worktree 共享) |

---

## Procedure

### Phase 1 — 偵測

#### 1.1 Pre-check

依以下順序,任一失敗就停下並回報:

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/lib/Common.ps1`(PowerShell)或 `common.sh`(Bash)的 `Probe-GitVersion` / `probe_git_version`。Git < 2.31 → fail loudly 帶升級提示。
2. 跑 `git rev-parse --show-superproject-working-tree`。非空 → 拒跑,提示「submodule 不在 turbo-plugin 管理範圍內,請在 superproject root 設定」。

#### 1.2 Encoding profile detect(zh-TW Windows 中文檔名 SVN 相容性)

跑 `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Test-EncodingSupport.ps1"` 偵測當前 PowerShell + Windows codepage 是否支援中文檔名 SVN 操作。

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
  | **(a) 我跟同事都用中文 Windows,沒人用 Mac/Linux** | 你的 SVN repo 同事都用中文 Windows 開發,沒有 Mac/Linux 同事用 svn checkout。 **plugin 會處理**:含中文檔名的 SVN 操作自動走 Git Bash(`.sh`)版本,你不用換工具。後續 tp-push-to-svn 等 SVN 操作都會自動選對。 **代價**:SVN repo 裡中文檔名存的是 Big5 編碼(你跟同事看都正確,Mac/Linux 同事如果加入會看到亂碼)。 | 在 `.turbo-plugin/encoding-status.local.md` 寫:「Profile: zh-TW-only team. SVN ops with Chinese filenames are routed to .sh siblings automatically by each skill's 執行路由 (Git Bash detection); Big5 bytes in SVN repo.」**不再**寫任何 force_bash 設定(`.turbo-plugin/config.toml` 的 `[svn] force_bash` 與 settings.local.json 的 `TURBO_PLUGIN_SVN_FORCE_BASH` 都不寫)。含中文檔名的 SVN 操作改由各 skill 的**執行路由**(偵測到 Git Bash 時自動走 `.sh`)處理。 |
  | **(b) 我有 Mac/Linux 同事會 svn checkout(他們會看到亂碼)** | 跨 OS 團隊。為了讓 Mac/Linux 同事 checkout 看到的是正常中文,SVN repo 必須存 UTF-8 編碼,要把你的 PowerShell 升級或改 Windows 編碼設定。 | nested `AskUserQuestion` 二選一:**(b1) 安裝 PowerShell 7+(Recommended,不用重開機)**:跑 `winget install --id Microsoft.PowerShell --silent --accept-package-agreements --accept-source-agreements`(若 winget 不存在 → 提示從 https://aka.ms/powershell 下載 MSI 手動裝);完成後在 `.claude/settings.local.json` 加 `{"env":{"TURBO_PLUGIN_SHELL_HINT":"pwsh"}}`;告知 user「裝好了!請關掉這個 Claude Code session,改用 pwsh.exe 啟動 Claude Code(不是 powershell.exe)」。**(b2) 改 Windows 系統編碼設定(要重開機)**:`Start-Process intl.cpl -Verb RunAs`;emit 訊息「會幫你打開 Windows 設定。請點『系統管理』→『變更系統地區設定...』→ 勾『Beta:使用 Unicode UTF-8 提供全球語言支援』→ 確定 → **重新開機**生效。重開後 SVN 中文檔名會以 UTF-8 存。」 |
  | **(c) 我不會用中文檔名,維持現狀就好** | 你的 SVN 操作不會有中文檔名(或會避免)。plugin 其它功能(build / run / publish 等)不受影響。 | 在 `.turbo-plugin/encoding-status.local.md` 寫:「Profile: ASCII-only filenames. User declined encoding remediation. SVN ops with non-ASCII filenames will fail.」 |

  **Note for SKILL implementer**:不要在 question/options 文字裡用 CP_ACP / CreateProcessA / DBCS / MSYS2 等術語 — user 看不懂。用「中文 Windows」「Git Bash」「PowerShell 7」「UTF-8 設定」這類具體名詞。

  **完成後**:plugin 印一句確認(例如「OK,已記載你選了選項 (a) — 後續 SVN 中文檔名操作會自動走 .sh」),繼續跑後續 Phase(remediation 不阻塞 setup)。

#### 1.3 Case detection

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

#### 1.4 Phase summary + AskUserQuestion(繼續 / 取消 / 改執行其他 case)

進 case 之前**先報告**:「偵測為 case (X) <短說明>,即將執行 <該 case 的高階步驟>」,接著 emit **Phase summary** — 只列「會動到外部」的 unconditional 動作(亦即 case 進入後**必然**會發生的事,不論使用者後續選什麼):

- ✅ **要列**:
  - case (a)/(b):從 SVN 伺服器抓取專案內容到本機(`svn checkout <url>`)
  - case (a):設定 SVN 預設忽略規則並推送到 SVN 伺服器(`svn propset svn:ignore` + `svn commit`)
  - case (b):將 SVN 內容合進當前 git branch(`git merge --allow-unrelated-histories`,merge commit 留在本地,**不**自動 push)
- ❌ **不要列**(internal repo-only 動作,屬 transparency 範圍外):
  - `.gitignore` / `.commitlintrc.json` / `CLAUDE.md` 寫入
  - `.turbo-plugin/` 範本目錄複製
  - 任何 git 本地 op(`git init` / `git worktree add` / `git checkout --orphan` / 本地 commit)
  - AskUserQuestion 本身
  - 檔案讀取 / probe
- ❌ **不要預列** Phase 3 的「視使用者選擇的外部動作」(LSP server install / Claude Code 從網路下載 plugin 等)— 由 Phase 3 各 AskUserQuestion 選項 preview 自己列。

平實白話 + 具體項目名稱:「從 SVN 伺服器抓取專案內容到本機」「設定 SVN 預設忽略規則並推送到 SVN 伺服器」,不用 raw shell 指令。

Phase summary 顯示後用 `AskUserQuestion` 給使用者選擇:

- **執行偵測到的 case (X)** **(Recommended)**
- 改執行 case (a) — 新建 git+SVN 專案
- 改執行 case (b) — init-from-existing(接管既有 git+SVN)
- 改執行 case (c) — 主 worktree 補設定
- 改執行 case (d) — peer-mode
- 取消 setup

(偵測到的那個 case 不重複列在 override 選項中,只列其餘四個 + 取消)

依使用者選擇進對應 case 的 Phase 2。這讓使用者可以覆蓋自動偵測(例如手動測試 case (b) on a worktree 被偵測為 (d) 的情況)。

---

### Phase 2 — Case-specific bootstrap

依 Phase 1 決定的 case 進入下列其中一條子流程,跑完該 case 的動作序列後再執行 **apphost bootstrap**(case (d) 不執行),最後 fall through 到 Phase 3。

#### 2(a). Case (a) — 新建 git+SVN 專案

**順序敏感,以下 sub-step 不可重排**(SVN obstruction 避免 +「先 ignore 再 commit」+ 歷史連接):

1. `git init -b main` 在當前目錄。**明確指定預設分支 `main`** — 與稍後建立的 `remote-svn/main` bridge 對齊;裸 `git init` 在多數環境落在 `master`,會導致首次 `/tp-push-to-svn` 時 working branch(`master`)與 bridge(`remote-svn/main`)名稱不符而卡住。Git ≥ 2.31 已於 Phase 1.1 pre-check 驗證,必支援 `-b`。

2. 寫入 `.gitignore`(若已存在則 idempotent merge,不重複追加)。**此步驟必須先於 sub-step 5 的初始 commit 與 sub-step 7 的任何 `git worktree add`**:turbo-plugin 容器規則(`.turbo-plugin/worktrees/`)要先寫進去,否則 nested worktree 一建立就弄髒主 worktree `git status`;**.NET Framework Web 產物規則也要先寫進去,否則 sub-step 5 的初始 commit 會把 `.vs/` / `bin/` / `obj/` 等機器產物掃進版控**。兩個區塊都寫:

   ```
   # turbo-plugin
   .claude/**/*.local.*
   .turbo-plugin/**/*.local.*
   .turbo-plugin/worktrees/
   .svn/

   # .NET Framework Web 產物(Visual Studio)
   .vs/
   bin/
   obj/
   *.user
   packages/
   ```

   > .NET 區塊是合理預設,非窮舉;sub-step 5 的初始 commit 確認環節會把「將被 commit / 被忽略」兩份清單列給使用者,使用者可在 commit 前補上漏掉的 pattern(例如 `*.suo`、`TestResults/`)。

3. 建 `.turbo-plugin/` 集中目錄(複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/` 全部 template),複製出來的內容:`config.toml`、`applicationhost.config`、`conventions.md`、`dbhub.example.local.toml`(此四檔進 git,跨同事共用)。

4. 注入 `.commitlintrc.json` + `CLAUDE.md` convention 段:
   - `.commitlintrc.json`:若**不存在**則直接複製 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/commitlintrc-template.json`;若**已存在**則 JSON parse + merge `rules.type-enum[2]` array(將模板 12 類 union 進去,保留使用者既有 rules,不覆寫整檔)。
   - `CLAUDE.md`:注入的是**精簡指向 snippet**(`${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/claudemd-convention-snippet.md`)——祈使觸發語「執行 DB / commit / `*.cs` / `*.js` 操作前先讀 `.turbo-plugin/conventions.md`」+ R3a 常駐規則(不得提交僅限本機之物),**不再** inline 整份規範。若 `CLAUDE.md` **不存在**則建立含該 snippet 的內容;若**已存在**則用 marker `<!-- turbo-plugin:begin commit-type-convention -->` / `<!-- turbo-plugin:end commit-type-convention -->` 包夾的區段進行 idempotent 替換或追加,不影響其它段落。

5. **初始 commit(commit 前先確認)**。此時 working tree 含使用者既有檔案 + 剛寫入的 `.gitignore` / `.turbo-plugin/` / `.commitlintrc.json` / `CLAUDE.md`。main 分支需要至少一個 commit,sub-step 7 的 `git worktree add` 才有 HEAD 可依附。**不要直接 `git add -A` 就 commit**:
   - **先確認 git 提交身分**:跑 `git config user.name` 與 `git config user.email`(讀 local+global 合併後有效值)。任一為空 → **不自動代填**(尤其**不得**用 Claude 帳號 email 或本機使用者名稱);用 `AskUserQuestion` 請使用者輸入姓名 + email(寫 **repo-local**:`git config user.name <v>` / `git config user.email <v>`,**不加 `--global`**,不碰使用者全域設定),或選擇「先自行 `git config` 後重跑」/「取消」。兩者皆有值則略過此項。
   - **列兩份清單給使用者看**:**將被 commit**(`git add -An` 的輸出,或 `git status --porcelain`)與**被 `.gitignore` 排除**(`git status --ignored --porcelain` 取 `!!` 開頭者)。
   - 用 `AskUserQuestion`(平實白話)確認:
     - 「確認,建立初始 commit」→ 進下一步
     - 「先補 `.gitignore`(清單裡有不該進版控的檔案)」→ free-text 收要追加的 pattern → 加進 `.gitignore`(idempotent)→ 重新列清單再問
     - 「取消 setup」
   - 確認後**分開兩步驟**跑(CLAUDE.md 禁 `&&` 串接 state-changing git):先 `git add -A`,觀察成功,再 `git commit -m "chore: initial commit (turbo-plugin setup)"`。
   - 若 working tree 完全沒有可 commit 的內容(真空專案)→ 用 `git commit --allow-empty`。

6. `AskUserQuestion`(自由文字)收集 **SVN URL**(若 argument 沒帶 `--svn-url`)。空值或格式不對(非 http(s) / svn / file)→ 重問或取消。

7. **建 `remote-svn/main` orphan branch + worktree**(sub-step 順序 7a-7f 不可重排)。**前提**:sub-step 2 已把 `.turbo-plugin/worktrees/` 寫進 `.gitignore`、sub-step 5 已建立初始 commit,故下面的 `git worktree add` 不會弄髒主 worktree `git status`、也有 HEAD 可依附:
   - 7a. `git worktree add --detach --no-checkout ".turbo-plugin/worktrees/remote-svn-main"`(`--no-checkout` 確保 dir 為空,svn checkout 不被 obstruction)
   - 7b. cd 進新 worktree
   - 7c. `git checkout --orphan remote-svn/main`
   - 7d. `git rm -rf --cached .`,然後 `git commit --allow-empty -m "init: remote-svn/main branch"`(初始 empty commit,讓 remote-svn/main 為 proper branch;sub-step 8 會把它與 main 連接)
   - 7e. `svn checkout <url> .`(此時 dir 空 svn 可進)
   - 7f. 寫入 `svn:ignore` 預設 patterns(同 `.gitignore` 的 turbo-plugin 條目,**含 `.turbo-plugin/worktrees/`**,確保 nested worktree 容器不會被 svn add / push 到 SVN),`svn propset svn:ignore --file <utf8-no-bom-tmp> .`

   **Step 7 rollback notes** — 若 7e (`svn checkout`) 失敗,手動還原步驟:
   1. `git worktree remove --force .turbo-plugin/worktrees/remote-svn-main`
   2. `git branch -D remote-svn/main`
   3. 確認清理完成後重跑 `/tp-setup`

8. **連接 main ↔ remote-svn/main 歷史**。sub-step 7 把 `remote-svn/main` 建成 orphan(獨立 root),與 `main` 無共同祖先;**若不連接**,首次 `/tp-push-to-svn`(在 remote 端 `git merge main`)與首次 `/tp-pull-from-svn`(在 main 端 `git merge remote-svn/main`)都會撞 `fatal: refusing to merge unrelated histories`。在**主 worktree、branch `main`** 上跑(`remote-svn/main` 為空 orphan,合併無內容、不會衝突):

   `git -C <main-worktree> merge --allow-unrelated-histories -m "chore: connect SVN bridge via turbo-plugin" remote-svn/main`

   （與 case (b) 的 connect merge 同機制;差別只在 case (b) 藉此帶入既有 SVN 內容,case (a) 的 SVN 為空、純粹連接歷史。連接後 main 多一個空 merge commit,屬預期。）

9. **apphost bootstrap**(見下方 §2.apphost-bootstrap)。

完成後 fall through to Phase 3。

#### 2(b). Case (b) — 接管既有 git+SVN

1. 檢查 `git config --get svn-remote.svn.url`。非空 → 警告:「偵測到 git-svn 設定(`<url>`)。turbo-plugin 不相容 git-svn,請手動移除設定後再繼續:`git config --unset-all svn-remote.svn.url` + 移除 `.git/svn/`。」`AskUserQuestion` 讓使用者確認:已移除 / 取消 setup。
2. 跑 case (a) 的 sub-step 2(寫 `.gitignore`,含 .NET 產物區塊)、3(建 `.turbo-plugin/`)、4(寫 `.commitlintrc.json` + `CLAUDE.md`)。**先依 case (a) sub-step 5 的「git 提交身分」檢查**確認 committer 身分(case (b) 接下來會建 merge commit,需要身分;同樣**不自動代填**)。case (b) 的 repo 已有 commit 歷史,**不跑** case (a) sub-step 5 的「初始 commit」。
3. 跑 case (a) 的 sub-step 6-7(SVN URL + remote-svn/main orphan worktree + svn checkout;sub-step 2 已把 `.turbo-plugin/worktrees/` 寫進 `.gitignore`,先於該 worktree add),**外加**(此即 case (a) sub-step 8「連接歷史」在 case (b) 的對應做法,故 case (b) 不再另跑 sub-step 8)`git merge --allow-unrelated-histories -m "chore: connect SVN via turbo-plugin (r<rev>)" remote-svn/main` 把 SVN content 合進當前主 branch(同 tgs `init-from-existing.md` Phase 6)。merge 衝突 → 列出衝突檔,提示使用者手動解,**不自動 abort**。
4. **apphost bootstrap**(見下方 §2.apphost-bootstrap)。

完成後 fall through to Phase 3。

#### 2(c). Case (c) — 主 worktree 補設定(idempotent)

順序檢查並補建,每個 sub-step **idempotent**:

1. `.turbo-plugin/config.toml` 不存在 → 複製 default-files template;**已存在則不覆寫**。
2. `.turbo-plugin/applicationhost.config` 不存在 → 複製 default-files template;**已存在則不覆寫**。
3. `.turbo-plugin/dbhub.example.local.toml` 不存在 → 複製 default-files template;**已存在則不覆寫**。
4. `.turbo-plugin/dbhub.local.toml` 不存在 → 提醒使用者「dbhub 需要使用者自填 credentials,請 `cp .turbo-plugin/dbhub.example.local.toml .turbo-plugin/dbhub.local.toml` 後編輯」,**不自動建立**(避免假裝有效設定)。
5. `.gitignore` 缺 turbo-plugin patterns → idempotent append（patterns 含 `.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*`、`.turbo-plugin/worktrees/`、`.svn/`;`.turbo-plugin/worktrees/` 確保任何 `tp-push-to-svn` 首推 bootstrap(New-RemoteBridge)建立的 nested worktree 容器不污染主 worktree `git status`,`.svn/` 讓 git 忽略 bridge worktree 內的 SVN 管理目錄,各 SVN 腳本不再需要手動過濾 `.svn/*`）。
6. `.commitlintrc.json` 缺 → 複製 template;**已存在則 JSON merge `rules.type-enum[2]` 不覆寫整檔**。
7. `CLAUDE.md` 缺 turbo-plugin convention 段 → 注入;**已存在則用 marker 區段比對,內容相同則 skip**。
8. **apphost bootstrap**(見下方 §2.apphost-bootstrap;case (c) 通常 canonical 已存在,bootstrap 在 sub-step 2 已 idempotent 跳過,實際觸發機率低)。

完成後 fall through to Phase 3。

#### 2(d). Case (d) — peer-mode

**前提**:當前 worktree 不是 main worktree,且 `.turbo-plugin/` marker **必須**存在。若 marker 不存在 → 拒跑,提示「請先在主 worktree 跑 `/tp-setup` 完成 bootstrap」。

只處理 per-peer non-shared files(**不碰**任何 git-versioned shared files):

1. `.turbo-plugin/dbhub.local.toml` 在 peer 缺 → `AskUserQuestion`:
   - 「從主 worktree 複製過來(`cp <main>/.turbo-plugin/dbhub.local.toml ./.turbo-plugin/`)」
   - 「互動輸入新 credentials」
   - 「跳過(不用 dbhub MCP server)」

2. **不**做 apphost bootstrap — canonical(`.turbo-plugin/applicationhost.config`)在主 worktree 已存在,跨 worktree 由 git 共享。peer 的 IIS Express 啟動由 `start-iis` runtime 自動讀 canonical 並渲染到 temp file(已由 U3 實作)。

3. **不**重寫 `.commitlintrc.json` / `CLAUDE.md` / `.turbo-plugin/config.toml` / `.turbo-plugin/conventions.md` / `.turbo-plugin/applicationhost.config` / `.turbo-plugin/dbhub.example.local.toml`(這些是 git-versioned shared files,只由主 worktree 管理)。

完成後 fall through to Phase 3。

#### 2.apphost-bootstrap — applicationhost.config 三選一

此區段**只**在 case (a)/(b)/(c) 結尾觸發,case (d) 不執行。

```
if test -f <repo>/.turbo-plugin/applicationhost.config:
  → pass(canonical 已存在,不動)
elif test -f <repo>/.vs/<sln>/config/applicationhost.config:
  → 從 VS 複製進來,並把 physicalPath 替換成佔位符
     1. cp .vs/<sln>/config/applicationhost.config -> .turbo-plugin/applicationhost.config
     2. XML parse + replace 每個 <site><application><virtualDirectory> 的 physicalPath
        屬性值為 "__TURBO_PLUGIN_PHYSICAL_PATH__"
        (也包括 <application> 自己的 physicalPath)
     3. 避免機器-specific 絕對路徑進版控;runtime 由 start-iis(U3 已實作)
        在 temp file 裡替換為實際 worktree 路徑
     4. Phase 4 報告會列「已從 VS 複製 apphost.config」
else:
  → AskUserQuestion 三選一:
    (1) 暫停 setup,使用者執行下列步驟後重跑 /tp-setup:
          a. 打開 Visual Studio 並載入 .sln 一次
             (VS 會自動把 applicationhost.config 寫到 .vs/<sln>/config/ 目錄 — 那是 VS 內部目錄)
          b. 完成後重跑 /tp-setup
          c. setup 偵測到 .vs/<sln>/config/applicationhost.config 存在,
             複製到 .turbo-plugin/applicationhost.config(進 git 共享),
             並把每個 <site> 的 physicalPath 屬性替換為佔位符
             __TURBO_PLUGIN_PHYSICAL_PATH__
    (2) 在 .turbo-plugin/config.toml 寫 [iis] enabled = false,跳過 IIS skill
        (本機無 .NET Framework Web 開發需求時選 — 後續 tp-run / tp-stop /
         tp-build / tp-publish / tp-cleanup-orphan-iis 會直接 fail-loudly
         友善訊息,不啟動任何 IIS 邏輯)
    (3) 取消 setup
```

選項 (1):AskUserQuestion preview 要列「(無外部動作 — 只是請你開 VS 後重跑 setup)」。
選項 (2):AskUserQuestion preview 要列「(無外部動作 — 只是在 config.toml 寫入設定)」。
選項 (3):AskUserQuestion preview 要列「取消 setup,不做後續動作」。

(三選一都沒有「動到外部」的副作用,所以 preview 不列任何 SVN / install 動作。)

---

### Phase 3 — 環境配置

Phase 3 把使用者本機環境(工具路徑、Claude Code 開發體驗功能)一次補齊。流程串成 4 個小階段:

```
3.1 偵測(外部工具 + Claude Code 既有設定)
 ↓
3.2 列出(✓ 已啟用 / ✗ 尚未配置)+ Phase summary AskUserQuestion 繼續 / 取消
 ↓
3.3 Per-item AskUserQuestion(最多 4 題/batch;最壞情況 7 題 = 2 batches)
 ↓
3.4 執行寫入(tool paths → .turbo-plugin/config.local.toml;Claude Code features → settings.json + LSP server binary 自動安裝)
```

#### 3.1 偵測階段

跑下列偵測(每項各自獨立、失敗不阻塞,只記成「未配置」):

| 項目 | 偵測方式 | 用途 |
|---|---|---|
| **MSBuild** | call `Find-MSBuild` from `${CLAUDE_PLUGIN_ROOT}/scripts/lib/Common.ps1`;throw 視為「未配置」(會問) | tp-build / tp-publish 前置 |
| **IIS Express** | call `Find-IisExpressPath` from `${CLAUDE_PLUGIN_ROOT}/scripts/lib/IisHelpers.ps1`;throw 視為「未配置」(會問) | tp-run / tp-stop 前置 |
| **dotnet SDK** | `dotnet --version`(exit code 0 + 非空 stdout 視為 ✓) | C# LSP server (`csharp-ls`) 安裝前置條件 |
| **npm** | `npm --version`(exit code 0 + 非空 stdout 視為 ✓) | TS/JS LSP server (`typescript-language-server`) 安裝前置條件 |
| **docker** | `docker --version`(exit code 0 視為 ✓) | dbhub MCP server 前置(僅提示) |
| **svn** | `svn --version`(exit code 0 視為 ✓) | turbo-plugin core 必需;若 missing 在 Phase 4 報告中明寫補裝(此處不阻塞,Phase 1 應該已經提前驗證) |

跑完上述外部工具偵測後,讀 **Claude Code 既有設定**(三個 scope 都要讀,任一已啟用就視為「✓ 已啟用」、不再 prompt):

| Scope | 檔案路徑 |
|---|---|
| user-level | `~/.claude/settings.json`(展開 `$HOME` / `$env:USERPROFILE`) |
| project-level | `<repo>/.claude/settings.json` |
| local-level | `<repo>/.claude/settings.local.json` |

每個 scope 的檔案不存在當作 `{}`;存在就 JSON parse(失敗則記入 Phase 4 報告 + 視為 `{}` 不阻塞)。三個 scope **合併**(任一 scope 設了該 key 就視為已啟用)後,檢查以下 keys:

| 偵測 key(於合併後的設定) | 已啟用條件 | 對應 Phase 3 題目 |
|---|---|---|
| `enabledPlugins["csharp-lsp@claude-plugins-official"]` | `=== true` | C# LSP |
| `enabledPlugins["typescript-lsp@claude-plugins-official"]` | `=== true` | TS/JS LSP |
| `enabledPlugins["compound-engineering@compound-engineering-plugin"]` | `=== true` | compound-engineering |
| `env.ENABLE_LSP_TOOL` | `== "1"`(字串比對) | LSP tool 旗標(C# LSP 或 TS/JS LSP 啟用時會自動寫,單獨偵測只用於跳過 prompt) |
| `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `== "1"` | agent teams |
| top-level `tui` | `=== "fullscreen"` | TUI fullscreen |

**Tool Preference 提醒**:`settings.json` 讀取一律用 Read tool + 內建 JSON parse(不要用 PowerShell / Bash 做檔案 IO)。

#### 3.2 列出階段 + Phase summary AskUserQuestion

emit 兩張清單(平實白話、具體項目名稱):

```
Phase 3 — 環境配置

✓ 已啟用(會跳過,不重問):
  - <列出 3.1 偵測到的 ✓ 項目;每項標註偵測來源 scope,例如 "TUI fullscreen (user-level)" / "C# LSP (project-level)">
  (若全部都未啟用此區塊就寫「(無)」)

✗ 尚未配置(以下會問):
  - <列出 3.1 偵測到的 ✗ 項目;tool paths 標記「會寫進 .turbo-plugin/config.local.toml」、Claude Code features 標記「會寫進你選擇的 scope 的 settings.json」>
  (若全部都已啟用此區塊就寫「(無 — Phase 3 沒事做)」)
```

接著用 `AskUserQuestion` emit **Phase 3 summary question**:

- **Question text**:「準備開始 Phase 3 環境配置詢問。是否繼續?」
- **Options**(2 個):
  - **繼續** — 進入 3.3 per-item 詢問
  - **取消** — 跳過整個 Phase 3,直接進 Phase 4(會在 Phase 4 報告中標示「使用者跳過 Phase 3」)

若 3.1「✗ 尚未配置」清單為空(全部已啟用),**直接跳過此 AskUserQuestion**(以及 3.3 / 3.4),emit「Phase 3 沒事做(全部已啟用)」訊息後 fall through to Phase 4。

#### 3.3 Per-item AskUserQuestion batch

依「✗ 尚未配置」清單組裝 AskUserQuestion(最多 4 題/batch — 平台限制)。**Batch 分組順序固定**:

- **Batch 1**:tool paths + 兩個 LSP — `MSBuild path` / `IIS Express path` / `C# LSP` / `TS/JS LSP` 四題(視「✗ 尚未配置」實際出現項目挑選,跳過已啟用者)
- **Batch 2**:其它 Claude Code features — `compound-engineering` / `agent teams` / `TUI fullscreen` 三題(同上,跳過已啟用者)

若某 batch 沒有要問的題目就整個 batch 不發。

##### 3.3.A Tool paths 題目格式(MSBuild / IIS Express)

**2 options**(無 scope 概念,都寫 `.turbo-plugin/config.local.toml`):

| Option label | description |
|---|---|
| **跳過** | 不寫 `.turbo-plugin/config.local.toml` 的 `[tools]` `<key>`(後續呼叫 build / run / publish 等 SKILL 時,`Find-MSBuild` / `Find-IisExpressPath` 會再嘗試 standard install path 偵測 → 找不到則 throw 引導重跑 `/tp-setup`)。**無外部副作用**(此選項 preview 不列任何外部動作)。 |
| **輸入路徑** | 跳出 free-text follow-up question,問使用者「請貼上 `<工具>` 的絕對路徑(例如 `C:/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe`)」。**無外部副作用**(只動 repo 內 `.turbo-plugin/config.local.toml`)。 |

**Question text 範例(MSBuild)**:

> 偵測不到 MSBuild 路徑(`.turbo-plugin/config.local.toml [tools] msbuild_path` 未設,且機器上沒找到 VS 標準安裝)。是否現在輸入?
> 之後使用 `/tp-build-dotnet-framework-web` / `/tp-publish-dotnet-framework-web` 都會用到。

(IIS Express 題目同模式,只把工具名替換成「IIS Express」、key 替換成 `iis_express_path`、用途說明替換成「`/tp-run-dotnet-framework-web` / `/tp-stop-dotnet-framework-web` 都會用到」。)

**輸入路徑** 選項使用者貼上路徑後,**驗證**:
- 用 Read tool 確認 file 存在(`Test-Path -LiteralPath <path> -PathType Leaf` 的等價);**不存在** → emit 訊息「路徑指向的檔案不存在: `<path>`」,**重問**(同題目最多 1 次重試,再失敗則記入 Phase 4 「使用者仍須手動處理」並 fall through)
- 若使用者輸入 Git Bash 形式路徑(`/c/Users/...`),寫入前轉成 Windows 形式(`C:/Users/...`)— `tr '\\\\' '/'` 後將 leading `/c/` 轉成 `C:/`

##### 3.3.B Claude Code feature 題目格式(C# LSP / TS/JS LSP / agent teams / TUI fullscreen)

**4 options**(per-item scope choice;preview 列「動到外部」副作用):

| Option label | description / preview |
|---|---|
| **跳過** | 不啟用。**無外部副作用**。 |
| **user-level**(寫 `~/.claude/settings.json`) | 寫使用者全域設定,影響所有 Claude Code session(包括其它 repo)。**外部副作用**(依題目): C# LSP 題 → 「寫 `~/.claude/settings.json`(影響所有 Claude Code session) / Claude Code 啟動會從網路下載 `csharp-lsp@claude-plugins-official` plugin / 安裝 C# 語言伺服器 `csharp-ls` 到你的電腦(機器全域,不跟著專案走)」;TS/JS LSP 題 → 「寫 `~/.claude/settings.json` / Claude Code 下載 `typescript-lsp@claude-plugins-official` plugin / 安裝 `typescript-language-server` + `typescript` 到你的電腦」;agent teams 題 → 「寫 `~/.claude/settings.json` 的 `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`(影響所有 Claude Code session)」;TUI 題 → 「寫 `~/.claude/settings.json` 的 `tui = "fullscreen"`」 |
| **project-level**(寫 `<repo>/.claude/settings.json`) | 寫進 git 跟同事共享(commit 後其他人 clone 也會啟用)。**外部副作用** 同 user-level 描述,但「寫 `~/.claude/settings.json`」改成「寫 `<repo>/.claude/settings.json`(進 git,跨同事共享)」 |
| **local-level**(寫 `<repo>/.claude/settings.local.json`) | 只影響你本機,**不**進 git(`.gitignore` 已排除 `.claude/**/*.local.*`)。**外部副作用** 同 user-level 描述,但檔案改成 `<repo>/.claude/settings.local.json` |

**重要 preview 原則(R14/R15/R16)**:
- LSP 題:**列** plugin 下載 + binary 安裝(動到外部)
- agent teams / TUI 題:**只列** settings.json 寫入(視 scope 而定)— **不**列 plugin 下載 / binary 安裝(這兩個 feature 不涉及外部下載或安裝)
- **永遠不**列 `.turbo-plugin/config.local.toml` 的寫入(repo 內 file write,屬 internal — per R14)
- **永遠不**列 settings.json 寫入時的 JSON merge 動作(屬 internal implementation 細節)

##### 3.3.C compound-engineering 題目格式(特殊 — 3 options,scope 一律 user-level)

CE 與其它 Claude Code feature 不同:scope 一律 user-level(dev tool 通常 cross-project 共用),所以 4 options 換成「跳過 / 安裝(自動更新)/ 安裝(不自動更新)」三選一,把 autoUpdate dimension 占用一個 option slot。

| Option label | description / preview |
|---|---|
| **跳過** | 不啟用。**無外部副作用**。 |
| **安裝(自動更新)** | 寫 `~/.claude/settings.json` 的 `extraKnownMarketplaces["compound-engineering-plugin"]`(含 git URL `https://github.com/EveryInc/compound-engineering-plugin.git` + `autoUpdate: true`)+ `enabledPlugins["compound-engineering@compound-engineering-plugin"] = true`。**外部副作用**:「寫 `~/.claude/settings.json`(影響所有 Claude Code session) / Claude Code 啟動會自動從 GitHub fetch 最新版的 compound-engineering plugin(注意:GitHub repo 一旦被攻擊者 hijack,自動載入會有把惡意 code 拉進你電腦的風險)」 |
| **安裝(不自動更新)** | 同上但 `autoUpdate: false`。**外部副作用**:「寫 `~/.claude/settings.json` / Claude Code 啟動會從 GitHub fetch 一次 compound-engineering plugin;之後要更新時需手動跑 `/plugin update`」 |

**Question text 範例**:

> 是否啟用 `compound-engineering@compound-engineering-plugin`(第三方 plugin,提供 ce-brainstorm / ce-plan / ce-debug / ce-code-review 等 Claude Code 工具流程)?
> 啟用後寫進 `~/.claude/settings.json`(user-level),影響你所有 Claude Code session。

#### 3.4 執行寫入階段

依使用者在 3.3 的選擇依序執行寫入。**全部寫入都要 idempotent**(已有目標 key 直接覆寫該 key 的值,**不**破壞既有的其它 keys)。

##### 3.4.A Tool paths(MSBuild / IIS Express)→ `.turbo-plugin/config.local.toml`

若使用者選「輸入路徑」(且通過 file-existence 驗證):

- 目標檔案:`<repo>/.turbo-plugin/config.local.toml`
- 若檔案不存在 → 先建立空檔(無 header 即可,TOML reader 容許)
- 若 `[tools]` section 不存在 → append 該 section header `[tools]`
- 若該 key 已存在 → in-place 覆寫該 key 的 value
- 若該 key 不存在 → append `<key> = "<path>"` 到 `[tools]` section 底下

**Path format**:寫入時用 forward slash(`C:/Program Files/...`),便於跨 PS/Bash 解析。雙引號包夾(TOML basic string)。

**寫入後 emit 確認訊息**:「已寫入 `.turbo-plugin/config.local.toml` `[tools] <key>` = `<path>`」。

##### 3.4.B C# LSP / TS/JS LSP → 所選 scope 的 settings.json + 自動安裝 LSP server binary

依使用者所選 scope 鎖定目標檔案:

| Scope 選擇 | 目標檔案 |
|---|---|
| user-level | `~/.claude/settings.json` |
| project-level | `<repo>/.claude/settings.json` |
| local-level | `<repo>/.claude/settings.local.json` |

**JSON merge 規則**(用 Read + 內建 JSON parse + Write,**不**用 PowerShell / Bash 做 IO):
1. 若檔案不存在 → 視為 `{}`
2. JSON parse 既有內容(失敗 → 不覆寫,emit 錯誤 + 記入 Phase 4 報告失敗清單,跳過此項目寫入)
3. 確保 `enabledPlugins` 是 object(不存在則建立 `{}`),`env` 是 object(同上)
4. 寫入 / 覆寫:
   - C# LSP: `enabledPlugins["csharp-lsp@claude-plugins-official"] = true`
   - TS/JS LSP: `enabledPlugins["typescript-lsp@claude-plugins-official"] = true`
   - 兩個 LSP 任一啟用 → `env.ENABLE_LSP_TOOL = "1"`(idempotent — 兩個 LSP 都啟用時也只寫一次,不重複)
5. **注意**:`claude-plugins-official` 是 Claude Code 內建 marketplace,**不**寫 `extraKnownMarketplaces`
6. Write 回檔案時用 UTF-8 (no BOM) + 2-space indent + trailing newline(同 Claude Code settings.json 預設風格)
7. 既有其它 keys(例如使用者自訂的 `env.MY_PERSONAL_VAR` / 其它 `enabledPlugins` 條目 / 其它 top-level 設定) **必須** 完整保留

**寫入後執行 LSP server binary 自動安裝**(merged from old U7;binary 機器全域,**無** scope 概念):

```
if 使用者啟用了 C# LSP(不論選哪個 scope):
  if dotnet 偵測 ✓:
    執行 dotnet tool install -g csharp-ls(用 & dotnet tool install -g csharp-ls 形式呼叫,
    每個 arg 獨立、不字串拼接、不用 Invoke-Expression)
    capture exit code:
      0 → 記 Phase 4 報告「✓ 已安裝 C# LSP server (csharp-ls)」
      非 0 → 記 Phase 4 補裝清單,含 stderr 摘要 + 「可手動跑 `dotnet tool install -g csharp-ls` 補裝」
  else(dotnet 偵測 ✗):
    不執行安裝;記 Phase 4 補裝清單「C# LSP server (csharp-ls) 需要先裝 .NET SDK
    (https://dotnet.microsoft.com/download),裝好後手動跑 `dotnet tool install -g csharp-ls`」

if 使用者啟用了 TS/JS LSP(不論選哪個 scope):
  if npm 偵測 ✓:
    執行 npm install -g typescript-language-server typescript
    (& npm install -g typescript-language-server typescript 形式呼叫,同上)
    capture exit code:
      0 → 記 Phase 4 報告「✓ 已安裝 TS/JS LSP server (typescript-language-server)」
      非 0 → 記 Phase 4 補裝清單,含 stderr 摘要 + 「可手動跑 `npm install -g typescript-language-server typescript` 補裝」
  else(npm 偵測 ✗):
    不執行安裝;記 Phase 4 補裝清單「TS/JS LSP server 需要先裝 Node.js
    (https://nodejs.org/),裝好後手動跑 `npm install -g typescript-language-server typescript`」
```

**安裝失敗不阻塞 setup** — 繼續處理其它項目,失敗都集中在 Phase 4 報告。

##### 3.4.C compound-engineering → user-level settings.json(不論使用者 in 3.3.C 選哪個)

目標檔案固定 `~/.claude/settings.json`。JSON merge 規則同 3.4.B(讀 → parse → 確保 path 是 object → 寫入 → write back),寫入 keys:

```json
{
  "extraKnownMarketplaces": {
    "compound-engineering-plugin": {
      "source": {
        "source": "git",
        "url": "https://github.com/EveryInc/compound-engineering-plugin.git"
      },
      "autoUpdate": <true 或 false,依使用者選擇>
    }
  },
  "enabledPlugins": {
    "compound-engineering@compound-engineering-plugin": true
  }
}
```

**重要**:`extraKnownMarketplaces["compound-engineering-plugin"]` 整個物件覆寫(包含 `autoUpdate` 開關);使用者既有的其它 marketplace 條目(其它 keys 在 `extraKnownMarketplaces` 下)**必須**保留。

寫入後 emit 訊息:「已啟用 compound-engineering plugin(autoUpdate: <true/false>)。請重啟 Claude Code 後才會生效。」

##### 3.4.D agent teams → 所選 scope 的 settings.json

JSON merge 規則同 3.4.B,寫入:

- `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`(字串,**不**寫 boolean)

##### 3.4.E TUI fullscreen → 所選 scope 的 settings.json

JSON merge 規則同 3.4.B,寫入:

- top-level `tui = "fullscreen"`(top-level key,**不**在 `env` 下)

---

完成 3.4 所有寫入與安裝後 fall through to Phase 4。在 Phase 4 報告需包含:

- ✓ 已寫入位置清單(tool paths / settings.json 各 scope 各 key)
- ✓ LSP server binary 安裝成功 / 失敗 / 因 runtime 缺失而未嘗試 — 各分類列出
- ✓ 使用者仍須手動處理事項(runtime 缺失補裝指令 / 重啟 Claude Code 才會生效的設定)


---

### Phase 4 — 完成報告

報告:

- **偵測結果**:Phase 1 偵測到的 case + Phase 2 走的子流程
- **寫入位置清單**:新建 / 已存在 / 補設定 的項目(`.gitignore` / `.commitlintrc.json` / `CLAUDE.md` / `.turbo-plugin/*` / `applicationhost.config` 等)
- **apphost bootstrap 結果**:跳過(canonical 已存在)/ 已從 VS 複製(列出 physicalPath 佔位符替換動作)/ 使用者選 (1) 暫停 / 使用者選 (2) 寫 `[iis] enabled = false`
- **外部安裝成功 / 失敗清單**:Phase 3 觸發的安裝(LSP server binary 等)的成功與失敗結果
- **使用者仍須手動處理事項**:
  - `dbhub.local.toml` credentials(若 dbhub MCP 要用)
  - 缺失的 LSP server binary 補裝指令(若 Phase 3 偵測 dotnet / npm 缺,記入此清單;含官方下載連結 — .NET SDK https://dotnet.microsoft.com/download、Node.js https://nodejs.org/)
  - 其它使用者選擇延後處理的項目
- **若 Phase 3 寫入了任何 `~/.claude/settings.json` 變更**(plugin 啟用 / env / tui 等):
  > 請使用者**重啟 Claude Code 後才會生效**。重啟後:
  > - 跑 `/plugin list` 確認啟用的 plugin 都出現(verify schema 在當前版本被接受)
  > - 看 TUI 是否變全螢幕(若有啟用)
  > - LSP / agent teams 等 env 在新 session 才被讀取
- **下一步建議**:
  - case (a)/(b):「現在可執行 `/tp-pull-from-svn --branch main` 拉初次 SVN 內容」
  - case (c)/(d):「設定已就緒,可開始開發」

---

## Decision Rules

- **Case 偵測順序固定**(submodule → no .git → not main worktree → no .turbo-plugin → else),不要更改邏輯。
- **Case (a) 的 sub-step 7 內部順序 7a-7f 不可重排** — 7a `--no-checkout`、7e svn checkout、7d empty commit 都是 SVN obstruction 與後續 merge 的 load-bearing 步驟。
- **Case (a) `git init` 一律帶 `-b main`** — 預設分支必須與 `remote-svn/main` bridge 對齊,否則首推 branch mismatch。
- **Case (a) sub-step 8 / case (b) 的 connect merge 不可省** — orphan `remote-svn/main` 與 main 無共同祖先,不連接則首次 push / pull 撞 unrelated histories。
- **不自動代填使用者身分或設定** — 遇到缺漏的前置設定(git `user.name`/`user.email`、缺工具路徑等)一律**先 `AskUserQuestion` 詢問並提供建議**再執行;**絕不**拿 Claude 帳號 email、本機使用者名稱或任何臆測值代填。寫 git 身分一律 repo-local(不加 `--global`)。
- **初始 commit 前先列「將被 commit / 被忽略」兩清單並確認** — 避免把 `.vs`/`bin`/`obj` 等機器產物掃進版控;.gitignore 在 commit 前已含 .NET 產物區塊,使用者仍可補漏。
- **Case (c) 與 case (d) 必須 idempotent**:跑兩次的結果與跑一次相同,不重複追加 `CLAUDE.md` 區段、不覆寫已存在的 shared file。
- **`dbhub.local.toml` 永不自動建立**(避免使用者誤以為已 ready)。只 prompt 使用者複製 example 後手動編輯。
- 寫 `.commitlintrc.json` 用 JSON parse + array merge(`rules.type-enum[2]`),不要用 string 替換 — 使用者既有的其他 rules 必須保留。
- `CLAUDE.md` 用 marker `<!-- turbo-plugin:begin commit-type-convention -->` / `<!-- turbo-plugin:end commit-type-convention -->` 包夾 — 注入 / 更新 / 移除都以這對 marker 為錨。
- **不裝** husky、不裝 commit-msg hook、**不執行** `npm install` 或任何 npm 工具鏈(Phase 3 的 LSP server install 屬獨立決策,不在此規則範圍內)。`.commitlintrc.json` 純諮詢,enforce 由 `tp-push-to-svn` 自 parse 完成。
- Git Bash 路徑(`/c/Users/...`)若使用者輸入,寫進設定檔前轉成 Windows 格式(`C:/Users/...`)。
- **不寫 user-level env 給 turbo-plugin 自己的設定** — `msbuild_path` / `iis_express_path` 等 turbo-plugin 自有設定一律寫 `.turbo-plugin/config.local.toml` `[tools]` section(per repo-machine,gitignored)。Phase 3 寫 user-level `~/.claude/settings.json` 只用於 Claude Code 本身的設定(plugin 啟用 / env / tui 等)。
- **不**裝 .NET FW workload / SVN / Docker / VS / IIS Express 本身 — 這些是使用者本機環境責任;只 probe + 提示官方下載連結。
- **apphost bootstrap 只在 case (a)/(b)/(c) 觸發,case (d) 不執行** — canonical 在主 worktree,peer 直接讀(U3 runtime 跨 worktree 共享 canonical)。
- **apphost canonical 必須帶 physicalPath 佔位符** — 從 VS 複製 `.vs/<sln>/config/applicationhost.config` 到 `.turbo-plugin/applicationhost.config` 時必須把每個 `<site>` / `<application>` / `<virtualDirectory>` 的 `physicalPath` 屬性值替換為 `__TURBO_PLUGIN_PHYSICAL_PATH__`,避免機器-specific 絕對路徑進版控。runtime 由 `start-iis`(U3 已實作)在 temp file 裡替換為實際 worktree 路徑。
- **Phase summary transparency**(R14/R15/R16):只列「會動到外部」的 unconditional 動作。`.gitignore` / `CLAUDE.md` / `.turbo-plugin/*` / git 本地 op / template copy 等 internal repo-only 動作不列。Phase 3 視使用者選擇的外部動作由各 AskUserQuestion 選項 preview 自己列。措辭用平實白話 + 具體項目名稱,不用 raw shell 指令。
- **建議或執行任何修改前,先 `AskUserQuestion` 確認** — 尤其 case (b) 偵測 git-svn 的處置、SVN URL、apphost bootstrap 三選一、Phase 1 結尾 case override、Phase 3 各 per-item question。

## Completion Checks

- `.turbo-plugin/` marker 目錄存在,內含 `config.toml`、`applicationhost.config`、`conventions.md`、`dbhub.example.local.toml`(四件 git-versioned)。
- `.gitignore` 含 `turbo-plugin` 相關 patterns(`.claude/**/*.local.*` / `.turbo-plugin/**/*.local.*` / `.turbo-plugin/worktrees/` / `.svn/`)。
- `.commitlintrc.json` 含 `rules.type-enum[2]` ⊇ 12 類預設;`CLAUDE.md` 含 turbo-plugin convention 段(由 marker 包夾)。
- Case (a)/(b):`git branch -a` 含 `remote-svn/main`,`git worktree list` 含 `.turbo-plugin/worktrees/remote-svn-main`,該 worktree 內含 `.svn/`;主 worktree `git status --porcelain` 乾淨(`.turbo-plugin/worktrees/` 已 gitignore)。
- Case (a):`git rev-parse --abbrev-ref HEAD` = `main`(非 `master`);`git config user.name` 與 `user.email` 皆非空;初始 commit 的 `git show --stat HEAD` **不含** `.vs/` / `bin/` / `obj/`(已被 .gitignore 排除);`git merge-base main remote-svn/main` 非空(歷史已連接,首次 push/pull 不會撞 unrelated histories)。
- Case (a)/(b)/(c) apphost bootstrap 終態:
  - 走 canonical-already-exists 分支 → `.turbo-plugin/applicationhost.config` 內容未動
  - 走 from-VS 分支 → `.turbo-plugin/applicationhost.config` 存在,且 `physicalPath` 屬性 = `__TURBO_PLUGIN_PHYSICAL_PATH__`(grep 確認)
  - 走 user-pause 分支 → setup 已結束,留訊息「請開 VS 後重跑 `/tp-setup`」
  - 走 disable-iis 分支 → `.turbo-plugin/config.toml` 內有 `[iis] enabled = false`
- Missing dependencies(MSBuild / IIS Express / dotnet / npm 等)已在 Phase 3 prompt;若任何 LSP server install 失敗,Phase 4 報告含補裝指令。
- Case (d):未動到任何 git-versioned shared file(`.gitignore` / `.commitlintrc.json` / `CLAUDE.md` / `.turbo-plugin/config.toml` / `.turbo-plugin/conventions.md` / `.turbo-plugin/applicationhost.config` / `.turbo-plugin/dbhub.example.local.toml` 全未變);`dbhub.local.toml` 已處理完畢。
- 跑兩次 `/tp-setup` case (c) / (d):結果與跑一次相同(idempotent 驗證)。

## Test Scenarios

- **invoke-sessionstart.sh ERR trap**: 在 `scripts/hooks/invoke-sessionstart.sh` 的 trap 宣告之後暫時插入 `false` 一行,開新 Claude session。確認 (a) session 正常啟動沒 block、(b) stderr 沒漏出 trap 之外的錯誤訊息(`{}` 是預期 fallback)、(c) 沒 systemMessage prompt 出現。驗完拔掉 `false`。

## Tool Preference

所有檔案 read / write / search / edit 優先使用 Read / Write / Edit / Glob / Grep / LSP tool,避開 Bash / PowerShell / Python / Node.js 做檔案操作。呼叫 subagent 時也要傳遞此規則。

shell 操作只限:`git` / `svn` / 跑 `tp-setup` plugin script(`${CLAUDE_PLUGIN_ROOT}/scripts/...`)、`Get-Command` 等 probe 指令。
