# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Type

這個 repo 是一個 **Claude Code plugin marketplace**（不是一般應用程式），由 `.claude-plugin/marketplace.json` 宣告，並收納四個獨立 plugin 在 `plugins/` 底下。沒有 build / test / lint 指令——驗證方式是「在實際 Claude Code session 中安裝並執行 plugin 的 skill / command」。

## Versioning Rules（重要）

Claude Code 的 plugin 更新機制是基於 **版本號** 而不是 git commit。每一個 PR 或開發分支若有改到某個 plugin，都要 bump 該 plugin 的版本號：

- **patch（修訂號）**：bug 修正、文件修整、向後相容的內部調整
- **minor（次版號）**：新增 skill / command / script，或新增不破壞既有用法的功能
- **major（主版號）**：**只在使用者明確要求時** bump（破壞性變更也要先和使用者確認）

每次 bump 必須同步更新 **兩個檔案**：

1. `plugins/<plugin>/.claude-plugin/plugin.json` 的 `version` 欄位
2. `plugins/<plugin>/CHANGELOG.md` — 在 `[Unreleased]` 之下新增一個對應版本與日期的區段（格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/) 的 `Added` / `Changed` / `Fixed` / `Removed` 分類，使用繁體中文）

只動到單一 plugin 的 PR 只 bump 那一個 plugin；跨多個 plugin 的 PR 要分別 bump 每個受影響的 plugin。`tpi` 變更若有改到跨 plugin 行為也要 bump。

## Plugin Architecture

### 四個 plugin 與職責

| Alias | 目錄 | 職責 |
|---|---|---|
| `tdp` | `plugins/turbo-dev-pack/` | Web 專案開發流程 skills（goal → plan → implement-task → testing-and-proof → finish-dev），整合 dbhub / memory / markitdown MCP server |
| `tnf` | `plugins/turbo-dotnet-framework-commands/` | .NET Framework + MSBuild + IIS Express 的 build / run / publish 指令 |
| `tgs` | `plugins/turbo-git-with-remote-svn/` | 用 git worktree 橋接遠端 SVN repo 的工作流（pull / push / 建立 worktree / 管理 ignore） |
| `tpi` | `plugins/turbo-plugins-integration/` | 跨 plugin 編排：`setup-all` 一次跑完所有 plugin 的 setup 並把 env 同步到 peer worktree、`teach-me` 整合教學、`dependency-check` 依賴檢查 |

### 標準 plugin 內部結構

每個 plugin 都遵循這個佈局（部分可選）：

```
plugins/<plugin-name>/
├── .claude-plugin/plugin.json   # 必要 — name / description / version
├── .mcp.json                    # 可選 — MCP server 宣告（目前只有 tdp 有）
├── CHANGELOG.md                 # 必要 — 每次版本 bump 同步更新
├── README.md                    # 必要 — 安裝、用法
├── LICENSE                      # MIT
├── commands/<name>.md           # 可選 — slash command（含 frontmatter）
├── skills/<name>/SKILL.md       # 可選 — agent skill（含 frontmatter）
├── skills/<name>/assets/        # 可選 — skill 用的 template 等資產
├── scripts/<name>.ps1           # 可選 — PowerShell 實作（Windows）
├── scripts/<name>.sh            # 可選 — Bash 實作（Linux / macOS / Git Bash）
└── default-files/               # 可選 — `setup` skill 會複製這些範本到 workspace
```

### Skill ↔ Command ↔ Script 三層分工

- **Skill**（`skills/<name>/SKILL.md`）：用 frontmatter 宣告 `name` / `description` / `argument-hint` / `user-invocable`，內容是給 agent 讀的「Procedure / Decision Rules / Completion Checks」式說明。Skill 不直接執行指令，會委派給 subagent 或叫 user-level 工具。
- **Command**（`commands/<name>.md`）：用 frontmatter 宣告 `description` / `allowed-tools`，本體通常極短，只是叫 agent 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/<name>.ps1` 或 `.sh`。
- **Script**：實際做事的地方。**所有 script 都要同時提供 `.ps1` 和 `.sh` 兩個版本**，行為一致；Windows 走 PowerShell、其它平台走 Bash。命名為配對（如 `pull-from-svn.ps1` + `pull-from-svn.sh`）。

### Cross-platform script 約定

- PowerShell script 一律用 `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'` 開頭。
- 路徑用 `${CLAUDE_PLUGIN_ROOT}` 引用 plugin 內部資源（不要用相對路徑——使用者不一定從 plugin 目錄呼叫）。
- 不要用 `&&` 串接會改變狀態的 shell 指令（建立目錄、移動檔案、commit 等）；分成獨立步驟跑（這條規則在多個 skill 的 Decision Rules / Procedure 都有寫，要遵守）。
- Windows 上若使用者傳入 Git Bash 風格的路徑（`/c/Users/...`），在寫進 `settings.local.json` 之前要轉成 Windows 格式（`C:/Users/...`）——否則 Docker Desktop 不認。

### 設定檔分層

- `.claude/settings.json`：可進版控的設定（這個 repo 自己的 `enabledPlugins`）。
- `.claude/settings.local.json`：每個 workspace / worktree 自己的 env 設定，**不進版控**（已經在 `.gitignore` 用 `.claude/**/*.local.*`），所有 plugin 的 `setup` skill 都只動這個檔案的 `env` block，**不會** 覆蓋其它 plugin 的 keys。
- 各 plugin 的 env key 都有命名前綴：`TDP_*` / `TGS_*` / `PUBLISH_*` / `RUN_IIS_*` / `DBHUB_*` / `MEMORY_SERVER_*` / `MARKITDOWN_*` 等。

### tgs 的 worktree 模型（特別注意）

`tgs` 透過多個 git worktree 把職責拆開：

```
<proj>/                            ← main worktree（main / test-<n> 切換）
<proj>.worktrees/
  ├─ remote-main/                  ← branch: remote/main，SVN trunk 同步用
  ├─ remote-test-<n>/              ← branch: remote/test-<n>，SVN test 分支同步用
  └─ dev-<n>/                      ← 個人開發隔離 worktree
<proj>.code-workspace              ← 由 tgs 自動維護
```

- **每個 worktree 有獨立的 `.claude/settings.local.json`**，env 不共享；`tpi:setup-all` 會把同一份 env 複製到使用者勾選的 peer worktree。
- `remote-*` worktree 是 git/SVN 橋樑，通常不直接編輯。
- 在任一 worktree 開的 Claude Code 都能呼叫 `tgs` 指令——script 會自動定位主目錄。

### tdp 開發流程（skill 之間的順序）

`tdp` 的 dev skill 串成一條鏈，要按順序走：

```
start-dev          → 建立 bugfix/<slug> 或 feature/<slug> 分支與 specs 資料夾
  ↓
write-goal         → 在 specs/<type>/<slug>/goal.md 寫並反覆討論需求；目標編號格式 <number>[<letter>]，例如 1, 2a, 2b, 3
  ↓ （每個目標循環）
write-plan         → 在 specs/<type>/<slug>/goal-<id>/plan.md 寫實作 plan（最多 9 個實作任務 + 1 個建置任務 = 10 個）
  ↓
implement-task     → 依 plan.md 順序、用 subagent 跑「實作 → N 個平行 reviewer subagent → 讀 review report → COMPLETE 才換下一個」迴圈
  ↓ （所有目標完成後可選）
write-test-plan    → 在 spec 資料夾根目錄寫 test-plan.md / test-n.md
  ↓
testing-and-proof  → 跑驗證並產生佐證
  ↓
finish-dev         → 把 specs/<type>/<slug>/ 與 sql files/<env>/<slug>/ 移到 archives/
```

兩個 skill 有 `-fast` 變體（`write-plan-fast`、`implement-task-fast`），用較少 subagent 換速度。

## File Operation Tool Preference

`tdp` 的 `write-goal` / `write-plan` / `implement-task` 等 skill 在 `Tool Preference` 段落明文要求：所有檔案 read / write / search / edit 優先使用 Read / Write / Edit / Glob / Grep / LSP，避開 Bash / PowerShell / Python / Node.js 做檔案操作。呼叫 subagent 時也要傳遞此規則。修改這些 skill 時請維持一致。

## Important Cross-cutting Conventions

- **Changelog 語言**：CHANGELOG.md 用 **繁體中文** 撰寫，分類用 `Added` / `Changed` / `Fixed` / `Removed`（不翻譯）。
- **日期**：CHANGELOG.md 與其它需要日期的地方都用絕對日期（`YYYY-MM-DD`），不要用「今天」「上週」這種相對時間。
- **AC 分類**（影響 `tdp` 的 `write-plan` 與 `implement-task`）：固定 7 類，順序是 Correctness / Security / Integration & Compatibility / Maintainability & Code Quality / Testability & Observability / Performance & Resource Usage / User Experience。修改 plan template 時要保留全部 7 類，不適用就寫 `N/A`。
- **C# 註解**：改 C# 程式碼要呼叫 `/tdp:csharp-comment`；**JS/TS 註解**：改 `.js` / `.ts` 或 `.vue` / `.cshtml` / `.html` 中的 `<script>` 區塊要呼叫 `/tdp:js-comment`。
- **不要 commit `.local.*`**：已經在 `.gitignore`，但要記得不要把 `settings.local.json` 或 `*.local.toml` 加進範本以外的位置。

## Marketplace Manifest

`.claude-plugin/marketplace.json` 列出全部 plugin 與其相對路徑。新增 plugin 時要：

1. 在 `plugins/` 下建立完整目錄結構（含 `.claude-plugin/plugin.json` 起 version `0.1.0`）。
2. 在 `marketplace.json` 的 `plugins` 陣列加一筆 `{ name, description, source: "./plugins/<dir>" }`。
3. README.md 安裝章節同步更新（新增 `搜尋 <alias> → 安裝` 步驟）。
