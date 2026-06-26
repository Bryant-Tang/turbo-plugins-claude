---
name: tp-setup
description: '設定 turbo-plugin-git-svn 環境(git↔SVN bridge)。使用者明確要求 setup 時執行;agent 偵測到 .turbo-plugin/ marker 不存在 / SessionStart 提示需 setup 時可建議使用者執行,**不要自動觸發**。先跑共用 base 段(建 .turbo-plugin/ + concern-neutral 共用檔),再做 git↔SVN bridge bootstrap。涵蓋四個 case:(a) 新建 git+SVN / (b) 接管既有 git+SVN / (c) 主 worktree 補設定 / (d) peer worktree。'
argument-hint: 'optional: --svn-url <url>'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup（turbo-plugin-git-svn）

## Purpose

`turbo-plugin-git-svn` 的設定入口。流程兩層:

1. **共用 base 段**(concern-neutral):pre-check + case 偵測 + 建 `.turbo-plugin/` 與共用檔骨架。見
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md`,**先讀並執行該檔**。
2. **git-svn concern 段**(本檔):git↔SVN bridge bootstrap、`[svn]` 設定、
   `.gitignore` 的 git-svn 區塊。

> 本 plugin **不**處理 IIS apphost(屬 `turbo-plugin-dotnet-framework-web`)、dbhub(屬
> `turbo-plugin-three-environment-db`)。那些 plugin 各有自己的 `tp-setup`,共用同一份 base 段、
> 各寫自己的標記區塊,彼此不覆蓋。

各 case 觸發條件與 git-svn 動作:

| Case | 觸發條件 | git-svn 動作 |
|---|---|---|
| (a) 新建 | `.git/` 不存在 | base 骨架 → `git init -b main` → git-svn ignore/設定 → 確認身分後初始 commit → SVN URL → `remote-svn/main` orphan + worktree + svn checkout + 固定 `svn:ignore=.git` → 連接 main↔remote-svn/main 歷史 |
| (b) init-from-existing | `.git/` 存在 + `.turbo-plugin/` 不存在 | 警告 git-svn 不相容 → base 骨架 + git-svn 設定 → SVN URL → bridge + svn checkout → `git merge --allow-unrelated-histories` 合 SVN content |
| (c) 主 worktree 補設定 | `.turbo-plugin/` 存在 + 在主 worktree | idempotent 補 base 骨架 + git-svn 標記區塊 / 缺檔 |
| (d) peer-mode | `.turbo-plugin/` 存在 + 在 peer worktree | git-svn 無 per-peer 檔,僅確認 marker 存在;實際無動作(dbhub per-peer 屬 db plugin) |

---

## Procedure

### Phase 1 — 偵測

#### 1.1 共用 base pre-check + case 偵測

讀並執行 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md` 的 **Pre-check** 與 **Case 偵測**
(Git ≥ 2.31、非 submodule;case (a)/(b)/(c)/(d) 優先序)。

#### 1.2 Encoding profile detect（檔名編碼可攜性,純資訊性）

跑編碼偵測 script(`${CLAUDE_PLUGIN_ROOT}/scripts/Test-EncodingSupport.ps1` / `${CLAUDE_PLUGIN_ROOT}/scripts/test-encoding-support.sh`,無參數),**依下方 Decision Rules 的「執行路由」選工具**:有 Git Bash 就用 **Bash 工具**跑 `.sh`(其 `-ExecutionPolicy Bypass` 包在 `ps1-delegate.sh` 內、不在 agent 下的指令上,故 auto mode 不會擋);無 Git Bash 才用 **PowerShell 工具**直接跑 `.ps1`。

> **重要**:`ARGV_SAFE_FOR_UNICODE=False` **不代表**本機中文檔名 SVN 操作會壞,**也不代表**檔名會以非可攜方式存進 SVN。
> 已實證(svn 1.14 + PS5.1 + cp950,讀 FSFS revision bytes 確認):**凡系統 codepage 能表示的字元(例如 Big5 內的繁中
> 檔名),svn 會存成可攜 UTF-8,Mac/Linux(UTF-8)checkout 看到的是正確檔名。** push/pull 腳本已正確處理(`.ps1` 把
> `[Console]::OutputEncoding` 設系統 ANSI codepage 包住 svn,argv 對齊 svn locale → svn 正確 ANSI→UTF-8;`.sh` 用
> `svn status --xml`,恆為 UTF-8)。
>
> 此 flag 真正的意義:PS5.1 + 非-UTF-8 codepage 下,native-exe 的 argv **只能承載你 codepage 表示得了的字元**。檔名若含
> **超出該 codepage 的字元**(如繁中 cp950 系統上的日文假名 / CJK 擴充字 / emoji),根本傳不進 svn、會被降成 `?` 遺失——
> 而且這是**本機就壞**,不是只壞在跨平台。修法(PS7 / Win10 UTF-8)**只在你需要用超出系統 codepage 的字元時**才需要。

parse stdout 的 `ARGV_SAFE_FOR_UNICODE`:
- `True` → 略過。
- `False` → **本機與跨平台對「codepage 內的檔名」都無虞**;只有「要用超出系統 codepage 的字元當檔名」才需處理。用 `AskUserQuestion` 問**實際情境**(不用技術術語):

  **Question text**(對新使用者**直接講限制**就好——不要鋪陳「你本來沒問題」這種他根本不知道存在的問題):
  > 小提醒:在你目前的環境(Windows 中文版 + PowerShell 5.1)下,**SVN 檔名不能用「中文以外」的特殊文字**——例如日文假名、韓文、emoji(一般中文與英數字檔名不受影響)。你之後會需要用這類文字當**檔名**嗎?

  | 選項 | 動作 |
  |---|---|
  | (a) 不會(只用中文 / 英數 / ASCII 檔名)— 預設、絕大多數情況 | 在 `.turbo-plugin/encoding-status.local.md` 記「codepage-representable + ASCII filenames only;push/pull 本機正確處理;SVN 存可攜 UTF-8;無需額外設定」。**不寫**任何 routing/force_bash。 |
  | (b) 會用到中文以外的特殊文字(日文 / 韓文 / emoji 等) | nested `AskUserQuestion` 二選一:**(b1) 裝 PowerShell 7+**(`winget install --id Microsoft.PowerShell --silent ...`;winget 缺則導向 https://aka.ms/powershell;裝後在 `.claude/settings.local.json` 寫 `{"env":{"TURBO_PLUGIN_SHELL_HINT":"pwsh"}}`、請使用者改用 pwsh.exe 重啟)。**(b2) 開 Windows UTF-8 設定**(`Start-Process intl.cpl -Verb RunAs`,引導勾「Beta:UTF-8」後重開機)。 |

  純資訊性、不阻塞;完成印一句確認後繼續。

#### 1.3 Phase summary + override

依 base 段「Case 偵測」的 Phase summary 規則:平實白話報告偵測到的 case + 高階步驟,用 `AskUserQuestion`
讓使用者「執行偵測到的 case / 改執行其他 case / 取消」。**只列「會動到外部」**的 unconditional 動作:
- case (a)/(b):從 SVN 伺服器抓取專案內容(`svn checkout <url>`)
- case (a):設定固定 `svn:ignore=.git` 並 commit 到 SVN 伺服器
- case (b):將 SVN 內容合進當前 git branch(merge commit 留本地,**不**自動 push)

`.gitignore` / `CLAUDE.md` / `.turbo-plugin/` 寫入、git 本地 op、template copy、
AskUserQuestion 本身、檔案讀取/probe **不列**。

---

### Phase 2 — base 骨架 + git-svn concern

先依 base 段「Base 檔骨架」建立 concern-neutral 共用檔(`.turbo-plugin/` 目錄、`config.toml` 殼、
`.gitignore` base 區塊、`CLAUDE.md` base 區塊),再依 case 做下列 git-svn 動作。

#### 2(a). Case (a) — 新建 git+SVN

**順序敏感,以下不可重排**(SVN obstruction 避免 +「先 ignore 再 commit」+ 歷史連接):

1. `git init -b main`。**明確 `-b main`** — 與稍後 `remote-svn/main` bridge 對齊;裸 `git init` 多落在
   `master`,會使首次 `/tp-push-to-svn` branch mismatch。Git ≥ 2.31 已於 Pre-check 驗證。

2. **base 骨架**(見 base 段):寫 `.gitignore` base(`.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*`)、
   建 `.turbo-plugin/`、複製 `config.toml` 殼、注入 `CLAUDE.md` base 區塊。
   **此步必須先於 sub-step 5 的初始 commit 與 sub-step 7 的 `git worktree add`**。

3. **git-svn 的 `.gitignore` 追加**(idempotent,缺則加):
   ```
   .turbo-plugin/worktrees/
   .svn/
   ```
   - `.turbo-plugin/worktrees/`:nested bridge worktree 容器不污染主 worktree `git status`。
   - `.svn/`:讓 git 忽略 bridge worktree 內的 SVN 管理目錄。
   - > 注意:.NET 產物(`.vs/` / `bin/` / `obj/` / `packages/`)的 ignore 屬 **dotnet** plugin。若這是 .NET
     > 專案,請也裝 `turbo-plugin-dotnet-framework-web` 並跑其 setup;或在 sub-step 5 初始 commit 的「將被
     > commit」清單確認時自行補上這些 pattern(該確認步驟是把 .NET 機器產物擋在版控外的後盾)。

4. **git-svn 設定與檔案**:
   - `.turbo-plugin/config.toml` 的 `git-svn` 標記區塊:確保含 `[svn]` section(目前無必填 key,保留空 section
     供未來 svn 行為設定)。用 base 段「更新自己區塊」程序,只動 `# >>> turbo-plugin:git-svn >>>` 區塊。

5. **初始 commit(commit 前先確認)**。main 需至少一個 commit,sub-step 7 的 `git worktree add` 才有 HEAD 可依附:
   - **先確認 git 提交身分**:`git config user.name` / `user.email`(local+global 合併)。任一為空 →
     **不自動代填**(尤其**不得**用 Claude 帳號 email / 本機使用者名稱);用 `AskUserQuestion` 請使用者輸入
     (寫 **repo-local**,**不加 `--global`),或「先自行 `git config` 後重跑」/「取消」。
   - **列兩份清單**(dry-run,先不 stage):**將被 commit** = `git add -An`;**被 ignore** =
     `git status --ignored --porcelain` 取 `!!`。(不要混用 `git status --porcelain`。)
   - `AskUserQuestion` 確認:「確認建立初始 commit」/「先補 `.gitignore`(free-text 收 pattern,idempotent 加,
     重列再問)」/「取消」。
   - 確認後**分兩步**(禁 `&&` 串接 state-changing git):先 `git add -A`,再
     `git commit -m "chore: initial commit (turbo-plugin setup)"`。
   - 邊界:`git add -A` 後 index 為空(`git diff --cached --quiet` exit 0)→ `git commit --allow-empty`。

6. `AskUserQuestion`(自由文字)收 **SVN URL**(若 argument 沒帶 `--svn-url`)。空 / 格式不對(非 http(s)/svn/file)→ 重問或取消。

7. **建 `remote-svn/main` orphan branch + worktree**(7a-7g 不可重排;前提:sub-step 2/3 已把
   `.turbo-plugin/worktrees/` 寫進 `.gitignore`、sub-step 5 已建初始 commit):
   - 7a. `git worktree add --detach --no-checkout ".turbo-plugin/worktrees/remote-svn-main"`(`--no-checkout` 確保 dir 空,svn checkout 不被 obstruct)
   - 7b. cd 進新 worktree
   - 7c. `git checkout --orphan remote-svn/main`
   - 7d. `git rm -rf --cached .` 然後 `git commit --allow-empty -m "init: remote-svn/main branch"`
   - 7e. `svn checkout <url> .`
   - 7f. 設定**固定** `svn:ignore=.git`:`svn propset svn:ignore '.git' .`(`.git` 是唯一無法靠 push 腳本
     `git check-ignore` 過濾的 must-exclude 路徑;其餘排除項由 `.gitignore` 涵蓋,不寫進 svn:ignore)。
   - 7g. **commit 該屬性**:`svn commit -m "svn:ignore=.git (turbo-plugin bridge)"`。此為 case (a) 唯一的
     svn commit;7f propset 與 7g commit 分兩步(禁 `&&`)。

   **Step 7 rollback**(7e 失敗時):`git worktree remove --force .turbo-plugin/worktrees/remote-svn-main` →
   `git branch -D remote-svn/main` → 確認清理後重跑 `/tp-setup`。

8. **連接 main ↔ remote-svn/main 歷史**。`remote-svn/main` 為 orphan,與 main 無共同祖先;不連接則首次
   push/pull 撞 `refusing to merge unrelated histories`。**`<main-worktree>` = sub-step 1 `git init` 的專案根**;
   sub-step 7b 已 cd 進 bridge worktree,故**務必用 `git -C <main-worktree>`**:

   `git -C <main-worktree> merge --allow-unrelated-histories -m "chore: connect SVN bridge via turbo-plugin" remote-svn/main`

> **case (a) 中途取消/失敗的復原**:sub-step 2/3 後 `.turbo-plugin/` 已建。若在 sub-step 5/8 取消後直接重跑,
> case 偵測會因 `.turbo-plugin/` 已存在判成 **case (c)**,**不會**補做 `git init` / 初始 commit / 連接歷史。
> 要乾淨重跑 case (a):先移除 `.turbo-plugin/`(及已建的 `remote-svn/main` branch 與 worktree)再重跑。

完成後 fall through to Phase 4。

#### 2(b). Case (b) — 接管既有 git+SVN

1. 檢查 `git config --get svn-remote.svn.url`。非空 → 警告「偵測到 git-svn 設定(`<url>`)。turbo-plugin 不相容
   git-svn,請手動移除:`git config --unset-all svn-remote.svn.url` + 移除 `.git/svn/`」。`AskUserQuestion`:已移除 / 取消。
2. 跑 base 骨架(`.gitignore` base、`.turbo-plugin/`、`config.toml` 殼、`CLAUDE.md` base)
   + case (a) sub-step 3(git-svn `.gitignore` 追加)、4(git-svn 設定)。**先依 sub-step 5
   的「git 提交身分」檢查**確認身分(case (b) 會建 merge commit;同樣**不自動代填**)。case (b) 已有歷史,**不跑**初始 commit。
3. 跑 case (a) sub-step 6-7(SVN URL + remote-svn/main bridge + svn checkout + 固定 svn:ignore),**外加**(即
   sub-step 8 在 case (b) 的對應做法,故不再另跑 8)`git merge --allow-unrelated-histories -m "chore: connect SVN
   via turbo-plugin (r<rev>)" remote-svn/main` 把 SVN content 合進當前主 branch。merge 衝突 → 列衝突檔提示手動解,
   **不自動 abort**。

完成後 fall through to Phase 4。

#### 2(c). Case (c) — 主 worktree 補設定（idempotent）

順序檢查並補建,每步 **idempotent**:
1. base 骨架缺項補建(`.turbo-plugin/` / `config.toml` 殼 / `.gitignore` base / `CLAUDE.md` base)— 已存在不覆寫。
2. `.gitignore` 缺 git-svn patterns(`.turbo-plugin/worktrees/`、`.svn/`)→ idempotent append。
3. `config.toml` 的 `git-svn` 區塊缺 `[svn]` → 補(只動自己標記區塊)。
4. `CLAUDE.md` base 區塊缺 → 注入(marker 比對,內容相同則 skip)。

> case (c) **不**處理 bridge bootstrap(那是 case (a)/(b));若主 worktree 尚無 `remote-svn/main` bridge 且
> 使用者要建,請改跑 case (a)/(b) 或用 `/tp-push-to-svn` 首推 bootstrap。

完成後 fall through to Phase 4。

#### 2(d). Case (d) — peer-mode

**前提**:當前非 main worktree,且 `.turbo-plugin/` marker **必須**存在。marker 不存在 → 拒跑,提示「請先在主
worktree 跑 `/tp-setup` 完成 bootstrap」。

git-svn **無 per-peer 專屬檔**(dbhub per-peer 設定屬 `turbo-plugin-three-environment-db`)。故 git-svn 在 peer-mode
**不做任何寫入**,只回報「git-svn 在 peer worktree 無需額外設定;若你用 dbhub,請在此 peer 跑 db plugin 的 `/tp-setup`」。
**不**碰任何 git-versioned shared file。

完成後 fall through to Phase 4。

---

### Phase 4 — 完成報告

- **偵測結果**:Phase 1 的 case + Phase 2 子流程。
- **寫入位置清單**:base 骨架(`.turbo-plugin/` / `config.toml` / `.gitignore` / `CLAUDE.md`)+
  git-svn 項目(`config.toml [svn]` / `.gitignore` git-svn patterns)各標「新建 / 已存在 / 補設定」。
- **bridge 結果**(case (a)/(b)):`remote-svn/main` branch + `.turbo-plugin/worktrees/remote-svn-main` worktree、
  svn checkout、固定 `svn:ignore=.git`、連接歷史。
- **使用者仍須手動處理**:
  - 若是 .NET Framework Web 專案 → 裝 `turbo-plugin-dotnet-framework-web` 並跑其 `/tp-setup`(IIS / build 設定)。
  - 若要用三環境 DB → 裝 `turbo-plugin-three-environment-db` 並跑其 `/tp-setup`(dbhub)。
- **下一步建議**:
  - case (a)/(b):「現在可執行 `/tp-pull-from-svn --branch main` 拉初次 SVN 內容」。
  - case (c)/(d):「設定已就緒」。

---

## Decision Rules

- **Case 偵測順序固定**(submodule → no .git → not main worktree → no .turbo-plugin → else),不要更改。
- **先跑共用 base 段、再做 git-svn concern** — base 只建 concern-neutral 共用檔骨架;bridge / `[svn]` /
  git-svn 標記區塊等屬 git-svn concern。
- **Case (a) 的 sub-step 7 內部順序 7a-7g 不可重排** — 7a `--no-checkout`、7e svn checkout、7d empty commit
  是 SVN obstruction 與後續 merge 的 load-bearing;7f propset + 7g commit 把固定 svn:ignore 固化,必在 7e 之後。
- **Case (a) `git init` 一律帶 `-b main`** — 否則首推 branch mismatch。
- **Case (a) sub-step 8 / case (b) 的 connect merge 不可省** — 否則首次 push/pull 撞 unrelated histories。
- **不自動代填使用者身分或設定** — git `user.name`/`user.email`、SVN URL 等缺漏一律先 `AskUserQuestion` 再做;
  **絕不**拿 Claude 帳號 email / 本機使用者名稱 / 臆測值代填。寫 git 身分一律 repo-local(不加 `--global`)。
- **初始 commit 前先列「將被 commit / 被忽略」兩清單並確認** — git-svn 的 `.gitignore` 不含 .NET 產物區塊
  (那是 dotnet plugin),此確認步驟是把機器產物擋在版控外的後盾;使用者可在此補 pattern。
- **Case (c)/(d) 必須 idempotent** — 跑兩次結果同跑一次,不重複追加標記區塊、不覆寫已存在 shared file。
- **標記區塊只動自己 concern 的** — config.toml 用 concern 標記、CLAUDE.md 用單一 `base` 區塊;git-svn 只寫
  config.toml 的 `git-svn`(及 CLAUDE.md 的 `base`,若 base 段未先建)區塊,不碰 dotnet 區塊或標記外內容。
- **turbo-plugin-git-svn 不管 commit type**:**不裝** husky / commit-msg hook、**不執行** npm 工具鏈、**不產生 `.commitlintrc.json`**;`tp-commit-msg` 只顧訊息語意品質(不驗證 / 不限制 type)、`tp-push-to-svn` 不依 type 過濾(push body 收所有非-merge subject)。
- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- Git Bash 路徑(`/c/Users/...`)若使用者輸入,寫進設定檔前轉成 Windows 格式(`C:/Users/...`)。
- **Phase summary transparency**:只列「會動到外部」的 unconditional 動作;repo-only 本地寫入 / git 本地 op /
  template copy 不列。措辭平實白話 + 具體項目名稱,不用 raw shell 指令。

## Completion Checks

- `.turbo-plugin/` 存在,內含 `config.toml`(含 `git-svn` 標記區塊內的 `[svn]`)。
- `.gitignore` 含 base(`.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*`)+ git-svn(`.turbo-plugin/worktrees/`、`.svn/`)patterns。
- `CLAUDE.md` 含 `base` 標記區塊。
- Case (a)/(b):`git branch -a` 含 `remote-svn/main`,`git worktree list` 含 `.turbo-plugin/worktrees/remote-svn-main`,
  該 worktree 內含 `.svn/`;主 worktree `git status --porcelain` 乾淨。
- Case (a):`git rev-parse --abbrev-ref HEAD` = `main`;`git config user.name`/`user.email` 皆非空;
  `git merge-base main remote-svn/main` 非空(歷史已連接)。
- Case (c)/(d):跑兩次結果同跑一次(idempotent)。
- Case (d):未動到任何 git-versioned shared file。

## Test Scenarios

- **base 骨架 idempotent**:乾淨 sandbox 跑 case (c) 兩次,`.turbo-plugin/` 內容與 `.gitignore` /
  `CLAUDE.md` 的標記區塊不重複、不變動。
- **標記區塊不互蓋**:在已有 dotnet 標記區塊的 `config.toml` 上跑 git-svn setup,只更新 git-svn 區塊,dotnet 區塊與標記外內容不變。
- **config reader 容忍 marker**:含 `# >>> turbo-plugin:* >>>` 註解行的 `config.toml` 由 `Read-TurboPluginConfig` /
  `read_turbo_plugin_config` 解析時,marker 行被略過、section/key 正常(見 `tests/unit/scripts/lib/common.test.*`)。
- **invoke-sessionstart.sh ERR trap**:在 `scripts/hooks/invoke-sessionstart.sh` trap 宣告後暫插 `false`,開新 session,
  確認 (a) 正常啟動、(b) stderr 無漏、(c) 無 systemMessage。驗完拔掉。

## Tool Preference

所有檔案 read / write / search / edit 優先用 Read / Write / Edit / Glob / Grep / LSP,避開 Bash / PowerShell / Python /
Node.js 做檔案操作。呼叫 subagent 時也傳遞此規則。shell 操作只限:`git` / `svn` / 跑 plugin script
(`${CLAUDE_PLUGIN_ROOT}/scripts/...`)、`Get-Command` 等 probe。
