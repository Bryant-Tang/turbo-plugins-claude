# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Type

這個 repo 是一個 **Claude Code plugin marketplace**（不是一般應用程式），由 `.claude-plugin/marketplace.json` 宣告，並收納若干獨立 plugin 在 `plugins/` 底下。沒有 build / lint 指令——驗證靠**自動化的 plugin 測試套件**（見「測試標準」）。

> **每個 plugin 的細節規範寫在各自的 `plugins/<name>/README.md`。** 本檔只收 marketplace 層級、跨 plugin 通用的規約；任何只對單一 plugin 成立的內容（worktree 模型、特定 skill 的命名/路徑 convention、env 前綴、commit-type 過濾等）一律寫進該 plugin 自己的 README，不要回流到本檔。

## Versioning Rules（重要）

Claude Code 的 plugin 更新機制是基於 **版本號**。版本由 **release-please** 依 conventional commit 自動管理——**不要手動 bump `plugin.json`、也不要手寫發版的 CHANGELOG 區段**。

**怎麼運作**：每次 merge 進 `main`，`.github/workflows/release-please.yml` 會依各 plugin 自上次發版以來的 commit type，為「有可發版變更」的 plugin 各開一個 **Release PR**（自動更新該 plugin 的 `.claude-plugin/plugin.json` `version` + `CHANGELOG.md`）；merge 那個 Release PR 即發版 + 打 tag（**`<plugin>--v<version>`，兩個減號**）。設定在 repo 根的 `release-please-config.json` + `.release-please-manifest.json`（四個 plugin 各自獨立版本 / 各自 Release PR）。

**tag 名稱格式是 load-bearing，不要改成單一減號**：Claude Code 解析 plugin 相依的版本約束時，是去 marketplace repo 列 tag、篩出開頭為 `<plugin-name>--v` 的那些，再取滿足 semver range 的最高版；用單一減號一個都篩不到，帶約束的相依會直接讓依賴方**被停用**（`no-matching-tag`）。所以 `release-please-config.json` 的 `tag-separator` 必須是 `--`，才跟官方 `claude plugin tag` 產生的 tag 同名。另：pre-1.0 的相依**不要用 `^0.1.0` / `~0.1.0`**——0.x 的 caret / tilde 都只允許 patch，而本 repo 設了 `bump-minor-pre-major`，每個 `feat:` 都跳 minor，約束會立刻對不上；用 `>=0.1.0` 之類的寫法。

**commit type → 版本級距**（只有 `feat` / `fix` 會觸發發版）：

- `fix:` → **patch**
- `feat:` → **minor**
- `feat!:` 或 commit body 含 `BREAKING CHANGE:` → **major**（破壞性變更，**仍須先和使用者確認**）
- `refactor` / `perf` / `docs` / `db` / `chore` / `test`：**單獨不觸發發版**，但會隨下一次 `feat` / `fix` 發版時一起列進 CHANGELOG（`chore` / `test` / `ci` / `build` 預設隱藏）。若某個純文件 / refactor 變更**必須單獨發佈**，改用 `fix:` 讓它觸發 patch。

**CHANGELOG 由 commit 生成**：每條 bullet = 你 commit 的**標題描述**（`type(scope): ` 後那段），**commit 寫繁中、CHANGELOG 就是繁中**；分類標題（`Added` / `Fixed` / `Changed` …）由 `release-please-config.json` 的 `changelog-sections` 依 commit type 對應。所以**寫好 commit 標題 = 寫好 CHANGELOG**。

**初版是手寫的種子**：每個 plugin 的 `## [0.1.0]` 是手寫的乾淨初版（描述最終 ship 的狀態）；release-please 從**下一次變更**起接手，把新版本疊在 0.1.0 之上。`.release-please-manifest.json` 記錄各 plugin 現在的版本。（首次啟用步驟——merge 後替四個 plugin 各打一個 `0.1.0` tag 當基準——見 `release-please.yml` 開頭註解。）

**所以**：① 不要手改 `plugin.json` 的 `version`、也不要手寫發版 CHANGELOG 區段（那兩處由 release-please 的 Release PR 維護）。② 想發版就把變更寫成清楚的 `feat:` / `fix:` commit。③ release-please 把「自上次發版以來的所有 commit」累積成一個 Release PR——等同「一批變更發一版」，不是每個 commit 發一版。④ major 仍須使用者明確同意才用 `!` / `BREAKING CHANGE`。

**PR 標題不要用 `fix:` / `feat:` 前綴（會污染 CHANGELOG）**：決定 CHANGELOG 內容的是**分支上每一顆
commit 的標題**，不是 PR 標題。PR 標題只是給人看的，但如果它以 `fix:` / `feat:` 開頭，merge 之後會多出
一條假的 CHANGELOG 條目。

原因是 GitHub 產生的 merge commit 長這樣：

```
subject: Merge pull request #31 from <owner>/<branch>
body:    fix: 修掉全部 open issue(dotnet 兩顆、git-svn 七顆)   ← PR 標題被放進 body
```

release-please 會解析 merge commit 的 body，看到 `fix:` 就收成一筆變更。而且那條**沒有 scope**，所以會
同時出現在**每一個**該次 merge 有動到的 plugin 的 CHANGELOG 裡。2026-08-06 實際發生過：PR #31 讓
`turbo-plugin-git-svn` 與 `turbo-plugin-dotnet-framework` 兩個 Release PR 都多了一條
「修掉全部 open issue…」——那不是一個具體修正，對讀 CHANGELOG 的人沒有意義。

**寫 PR 標題時**：用 `chore:` 前綴，或乾脆不加前綴。`changelog-sections` 已把 `chore` 設成
`hidden: true`，所以 `chore:` 開頭的 PR 標題不會進 CHANGELOG。

**這件事沒有設定層的解，已經查證過，不要再花時間找**：

- **GitHub 的 merge commit 設定救不了**。合法組合只有三種（API 會擋掉其它組合）：
  `PR_TITLE`+`PR_BODY`、`PR_TITLE`+`BLANK`、`MERGE_MESSAGE`+`PR_TITLE`。後兩者分別把 PR 標題放進
  subject 或 body，**三種都會被 release-please 解析到**。想要的「subject 保持 Merge pull request、
  body 留空」這個組合並不存在。
- **release-please 沒有排除 merge commit 的選項**。設定裡只有 `exclude-paths`（按路徑排除），而 merge
  commit 觸及所有 plugin 的檔案，用不上。「filter merge commits」是開著的功能請求
  （release-please-action issue #1046，p3，未實作）。
- **不能改用 squash 迴避**。squash 會把個別 commit 壓成一顆，CHANGELOG 就只剩一條——那正是本檔一再強調
  不要 squash 的理由。

**已經污染了怎麼辦**：在 Release PR 的分支上直接編輯該 plugin 的 `CHANGELOG.md` 刪掉那行再 merge。
release-please 只有在 main 有新 commit 時才重新生成，所以改完直接 merge 是安全的。

## Plugin Architecture

### 標準 plugin 內部結構

每個 plugin 都遵循這個佈局（部分可選）：

```
plugins/<plugin-name>/
├── .claude-plugin/plugin.json   # 必要 — name / description / version
├── .mcp.json                    # 可選 — MCP server 宣告
├── CHANGELOG.md                 # 必要 — 手寫初版 0.1.0 種子,之後由 release-please 維護
├── README.md                    # 必要 — 安裝、用法、plugin 專屬規範
├── LICENSE                      # MIT
├── commands/<name>.md           # 可選 — slash command（含 frontmatter）
├── skills/<name>/SKILL.md       # 可選 — agent skill（含 frontmatter）
├── skills/<name>/assets/        # 可選 — 單一 skill 用的 template 等資產
├── assets/                      # 可選 — 跨多個 skill 共用、沒有單一擁有者的資產
├── scripts/<name>.ps1           # 可選 — PowerShell 實作（Windows）
├── scripts/<name>.sh            # 可選 — Bash 實作（Linux / macOS / Git Bash）
├── default-files/               # 可選 — `setup` 類 skill 會複製這些範本到 workspace
└── tests/                       # 必要 — 自動化測試套件（見「測試標準」）
```

### SKILL 的 `description` 用英文、body 用繁中（常駐規約）

`skills/*/SKILL.md` 的 frontmatter **`description` 一律用英文**；SKILL 的 body（Purpose / Procedure /
Decision Rules …）**維持繁體中文**。

分界的理由是**載入時機不同**：`description` 是唯一會被**前載**的部分——每一支已安裝 skill 的
description 都常駐在 context 裡，供模型決定要不要叫它；body 只有真的用到那支 skill 才會載入。所以
description 是**給機器做路由的中繼資料**，body 才是給 agent 讀的作業說明。實測 18 支的 description
從繁中改成英文，估計約 2040 tokens → 1143（**省下約 44%**，中文一字約一個 token，英文約四字元一個）。

寫的時候：

- **只寫三件事**：這支做什麼、什麼時候該觸發、以及硬性的觸發限定語。解釋、範例、細節一律進 body——
  第一版翻譯把解釋也寫進 description，字數變兩倍、token 幾乎沒省到，那就白改了。
- **限定觸發行為的語句是契約，一個都不能漏**：「主動套用、不需使用者明講」、「使用者明確要求才執行」、
  「可建議但**不要自動觸發**」、「需明確確認」、「read-only，可安全 auto-trigger」。翻掉一個限定詞，
  觸發行為就變了。
- 改完用乾淨 session 抽驗觸發行為（同一個 session 裡跑過一次之後就不會再自動觸發，在那裡驗等於白驗）。

> 這條**不含** `.claude-plugin/marketplace.json` 的 plugin description 與 `commands/*.md`；那些不受
> skill 前載機制影響。

### Skill ↔ Command ↔ Script 三層分工

- **Skill**（`skills/<name>/SKILL.md`）：用 frontmatter 宣告 `name` / `description` / `argument-hint` / `user-invocable`，內容是給 agent 讀的「Procedure / Decision Rules / Completion Checks」式說明。Skill 不直接執行指令，會委派給 subagent 或叫 user-level 工具。**選 SKILL 的時機**：當 agent 看到某種狀態（例如新 untracked 檔案）時應主動建議該指令（典型範例：偵測到 untracked 檔案時建議加 ignore）。
- **Command**（`commands/<name>.md`）：用 frontmatter 宣告 `description` / `allowed-tools` / `argument-hint`。**本體長度依需求變化**：
  - **薄 command**：body 極短，只引導 agent 執行對應 script 並解讀輸出。
  - **長 orchestrator command**：body 包含完整的 Procedure / Decision Rules / Completion Checks 段落，含 `AskUserQuestion` 多步互動、parse script 輸出、委派其它指令——形式上幾乎等同 SKILL 寫法，差別只在於不會被 agent 自動觸發。

  **選 command 的時機**：使用者主動觸發為主，agent 沒有「該主動建議」的場景。`/<plugin>:<name>` 觸發路徑與 SKILL 完全相同，差別只在於 agent 是否會自動依 description 觸發。
- **Script**：實際做事的地方。**所有 script 都要同時提供 `.ps1` 和 `.sh` 兩個版本**，行為一致；Windows 走 PowerShell、其它平台走 Bash。命名為配對，**`.ps1` 用 PascalCase（Verb-Noun）、`.sh` 用小寫連字**（如 `Build-SvnCommit.ps1` + `build-svn-commit.sh`、`Remove-OrphanIis.ps1` + `remove-orphan-iis.sh`）。

  > **唯一的例外：`.mcp.json` 直接啟動的腳本寫成一支 `.js`。** plugin 的 `.mcp.json` 只吃字面的 `command`、沒有平台條件式，而且 Claude Code 是**直接 spawn** 它（不像 hook 那樣走 Claude Code 自己的 shell）——Windows PATH 上的 `bash` 是 WSL 轉接器、`sh` 不存在，所以 `"command": "bash"` 在標準 Git for Windows 機器上必然起不來。`node` 是三平台同名都在 PATH 上的唯一選擇。這條規則的目的是「兩個平台不會漂移」，單一實作更直接達成它；仍要用 Pester + shUnit2 兩套測試驅動同一支腳本。現況只有 `turbo-plugin-three-environment-db/scripts/start-dbhub.js`，理由寫在該 plugin 的 README。**不要「順手」幫它補一組 `.ps1` + `.sh`。**

### Cross-platform script 約定

- PowerShell script 一律用 `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'` 開頭。
- 路徑用 `${CLAUDE_PLUGIN_ROOT}` 引用 plugin 內部資源（不要用相對路徑——使用者不一定從 plugin 目錄呼叫）。
- 不要用 `&&` 串接會改變狀態的 shell 指令（建立目錄、移動檔案、commit 等）；分成獨立步驟跑（這條規則在多個 skill 的 Decision Rules / Procedure 都有寫，要遵守）。
- Windows 上若使用者傳入 Git Bash 風格的路徑（`/c/Users/...`），在寫進設定檔之前要轉成 Windows 格式（`C:/Users/...`）——否則部分工具（如 Docker Desktop）不認。

#### Windows PowerShell 5.1 相容性（必須遵守）

支援目標 = **Windows PowerShell 5.1**（內建 `powershell.exe`，跑在 .NET Framework 4.x 上）— 多數 Windows 使用者沒裝 PowerShell 7+。下列 syntax / API **必禁**：

- ❌ **3+ arg `Join-Path`**：`Join-Path $a 'b' 'c'` 是 PS 7+ only，PS 5.1 噴 `A positional parameter cannot be found...`。改用 `[System.IO.Path]::Combine($a, 'b', 'c')`（PS 5.1 + 7+ 通吃）。
- ❌ **`[System.IO.Path]::GetRelativePath`**：.NET Core / .NET 5+ only，PS 5.1（.NET Framework）沒這個 method。用自備的 relative-path helper（內部用 `System.Uri.MakeRelativeUri`）。
- ❌ **無 BOM 的含中文 `.ps1`**：PS 5.1 在中文 Windows（system codepage 950 / Big5）讀無 BOM UTF-8 → mojibake → parser fail。任何含非 ASCII 字串的 `.ps1` 都要存成 **UTF-8 with BOM**（前 3 bytes `EF BB BF`）。
- ❌ **對 native exe 用 `2>&1`**：PS 5.1 會把 stderr 包成 `NativeCommandError`，把 exe 的 `$?` 變成 `$false`（即使 exit code 0）。改用 `2>$null` 抑制 + 明確 check `$LASTEXITCODE`，或讓 stderr 自然往上走。
  - ⚠️ **但 `2>$null` 在 `$ErrorActionPreference = 'Stop'` 下擋不住 stderr-throw**：native exe 只要**寫了 stderr**，EAP=Stop 就會丟 terminating `NativeCommandError`——即使加了 `2>$null`（實證於 PS 5.1.26100）。後果:緊接其後的 `if ($LASTEXITCODE -ne 0)` guard 在「失敗且有 stderr」的常見情境**不可達**（throw 先發生、跳外層 catch），該 guard 只能接「非零 exit 但無 stderr」的 silent 情境。若**真的需要** `$LASTEXITCODE` 可達:用 `try { & exe ... } catch {}` 包住、或對該呼叫局部 `$ErrorActionPreference='Continue'`。多數情況靠 EAP=Stop 自然 fail-loud 即可（行為正確,只是不是 guard 在接）。
- ❌ **單元素 pipeline 直接讀 `.Count`**：`($x | Where ...).Count` 在 result 只 1 個 object 時不會 wrap 成 array，`.Count` 可能讀到該 object 自己的 property（hashtable 的 key 數、字串長度等）。改用 `@($x | Where ...).Count` 強制 array。

新增 `.ps1` 或修改既有 .ps1 時請以上 5 條對照檢查。

### 設定檔分層

- `.claude/settings.json`：可進版控的設定（這個 repo 自己的 `enabledPlugins` 等）。
- `.claude/settings.local.json`：每個 workspace / worktree 自己的 env / 機器專屬設定，**不進版控**（已經在 `.gitignore` 用 `.claude/**/*.local.*` 排除）。plugin 的 `setup` 類 skill 若要寫 env，只動這個檔案，**不會** 覆蓋其它 plugin 的 keys。
- plugin 自己的設定檔（machine-specific tool paths、credentials 等）一律用 `*.local.*` 命名落在 gitignored 路徑；可進版控的偏好設定與範本則用非 `.local.` 命名。
- plugin 之間若共用 env key，各自加命名前綴避免衝突（每個 plugin 的前綴與 key 清單寫在該 plugin 的 README）。

## 測試標準（每個 plugin 必須遵守）

**每個 plugin 都必須附帶完整的自動化測試 + CI**，全部擺在慣例路徑 `plugins/<name>/tests/`，讓 repo 的 CI（`.github/workflows/tests.yml`）能慣例自動探索——新增遵循此佈局的 plugin **零改 `.yml`** 即被納入。

**Script 測試（自動化）**：驗證 `scripts/*.ps1` / `*.sh` 的實際行為。`.ps1` 走 Windows PowerShell 5.1、`.sh` 走 bash，行為一致。由 plugin 的標準入口 orchestrator 跑：`plugins/<name>/tests/Invoke-ScriptTests.ps1`（PowerShell）與 `plugins/<name>/tests/invoke-script-tests.sh`（bash）。CI 依此入口探索並執行。

> 先前的「Skill 測試（人工、可重複）」層已退役——改以**自動化測試為唯一常駐驗證標準**。不再維護 `tests/docs/` 手動測試流程文件（schema / session 計畫 / budget / rollback / fail-then-fix）。

**`tools/` 的 repo 層級腳本同樣要測**，佈局沿用 plugin 的 `tests/`（`tools/tests/invoke-script-tests.sh` + `unit/*.test.sh` + vendored `lib/shunit2`），由 `tests.yml` 的 `tools-tests` job 執行。細節與幾條刻意的決定（為何不做 `.ps1` 孿生、為何探索到零個測試檔要 FAIL）寫在 `tools/README.md`。

**新增任何 CI job 都要加進 `tests-passed` 的 `needs`**：branch protection 只指向 `tests-passed` 這一個 check，沒被它 `needs` 到的 job 失敗**不會擋 merge**——一個沒人依賴的測試就是一個可以無聲停跑的測試。

**判斷邏輯不要留在 workflow 的 `run:` 區塊裡**：那種程式碼只能靠 push 才驗得到，而它壞掉的方向通常不是紅燈，是「某些測試根本沒跑、畫面卻全綠」。抽成 `tools/` 底下的腳本、讓 workflow **呼叫**它（不是複製一份），再補測試。已經這樣處理的：`tools/affected-plugins.sh`。

共通原則：

- **Path-free**：所有測試（含 fixture、sandbox）一律不得寫死機器專屬絕對路徑；工作根用 repo 相對的 gitignored sandbox。
- **「能跑的就跑」**：CI 在多 OS 上跑——windows runner 跑全部（`.ps1` + `.sh`）；ubuntu runner 跑可移植的 `.sh`，缺工具（如 .NET / IIS / 特定 native exe）的測試 **自我 SKIP（非 FAIL）**。orchestrator 要能區分 PASS / SKIP / FAIL，CI 把 SKIP 當綠。
- **零污染**：跑完測試不得在 sandbox 以外留下產物，也不得改動使用者 / runner 的全域狀態（例如 svn 全域設定用 sandbox-local config 隔離）。

## File Operation Tool Preference

涉及檔案 read / write / search / edit 的工作，優先使用 Read / Write / Edit / Glob / Grep / LSP，避開 Bash / PowerShell / Python / Node.js 做檔案操作。呼叫 subagent 做檔案操作時也要傳遞此規則。若 plugin 的 skill 在自己的 `Tool Preference` 段落明文要求此規則，修改時請維持一致。

## Important Cross-cutting Conventions

- **Changelog 語言**：CHANGELOG.md 用 **繁體中文** 撰寫，分類用 `Added` / `Changed` / `Fixed` / `Removed`（不翻譯）。
- **日期**：CHANGELOG.md 與其它需要日期的地方都用絕對日期（`YYYY-MM-DD`），不要用「今天」「上週」這種相對時間。
- **Commit message 類型**：建議用 conventional commit type 前綴——`feat` / `fix` 限程式碼、`refactor` 給行為不變的整理（含測試重構）、`docs` 給純文件、`db` 給 SQL 腳本、`chore` 給非實作雜務。
- **不要 commit `.local.*`**：已經在 `.gitignore`，但要記得不要把任何 `*.local.*` 設定檔加進範本以外的位置。
- **不得提交僅限本機才有的東西**：機器路徑（`C:\Users\...`、`C:\Turbo\...` 等絕對路徑）、內部 hostname / URL（內網 SVN / host）、僅本機或單次情境才有意義的識別碼（需求 / 計畫 / 任務代號、單一 session 的項目編號）一律不得寫進任何版控檔（含文件、範本、測試 fixture）。文件需要舉例時改用固定 placeholder token（如 `<MACHINE-PATH>` / `<INTERNAL-SVN-URL>`）；測試一律走 repo 相對的 gitignored sandbox。此為常駐規約，目前以人工 / code review 把關（advisory），自動化 CI lint 列為後續工作。

## Marketplace Manifest

`.claude-plugin/marketplace.json` 列出全部 plugin 與其相對路徑。新增 plugin 時要：

1. 在 `plugins/` 下建立完整目錄結構（含 `.claude-plugin/plugin.json` 起 version `0.1.0`、手寫 `CHANGELOG.md` 的 `## [0.1.0]` 種子，以及 `tests/` 自動化測試套件）。
2. 在 `marketplace.json` 的 `plugins` 陣列加一筆 `{ name, description, source: "./plugins/<dir>" }`。
3. **註冊進 release-please**：`release-please-config.json` 的 `packages` 加一筆（`component` + `extra-files` 指向該 plugin 的 `.claude-plugin/plugin.json`），`.release-please-manifest.json` 加 `"plugins/<dir>": "0.1.0"`。
4. repo 根 README.md 安裝章節同步更新（新增該 plugin 的搜尋 / 安裝步驟）。

CI 不需要每加一個 plugin 就手寫 workflow——只要 `tests/` 遵循慣例佈局，`.github/workflows/tests.yml` 會自動探索並納入；release-please 也只看上述兩個設定檔。
