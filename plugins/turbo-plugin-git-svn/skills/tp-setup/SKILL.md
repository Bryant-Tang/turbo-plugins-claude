---
name: tp-setup
description: '設定 turbo-plugin-git-svn 環境(git↔SVN bridge)。使用者明確要求 setup 時執行;agent 偵測到 .turbo-plugin/ marker 不存在 / SessionStart 提示需 setup 時可建議使用者執行,**不要自動觸發**。兩層:共用 base 段(.turbo-plugin/ + concern-neutral 共用檔)與 git↔SVN bridge bootstrap;case (a)/(b) 的 bridge bootstrap 由 Initialize-GitSvnBridge 腳本承接、base 骨架腳本後置。涵蓋四個 case:(a) 新建 git+SVN / (b) 接管既有 git+SVN / (c) 主 worktree 補設定 / (d) peer worktree。'
argument-hint: 'optional: --svn-url <url>'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-setup（turbo-plugin-git-svn）

## Purpose

`turbo-plugin-git-svn` 的設定入口。流程兩層:

1. **共用 base 段**(concern-neutral):pre-check + case 偵測(**先跑**)+ 共用檔骨架(`.turbo-plugin/` 等)。見
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md`,**先讀並執行該檔的 pre-check + case 偵測**;
   骨架建立**時機依 case 不同**:case (c)/(d) 即時建、**case (a)/(b) 在 bootstrap 腳本成功後才建**(見 Phase 2)。
2. **git-svn concern 段**(本檔):git↔SVN bridge bootstrap(case (a)/(b) 委派 `Initialize-GitSvnBridge` 腳本)、
   `[svn]` 設定、`.gitignore` 的 git-svn 區塊。

> 本 plugin **不**處理 IIS apphost(屬 `turbo-plugin-dotnet-framework-web`)、dbhub(屬
> `turbo-plugin-three-environment-db`)。那些 plugin 各有自己的 `tp-setup`,共用同一份 base 段、
> 各寫自己的標記區塊,彼此不覆蓋。

各 case 觸發條件與 git-svn 動作:

| Case | 觸發條件 | git-svn 動作 |
|---|---|---|
| (a) 新建 | `.git/` 不存在 | 收 SVN URL → 確認 → 呼叫 `Initialize-GitSvnBridge`(腳本做 `git init` → 身分檢查 → 空 commit → `remote-svn/main` orphan bridge + svn checkout + 固定 `svn:ignore=.git` → merge 進空 main)→ **腳本後**套 base 骨架 + git-svn 設定 |
| (b) init-from-existing | `.git/` 存在 + `.turbo-plugin/` 不存在 | 警告 git-svn 不相容 → 收 SVN URL → 確認 → 呼叫 `Initialize-GitSvnBridge`(同上,merge 進**既有**分支、可能衝突)→ 衝突則引導手動解 → **腳本後**套 base 骨架 + git-svn 設定 |
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

依 base 段「Case 偵測」的 Phase summary 規則:**平實白話**報告偵測到的**情境**(不是代號)+ 高階步驟,用
`AskUserQuestion` 讓使用者「照偵測到的情境執行 / 改用其他情境 / 取消」。**對使用者一律用白話描述情境,絕不把
「case (a)/(b)/(c)/(d)」這類內部代號丟給使用者**——使用者根本不知道那是什麼;各情境的白話說法見 base 段
「Phase summary + override」的對照表(如偵測 (a) 講「全新的專案資料夾,將建立版控並接上 SVN」)。
下列 `AskUserQuestion` 的選項標籤與「即將執行」描述都用白話,例如:
- 「照偵測結果執行(全新專案 → 建立 git+SVN bridge)」/「這其實是<其他情境的白話> → 改用那個」/「取消」。

**只列「會動到外部」**的 unconditional 動作,對使用者用白話呈現(下方括號內的 case 代號 / 指令僅供 agent 對照,
不要照唸給使用者;case (a)/(b) 皆由 `Initialize-GitSvnBridge` 腳本執行):
- (新建 / 接管)從 SVN 伺服器抓取專案內容(`svn checkout <url>`)
- (新建 / 接管)設定固定 `svn:ignore=.git` 並 commit 到 SVN 伺服器
- (接管既有 git)將 SVN 內容合進當前 git branch(merge commit 留本地,**不**自動 push)

`.gitignore` / `CLAUDE.md` / `.turbo-plugin/` 寫入、git 本地 op、template copy、
AskUserQuestion 本身、檔案讀取/probe **不列**。

---

### Phase 2 — base 骨架 + git-svn concern

**骨架時機依 case 不同**:
- **case (a)/(b)**:bridge bootstrap 由 `Initialize-GitSvnBridge` 腳本承接,腳本會把 SVN 內容 merge 進當前分支。
  base 骨架(`.turbo-plugin/` / `config.toml` 殼 / `.gitignore` base / `CLAUDE.md` base)與 git-svn 設定一律
  **在腳本成功後**才疊上(KTD1「空 main 先行 + 骨架後置」)——**不要**在呼叫腳本前先建骨架。
- **case (c)/(d)**:不跑 bootstrap,base 骨架在各自 case 段內依 base 段「Base 檔骨架」idempotent 建立(時機不變)。

#### 2(a). Case (a) — 新建 git+SVN

bridge bootstrap 的機械步驟(`git init` → 身分檢查 → 空 commit → orphan bridge + svn checkout + 固定
`svn:ignore=.git` → merge 進空 main)**全部交給 `Initialize-GitSvnBridge` 腳本**;agent 只留收 URL、收身分、
確認三件互動,base 骨架腳本後置。**不要**自己逐條下 git/svn 指令。

1. **收 SVN URL(前置)**。腳本需要 URL 才能跑,故在呼叫前先收:`AskUserQuestion`(自由文字)收 **SVN URL**
   (若 argument 已帶 `--svn-url` 則用它)。空 / 格式不對(非 http(s)/svn/file)→ 重問或取消。

2. **呼叫 bootstrap 腳本**(依下方 Decision Rules「執行路由」選 `.ps1` / `.sh`;PowerShell 一律單破折號參數
   `-SvnUrl`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Initialize-GitSvnBridge.ps1" -SvnUrl <url>
   ```
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/initialize-git-svn-bridge.sh" --svn-url <url>
   ```
   腳本內部(無需 agent 逐條下指令):`git init -b main`(idempotent、無需身分)→ 檢查 git 身分 →
   root-commit 分流(case (a) 無 root commit → 建空 commit)→ orphan bridge worktree + `git clean` 清空 →
   plain `svn checkout` → `svn rm --keep-local .git` → 確保 bridge `.gitignore` 含 `.svn/` → `git add -A`
   commit SVN 內容到 bridge → 固定 `svn propset svn:ignore=.git` + `svn commit` → `git merge
   --allow-unrelated-histories` 進空 main(零衝突)。中途失敗自動 rollback 本機 git 端(含 Windows `.svn` 唯讀檔
   清理);已執行的 `svn commit`(svn:ignore)為永久,乾淨重跑會吸收。

3. **身分未設(`TP_TOKEN:IDENTITY_REQUIRED`)→ 收身分後重呼叫**。腳本在 `git init` 後若偵測 git
   `user.name`/`user.email` 任一為空,印 `TP_TOKEN:IDENTITY_REQUIRED` 並非零 exit(此時 `.git` 已建、bridge 未建)。agent:
   - 用**固定模板** `AskUserQuestion`(自由文字)收 name / email。**不自動代填**(尤其**不得**用 Claude 帳號
     email / 本機使用者名稱)。
   - 寫 **repo-local**:`git config user.name <name>` 與 `git config user.email <email>`(**不加 `--global`**;
     此時腳本已 `git init`,`--local` 有 repo 可寫)。**分兩步、禁 `&&` 串接**。
   - **重新呼叫**同一支腳本(乾淨重跑:`git init` no-op、仍無 root commit → 走 case (a) arm、不會重複建 bridge)。

3b. **匯入歷史較深(`TP_TOKEN:GRANULARITY_REQUIRED count=<N> range=r<lo>:r<hi>`)→ 問粒度後重呼叫**。SVN URL
   的既有歷史**超過 5 個修訂**且未指定粒度時,腳本印此 token 並 **exit 0、零 commit、bridge 未建**(乾淨可重跑;
   身分階段在此之前,故此時身分已設)。agent:
   - 用 `AskUserQuestion` 以**白話**問使用者要怎麼匯入這些歷史,三選一、預設「一顆一顆保留」。**不得**把 token /
     `svn-revision` / 修訂號等內部語彙丟給使用者;用情境化描述(可用 `<N>` 個「更新紀錄」這類白話):
     - **一顆一顆保留(建議)**——每筆更新各成一顆 commit,歷史與 blame 最完整。
     - **壓成一顆**——只匯最新內容成一顆 commit(最快;適合歷史很深、不需逐筆歷史時)。
     - **指定一段逐筆、其餘壓一顆**——請使用者給一段範圍(落在腳本回報的可選範圍內),範圍內逐筆、範圍外壓一顆。
   - 依選擇**重新呼叫**同一支腳本並帶粒度參數(乾淨重跑;此時腳本走到粒度階段後直接匯入):
     - 一顆一顆:PowerShell `-Granularity per-revision` / bash `--granularity per-revision`
     - 壓成一顆:PowerShell `-Granularity squash` / bash `--granularity squash`
     - 指定範圍:PowerShell `-Granularity range -Range <lo>:<hi>` / bash `--granularity range --range <lo>:<hi>`
   - **≤5 個修訂**時腳本不發此 token(直接逐筆匯入),agent 無需處理。

4. **腳本成功後 → base 骨架後置**(疊在 merge 進來的 SVN 內容上,全 idempotent):
   - **順序硬性要求:先 append `.gitignore` 的 git-svn patterns(4b),才做任何 `git add`(4d)**。否則巢狀
     bridge worktree(`.turbo-plugin/worktrees/`)與其 `.svn/` 在 main 尚未被 ignore,`git add -A` 會誤把 `.svn`
     內容 stage 進 main。
   - 4a. **base 骨架**(見 base 段「Base 檔骨架」):建 `.turbo-plugin/`、複製 `config.toml` 殼、`.gitignore`
     base 區塊(`.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*`)、注入 `CLAUDE.md` base 區塊。
   - 4b. **git-svn `.gitignore` 追加**(idempotent,缺則加):
     ```
     .turbo-plugin/worktrees/
     .svn/
     ```
     - `.turbo-plugin/worktrees/`:nested bridge worktree 容器不污染主 worktree `git status`。
     - `.svn/`:讓 git 忽略 bridge worktree 內的 SVN 管理目錄。
   - 4c. **git-svn 設定**:`.turbo-plugin/config.toml` 的 `git-svn` 標記區塊確保含 `[svn]` section(目前無必填
     key,保留空 section 供未來 svn 行為設定)。用 base 段「更新自己區塊」程序,只動 `# >>> turbo-plugin:git-svn >>>` 區塊。
   - 4d. **commit 骨架**(分兩步、禁 `&&` 串接 state-changing git):先 `git add -A`(此時 4b 已 ignore 掉
     `.svn/` 與 worktree 容器),再 `git commit -m "chore: turbo-plugin git-svn setup (skeleton)"`。
     > .NET 產物(`.vs/` / `bin/` / `obj/` / `packages/`)的 ignore 屬 **dotnet** plugin。若這是 .NET 專案,請也裝
     > `turbo-plugin-dotnet-framework-web` 並跑其 setup;或在 4d `git add -A` 前先補上這些 pattern(這是把 .NET
     > 機器產物擋在版控外的後盾)。

> **case (a) 中途取消/失敗的復原**:腳本的 rollback 會清掉中途失敗留下的 bridge branch / worktree;唯一可能
> 殘留的是身分 throw 留下的 bare 空 `.git`(無 commit)。若使用者此時取消、之後直接重跑 `/tp-setup`,case 偵測
> 會因 `.git` 已存在判成 **case (b)**——但 case (b) 一樣呼叫本腳本,腳本偵測「無 root commit」會自走 case (a)
> arm(空 commit + merge 進空 main),仍能正確完成。要回到乾淨的 case (a) 偵測:先移除該 bare `.git` 再重跑。
> (4a 之後才建 `.turbo-plugin/`,故腳本未成功前不會殘留 `.turbo-plugin/`。)

完成後 fall through to Phase 4。

#### 2(b). Case (b) — 接管既有 git+SVN

case (b) 與 case (a) **共用同一支 `Initialize-GitSvnBridge` 腳本**;差別只在腳本偵測「**已有 root commit**」會走
case (b) arm(不建空 commit、用當前分支、merge 進**有內容**的分支可能衝突)。

1. **git-svn 不相容檢查**:`git config --get svn-remote.svn.url`。非空 → 警告「偵測到 git-svn 設定(`<url>`)。
   turbo-plugin 不相容 git-svn,請手動移除:`git config --unset-all svn-remote.svn.url` + 移除 `.git/svn/`」。
   `AskUserQuestion`:已移除 / 取消。
2. **收 SVN URL(前置)+ 呼叫 bootstrap 腳本**:同 case (a) sub-step 1-2(收 URL → 依執行路由呼叫
   `Initialize-GitSvnBridge`)。腳本偵測**已有 root commit** → case (b) arm:不建空 commit、用當前分支,bridge
   bootstrap 後 `git merge --allow-unrelated-histories` 把 SVN 內容合進**當前分支**。身分未設一樣回
   `TP_TOKEN:IDENTITY_REQUIRED` → 同 case (a) sub-step 3 固定模板收身分 + `git config --local` + 重呼叫。
   歷史 >5 修訂一樣回 `TP_TOKEN:GRANULARITY_REQUIRED` → 同 case (a) sub-step 3b 白話問粒度 + 帶粒度參數重呼叫。
3. **merge 衝突(`TP_TOKEN:MERGE_CONFLICT <files>`)→ agent 端收尾,不重呼叫腳本**。populated git × populated
   SVN 有重疊檔(`CLAUDE.md` 等)時腳本印 `TP_TOKEN:MERGE_CONFLICT` + 非零 exit,**bridge 已建成且刻意不
   rollback、merge 留在進行中**。agent:
   - **不**重呼叫 bootstrap 腳本(會撞「bridge 已存在」死路)。
   - 列出衝突檔(token 後的清單),引導使用者手動解衝突 + `git add` 已解檔 + `git commit` 完成該 merge
     (**不自動 abort**,同先前 case (b) 行為)。
   - merge commit 完成後,**由 agent 直接接 case (a) sub-step 4「base 骨架後置」收尾**(套 `.gitignore` /
     `CLAUDE.md` / config 並 commit)。
4. **腳本成功(merge 乾淨)→ base 骨架後置**:同 case (a) sub-step 4(疊在當前分支上,先 append `.gitignore`
   patterns 再 `git add`)。

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
  - case (a)/(b):「bridge 已連接、初次 SVN 內容已在當前分支;之後用 `/tp-pull-from-svn --branch main` 同步 SVN
    後續變更、`/tp-push-to-svn` 推送本機 commit」。
  - case (c)/(d):「設定已就緒」。

---

## Decision Rules

- **Case 偵測順序固定**(submodule → no .git → not main worktree → no .turbo-plugin → else),不要更改。
- **case (a)/(b) 的 bridge bootstrap 委派 `Initialize-GitSvnBridge` 腳本** — agent 不再逐條下 git/svn 指令;
  `git init -b main` / 身分 throw / 空 commit / orphan bridge + `git clean` + plain `svn checkout` / 固定
  `svn:ignore=.git` / `git merge --allow-unrelated-histories`(連接歷史、避免首推 unrelated histories)全在腳本內,
  rollback 含 Windows `.svn` 唯讀檔清理。
- **case (a)/(b) base 骨架腳本後置(KTD1)** — base 骨架 + git-svn 設定必在腳本成功後才疊上(腳本把 SVN 內容
  merge 進當前分支);**先 append `.gitignore` 的 git-svn patterns(`.turbo-plugin/worktrees/`、`.svn/`)才做任何
  `git add`**,否則巢狀 bridge worktree 的 `.svn/` 會被誤 stage 進 main。case (c)/(d) 不跑 bootstrap、骨架時機不變。
- **身分 throw 重呼叫迴圈(case (a)/(b))** — 腳本回 `TP_TOKEN:IDENTITY_REQUIRED` 時 agent 用固定模板收身分、
  `git config --local` 寫入(此時腳本已 `git init`,`--local` 可寫)、**重呼叫同一支腳本**(乾淨重跑、不重複建 bridge)。
- **粒度選擇重呼叫迴圈(case (a)/(b),>5 修訂首匯)** — 腳本回 `TP_TOKEN:GRANULARITY_REQUIRED count=<N> range=r<lo>:r<hi>`
  (exit 0、零 commit、bridge 未建)時,agent **白話**問粒度(一顆一顆/壓成一顆/指定範圍,預設一顆一顆;**不外洩** token /
  `svn-revision` / 修訂號給使用者),再帶 `-Granularity`/`--granularity`(+ 範圍時 `-Range`/`--range`)**重呼叫同一支腳本**。
  ≤5 修訂不發此 token。見 case (a) sub-step 3b。
- **case (b) `TP_TOKEN:MERGE_CONFLICT` 由 agent 端收尾、不重呼叫腳本** — bridge 已建成且不 rollback;agent 列衝突檔、
  引導手動解 + commit merge(不自動 abort),再直接接「base 骨架後置」收尾。盲目重呼叫腳本會撞「bridge 已存在」死路。
- **不自動代填使用者身分或設定** — git `user.name`/`user.email`、SVN URL 等缺漏一律先 `AskUserQuestion` 再做;
  **絕不**拿 Claude 帳號 email / 本機使用者名稱 / 臆測值代填。寫 git 身分一律 repo-local(不加 `--global`)。
- **骨架 commit 的 .NET 產物後盾** — git-svn 的 `.gitignore` 不含 .NET 產物區塊(那是 dotnet plugin);若是 .NET
  專案,在 case (a)/(b) sub-step 4d `git add -A` 前先補 `.vs/`/`bin/`/`obj/`/`packages/` pattern(或裝 dotnet
  plugin 跑其 setup),把機器產物擋在版控外。
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
  該 worktree 內含 `.svn/`;**腳本後置的 base 骨架已 commit**,故主 worktree `git status --porcelain` 乾淨。
- Case (a):`git rev-parse --abbrev-ref HEAD` = `main`;`git config user.name`/`user.email` 皆非空;
  `git merge-base main remote-svn/main` 非空(歷史已連接)。
- Case (b):`git config user.name`/`user.email` 皆非空;當前分支與 `remote-svn/main` 的 `git merge-base` 非空
  (SVN 內容已併入);若 merge 曾衝突,須使用者先手動解完 + `git commit` 後 agent 才接骨架收尾。
- Case (c)/(d):跑兩次結果同跑一次(idempotent)。
- Case (d):未動到任何 git-versioned shared file。

## Test Scenarios

- **case (a)/(b) bridge bootstrap**:由 `Initialize-GitSvnBridge` 腳本的兩層自動測試覆蓋(case a/b × 空/非空
  SVN、身分 throw 重呼叫、MERGE_CONFLICT 回報、rollback;見 `tests/unit/scripts/Initialize-GitSvnBridge.test.*`);
  SKILL 端的編排(收 URL/身分重呼叫/骨架後置/衝突收尾)為 agent-prose,以一次真實 `/tp-setup` case (a)(空與非空
  SVN)+ 一次 case (b)人工驗證為準。
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
