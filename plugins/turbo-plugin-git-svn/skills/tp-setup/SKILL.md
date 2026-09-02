---
name: tp-setup
description: 'Set up turbo-plugin-git-svn (the git<->SVN bridge). Run on explicit request; you may SUGGEST it when `.turbo-plugin/` is missing, but **do NOT auto-trigger**. Covers four cases: new git+SVN, taking over an existing repo, adding config to the main worktree, and peer worktrees.'
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

> 本 plugin **不**處理 IIS apphost(屬 `turbo-plugin-dotnet-framework`)、dbhub(屬
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

#### 1.0 確定要對哪個 repo 動手（**最先做,先於 case 偵測**）

讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`,依它的判準決定要不要帶 `-RepoRoot` / `--repo-root`。
單一專案的目錄不用帶(維持既有行為);當前目錄自己不是 repo 但底下並排著多個 repo 時**必須先問使用者是哪一個**再指名。
**決定後,本 SKILL 之後每一次呼叫腳本都要帶同一個值**——包含 `IDENTITY_REQUIRED` / `GRANULARITY_REQUIRED` /
`EXISTING_GIT_REMOTE` / `NESTED_GIT_REPOS` 的每一次重呼叫。目標中途變掉會把不同 repo 的狀態混在一起。

> **這一步在 setup 特別要緊**:這是唯一會**建立** repo 的指令。case 偵測本身就是看目標資料夾的內容
> (`.git/` 在不在、`.turbo-plugin/` 在不在),所以目標若一開始就搞錯,連 case 都會判錯。

#### 1.1 共用 base pre-check + case 偵測

讀並執行 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/setup-base.md` 的 **Pre-check** 與 **Case 偵測**
(Git ≥ 2.31、非 submodule;case (a)/(b)/(c)/(d) 優先序)。**偵測的對象是 1.0 決定的那個目標**,不是「你剛好站在哪」。

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

  **Question text ——「哪些字可以用」必須依偵測到的 codepage 渲染,不可假設主機語系。**

  先從 stdout 讀出 `ANSI_CODEPAGE=<name> (<cp>)`,用下表決定這台機器的檔名能用什麼字:

  | 偵測到的 codepage | 檔名可安全使用 | 會壞掉的 |
  |---|---|---|
  | `950` / `big5` | 英數 + **繁體中文** | 日文假名、韓文、簡體專用字、emoji |
  | `936` / `gb2312` / `gbk` | 英數 + **簡體中文** | 日文假名、韓文、繁體專用字、emoji |
  | `932` / `shift_jis` | 英數 + **日文** | 韓文、中文專用字、emoji |
  | `949` / `ks_c_5601` | 英數 + **韓文** | 日文假名、中文專用字、emoji |
  | `1252` / `windows-1252` | 英數 + **西歐字母**(é ü ñ 等) | **中文、日文、韓文、emoji 全部會壞** |
  | 其他 | 英數 + 該 codepage 涵蓋的語言文字 | 該 codepage 涵蓋不到的所有文字 |

  > **`windows-1252` 那一列不是邊角情況**:那是英文版 Windows 的預設,而台灣公司用英文版映像檔並不罕見。
  > 在那種機器上**中文檔名正是會壞的那一種**——2026-08-04 於 CI(GitHub Windows runner,windows-1252)
  > 實測:Big5 主機裝得下中文檔名,windows-1252 主機得到 `??????.txt`。
  > 所以**絕對不要**照搬「中文沒問題」這句話。講反了,使用者會把壞掉的檔名推上 SVN,而 SVN 的提交是永久的。

  依上表取「可安全使用」與「會壞」兩段文字填進下面的模板。**填進去的是那兩欄的白話內容本身**
  (例如「英數字與繁體中文」),不要把角括號、欄位名或 codepage 代號原封不動唸給使用者聽。
  對新使用者**直接講限制**就好——不要鋪陳「你本來沒問題」這種他根本不知道存在的問題:

  > 小提醒:在你目前的環境下,**SVN 檔名只能用 ⟨可安全使用⟩**;⟨會壞⟩ 這類文字傳給 svn 時會遺失。
  > 你之後會需要用這類文字當**檔名**嗎?

  | 選項 | 動作 |
  |---|---|
  | (a) 不會(只用 ⟨可安全使用⟩ 當檔名)— 預設、絕大多數情況 | 在 `.turbo-plugin/encoding-status.local.md` 記「codepage-representable + ASCII filenames only;push/pull 本機正確處理;SVN 存可攜 UTF-8;無需額外設定」,並**記下實際偵測到的 codepage**。**不寫**任何 routing/force_bash。 |
  | (b) 會用到 ⟨會壞⟩ 那類文字 | nested `AskUserQuestion` 二選一:**(b1) 裝 PowerShell 7+**(`winget install --id Microsoft.PowerShell --silent ...`;winget 缺則導向 https://aka.ms/powershell;裝後在 `.claude/settings.local.json` 寫 `{"env":{"TURBO_PLUGIN_SHELL_HINT":"pwsh"}}`、請使用者改用 pwsh.exe 重啟)。**(b2) 開 Windows UTF-8 設定**(`Start-Process intl.cpl -Verb RunAs`,引導勾「Beta:UTF-8」後重開機)。 |

  純資訊性、不阻塞;完成印一句確認後繼續。

#### 1.3 Phase summary + override

依 base 段「Case 偵測」的 Phase summary 規則:**平實白話**報告偵測到的**情境**(不是代號)+ 高階步驟,用
`AskUserQuestion` 讓使用者「照偵測到的情境執行 / 改用其他情境 / 取消」。**對使用者一律用白話描述情境,絕不把
「case (a)/(b)/(c)/(d)」這類內部代號丟給使用者**——使用者根本不知道那是什麼;各情境的白話說法見 base 段
「Phase summary + override」的對照表(如偵測 (a) 講「全新的專案資料夾,將建立版控並接上 SVN」)。
下列 `AskUserQuestion` 的選項標籤與「即將執行」描述都用白話,例如:
- 「照偵測結果執行(全新專案 → 建立 git+SVN bridge)」/「這其實是<其他情境的白話> → 改用那個」/「取消」。

**這個 summary 的第一行必須是要動的專案絕對路徑**(1.0 決定的目標,或不帶 `--repo-root` 時腳本實際會作用的那個
資料夾):`要動的專案:<絕對路徑>`。setup 會建立 repo、寫 SVN,而「目標資料夾本身完全合法、只是不是使用者想的那個」
這種錯沒有任何守門攔得住——只有把路徑攤出來給使用者看才擋得下。

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
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Initialize-GitSvnBridge.ps1" -SvnUrl <url> [-RepoRoot <path>]
   ```
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/initialize-git-svn-bridge.sh" --svn-url <url> [--repo-root <path>]
   ```
   (`--repo-root` 依 1.0 的決定帶或不帶,**之後每次重呼叫都要一致**。)
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
     `refs/tp/svn/<n>` / 修訂號等內部語彙丟給使用者;用情境化描述(可用 `<N>` 個「更新紀錄」這類白話):
     - **一顆一顆保留(建議)**——每筆更新各成一顆 commit,歷史與 blame 最完整。
     - **壓成一顆**——只匯最新內容成一顆 commit(最快;適合歷史很深、不需逐筆歷史時)。
     - **最近幾筆逐筆保留、更早的壓成一顆**——問使用者要保留**最近幾筆**(用序數,例如「最近 5 筆」),
       不是問修訂號。

   > **絕對不要把 token 裡的 `range=r<lo>:r<hi>` 原樣搬給使用者。** 那是版本庫全域的修訂號,而版本庫是
   > 多個專案共用的——**對單一路徑而言它是稀疏的**。實測看過這個組合:同一題裡主文寫「已經有 8 筆更新
   > 紀錄」、選項說明寫「可選範圍:第 15 到 27 號更新」,兩套數字對不起來,使用者只會困惑。
   > 使用者講「最近 N 筆」之後,**由你自己換算**成腳本要的修訂號:對那個 SVN URL 跑
   > `svn log -q --xml <url>`(XML 恆為 UTF-8)取得**這條路徑自己**的修訂清單,倒數第 N 筆的修訂號就是
   > `<lo>`,`<hi>` 用 token 給的上界。換算完才呼叫腳本。
   - 依選擇**重新呼叫**同一支腳本並帶粒度參數(乾淨重跑;此時腳本走到粒度階段後直接匯入):
     - 一顆一顆:PowerShell `-Granularity per-revision` / bash `--granularity per-revision`
     - 壓成一顆:PowerShell `-Granularity squash` / bash `--granularity squash`
     - 指定範圍:PowerShell `-Granularity range -Range <lo>:<hi>` / bash `--granularity range --range <lo>:<hi>`
   - **≤5 個修訂**時腳本不發此 token(直接逐筆匯入),agent 無需處理。
   - **粒度參數一律生效**:你明確帶 `-Granularity` / `--granularity` 時,不論修訂數多少腳本都會照辦
     (以前 ≤5 筆會把你傳的值丟掉、一律逐筆)。所以使用者若在少量修訂時主動說要壓成一顆,直接帶參數即可。

3b-2. **匯入期間 SVN 資料夾被改過名(`TP_TOKEN:SVN_PATH_RENAMED old=<url> new=<url> range=r<lo>:r<hi>`)**。
   **這不是錯誤、不需要任何處理**——腳本已自動跟著改名走完,逐筆歷史完整保留。但**要用白話提一句**,
   因為使用者會在匯入的歷史裡看到路徑變動,不講他會以為是自己 URL 給錯:

   > 這個專案在 SVN 上的資料夾中途改過名(<舊資料夾名> → <新資料夾名>),已經自動跟著處理,歷史完整帶進來了。

   只講**資料夾名**的變化就好,不要把整串 URL 或 token 原樣貼給使用者。

   > **匯入途中出現 `svn: E160005: Target path ... does not exist`,只要緊接著有
   > `Note: r<N> is not reachable at the current path; following the rename to ...`,那就不是失敗。**
   > 資料夾在匯入範圍**中途**改過名(甚至改走又改回來)時,腳本是刻意「先照常試,失敗了才去查那個修訂
   > 當時的位置」——沒改過名的專案因此一次多餘查詢都不用付。那行 E160005 是觸發修正的訊號,後面的
   > `At revision <N>.` 就是已經跨過去了。**不要**把這行 svn 錯誤轉述給使用者當成問題;整個匯入的成敗
   > 看最後有沒有 `SVN bridge connected.` 與腳本的離開碼。

3c. **目標專案已連著 git 遠端(`TP_TOKEN:EXISTING_GIT_REMOTE remotes=<names>`)→ 確認後才重呼叫**。腳本在**動任何
   東西之前**偵測到目標 repo 已設定 git remote 時印此 token 並非零 exit(**零變更、可乾淨重跑**)。這絕大多數
   情況代表**跑錯資料夾**——本 plugin 是給「只能用 SVN、沒有 git 伺服器」的專案用的。agent:
   - **先查資料夾對不對**:把腳本回報的路徑跟使用者當初指定的專案對照。不一致 → 換到正確資料夾重跑,
     **不要**直接放行旗標。
   - 確實要在這個專案建橋時,用 `AskUserQuestion` 以**白話**向使用者確認(**不得**把 token 名或旗標名丟給
     使用者),例如:「這個專案已經連著一個 git 遠端(`<names>`)。turbo-plugin 是設計給沒有 git 伺服器、
     只能靠 SVN 共用程式碼的專案。確定要在這個專案上建立 SVN 橋接嗎?」
   - 使用者確認後才**重新呼叫**同一支腳本並加旗標:PowerShell `-AllowExistingRemote` /
     bash `--allow-existing-remote`。

3d. **這裡不是 repo、但底下的子資料夾是(`TP_TOKEN:NESTED_GIT_REPOS dirs=<names>`)→ 先問是哪一個專案**。
   腳本在 `git init` **之前**偵測到「當前資料夾沒有 git、但直屬子目錄有」時印此 token 並非零 exit(零變更)。
   這是「多個獨立專案並排放在一個工作區資料夾底下」的形狀——在這裡 `git init` 會把它們全部包進同一個 repo,
   而且事後沒有東西能還原。agent:
   - **預設就是跑錯地方**:用 `AskUserQuestion` 白話問使用者要對**哪一個**子專案建橋(選項就用 token 帶回來
     的那幾個目錄名),然後用 `-RepoRoot` / `--repo-root` **指名該子專案**重呼叫,不要放行旗標。
     (用指名而不是 `cd`:指名留下明確紀錄、後續每次重呼叫都帶同一個值,也不會讓「當前目錄」跟其它工作互相干擾。)
   - 只有在使用者明確表示「這個資料夾本身就是一個專案,底下那些是它內含的第三方原始碼」時,才用
     `-AllowNestedRepos` / `--allow-nested-repos` 重呼叫。
   - **不得**把 token 名或旗標名丟給使用者。

3e. **SVN 那邊連不到(`TP_TOKEN:SVN_UNREACHABLE url=<url>`)→ 這是環境問題,不要自己想辦法繞**。
   腳本在**動任何東西之前**就停了(零變更、可乾淨重跑)。把 svn 自己給的原始訊息一起顯示給使用者,
   常見原因是 URL 打錯、VPN 沒開、伺服器沒起、或需要認證。修好之後重跑。

3f. **版本庫連得到、但這個路徑不存在(`TP_TOKEN:SVN_PATH_MISSING url=<url>`)→ 問要不要幫忙建**。
   一樣是零變更、可乾淨重跑。這個情況很常見:專案在版本庫裡的落腳點得先有人建出來,而本 plugin 的
   其它腳本一律不會自己建。agent:
   - 用 `AskUserQuestion` 以**白話**問兩件事(**不得**把 token 名丟給使用者),而且問句裡要**原樣寫出完整 URL**——
     URL 打錯時自動建會安靜地造出一個錯路徑,而 **SVN 上建出來的路徑是永久的,沒有真正的刪除**。
     1.「版本庫連得到,但裡面還沒有 `<url>` 這個位置。要幫你建嗎?」(**預設不建**;使用者也可能只是打錯字)
     2. 使用者要建、且 URL 是以 `/trunk` 結尾時,再問:「要不要一併建 `branches` 與 `tags`?」
        **這不是裝飾**:之後用本工具開分支是 `svn copy` 到 `branches/` 底下,而那個 `svn copy` 沒有帶
        `--parents`,`branches` 不存在就直接失敗。URL 不是以 `/trunk` 結尾時**不要問這題**(沒有明確的解讀)。
   - 使用者同意後跑建立腳本(它**只**做這件事,不會順手建別的):
     ```powershell
     powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/New-SvnPath.ps1" -SvnUrl <url> [-StandardLayout]
     ```
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/new-svn-path.sh" --svn-url <url> [--standard-layout]
     ```
   - 建好之後**重新呼叫** `Initialize-GitSvnBridge`,照常往下走。
   - 使用者選不建 → 乾淨結束,SVN 零寫入,告訴他可以自己建好之後再跑一次。

4. **腳本成功後 → base 骨架後置**(疊在 merge 進來的 SVN 內容上,全 idempotent):
   - **順序硬性要求:先 append `.gitignore` 的 git-svn patterns(4b),才做任何 `git add`(4d)**。否則巢狀
     bridge worktree(`.turbo-plugin/worktrees/`)與其 `.svn/` 在 main 尚未被 ignore,`git add -A` 會誤把 `.svn`
     內容 stage 進 main。
   - 4a. **base 骨架**(見 base 段「Base 檔骨架」):建 `.turbo-plugin/`、複製 `config.toml` 殼、`.gitignore`
     的 `base` 標記區塊、注入 `CLAUDE.md` base 區塊。**區塊的實際內容以 base 段第 3 項為準**,不要照抄
     這裡——寫兩份清單就會漂移,而漂移的那一份不會有人發現。
   - 4b. **git-svn `.gitignore` 區塊**(用 base 段「更新自己區塊」程序,只動 `git-svn` 標記區塊):
     ```
     # >>> turbo-plugin:git-svn >>>
     .turbo-plugin/worktrees/
     .svn/
     # <<< turbo-plugin:git-svn <<<
     ```
     - 標記的理由與 base 區塊完全相同(issue #65):沒有標記就沒辦法調和,日後多加一條規則時
       既有專案永遠拿不到。既有專案那兩行沒有標記 → **只在檔尾追加帶標記的新區塊,舊的留著**。
     - **這裡不要再問一次清理**:base 段第 3 項的舊區塊詢問已經把這兩行算進判定範圍(舊版把
       base 與 concern 的行寫在一起、中間沒有分隔),同一件事問兩次只會讓使用者困惑。
     - `.turbo-plugin/worktrees/`:nested bridge worktree 容器不污染主 worktree `git status`。
     - `.svn/`:讓 git 忽略 bridge worktree 內的 SVN 管理目錄。
   - 4c. **git-svn 設定**:`.turbo-plugin/config.toml` 的 `git-svn` 標記區塊確保含 `[svn]` section(目前無必填
     key,保留空 section 供未來 svn 行為設定)。用 base 段「更新自己區塊」程序,只動 `# >>> turbo-plugin:git-svn >>>` 區塊。
   - 4c-2. **產物 / 機密的 ignore 判斷(在 `git add -A` 之前)**:4b 只寫死 plugin 自造的基礎設施;
     **這個專案自己的**建置產物、本機設定與機密沒有固定清單,由你判斷。讀
     `${CLAUDE_PLUGIN_ROOT}/skills/tp-suggest-ignore/assets/ignore-rubric.md`,對照 `git -c core.quotePath=false status --short`
     裡 `??` 的東西逐項判斷,把該擋的 pattern append 進 `.gitignore`(不必單獨 commit,4d 會一起帶走)。
     - **時機不能往後挪**:4d 的 `git add -A` 會把當下沒被忽略的東西全部掃進第一顆 commit,之後再補
       `.gitignore` 也救不回來(已經在版控裡了,而且很可能已經推上 SVN)。
     - 有判不準的就**問使用者**,不要猜(§判準:「不確定就不要動」)。看到疑似機密要單獨、明確地講。
   - 4d. **commit 骨架**(分兩步、禁 `&&` 串接 state-changing git):先 `git add -A`(此時 4b/4c-2 已 ignore 掉
     `.svn/`、worktree 容器與這個專案的產物),再 `git commit -m "chore: turbo-plugin git-svn setup (skeleton)"`。

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
3b. **merge 失敗但**不是**衝突(`TP_TOKEN:MERGE_FAILED branch=<name>`)→ 不要說成衝突**。這個 token 只在
   `git merge` 非零退出、而衝突檔清單是**空的**時出現,代表 merge 是為了別的原因被拒(例如橋接分支還沒有
   任何 commit)。**不要**叫使用者去找衝突檔——一個都沒有。把 git 自己印在 stderr 的原文轉述給使用者,說明
   bridge 已建成、SVN 端的寫入是永久的,並詢問要怎麼處理;**不要**重呼叫 bootstrap 腳本。
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
  - 若是 .NET Framework Web 專案 → 裝 `turbo-plugin-dotnet-framework`。它**沒有 setup 指令**,直接
    `/tp-build-dotnet-framework` / `/tp-run-dotnet-framework` 即可(設定用到才建)。
  - 若要用三環境 DB → 裝 `turbo-plugin-three-environment-db` 並跑其 `/tp-setup`(dbhub)。
- **下一步建議**:
  - case (a)/(b):「bridge 已連接、初次 SVN 內容已在當前分支;之後用 `/tp-pull-from-svn --branch main` 同步 SVN
    後續變更、`/tp-push-to-svn` 推送本機 commit」。
  - case (c)/(d):「設定已就緒」。

### Phase 5 — 收尾:跑一次 ignore 檢查（case (a)/(b)/(c)，peer-mode 不跑）

報告完之後,**直接跑一次 `tp-suggest-ignore` 的 analysis mode**(不必問要不要跑,跑它本身沒有副作用——
它自己會在要動任何東西之前徵求同意)。理由:使用者不會知道有這個 skill,而「哪些東西不該進版控」正是
setup 之後、第一次 push 之前最該處理、也最容易被漏掉的一件事;推上 SVN 之後就是永久的。

- case (a)/(b):4c-2 已經在骨架 commit 前判斷過一輪,這一輪是安全網(抓「已經被追蹤、但不該追蹤」的東西)。
- case (c):這是**唯一**一次判斷(既有專案沒有骨架 commit 那個時機點),不要跳過。
- case (d) peer-mode:不跑(不碰任何 git-versioned shared file)。
- 它回報「沒有發現」是正常結果,照實轉述、不要加工。

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
  `refs/tp/svn/<n>` / 修訂號給使用者),再帶 `-Granularity`/`--granularity`(+ 範圍時 `-Range`/`--range`)**重呼叫同一支腳本**。
  ≤5 修訂不發此 token。見 case (a) sub-step 3b。
- **「連不到」與「路徑不存在」是兩件事,給的指引也不同** — 腳本前置檢查分兩段:先確認版本庫本身連得到,
  再確認這個路徑存在。連不到 → `TP_TOKEN:SVN_UNREACHABLE`(環境問題:URL 打錯 / VPN / 伺服器 / 認證)。
  連得到但路徑不存在 → `TP_TOKEN:SVN_PATH_MISSING`,agent **要問使用者要不要幫忙建**(見 sub-step 3f)。
  兩種都是零變更、可乾淨重跑,而且都要把 **svn 自己給的原始訊息**一起顯示——舊版把 stderr 吞掉、
  一律回「Is the URL reachable?」,在版本庫明明連得到時完全誤導。
- **建 SVN 路徑一定要問過,而且要把完整 URL 寫出來** — `svn mkdir` 只在 `New-SvnPath` 這一支裡,沒有任何
  其它腳本會隱含地建路徑。**SVN 上建出來的路徑是永久的**,URL 打錯時自動建會安靜地造出一個錯位置,
  所以預設不建、一定先問,且問句要原樣附上完整 URL 讓使用者核對。URL 以 `/trunk` 結尾時才另外問要不要
  一併建 `branches` / `tags`——那不是裝飾,開分支的 `svn copy` **沒有** `--parents`,`branches` 不存在就直接失敗。
- **目標明確指定優先於 cwd 推導** — 腳本收 `-RepoRoot` / `--repo-root`;**不帶**時才從 cwd 往上推導(既有行為)。
  Phase 1.0 決定要不要帶,決定後**每一次重呼叫都帶同一個值**。三道守門判的都是**指名的那個目標**(不是你站在哪):
  指到 linked worktree 一樣被①擋、指到並排工作區一樣被③擋。
- **跑錯資料夾的三道守門(bootstrap 腳本內建,三道都在動任何東西之前)** — 不帶 `--repo-root` 時 bootstrap 從
  **cwd** 往上推導要橋接哪個 repo,所以「在錯的資料夾呼叫」會安靜地把橋建到使用者沒指名的 repo 上。故腳本自帶:
  ① **不是主 worktree 就硬拒**(非零 exit;否則會在**另一個** checkout 建分支/worktree 並把 SVN 內容 merge 進
  **它**的當前分支)。case 偵測本就把 peer worktree 導向 (d),這道是給「繞過 SKILL 直接呼叫腳本」的保險。
  ② **目標 repo 已有 git remote → 回 `TP_TOKEN:EXISTING_GIT_REMOTE remotes=<names>`**(零變更)。agent **先核對
  資料夾是否為使用者指定的專案**,確認無誤再**白話**徵得同意(不外洩 token / 旗標名),才帶
  `-AllowExistingRemote` / `--allow-existing-remote` 重呼叫。見 case (a) sub-step 3c。
  ③ **這裡不是 repo、但直屬子目錄是 → 回 `TP_TOKEN:NESTED_GIT_REPOS dirs=<names>`**(零變更)。①② 擋不到這種
  情況,因為這個資料夾**真的**沒有 git,而 `git rev-parse` 只往上找不往下找。這是「多個獨立專案並排」的工作區
  形狀,在這裡 `git init` 會把它們全包成一個 repo 且事後無法還原。預設當成跑錯地方,問清楚是哪個子專案後用
  `-RepoRoot` / `--repo-root` **指名它**重呼叫;`-AllowNestedRepos` / `--allow-nested-repos` 只留給「這資料夾
  本身就是專案、底下是內含的第三方原始碼」。
- **會寫入的操作要先把目標講出來** — Phase 1.3 的 summary 第一行是 `要動的專案:<絕對路徑>`。這道不是守門能取代的:
  當前目錄**是**一個合法 repo、只是不是使用者想的那個時,三道守門一個都不會響。判準見
  `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`。
  見 case (a) sub-step 3d。
- **case (b) `TP_TOKEN:MERGE_CONFLICT` 由 agent 端收尾、不重呼叫腳本** — bridge 已建成且不 rollback;agent 列衝突檔、
  引導手動解 + commit merge(不自動 abort),再直接接「base 骨架後置」收尾。盲目重呼叫腳本會撞「bridge 已存在」死路。
- **不自動代填使用者身分或設定** — git `user.name`/`user.email`、SVN URL 等缺漏一律先 `AskUserQuestion` 再做;
  **絕不**拿 Claude 帳號 email / 本機使用者名稱 / 臆測值代填。寫 git 身分一律 repo-local(不加 `--global`)。
- **兩類 ignore、責任不同** — 4b 寫死的只有 **plugin 自造的基礎設施**(`.turbo-plugin/worktrees/`、`.svn/`,
  加上 base 的兩條 `*.local.*` 與那條 `!*.example.local.*` 放行):形狀固定、且必須在任何 `git add` 之前就位。**這個專案自己的**建置產物 /
  本機設定 / 機密**沒有寫死清單**,由 agent 依 `skills/tp-suggest-ignore/assets/ignore-rubric.md` 的判準,
  在 4c-2(仍在 `git add -A` 之前)逐項判斷後 append。寫死清單只會同時漏掉這個專案真正的產物、又硬塞
  不適用的項目;而時機不能往後挪,因為第一顆 commit 掃進去的東西補 `.gitignore` 也拿不掉。
- **setup 收尾一定跑一次 ignore 檢查(Phase 5,peer-mode 除外)** — 不要只在報告裡「建議使用者去跑」。
  使用者不會知道有這個 skill;而 SVN 一旦提交就是永久的,這件事值得主動做。case (c) 尤其不能跳過——
  既有專案沒有骨架 commit 那個判斷時機,這是唯一一次。
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
- `.gitignore` 含 `base` 與 `git-svn` 兩組標記區塊,內容分別與 base 段第 3 項、上面 4b 一致;
  **各只有一組**(重跑沒有長出第二組)。
- `git check-ignore` 對 `*.example.local.*` 範本回非零(**不**被忽略),對真正的 `*.local.*` 回零(被忽略)。
- `CLAUDE.md` 含 `base` 標記區塊,且區塊開頭有「這中間由 turbo-plugin 產生、重跑會整段取代」那段自我說明。
- **base 區塊裡沒有「這件事該寫在哪」那張表**——它屬於 `turbo-plugin-knowledge-placement`,由該 plugin
  自己的標記區塊維護。這裡出現一份就是兩個來源,而其中一個永遠不會被更新。
- 專案根若存在未被追蹤的 `TODO.md`,**使用者已被明確告知它不再被 base 區塊忽略**,以及可以怎麼處理
  (自己在標記外加 ignore,或把內容搬進記憶並用 `/tp-export-handover` 交接)。
- Case (a)/(b):`git branch -a` 含 `remote-svn/main`,`git worktree list` 含 `.turbo-plugin/worktrees/remote-svn-main`,
  該 worktree 內含 `.svn/`;**腳本後置的 base 骨架已 commit**,故主 worktree `git status --porcelain` 乾淨。
- Case (a):`git rev-parse --abbrev-ref HEAD` = `main`;`git config user.name`/`user.email` 皆非空;
  `git merge-base main remote-svn/main` 非空(歷史已連接)。
- Case (b):`git config user.name`/`user.email` 皆非空;當前分支與 `remote-svn/main` 的 `git merge-base` 非空
  (SVN 內容已併入);若 merge 曾衝突,須使用者先手動解完 + `git commit` 後 agent 才接骨架收尾。
- Case (c)/(d):跑兩次結果同跑一次(idempotent)。
- Case (d):未動到任何 git-versioned shared file。
- Case (a)/(b)/(c):流程結尾跑過一次 `tp-suggest-ignore` analysis mode(「沒有發現」也算跑過)。
- Case (a)/(b):骨架 commit 內**不含**這個專案的建置產物(`git show --stat` 檢查第一顆 commit)。

## Test Scenarios

- **case (a)/(b) bridge bootstrap**:由 `Initialize-GitSvnBridge` 腳本的兩層自動測試覆蓋(case a/b × 空/非空
  SVN、身分 throw 重呼叫、MERGE_CONFLICT 回報、rollback;見 `tests/unit/scripts/Initialize-GitSvnBridge.test.*`);
  SKILL 端的編排(收 URL/身分重呼叫/骨架後置/衝突收尾)為 agent-prose,以一次真實 `/tp-setup` case (a)(空與非空
  SVN)+ 一次 case (b)人工驗證為準。
- **連不到 vs 路徑不存在**:① 給一個連不到的版本庫 URL → 訊息說「連不到」且含 svn 原文;② 給一個版本庫
  存在、但路徑不存在的 URL → 訊息說「路徑不存在」並提供建立選項;兩者都必須**零殘留可乾淨重跑**
  (見 `tests/unit/scripts/Initialize-GitSvnBridge.test.*` 的對應案例)。
- **建立路徑**:使用者選建立 + 建標準結構 → `trunk` / `branches` / `tags` 都出現且在**同一個修訂**裡,
  接著 bootstrap 正常往下走;使用者選不建 → 乾淨結束、SVN 零寫入(`svn info` 仍查不到該路徑)。
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
