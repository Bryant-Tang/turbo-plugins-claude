# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Type

這個 repo 是一個 **Claude Code plugin marketplace**（不是一般應用程式），由 `.claude-plugin/marketplace.json` 宣告，並收納若干獨立 plugin 在 `plugins/` 底下。沒有 build / lint 指令——驗證靠**自動化的 plugin 測試套件**（見「測試標準」）。

> **每個 plugin 的細節規範寫在各自的 `plugins/<name>/README.md`。** 本檔只收 marketplace 層級、跨 plugin 通用的規約；任何只對單一 plugin 成立的內容（worktree 模型、特定 skill 的命名/路徑 convention、env 前綴、commit-type 過濾等）一律寫進該 plugin 自己的 README，不要回流到本檔。

## Versioning Rules（重要）

Claude Code 的 plugin 更新機制是基於 **版本號**。版本由 **release-please** 依 conventional commit 自動管理——**不要手動 bump `plugin.json`、也不要手寫發版的 CHANGELOG 區段**。

**怎麼運作**：每次 merge 進 `main`，`.github/workflows/release-please.yml` 會依各 plugin 自上次發版以來的 commit type，為「有可發版變更」的 plugin 各開一個 **Release PR**（自動更新該 plugin 的 `.claude-plugin/plugin.json` `version` + `CHANGELOG.md`）；merge 那個 Release PR 即發版 + 打 tag（`<plugin>-v<version>`）。設定在 repo 根的 `release-please-config.json` + `.release-please-manifest.json`（四個 plugin 各自獨立版本 / 各自 Release PR）。

**commit type → 版本級距**（只有 `feat` / `fix` 會觸發發版）：

- `fix:` → **patch**
- `feat:` → **minor**
- `feat!:` 或 commit body 含 `BREAKING CHANGE:` → **major**（破壞性變更，**仍須先和使用者確認**）
- `refactor` / `perf` / `docs` / `db` / `chore` / `test`：**單獨不觸發發版**，但會隨下一次 `feat` / `fix` 發版時一起列進 CHANGELOG（`chore` / `test` / `ci` / `build` 預設隱藏）。若某個純文件 / refactor 變更**必須單獨發佈**，改用 `fix:` 讓它觸發 patch。

**CHANGELOG 由 commit 生成**：每條 bullet = 你 commit 的**標題描述**（`type(scope): ` 後那段），**commit 寫繁中、CHANGELOG 就是繁中**；分類標題（`Added` / `Fixed` / `Changed` …）由 `release-please-config.json` 的 `changelog-sections` 依 commit type 對應。所以**寫好 commit 標題 = 寫好 CHANGELOG**。

**初版是手寫的種子**：每個 plugin 的 `## [0.1.0]` 是手寫的乾淨初版（描述最終 ship 的狀態）；release-please 從**下一次變更**起接手，把新版本疊在 0.1.0 之上。`.release-please-manifest.json` 記錄各 plugin 現在的版本。（首次啟用步驟——merge 後替四個 plugin 各打一個 `0.1.0` tag 當基準——見 `release-please.yml` 開頭註解。）

**所以**：① 不要手改 `plugin.json` 的 `version`、也不要手寫發版 CHANGELOG 區段（那兩處由 release-please 的 Release PR 維護）。② 想發版就把變更寫成清楚的 `feat:` / `fix:` commit。③ release-please 把「自上次發版以來的所有 commit」累積成一個 Release PR——等同「一批變更發一版」，不是每個 commit 發一版。④ major 仍須使用者明確同意才用 `!` / `BREAKING CHANGE`。

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

### Skill ↔ Command ↔ Script 三層分工

- **Skill**（`skills/<name>/SKILL.md`）：用 frontmatter 宣告 `name` / `description` / `argument-hint` / `user-invocable`，內容是給 agent 讀的「Procedure / Decision Rules / Completion Checks」式說明。Skill 不直接執行指令，會委派給 subagent 或叫 user-level 工具。**選 SKILL 的時機**：當 agent 看到某種狀態（例如新 untracked 檔案）時應主動建議該指令（典型範例：偵測到 untracked 檔案時建議加 ignore）。
- **Command**（`commands/<name>.md`）：用 frontmatter 宣告 `description` / `allowed-tools` / `argument-hint`。**本體長度依需求變化**：
  - **薄 command**：body 極短，只引導 agent 執行對應 script 並解讀輸出。
  - **長 orchestrator command**：body 包含完整的 Procedure / Decision Rules / Completion Checks 段落，含 `AskUserQuestion` 多步互動、parse script 輸出、委派其它指令——形式上幾乎等同 SKILL 寫法，差別只在於不會被 agent 自動觸發。

  **選 command 的時機**：使用者主動觸發為主，agent 沒有「該主動建議」的場景。`/<plugin>:<name>` 觸發路徑與 SKILL 完全相同，差別只在於 agent 是否會自動依 description 觸發。
- **Script**：實際做事的地方。**所有 script 都要同時提供 `.ps1` 和 `.sh` 兩個版本**，行為一致；Windows 走 PowerShell、其它平台走 Bash。命名為配對，**`.ps1` 用 PascalCase（Verb-Noun）、`.sh` 用小寫連字**（如 `Build-SvnCommit.ps1` + `build-svn-commit.sh`、`Remove-OrphanIis.ps1` + `remove-orphan-iis.sh`）。

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
