---
date: 2026-05-22
type: feat
origin: docs/brainstorms/2026-05-20-turbo-plugin-rewrite-requirements.md
status: completed
---

# feat: turbo-plugin consolidation (4 plugins → 1)

## Summary

收合既有 `tdp` / `tnf` / `tgs` / `tpi` 四個 turbo-* plugin 為單一 `turbo-plugin`,釋出 v0.1.0。**13 個 skill** 涵蓋 Setup(1) + SVN bridge(5) + .NET Framework Web(4) + Ignore / 註解(3),全部 `user-invocable: true` 以 `/tp-<skill>` 為觸發入口。**env-free 設計**:`.turbo-plugin/` 集中目錄存放 `config.toml`(build/publish/frontend 偏好)+ `applicationhost.config` 共享 source-of-truth + `dbhub.example.local.toml`(template,進 git)+ `dbhub.local.toml`(gitignored 含 credentials),只保留 2 個 user-level optional env(`TURBO_PLUGIN_IIS_EXPRESS_PATH` / `TURBO_PLUGIN_MSBUILD_PATH`)。**IIS Express 識別** 改為 `(port + project identity)` 複合 key,project identity = `git rev-parse --path-format=absolute --git-common-dir` + `.csproj` 相對路徑(Windows case-normalize)。**Hooks**:plugin 自帶 `PostToolUse EnterWorktree` 自動補 applicationhost.config + `SessionStart` 提示性 3 分支(支援 Pattern A/B 切換)。**SVN bridge** 維持 dual worktree + svn checkout + git merge 模式,**tp-push-to-svn 自 parse subject** 作為 SVN history 篩選 source-of-truth(取代 husky / commitlint hook)。

最大化 lift 既有 scripts(tgs SVN bridge 全套、tnf build/publish/IIS、tdp comment skills、tgs suggest-ignore),新邏輯只在:hooks(repo 無 precedent)、IIS Express 新 identity 算法、`.commitlintrc.json` 寫入、`.turbo-plugin/` 集中目錄。**測試走 CLAUDE.md 約定** — real Claude Code session 安裝跑通驗證,無自動化 test suite。**Cutover** 期既有 4 plugin 並存,turbo-plugin 完成 13 skill 全套 + F1/F2/F3 flow 跑通 + 連續 5 工作日無 blocker → 立刻 disable / remove 既有 4 plugin。

---

## Problem Frame

兩類痛點需解決(見 origin: `docs/brainstorms/2026-05-20-turbo-plugin-rewrite-requirements.md`):

1. **自製開發流程維護成本太高** — `tdp` 嘗試做 goal → plan → implement → finish-dev skill 鏈,實際 bug 多在 goal/plan 階段就出現;撤退主要動機是「自己維護成本超過可投入時間」。turbo-plugin **撤出開發流程責任**,使用者搭配自選 dev flow plugin(建議 compound-engineering 但不綁定)。
2. **操作摩擦與真實 bug**:四個 plugin 各自獨立 setup + 每 worktree `.claude/settings.local.json` 不共享 → 主 worktree session 無法處理 peer worktree;`tnf` 的 `stop-iis` 以 worktree 為識別單位 → worktree A 跑 stop 殺不到 worktree B 啟的 IIS,且 `run-iis` 還會「假回報成功」。Skill 多 = 學習負擔;四個 plugin 職責邊界對使用者無意義。

新 plugin 解決:
- **單一 plugin、env-free**:`.turbo-plugin/` 集中目錄 + `config.toml` commit 進 repo 跨同事共用;新 worktree 設定由 hooks 自動補,使用者無需手動跑各 plugin setup。
- **IIS Express 跨 worktree 識別**:`(port + project identity)` 複合 key 解 stop-iis bug。
- **三層 trigger mode 判準是「做錯好不好救」**:可逆(build/run/stop/setup/suggest-ignore/comment)→ agent-proactive;難救(SVN push/publish/remote-test 建檔)→ proactive suggestion only(agent 建議但需使用者同意)。

---

## Scope Boundaries

### In scope (v0.1.0)

- 全部 13 個 skill 完整實作(R1 表列):`tp-setup`、`tp-pull-from-svn`、`tp-push-to-svn`、`tp-svn-log`、`tp-create-remote-test`、`tp-reset-remote-test`、`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-suggest-ignore`、`tp-csharp-comment`、`tp-js-comment`
- `hooks/hooks.json` 帶 `PostToolUse EnterWorktree` + `SessionStart` 兩 hook,plugin 自帶安裝即 active
- `.mcp.json` 宣告 `tp-dbhub` MCP server(過渡期重新命名避免與 `tdp:dbhub` 碰撞)
- `.turbo-plugin/` 集中目錄 + default-files template
- 跨平台:.NET FW Web 4 skill 提供 `.ps1`(原生)+ `.sh` thin wrapper(轉呼叫 `.ps1`)讓 Git Bash on Windows 用戶仍可用(見 Decision 10 update);其他 9 skill 提供 `.ps1` + `.sh` 雙原生版本
- Shared helper lib `scripts/lib/common.{ps1,sh}`(`Get-MainWorktree` / `Resolve-RepoPath` / `Write-Utf8NoBom` / `Resolve-RemoteWorktree` 等通用)+ `scripts/lib/applicationhost-helpers.ps1`(IIS XML 操作,PowerShell-only lib,見 U1 例外)

### Deferred to Follow-Up Work

- **v0.2.0 description 升級為 agent-proactive 觸發**:v0.1.0 descriptions 寫成 conservative(避免跟既有 `tdp:` / `tnf:` / `tgs:` 等 auto-trigger 碰撞);cutover 後既有 4 plugin disable / remove,0.2.0 改 description 加「何種狀態 agent 應主動執行」語句啟用 R2 三層 trigger mode 完整效果
- **`config.toml` schema migration framework**:v0.1.0 寫 `schema_version = 1`,skill 跑時讀到非 1 fail-loudly + 提示「請升 plugin」;未來 schema 演進時(rename field / 加 required / 改 type)當下決定 migration 策略(brainstorm 3 選 1:auto-migration / prompt manual / fail-loud)
- **MCP server lifecycle 深度驗證 follow-up**:v0.1.0 已含 fallback 設計(MCP server 找不到 dbhub.local.toml 時 fail loudly,見 U4 test scenarios)+ 在 U11 step 5 跑邊界驗證 probe(`/compact` / session resume / Claude Code update 期間 MCP relaunch 行為,見 Outstanding Questions 對應條目)。post-v0.1.0 若發現驗證結果跟預期不符再評估設計調整,本 follow-up 條目只追蹤「跑了 probe 後是否需要 design 改」
- **`tp-suggest-ignore` 偵測規則精修**:從既有 tgs 抄過來的基礎規則為 v0.1.0,未來依實際使用加更多 pattern
- **`tp-teach-me` 等同事 onboarding skill**:本次不做,同事首次安裝走使用者(你)親自帶 onboarding,brainstorm 已聲明
- **Per-branch DB 連線需求**(若同 project 不同 branch 需連別 DB):brainstorm Pattern A 假設「同 project 跨 worktree 同 DB」,例外切 Pattern B 各 worktree 自備 dbhub.local.toml — 不額外 framework

### Outside this product's identity (carried verbatim from origin)

- 自製開發流程(goal / plan / implement / testing-and-proof / finish-dev 等)— 撤退主因為「自己維護成本太高」,使用者搭配 dev flow plugin
- 通用 commit message 撰寫工具與提交時 commit format 強制 enforcement(原 tp-commit-msg + husky + commitlint hook)
- 文件轉換工具(markitdown 之類)
- 通用 memory 機制(Claude Code auto-memory 已涵蓋)
- 既有 4 plugin 棄用功能:`archive` / `merge-main-into-all` / `release` / `cleanup-remote-test` / `tag-release` / `create-project` / `init-from-existing`(後兩者併入 `tp-setup`)/ `create-dev-worktree` / `create-branch` / `apply-local-test-stash` / `revert-local-test-stash` / `pack-content`(併入 publish)/ `check-iis-listening`(併入 run)/ `frontend-standard` / `db-management` / `teach-me` / `dependency-check` / `setup-all`
- `specs/<type>/<slug>/` 資料夾 convention 與 `archives/` 機制
- .NET Core 支援(Deferred for later;命名已預留 `tp-*-dotnet-core-web` 差異)

### Platform support 限制

- .NET FW Web 4 skill 僅 Windows(.NET Framework 本來 Windows-only);Unix 環境 turbo-plugin 縮為 9 skill。A1 actor 若主要使用者切 Unix 應重新評估是否整合 .NET Core(Deferred)。

---

## Key Technical Decisions

每個決策都有 origin 對應條目;見 `docs/brainstorms/2026-05-20-turbo-plugin-rewrite-requirements.md` Key Decisions 段為完整理由。本段只摘 plan 階段定案。

1. **激進縮減 over 單純搬家**(Approach 2)— 每個 skill 都要為 trigger mode 寫精準 description,保留將砍 skill = 浪費。
2. **三層 trigger mode 判準「做錯好不好救」**(可逆性)— R2 完整定義。
3. **13 個 skill 為硬目標**(R17 拍板):盤點結果 = 設計約束,planning 不增不減湊數。
4. **IIS Express 用 `(port + project identity)` 識別**:project identity = `git rev-parse --path-format=absolute --git-common-dir` + `.csproj` 對 worktree top-level 相對路徑(複合 id;Windows lowercase drive + `Resolve-Path` normalize)。**Implementation detail**(這個 identity 寫進 IIS Express 啟動 process 哪裡讓 query 撈得到):**plan 階段選 site name suffix** — 在 applicationhost.config 寫 `<site name="<csproj-stem>-<short-hash-of-identity>">` 形式,wmic / `Get-CimInstance Win32_Process` 撈 commandLine match site name。理由:現有 `stop-iis.ps1` 已用 commandLine match site 模式,改 site name 內嵌 identity hash 是最小 delta;site name 本身寫進 applicationhost.config 由 PostToolUse hook 維護,跟同 hook 改寫 physicalPath 是同一個檔。
5. **`tp-push-to-svn` 自 parse subject 為 SVN bridge 篩選 source-of-truth**:取代 commitlint + husky 強制 enforce;`.commitlintrc.json` + `CLAUDE.md` convention 段純諮詢。零 JS 工具鏈依賴。
6. **Commit type 列表為 conventional commits 11 類 + `db`(turbo-plugin 自訂)= 12 類**;R12 篩選保留 `feat` / `fix` / `refactor` / `perf` / `revert`,過濾 `Merge ` / `docs` / `test` / `chore` / `style` / `build` / `ci` / `db`。
7. **R9 worktree 補設定機制定案為「env-free + per-project config.toml + 雙 Claude hook + marker」**:`.turbo-plugin/` 資料夾本身為 sole marker。`PostToolUse EnterWorktree` 自動補(applicationhost.config 改寫,從 stdin `tool_response.worktreePath` 取新路徑而非 `$CLAUDE_PROJECT_DIR`);`SessionStart` 只提示不自動寫(3 分支 + pre-check;分支 (iii) 動態 plug 主 worktree 實際路徑進 prompt)。
8. **commitlint + husky 全砍**:無 husky hook 安裝、無 npm 工具鏈、無 git-svn 自動 commit 被 reject 風險。
9. **既有 4 plugin 為測試過渡期備案**:cutover criteria = 完成 13 skill + F1/F2/F3 flow 各跑通一輪 + 連續 5 工作日無 blocker → disable / remove。過渡期 dbhub MCP server 改名 `tp-dbhub` 避免碰撞;cutover 後可選 rename 回 `dbhub`。
10. **.NET FW Web 4 skill 提供 `.sh` 為 thin wrapper 轉呼叫 `.ps1`**:`.sh` 內部 `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/<script>.ps1" $@`,Git Bash on Windows 用戶仍可 `/tp-build` 等觸發(實際跨 PowerShell 跑)。原 brainstorm「.sh 是技術債」判斷更新:Windows-only 是 *target tech*(.NET FW),不是 *script 不能 bash*;thin wrapper 避免 cygpath + wmic 完整 bash 重寫負擔,同時不丟 Git Bash 用戶。`.ps1` 仍是 single source of truth。
11. **其他 9 skill 保留 `.ps1` + `.sh` 雙版本各自原生實作**:Claude Code 在 Windows 常自選 Git Bash 而非 PowerShell;非 .NET FW 場景 cross-platform 需求高,bash 版各自原生實作更乾淨。
12. **Inclusion principle**:必要條件(實際在用 + agent enforce 需求) + 充分條件(整合外部系統);**既有 skill 豁免充分條件僅限本份 R1 列入 13 個**(一次性歷史例外)。
13. **R1 全 skill 介面**:不寫獨立 `commands/<name>.md` files,skill 一律 `user-invocable: true` 提供 `/tp-<skill>` 觸發入口。
14. **Helper script 抽 shared lib**:`scripts/lib/common.ps1` + `common.sh` 集中 `Get-MainWorktree` / `Resolve-RepoPath` / `Write-Utf8NoBom` / `Resolve-RemoteWorktree`,避免 5 個 script 各 copy 同一份。
15. **v0.1.0 descriptions 走 conservative**:0.1.0 ship 期間既有 `tdp:` / `tnf:` / `tgs:` 仍存在,description 寫成「使用者明確要求才執行」風格避免兩 plugin 都 auto-trigger;cutover 後 0.2.0 升 description 加「何種狀態 agent 應主動執行」啟用三層 trigger mode 完整效果。

---

## Output Structure

```
plugins/turbo-plugin/
├── .claude-plugin/
│   └── plugin.json                          # name, description, version 0.1.0
├── .mcp.json                                # tp-dbhub MCP server
├── CHANGELOG.md                             # 繁體中文,Keep-a-Changelog
├── README.md
├── LICENSE                                  # MIT
├── hooks/
│   └── hooks.json                           # PostToolUse EnterWorktree + SessionStart
├── skills/
│   ├── tp-setup/SKILL.md
│   ├── tp-pull-from-svn/SKILL.md
│   ├── tp-push-to-svn/SKILL.md
│   ├── tp-svn-log/SKILL.md
│   ├── tp-create-remote-test/SKILL.md
│   ├── tp-reset-remote-test/SKILL.md
│   ├── tp-build-dotnet-framework-web/SKILL.md
│   ├── tp-run-dotnet-framework-web/SKILL.md
│   ├── tp-stop-dotnet-framework-web/SKILL.md
│   ├── tp-publish-dotnet-framework-web/SKILL.md
│   ├── tp-suggest-ignore/SKILL.md
│   ├── tp-csharp-comment/
│   │   ├── SKILL.md
│   │   └── assets/example-with-comments.cs
│   └── tp-js-comment/
│       ├── SKILL.md
│       └── assets/example-with-comments.ts
├── scripts/
│   ├── lib/
│   │   ├── common.{ps1,sh}                  # git/path/encoding 通用 helper
│   │   └── applicationhost-helpers.ps1      # IIS-specific XML 操作(.ps1 only;lib 例外見 U1)
│   ├── hooks/
│   │   ├── posttooluse-enterworktree.ps1    # applicationhost.config 改寫(atomic+idempotent)
│   │   ├── posttooluse-enterworktree.sh
│   │   ├── sessionstart.ps1                 # 3 分支 + pre-check
│   │   └── sessionstart.sh
│   ├── pull-from-svn.{ps1,sh}
│   ├── push-to-svn-prepare.{ps1,sh}
│   ├── push-to-svn-commit.{ps1,sh}
│   ├── svn-log.{ps1,sh}
│   ├── create-remote-test.{ps1,sh}
│   ├── reset-remote-test.{ps1,sh}
│   ├── svn-ignore.{ps1,sh}                  # tp-suggest-ignore 用
│   ├── build-web.{ps1,sh}                   # .sh 為 thin wrapper 轉跑 .ps1(Git Bash on Windows)
│   ├── pack-content.{ps1,sh}
│   ├── publish-web.{ps1,sh}
│   ├── start-iis.{ps1,sh}
│   ├── stop-iis.{ps1,sh}
│   ├── check-iis-listening.{ps1,sh}
│   ├── get-target-url.{ps1,sh}
│   ├── resolve-iis-settings.{ps1,sh}
│   └── compute-project-identity.{ps1,sh}    # 新:(port + git-common-dir + csproj relpath) 算法
└── default-files/
    └── .turbo-plugin/
        ├── config.toml                       # template: schema_version=1
        ├── applicationhost.config            # IIS Express source-of-truth template
        └── dbhub.example.local.toml          # gitignored dbhub.local.toml 的範本
```

實際結構若實作中發現更好 layout 可調;per-unit `**Files:**` 為各 unit 權威清單。

---

## System-Wide Impact

| 受影響面 | 影響範圍 | 處置 |
|---|---|---|
| `.claude-plugin/marketplace.json` | 加 `turbo-plugin` 為第 5 個 entry | U1 |
| 既有 4 plugin(`tdp` / `tnf` / `tgs` / `tpi`) | 並存於 marketplace 直到 cutover | 不動;cutover 後使用者手動 disable / remove |
| `.commitlintrc.json` 在使用者 repo | 由 `tp-setup` 寫入(若不存在) | U3 |
| `CLAUDE.md` 在使用者 repo | 由 `tp-setup` 注入 commit type convention 段(idempotent — 偵測既有段不重複追加) | U3 |
| `.gitignore` / `svn:ignore` | 由 `tp-setup` 加入 `.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*` 等 pattern | U3 |
| `.turbo-plugin/` | 新建集中目錄,跨 worktree 共用 | U3 |
| 使用者 user-level `~/.claude/settings.json` env block | 偵測不到 IIS Express / MSBuild 標準位置時 prompt 補 `TURBO_PLUGIN_IIS_EXPRESS_PATH` / `TURBO_PLUGIN_MSBUILD_PATH` | U3 |
| 使用者本機 IIS Express applicationhost.config | PostToolUse hook 在 EnterWorktree 後改寫對應 site 的 physicalPath(atomic+idempotent) | U2 |
| Claude Code session 啟動時 | SessionStart hook 觸發提示性 message(non-blocking) | U2 |
| 同事(A1)workflow | onboarding 由使用者親自帶;cutover 期看到 `tdp:` + `tp-` 兩套 skill 共存 | 不另投資源,Scope Boundaries 已聲明 |

---

## Implementation Units

執行注:本 plugin 屬於 Claude Code marketplace plugin,**驗證方式為 real Claude Code session 安裝跑通**(CLAUDE.md 明訂無 build / test / lint 指令)。每個 unit 的 `Verification` 走 manual session 驗證,不寫自動化 test。Test scenarios 列出「應驗證的觀察點」,使用者在 session 內按 scenario 跑出來核對。

### U1. Plugin scaffolding + marketplace registration + shared helper lib

**Goal**: 建立 `plugins/turbo-plugin/` 骨架 + plugin manifest + 集中 helper functions,讓後續 unit 都能 reference。

**Requirements**: R1, R3, R4(過渡期並存的 plugin 註冊)

**Dependencies**: 無

**Files**:
- `plugins/turbo-plugin/.claude-plugin/plugin.json`(新)— version `0.1.0`、name `turbo-plugin`、description「.NET Framework Web + git+SVN bridged 環境的本機開發雜務工具集」、author、license MIT
- `plugins/turbo-plugin/CHANGELOG.md`(新)— Keep-a-Changelog 格式繁體中文,加 `[0.1.0] - 2026-05-22` 區段含 `Added` 列出 13 skill + hooks + `.turbo-plugin/` 集中目錄
- `plugins/turbo-plugin/README.md`(新)— 安裝、用法、Pattern A/B 說明、跟既有 4 plugin 過渡期共存說明
- `plugins/turbo-plugin/LICENSE`(新)— MIT
- `plugins/turbo-plugin/scripts/lib/common.ps1`(新)— git / path / encoding 通用 helper:`Get-MainWorktree`(用 `git rev-parse --path-format=absolute --git-common-dir` 取 `dirname`)、`Resolve-RepoPath`(Git Bash `/c/foo` → `C:\foo` + relative-to-absolute)、`Write-Utf8NoBom`、`Resolve-RemoteWorktree`(maps `main`/`test-<n>` 到 `<proj>.worktrees/remote-<name>/`)、`Test-IsMainWorktree`(`dirname(common-dir) == show-toplevel`)、`Test-IsSubmodule`(`git rev-parse --show-superproject-working-tree` 非空)、`Get-NormalizedAbsolutePath`(Windows lowercase drive + `Resolve-Path`)、`Probe-GitVersion`(< 2.31 fail with 升級提示)
- `plugins/turbo-plugin/scripts/lib/common.sh`(新)— 對應 bash 版,提供同等 function
- `plugins/turbo-plugin/scripts/lib/applicationhost-helpers.ps1`(新)— IIS-specific helper:`Update-ApplicationhostConfig`(XML parse + atomic + idempotent 改 site 的 physicalPath,給 U2 hook + U3 setup case (d) 共用)、`Find-ApplicationhostSite`(透過 `<site name>` match `<csproj-stem>-<identity-hash>`)、未來其他 IIS helper 也放這裡。**Lib helper 只提供 `.ps1`**——因為 bash 無法 dot-source PowerShell function library,且 lib 的 caller(U2 hook script `.sh`、U9 stop-iis.sh 等)本身已是 thin wrapper to `.ps1` 不會走 bash 路徑;`.sh` lib 是 dead code,故不建立(此為 CLAUDE.md「scripts 提供 .ps1 + .sh」約定的 library helper 例外)
- `.claude-plugin/marketplace.json`(改)— `plugins` 陣列加第 5 entry `{ "name": "turbo-plugin", "description": "...", "source": "./plugins/turbo-plugin" }`

**Approach**:
- `plugin.json` 參考 `plugins/turbo-dev-pack/.claude-plugin/plugin.json` 格式
- `CHANGELOG.md` 參考既有 plugin 的 Keep-a-Changelog 結構,初版只有 `[0.1.0]` + `[Unreleased]` 空段
- Helper functions 從既有 5 個 tgs scripts 抽出(`pull-from-svn.ps1` 等的 `Get-MainWorktree` 完全相同);bash 版同步實作
- PowerShell helpers 用 `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'` 開頭(CLAUDE.md 約定)
- Bash helpers 用 `set -euo pipefail` 開頭
- `Probe-GitVersion` 在每個會用到 `--path-format=absolute` 的 script 開頭呼叫一次,< 2.31 立即 throw

**Patterns to follow**:
- 既有 `plugins/turbo-git-with-remote-svn/scripts/pull-from-svn.ps1` 開頭 9 行(StrictMode + ErrorAction + Get-MainWorktree 函式)
- 既有 `plugins/turbo-dev-pack/.claude-plugin/plugin.json` 為 plugin.json 格式範本
- `plugins/turbo-git-with-remote-svn/scripts/resolve-iis-settings.ps1` lines 11-25 的 `Resolve-RepoPath` 路徑處理

**Test scenarios**:
- Manual: 在 Claude Code session `/plugin` 安裝 marketplace,看到 `turbo-plugin` 出現於可安裝清單
- Manual: 安裝後跑任何 turbo-plugin 內 script,`Get-MainWorktree` 在 main / peer worktree 都回正確絕對路徑
- Manual: 在 Git 2.30 環境跑 `Probe-GitVersion` 應 fail 帶清楚升級訊息(若可降版測試);Git 2.31+ 應通過
- Manual: `Test-IsMainWorktree` 在主 worktree 回 `$true`、peer worktree 回 `$false`、submodule 內回 `$true` 或 `$false` 不重要因為 `Test-IsSubmodule` 應先攔(這個交叉行為要明確驗證一次)

**Verification**: `plugins/turbo-plugin/` 目錄 + manifest + helper lib 三件齊備;`marketplace.json` 第 5 entry 加入;`/plugin` 可看到並安裝 `turbo-plugin`;helper functions 在 main / peer / submodule 三種 context 行為符合預期。

### U2. hooks/hooks.json + PostToolUse EnterWorktree + SessionStart scripts

**Goal**: plugin 自帶 hooks 安裝即 active;PostToolUse 自動補 applicationhost.config(從 stdin `tool_response.worktreePath` 取新路徑而非 `$CLAUDE_PROJECT_DIR`);SessionStart 提示性 3 分支 + pre-check(non-git / submodule silent exit)。

**Requirements**: R9(雙 hook 設計 + 集中目錄 + Pattern A/B 偵測)

**Dependencies**: U1(shared lib for `Test-IsSubmodule` / `Test-IsMainWorktree` / `Get-NormalizedAbsolutePath`)

**Files**:
- `plugins/turbo-plugin/hooks/hooks.json`(新)— `{ "description": "...", "hooks": { "PostToolUse": [{ "matcher": "EnterWorktree", "hooks": [...] }], "SessionStart": [{ "matcher": "*", "hooks": [...] }] } }` 包裝格式
- `plugins/turbo-plugin/scripts/hooks/posttooluse-enterworktree.ps1`(新)— 讀 stdin JSON,從 `tool_response.worktreePath` 取新 worktree 絕對路徑(已實機驗證為展開後絕對路徑,見 origin Resolve Before Planning Resolved);呼叫 `Update-ApplicationhostConfig <new-worktree-path>` 改寫 site 的 physicalPath(atomic 寫 temp + rename;idempotent 讀回比對若已正確 skip 寫);不存在 `.turbo-plugin/` marker 則 silent exit
- `plugins/turbo-plugin/scripts/hooks/posttooluse-enterworktree.sh`(新)
- `plugins/turbo-plugin/scripts/hooks/sessionstart.ps1`(新)— pre-check 順序:(1) `git rev-parse --is-inside-work-tree` 失敗 → silent exit;(2) `Test-IsSubmodule` 非空 → silent exit;通過 pre-check 進三分支:(i) marker 存在 + applicationhost.config physicalPath 不對 → system message「請手動執行 `/tp-setup` 完成本 worktree 設定」;(ii) marker 存在 + `Test-IsMainWorktree` false + 當前 worktree 缺 `dbhub.local.toml` → Pattern B prompt 含 hybrid warning;(iii) marker 不存在 → 算 `MAIN_PATH = dirname(git rev-parse --path-format=absolute --git-common-dir)` 與 `CUR_PATH = git rev-parse --path-format=absolute --show-toplevel`(走 normalize),(iii-a) `MAIN_PATH == CUR_PATH` 時 prompt「請在此目錄執行 `/tp-setup` 完成 bootstrap」、(iii-b) 不等時 prompt「請到 `<MAIN_PATH 的實際值>` 啟動 Claude 並執行 `/tp-setup` 完成 bootstrap」
- `plugins/turbo-plugin/scripts/hooks/sessionstart.sh`(新)
- `Update-ApplicationhostConfig` function **位於 `scripts/lib/applicationhost-helpers.ps1`**(見 U1 Files;hook script + U3 setup case (d) + U9 都 dot-source 引用)— applicationhost.config XML parse(用 .NET `[xml]` 或 `System.Xml.XmlDocument`,**不用 string find/replace**),透過 `<site name>` 跟 `<csproj-stem>-<identity-hash>` match(見 U9 site name suffix scheme),只改 `<application physicalPath>` 與 `<virtualDirectory physicalPath>`;atomic write 經 temp file + rename 替換,idempotent 讀回比對。bash 端 hook script 走 thin wrapper(同 .NET FW Web `.sh` 策略)轉呼叫 `.ps1`,XML edit 完全在 PowerShell 端

**Approach**:
- hooks.json 格式參考 `plugin-dev:hook-development` skill 文件(plugin format wrap 在 `hooks:` 下)
- PostToolUse script 必須**從 stdin JSON `tool_response.worktreePath` 取新 worktree 路徑**,**不能用 `$CLAUDE_PROJECT_DIR`**(它停留 session 啟動位置)。實機驗證見 origin doc Resolve Before Planning Resolved 條目
- SessionStart script 自帶 plugin 即 active(不需 `tp-setup` 跑過),hook 跑表示 plugin enabled
- 三分支 (iii) 的「主 worktree 路徑算出後 plug 進 prompt」由 hook script 在執行時計算,**不能在 prompt 文字 hard-code**
- 寫 hook output 為 JSON `{}` + exit 0(per plugin-dev:hook-development)

**Technical design**:

```
PostToolUse EnterWorktree:
  stdin → JSON.parse → tool_response.worktreePath = NEW_PATH
  if not exist NEW_PATH/.turbo-plugin → silent exit
  apphost_target = NEW_PATH/.vs/<sln>/config/applicationhost.config  (or default location by sln/.csproj)
  apphost_source = NEW_PATH/.turbo-plugin/applicationhost.config
  if not exist apphost_source → silent exit (尚未 setup)
  copy apphost_source → apphost_target (若 target 不存在)
  parsed = XML.parse(apphost_target)
  for each <site name>: if name matches <csproj-stem>-<identity-hash>:
      update <application physicalPath> + <virtualDirectory physicalPath> to NEW_PATH
  new_content = XML.serialize(parsed)
  if read(apphost_target) == new_content → skip write (idempotent)
  else atomic write: temp_file = apphost_target + ".tmp"; write new_content to temp_file; rename temp_file → apphost_target
  exit 0

SessionStart * :
  if git rev-parse --is-inside-work-tree fails → silent exit
  if Test-IsSubmodule → silent exit
  if exist .turbo-plugin:
    if applicationhost.config physicalPath wrong → emit "請執行 /tp-setup" message
    elif not Test-IsMainWorktree and not exist .turbo-plugin/dbhub.local.toml → emit Pattern B prompt with hybrid warning
    else → silent exit (everything ok)
  else: # marker missing — plugin installed but bootstrap not done
    MAIN_PATH = Get-NormalizedAbsolutePath(dirname(git rev-parse --path-format=absolute --git-common-dir))
    CUR_PATH = Get-NormalizedAbsolutePath(git rev-parse --path-format=absolute --show-toplevel)
    if MAIN_PATH == CUR_PATH → emit "請在此目錄執行 /tp-setup 完成 bootstrap"
    else → emit "請到 <MAIN_PATH> 啟動 Claude 並執行 /tp-setup 完成 bootstrap"
  exit 0
```

(directional guidance,implementer 不需逐行重現)

**Patterns to follow**:
- `plugin-dev:hook-development` skill 範例的 plugin format(`{ description, hooks: { Event: [...] } }`)
- 既有 `plugins/turbo-dotnet-framework-commands/skills/setup/SKILL.md` 對 applicationhost.config 處理的文字描述為 hook script 中 site name match 邏輯藍本
- `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Continue'`(probe-style,hook 必須不能 fail 拖累整個 session)— 跟 brainstorm probe scripts 一致

**Test scenarios**:
- Manual: 安裝 plugin 後,在主 worktree 跑 Claude `EnterWorktree` tool 進 peer worktree → PostToolUse 觸發 → applicationhost.config 對應 site 的 physicalPath 被改寫為新 worktree 路徑(其他 site 不動);第二次跑同 EnterWorktree → idempotent 不再寫(可用檔 mtime 確認)
- Manual: 在 main worktree 啟 Claude session(無 marker)→ SessionStart 跑分支 (iii-a),提示「請在此目錄執行 /tp-setup」
- Manual: 在 peer worktree 啟 Claude session(無 marker)→ SessionStart 跑分支 (iii-b),提示含主 worktree 實際路徑
- Manual: 在 submodule 內啟 Claude session → silent exit(無 prompt)
- Manual: 在非 git 目錄啟 Claude session(例如 `C:\Users\<name>`)→ silent exit
- Manual: marker 存在 + applicationhost.config 對應 site physicalPath 已正確 → silent exit(無多餘 prompt)
- Manual: Pattern A 場景(主 worktree 啟 + EnterWorktree 進 peer)→ peer 內沒 dbhub.local.toml 不會被 SessionStart 分支 (ii) 干擾(因為 session 是在主 worktree 啟動,session start 時看 main worktree 有 dbhub.local.toml,branch (ii) 不 fire)
- Manual: Pattern B 場景(直接 peer 啟 Claude + peer 缺 dbhub.local.toml)→ SessionStart 分支 (ii) 觸發,prompt 含 hybrid warning

**Verification**: hooks/hooks.json 與兩 hook script 安裝即生效;`PostToolUse EnterWorktree` 在新 worktree cwd 下執行(實機驗證已確認),正確讀 stdin 並改寫 applicationhost.config(atomic + idempotent);SessionStart 在每個 Claude session 啟動觸發,4 條 pre-check + 三分支邏輯走對。

### U3. tp-setup skill(4 cases 整合入口)

**Goal**: 唯一設定入口,整合新建專案 / 接管現有 git+SVN / 主 worktree 補設定 / peer-mode 四 case;env-free 設計實作;`.turbo-plugin/` 集中目錄建立;外部依賴可用性檢查 + user-level env prompt;`.commitlintrc.json` + `CLAUDE.md` convention 段寫入。

**Requirements**: R5、R6、R7、R8、R9(case (a)/(b)/(c)/(d) + 集中目錄 + 雙 hook 寫進 plugin 而非 setup);F1 整條 flow

**Dependencies**: U1(plugin scaffolding + shared lib)、U2(hooks 自帶但 setup 也要寫 applicationhost.config source-of-truth 進 `.turbo-plugin/`)

**Files**:
- `plugins/turbo-plugin/skills/tp-setup/SKILL.md`(新)— frontmatter `user-invocable: true`,description 走 conservative(「使用者明確要求 setup 時執行;agent 偵測到 marker 不存在 / 不一致時可建議使用者執行」),body 為 Procedure / Decision Rules / Completion Checks
- `plugins/turbo-plugin/default-files/.turbo-plugin/config.toml`(新)— template 含 `schema_version = 1`、`[build]`、`[frontend]` 全段註解掉、`[publish]` 例、`[run]` 例(`# listening_timeout_seconds = 30` 註解形式作為提示讓使用者知道 IIS Express 冷啟可調高)
- `plugins/turbo-plugin/default-files/.turbo-plugin/applicationhost.config`(新)— IIS Express config template,跨 worktree 共用 source-of-truth
- `plugins/turbo-plugin/default-files/.turbo-plugin/dbhub.example.local.toml`(新)— dbhub.local.toml 範本(無 credentials)
- 可選 `plugins/turbo-plugin/skills/tp-setup/assets/claudemd-convention-snippet.md`(新)— `CLAUDE.md` 注入的 Commit Type Convention 段文字
- `plugins/turbo-plugin/skills/tp-setup/assets/commitlintrc-template.json`(新)— `.commitlintrc.json` 範本(11+1 類)

**Approach**:
- SKILL.md 走 long orchestrator skill body 模式(參考既有 `plugins/turbo-git-with-remote-svn/commands/push-to-svn.md` 結構);Procedure 列出四 case 偵測訊號 + 對應動作
- **Case 偵測順序**(在 Procedure 開頭):(1) `Probe-GitVersion` < 2.31 → fail loudly + 升級提示(放第 1 步讓版本錯誤最先攔下,F8 fix);(2) `Test-IsSubmodule` 非空 → 拒跑提示「submodule 不在 turbo-plugin 管理範圍內」;(3) `.git` 不存在 → case (a);(4) `Test-IsMainWorktree` false → case (d) peer-mode,若 marker 不存在拒跑「請先在主 worktree 跑 case (a)/(b)」;(5) `.turbo-plugin/` 不存在 + `.git` 存在 + SVN remote URL 偵測(`<proj>.worktrees/remote-main/.svn/` 或詢問)→ case (b);(6) `.turbo-plugin/` 存在 → case (c)
- **case (a) 新建**(以下 sub-step 順序為 SVN obstruction 避免關鍵,**不可重排**):
  1. `git init` 在當前目錄
  2. 寫入 `.gitignore` 預設 patterns(`.claude/**/*.local.*`、`.turbo-plugin/**/*.local.*` 等)
  3. 建 `.turbo-plugin/` 集中目錄(複製 default-files template)
  4. 寫入 `.commitlintrc.json` 與 `CLAUDE.md` convention 段(idempotent)
  5. prompt SVN URL
  6. **建 `remote/main` orphan branch + worktree**(順序敏感,跟既有 tgs `init-from-existing` 一致):(6a) `git worktree add --detach --no-checkout "<proj>.worktrees/remote-main"` ——`--no-checkout` 確保新 worktree 目錄為空,讓 svn checkout 不被 obstruction;(6b) cd 進該 worktree;(6c) `git checkout --orphan remote/main`;(6d) `git rm -rf --cached .` + `git commit --allow-empty -m "init: remote/main branch"`(初始 empty commit,讓 remote/main 為 proper branch;此步驟跟既有 `init-from-existing.md` line 139-153 一致,避免後續 `tp-pull-from-svn` merge 時遇 'unrelated histories' error)— `tp-pull-from-svn` lift 自既有 tgs 已含 `--allow-unrelated-histories` 處理;(6e) `svn checkout <url> .`——此時 dir 空 svn 可進;(6f) 寫入 svn 跨 worktree `svn:ignore` 預設 patterns(從 main worktree `svn propset --revprop` 或同 worktree `svn propset`)
  7. 跑外部依賴可用性檢查(msbuild / IIS Express / svn CLI / Docker)
  8. 必要時 user-level env prompt(`TURBO_PLUGIN_IIS_EXPRESS_PATH` / `TURBO_PLUGIN_MSBUILD_PATH`)
  9. 完成 — `.turbo-plugin/` marker 已存在,後續任一 worktree 開啟即被 hook 識別
- **case (b) init-from-existing**:`.git/config` `git config --get svn-remote.svn.url` 非空 → 警告「turbo-plugin 不相容 git-svn,請移除 git-svn 設定」,等使用者確認移除後再繼續 → prompt SVN URL → 建 `remote/main` orphan branch + worktree + svn checkout → 後續同 (a) 寫 `.turbo-plugin/` + ignore + convention
- **case (c) 主 worktree 補設定**:檢查並補建缺失項目(例如 `dbhub.local.toml`、外部依賴可用性、user-level env);**idempotent** — 已存在的 git-versioned shared files 不覆寫
- **case (d) peer-mode**:**只**處理 per-peer non-shared files——(d.1) 若 peer 內缺 `dbhub.local.toml` 則 prompt 使用者複製主那份或互動填值、(d.2) 改寫 peer 的 `applicationhost.config` physicalPath(若 PostToolUse hook 漏跑);**不碰**任何 git-versioned shared files(`config.toml` / `applicationhost.config` source-of-truth / `dbhub.example.local.toml` 範本 / `.commitlintrc.json` / `CLAUDE.md`);要求 marker 已存在才能跑
- **外部依賴可用性檢查**:`msbuild --version`(若 fail,prompt user-level `TURBO_PLUGIN_MSBUILD_PATH` 設到 `~/.claude/settings.json`)、`iisexpress.exe` 標準位置(prompt `TURBO_PLUGIN_IIS_EXPRESS_PATH`)、`svn --version`、`docker --version`(dbhub 要 Docker)— 缺什麼 fail loudly 報訊
- **不**裝 husky / 不裝 commit-msg hook / 不裝任何 npm 工具鏈

**Patterns to follow**:
- 既有 `plugins/turbo-git-with-remote-svn/commands/init-from-existing.md` 為 case (b) 文字結構藍本(SVN URL prompt + remote worktree 建立步驟)
- 既有 `plugins/turbo-dev-pack/skills/setup/SKILL.md` 為一問一答 env prompt 模式
- 既有 `plugins/turbo-dotnet-framework-commands/skills/setup/SKILL.md` 為 applicationhost.config 偵測 prose
- 既有 `plugins/turbo-plugins-integration/skills/setup-all/SKILL.md` 為 worktree discovery 模式(setup-all 砍但概念保留)

**Test scenarios**:
- Covers AE8: 在現有 git+SVN 專案(`.git/config` 含 `[svn-remote "..."]`)觸發 → 警告「不相容 git-svn」並暫停,使用者確認後續走
- Covers AE9: 新環境偵測不到 IIS Express / MSBuild 標準位置 → prompt 設 user-level env;寫到 `~/.claude/settings.json` 不是 repo-level
- Covers AE10: 新建場景 `tp-setup` 偵測無 `.git` 也無 `.turbo-plugin/` → 從零建立 git repo + main worktree + `.turbo-plugin/` + `.gitignore` + `svn:ignore` + `.commitlintrc.json` + `CLAUDE.md` convention 段 + prompt SVN URL 後建 remote-main worktree;結束時 marker 存在,後續任一 worktree 開啟即被 hook 識別
- Manual: case (c) 補設定 idempotent — 已存在的 shared files 不覆寫;`dbhub.local.toml` 缺則 prompt 但 example template 不重寫
- Manual: case (d) peer-mode 在 marker 不存在的 peer 拒跑;marker 存在 + peer 缺 dbhub.local.toml 時建立(不碰其他 shared files)
- Manual: submodule 內跑 → 拒跑提示「不在管理範圍內」
- Manual: Git < 2.31 環境(若可降版)→ fail loudly 帶升級提示
- Manual: 跑兩次 `tp-setup` case (c) 不會破壞既有設定(idempotent)
- Manual: `.commitlintrc.json` 注入後再跑 `tp-setup` 不重複追加 type 條目;`CLAUDE.md` convention 段亦同

**Verification**: 四 case 各自跑通對應 AE8/AE9/AE10/manual scenarios;idempotent 行為驗證(case (c) / case (d) 跑兩次無 side-effect);submodule 與 Git 版本邊界正確拒跑。

### U4. .mcp.json with tp-dbhub MCP server

**Goal**: plugin 自帶 `.mcp.json` 宣告 `tp-dbhub` MCP server(過渡期重新命名避免與既有 `tdp:dbhub` 碰撞);設定路徑用 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml`(已實機驗證 Claude Code 會展開且 session 啟動鎖定)。

**Requirements**: R8(dbhub MCP 透過 `.mcp.json` 宣告 + `${CLAUDE_PROJECT_DIR}` 展開)、R4 cutover(過渡期改名 `tp-dbhub`)

**Dependencies**: U3(tp-setup 建立 `.turbo-plugin/dbhub.example.local.toml` template;`dbhub.local.toml` 由使用者複製填值)

**Files**:
- `plugins/turbo-plugin/.mcp.json`(新)— 宣告 `tp-dbhub` server,Docker stdio transport,`-v` mount `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml:/dbhub.toml`,其他參數依既有 `plugins/turbo-dev-pack/.mcp.json` 的 `dbhub` 區段轉抄

**Approach**:
- 直接從既有 `plugins/turbo-dev-pack/.mcp.json` 的 `dbhub` server entry copy 過來
- **改名**:`"dbhub"` → `"tp-dbhub"`(避免 Claude Code 同 session 兩個 server 同名碰撞)
- **改路徑**:Docker `-v` mount 從 `${DBHUB_TOML_FILE_PATH}:/dbhub.toml`(env-var)改為 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml:/dbhub.toml`(Claude Code 變數展開,實機驗證見 origin Resolve Before Planning Resolved)
- 其他 image / args 等保持不變

**Patterns to follow**:
- `plugins/turbo-dev-pack/.mcp.json` 的 `dbhub` server entry(Docker image 名 + args + `-v` mount 寫法)

**Test scenarios**:
- Manual: 安裝 turbo-plugin 後在主 worktree 啟 Claude session,觀察 MCP server `mcp__tp-dbhub__*` 在 tool list 出現
- Manual: 主 worktree 有 `.turbo-plugin/dbhub.local.toml`(內含 valid DB credentials)時,`mcp__tp-dbhub__*` tool 可正常運作(連上 DB)
- Manual: peer worktree 直接啟 Claude(Pattern B)且該 peer 沒 `dbhub.local.toml` → MCP server launch 失敗或讀檔失敗,Claude 中應有清楚錯誤訊息(non-silent)
- Manual: 同時安裝既有 `tdp`(內含 `dbhub` server)與 `turbo-plugin`(內含 `tp-dbhub` server),tool list 兩個都看得到、命名不碰撞

**Verification**: `tp-dbhub` MCP server 在 Claude session 內可被 list 與呼叫;`.local.toml` 缺檔時 fail loudly 不靜默;命名不碰撞既有 `tdp:dbhub`。

### U5. tp-pull-from-svn + tp-svn-log(SVN 讀操作 + lift from tgs)

**Goal**: 兩個 read-only-ish SVN skills,從既有 tgs 大量 lift,主要 delta 是去 env 化 + 用 shared lib 的 `Get-MainWorktree` 等。

**Requirements**: R10、F2 部分(pull-from-svn 為 proactive suggestion only;svn-log 為 agent-proactive)

**Dependencies**: U1(shared lib);U3(`.turbo-plugin/config.toml` 提供 default 等)

**Files**:
- `plugins/turbo-plugin/skills/tp-pull-from-svn/SKILL.md`(新)— frontmatter `user-invocable: true`,description 走 conservative
- `plugins/turbo-plugin/skills/tp-svn-log/SKILL.md`(新)
- `plugins/turbo-plugin/scripts/pull-from-svn.ps1`、`.sh`(lift)
- `plugins/turbo-plugin/scripts/svn-log.ps1`、`.sh`(lift,去掉 `TGS_SVN_LOG_DEFAULT_*` env 讀取改 CLI args / `config.toml`)

**Approach**:
- `pull-from-svn` script lift 自 `plugins/turbo-git-with-remote-svn/scripts/pull-from-svn.{ps1,sh}` — main worktree clean check → svn update in remote-* worktree → commit to `remote/*` branch → merge into working branch → 衝突報告
- `svn-log` script lift 自 `plugins/turbo-git-with-remote-svn/scripts/svn-log.{ps1,sh}` — 改 env 讀取為 CLI args + optional `config.toml` 預設
- SKILL.md description 為 conservative(讓 0.2.0 cutover 後再升級)

**Patterns to follow**:
- 既有 `plugins/turbo-git-with-remote-svn/scripts/pull-from-svn.ps1` 整個檔(直接 lift)
- 既有 `plugins/turbo-git-with-remote-svn/scripts/svn-log.ps1` 整個檔(直接 lift + 去 env)
- 既有 `plugins/turbo-git-with-remote-svn/commands/pull-from-svn.md` 為 SKILL.md body 文字結構藍本

**Test scenarios**:
- Manual: 在有 svn 變更的 remote-main worktree 跑 `/tp-pull-from-svn` → 正確同步,merge 進主 working branch
- Manual: working branch 不乾淨(uncommitted 變動)→ skill 拒跑提示先 commit / stash
- Manual: `/tp-svn-log` 顯示 remote worktree SVN log(指定 `-Limit 20` 等 args 行為跟原 tgs `svn-log` 一致)
- Manual: SVN 衝突 → skill 提示解衝突,不靜默 fallback

**Verification**: 兩 skill 在 main worktree 跑通;script 行為與既有 tgs 對等(無 regression);env 完全不需設。

### U6. tp-push-to-svn(orchestrator + 自 parse subject + 12 類 commit type 篩選)

**Goal**: SVN push 唯一入口,自 parse 每個待推送 commit subject 篩 SVN history;unknown type prompt 使用者(R12);UTF-8 no-BOM commit message。

**Requirements**: R10、R12、R18(commit type 篩選 source-of-truth);F2(完整 SVN push flow)

**Dependencies**: U1(shared lib `Resolve-RemoteWorktree`、`Write-Utf8NoBom`)、U3(`.commitlintrc.json` 已由 tp-setup 寫入提供 11+1 類為純諮詢來源)

**Files**:
- `plugins/turbo-plugin/skills/tp-push-to-svn/SKILL.md`(新)— **long orchestrator skill body**,結構完整 Procedure / Decision Rules / Completion Checks;**自 parse 邏輯寫在 SKILL.md body**(agent 依描述執行),script 處理機械步驟
- `plugins/turbo-plugin/scripts/push-to-svn-prepare.ps1`、`.sh`(lift)— stage merge with `--no-ff --no-commit`,emit COMMITS / FILES sections
- `plugins/turbo-plugin/scripts/push-to-svn-commit.ps1`、`.sh`(lift)— finalise merge,`svn add` / `delete` / `commit --file <tmp> --encoding UTF-8`,UTF-8 no-BOM 寫 commit message

**Approach**:
- SKILL.md body 結構(參考既有 `plugins/turbo-git-with-remote-svn/commands/push-to-svn.md`):
  1. **Step 1**: main worktree clean check
  2. **Step 2**: 跑 `push-to-svn-prepare.ps1` 取得 COMMITS / FILES sections
  3. **Step 3 (新邏輯)**: **逐 commit parse subject**:
     - **Parse 範圍**:**只看 subject 第一行**(`git log --format=%s`);regex `^(?<type>[a-z]+)(\(.+\))?!?:` 取 leading type;`revert: feat: ...` 等 nested 只看外層 `revert:` 不解內層
     - **Valid type 動態讀取 + 安全 fallback**:runtime 從 repo root `.commitlintrc.json` 讀 `rules.type-enum[2]` 拿當下 convention 認的 type 清單,使用者改 `.commitlintrc.json` 加/刪 type 自動同步;**fallback**:檔案不存在 / parse 失敗 / `rules.type-enum[2]` 非 array(例如使用者只寫 `{"extends": ["@commitlint/config-conventional"]}` 不顯式 rules,這是 commitlint 標準寫法)→ 用 **hard-coded default 12 類(conventional commits 11 + `db`)** + stderr 印 one-line notice「using built-in default 12-type list; customize by adding `rules.type-enum` to `.commitlintrc.json`」,**不靜默失敗也不 fail 拒跑**
     - **Kept-subset(turbo-plugin 篩選 source-of-truth,hard-code 在 push-to-svn script)**:`feat` / `fix` / `refactor` / `perf` / `revert` → 進入 SVN message body
     - **篩除**:type 在 valid 但不在 kept-subset(`docs` / `test` / `chore` / `style` / `build` / `ci` / `db` 等)→ 不上 SVN
     - **`Merge ` 開頭(無 conventional prefix)** + **`git-svn-id:` trailer 自動 commit**:按上述「無 leading type」自然走 unknown type 分支但 `Merge ` 開頭 hard-code 為篩除(避免 prompt 噪音);git-svn-id 已不存在(turbo-plugin 不用 git-svn)
     - **unknown type**(parse 不到 leading type,或 type 不在 valid types):`AskUserQuestion` prompt「(1) 保留進 SVN / (2) 篩除 / (3) 取消 push 讓使用者先 amend commit message」
  4. **Step 4**: 將篩選後 commit body 組裝為 SVN commit message
  5. **Step 5**: `AskUserQuestion` 確認最終 SVN message(Accept / Edit title / Cancel)
  6. **Step 6**: 跑 `push-to-svn-commit.ps1` 執行 svn commit(UTF-8 no-BOM 經 temp file + `--file <tmp> --encoding UTF-8`)
- script 部分**完全 lift 既有 tgs** — UTF-8 no-BOM 寫 + `svn commit --file <tmp> --encoding UTF-8` 是 load-bearing pattern(Windows CP_ACP/Big5 否則會 mangle 中文)
- SKILL.md description **走 proactive suggestion only**(不是 conservative 也不是 agent-proactive):agent 偵測到「使用者完成一輪改動準備 push」狀態應**建議**使用者執行,但需明確同意才執行(因為 SVN history 永久留下)

**Patterns to follow**:
- 既有 `plugins/turbo-git-with-remote-svn/commands/push-to-svn.md` 整個 body(orchestrator pattern + AskUserQuestion 互動)
- 既有 `plugins/turbo-git-with-remote-svn/scripts/push-to-svn-prepare.ps1`、`push-to-svn-commit.ps1`(lift)
- UTF-8 no-BOM pattern lines 76-80 + 130 of `push-to-svn-commit.ps1`(load-bearing,不可改)

**Test scenarios**:
- Covers AE3: 5 個 commit 含 `feat:` / `db:` / `docs:` / `fix:` / `test:`,push 後 SVN 只收 `feat:` + `fix:` body;本地 git history 保留全部 5 個
- Covers AE3b: commit subject 無 conventional prefix(例如 `update parser logic`)→ skill prompt 三選一,使用者選「取消 push 讓使用者先 amend」→ push 中止
- Manual: SVN message 含繁體中文 → svn 收到的 message 正確編碼(用 `svn log` 確認)
- Manual: 連續 `perf:` / `revert:` 也正確保留(R12 新增 perf/revert 為保留類別,需驗)
- Manual: 自動 commit(`Merge ` 開頭)被自然篩除,無需 prompt
- Manual: working branch 不乾淨 → 拒跑

**Verification**: SVN history 只含篩選後 commit body;unknown type 在 push 階段被攔下 prompt;UTF-8 中文不 mangle;本地 git history 完整保留。

### U7. tp-create-remote-test + tp-reset-remote-test(test 分支管理)

**Goal**: 管理 `remote/test-<n>` 分支的 git-svn 同步機制;移除既有 tgs 的 `dev-<n>` worktree(brainstorm 已聲明開發 worktree 由 ce-worktree 或手動 `git worktree add` 提供)。

**Requirements**: R11(worktree 模型保留 main + remote-main + remote-test-<n>)

**Dependencies**: U1(shared lib)、U3(`.turbo-plugin/` 已建立)

**Files**:
- `plugins/turbo-plugin/skills/tp-create-remote-test/SKILL.md`(新)
- `plugins/turbo-plugin/skills/tp-reset-remote-test/SKILL.md`(新)
- `plugins/turbo-plugin/scripts/create-remote-test.ps1`、`.sh`(lift)
- `plugins/turbo-plugin/scripts/reset-remote-test.ps1`、`.sh`(lift)

**Approach**:
- `create-remote-test` lift 自 `plugins/turbo-git-with-remote-svn/scripts/create-remote-test.{ps1,sh}` — 處理 svn-copy-from-trunk(target SVN URL 不存在時)、orphan-init-commit base 避免 SVN obstruction
- `reset-remote-test` lift 自 `plugins/turbo-git-with-remote-svn/scripts/reset-remote-test.{ps1,sh}` + `commands/reset-remote-test.md` — `--diff-only` preview mode + `git reset --hard main` + auto-switch-back
- 兩 skill 都是 **proactive suggestion only**(影響外部 SVN state)
- **移除** dev-<n> worktree 邏輯(原 tgs 服務 tdp 開發流程;這次撤退)

**Patterns to follow**:
- 既有 `plugins/turbo-git-with-remote-svn/scripts/create-remote-test.ps1`、`reset-remote-test.ps1` 整檔
- 既有 `plugins/turbo-git-with-remote-svn/commands/reset-remote-test.md` 為 SKILL.md body 模板

**Test scenarios**:
- Manual: SVN trunk 有內容、target test SVN URL 不存在 → `tp-create-remote-test 1` 建立 `<proj>.worktrees/remote-test-1/` worktree、svn-copy-from-trunk、`remote/test-1` branch、local `test-1` branch;`tp-reset-remote-test 1` 從 main 重設 test-1
- Manual: `--diff-only` 預覽不寫
- Manual: 已存在 remote-test-2 後 create remote-test-3 不衝突
- Manual: 砍掉 dev-<n> 沒對其他流程造成 regression(verify by reading 既有 plugins 不依賴 dev-<n>)
- Covers AE5: 使用者用 `/ce-worktree` 或手動 `git worktree add ../feature-x -b feature-x` 開新 worktree,新 worktree 與 turbo-plugin 的 SVN bridge worktree(`remote-main` / `remote-test-<n>`)並存不互相干擾(driver scripts 用 `Resolve-RemoteWorktree` 不誤撈)

**Verification**: 兩 skill 跟既有 tgs `create-remote-test` / `reset-remote-test` 對等;dev-<n> 不再被建立。

### U8. tp-build-dotnet-framework-web + tp-publish-dotnet-framework-web(.NET FW 建置 + 發佈)

**Goal**: MSBuild build + publish chain,env-free 改從 `.csproj` / `.sln` / `.pubxml` 自動偵測 + `config.toml` + CLI args 取得設定。

**Requirements**: R13(設定走 R9 4 層 lookup)、R17(`tp-publish` 內含 pack-content)

**Dependencies**: U1(shared lib)、U3(`config.toml` 為設定 source)

**Files**:
- `plugins/turbo-plugin/skills/tp-build-dotnet-framework-web/SKILL.md`(新)
- `plugins/turbo-plugin/skills/tp-publish-dotnet-framework-web/SKILL.md`(新)
- `plugins/turbo-plugin/scripts/build-web.ps1`(lift,native)
- `plugins/turbo-plugin/scripts/build-web.sh`(新,thin wrapper:`powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/build-web.ps1" "$@"`)
- `plugins/turbo-plugin/scripts/pack-content.ps1`(lift,native)
- `plugins/turbo-plugin/scripts/pack-content.sh`(新,thin wrapper)
- `plugins/turbo-plugin/scripts/publish-web.ps1`(lift,native)
- `plugins/turbo-plugin/scripts/publish-web.sh`(新,thin wrapper)

**Approach**:
- `build-web` lift 自 `plugins/turbo-dotnet-framework-commands/scripts/build-web.ps1`,**去 env** — `BUILD_PROJECT_PATH` 改自 `.csproj`/`.sln` 自動偵測;`BUILD_MSBUILD_PATH` 改自 VS 標準位置 + user-level `TURBO_PLUGIN_MSBUILD_PATH` fallback
- `pack-content` lift,合進 `tp-publish` skill body(R17 — 「pack-content 邏輯併入 publish」)
- `publish-web` lift 自 `plugins/turbo-dotnet-framework-commands/scripts/publish-web.ps1`;`.pubxml` parsing + `PublishProfile` / `PublishProfileRootFolder` 參數 + post-publish `PublishUrl` resolution
- **R9 4 層 lookup**:(1) skill argument → (2) `.turbo-plugin/config.toml` `[build]` / `[publish]` 區段 → (3) 內建 default(`Debug` / `Any CPU` 等)→ (4) fail with 清楚訊息
- `tp-build` 為 agent-proactive(可逆 — build 失敗重跑);`tp-publish` 為 proactive suggestion only(產出 artifact 可能被 CD pipeline 消費)

**Patterns to follow**:
- 既有 `plugins/turbo-dotnet-framework-commands/scripts/build-web.ps1`、`publish-web.ps1` 整檔結構
- `Resolve-RepoPath` Git Bash 路徑轉換 lines 11-25 of `resolve-iis-settings.ps1`

**Test scenarios**:
- Manual: 標準 `.csproj` + `config.toml` `[build] configuration = "Release"` → build 跑通 Release 配置
- Manual: `tp-build --configuration Debug` argument override 走通
- Manual: `config.toml` 沒寫 → 用 internal default Debug / Any CPU
- Manual: `tp-publish` 指定 `.pubxml` 跑通,artifact 落到 `<PublishUrl>`
- Manual: 多個 `.pubxml` 存在 → 用 `config.toml` `default_pubxml` 或 argument 選
- Manual: `frontend.dir` + `frontend.build_command = "yarn dev-build"` → `tp-publish` 內含 pack-content 跑前端 build(yarn install + yarn dev-build)再 publish
- Manual: `frontend` 整段省略 → publish 無前端 build 步驟
- Manual: MSBuild 不在標準位置且無 user-level env → fail loudly 提示「請設 `TURBO_PLUGIN_MSBUILD_PATH`」

**Verification**: build / publish 跟既有 tnf 對等;env 完全不設;4 層 lookup chain 各層都驗;前端 build 條件分支正確。

### U9. tp-run-dotnet-framework-web + tp-stop-dotnet-framework-web + 新 IIS Express identity

**Goal**: IIS Express 啟動 / 停止 + 跨 worktree 自動 self-heal(R15 (a) 自動停舊 instance);**新 identity 算法** = `(port + project identity)` 複合 key,project identity 寫進 site name suffix 讓 wmic / `Get-CimInstance` 撈得到。

**Requirements**: R13、R14(complex)、R15、R16、R17(listening 健康檢查)

**Dependencies**: U1(shared lib `Get-NormalizedAbsolutePath` / `Probe-GitVersion`)、U2(applicationhost.config 已由 PostToolUse 改寫對應 site)、U3(`.turbo-plugin/applicationhost.config` 為 source-of-truth)、U8(build 在前)

**Files**:
- `plugins/turbo-plugin/skills/tp-run-dotnet-framework-web/SKILL.md`(新)
- `plugins/turbo-plugin/skills/tp-stop-dotnet-framework-web/SKILL.md`(新)
- `plugins/turbo-plugin/scripts/start-iis.ps1`(lift `start-iis-detached.ps1` + 改 identity)
- `plugins/turbo-plugin/scripts/start-iis.sh`(thin wrapper)
- `plugins/turbo-plugin/scripts/stop-iis.ps1`(lift + 改 match key)
- `plugins/turbo-plugin/scripts/stop-iis.sh`(thin wrapper)
- `plugins/turbo-plugin/scripts/check-iis-listening.ps1`(lift)
- `plugins/turbo-plugin/scripts/check-iis-listening.sh`(thin wrapper)
- `plugins/turbo-plugin/scripts/get-target-url.ps1`(lift)
- `plugins/turbo-plugin/scripts/get-target-url.sh`(thin wrapper)
- `plugins/turbo-plugin/scripts/resolve-iis-settings.ps1`(lift + 去 env)
- `plugins/turbo-plugin/scripts/resolve-iis-settings.sh`(thin wrapper)
- `plugins/turbo-plugin/scripts/compute-project-identity.ps1`(**新**)
- `plugins/turbo-plugin/scripts/compute-project-identity.sh`(thin wrapper)— 算 `(git-common-dir-normalized + csproj-relpath-normalized)` 複合 id,輸出格式 `<git-common-dir>#<csproj-relpath>`;同時算出 site name suffix(short hash 例 sha256 first 8 chars)讓 site name = `<csproj-stem>-<identity-hash>`

**Approach**:
- **Project identity 算法(在 `compute-project-identity.ps1`)**:
  1. `git rev-parse --path-format=absolute --git-common-dir` → `Get-NormalizedAbsolutePath` → `GIT_COMMON_DIR`
  2. `.csproj` 對 `git rev-parse --show-toplevel`(亦 normalize)的相對路徑 → `CSPROJ_RELPATH`
  3. `IDENTITY_STRING = GIT_COMMON_DIR + "#" + CSPROJ_RELPATH`
  4. `IDENTITY_HASH = sha256(IDENTITY_STRING)` 前 8 字元 → site name suffix
  5. site name = `<csproj-stem>-<IDENTITY_HASH>`(例 `MyApi-3f7c2b8a`)
- **`tp-run`**(`start-iis.ps1`):
  1. 偵測 port(從 `.csproj` IIS 設定區段 `IISExpressSSLPort` / `IISUrl` / `DevelopmentServerPort`)
  2. 算 project identity + site name
  3. `Get-CimInstance Win32_Process` 找 `iisexpress.exe` instances,parse 各 instance 的 commandLine 取 `/site:<name>` argument
  4. **同 port 已被佔用 + site name match 當前 identity**(R15 a)→ 自動停掉舊 instance(`Stop-Process` by PID)+ 啟新 instance
  5. **同 port 已被佔用 + site name 不 match**(R15 b)→ `AskUserQuestion` prompt 三選一
  6. 無佔用 → 直接啟新 instance
  7. 啟動後跑 `check-iis-listening.ps1` 確認 port 真的可連
- **`tp-stop`**(`stop-iis.ps1`):算 project identity → match site name → `Stop-Process` 對應 instance
- **applicationhost.config 維護**:由 U2 PostToolUse hook 在 EnterWorktree 後改寫對應 site 的 physicalPath;`tp-run` 不負責改 applicationhost.config(只讀)
- **listening 健康檢查 incorporated 進 tp-run**(R17):`Start-Process` 後 polling `netstat -ano | Select-String LISTENING` 直到看到 port 才回報成功。timeout 走 R9 4 層 lookup:(1) skill argument `-Timeout <seconds>` → (2) `config.toml` `[run] listening_timeout_seconds` → (3) default 30(.NET FW 一般夠);冷啟 + first-request JIT 場景使用者可調至 90s

**Technical design**:

```
compute-project-identity:
  GIT_COMMON_DIR = Get-NormalizedAbsolutePath(git rev-parse --path-format=absolute --git-common-dir)
  TOPLEVEL = Get-NormalizedAbsolutePath(git rev-parse --path-format=absolute --show-toplevel)
  CSPROJ_RELPATH = (resolved csproj absolute path) → relative to TOPLEVEL, forward slashes, lowercase
  IDENTITY = GIT_COMMON_DIR + "#" + CSPROJ_RELPATH
  HASH = sha256(IDENTITY).Substring(0, 8)
  SITE_NAME = (csproj filename without .csproj) + "-" + HASH

tp-run port=44300:
  identity, site_name = compute-project-identity(.csproj)
  occupied = find iisexpress instance with port 44300 (via Win32_Process commandLine)
  if occupied:
    if occupied.site_name == site_name:
      stop occupied; start new with /site:<site_name>
    else:
      AskUserQuestion 三選一
  else:
    start new with /site:<site_name>
  wait for netstat LISTENING on port 44300, max 30s

tp-stop port=44300:
  identity, site_name = compute-project-identity(.csproj)
  process = find iisexpress with port 44300 AND site=<site_name>
  if process: Stop-Process; else: 無對應 instance
```

**Patterns to follow**:
- 既有 `plugins/turbo-dotnet-framework-commands/scripts/stop-iis.ps1`(`Get-CimInstance Win32_Process` enum 模式;改 match key)
- 既有 `plugins/turbo-dotnet-framework-commands/scripts/start-iis-detached.ps1`(Start-Process pattern)
- 既有 `plugins/turbo-dotnet-framework-commands/scripts/check-iis-listening.ps1`(netstat polling)

**Test scenarios**:
- Covers AE1: worktree B 已啟動專案 X 的 IIS(port 44300),切到 worktree A 跑 `tp-run-dotnet-framework-web` → identity 兩 worktree 同(同 git-common-dir + 同 csproj relpath)→ site name match → 自動停 worktree B 啟的 instance + 在 A 啟新 instance
- Covers AE2: worktree A 已啟動專案 X(port 44300),要跑專案 Y(port 44300,不同 repo)→ identity 不同(不同 git-common-dir)→ site name 不 match → prompt 三選一
- Manual: 同 repo 主 worktree 跟 peer worktree 的 csproj 相對路徑必相同 → identity 同 → cross-worktree match 成立(已實機可驗)
- Manual: `tp-stop` 在 worktree A 跑能殺掉 worktree B 啟的同 project instance(這是 brainstorm 動機 bug 的核心 fix,must verify)
- Manual: `tp-stop` 不殺別 project 同 port instance
- Manual: `tp-run` listening 健康檢查 — 假裝 IIS Express 啟動但 port 沒真的 listening(可故意給壞 config)→ skill 應 timeout 後 fail
- Manual: port 從 `.csproj` 解析失敗(例如只在 `.csproj.user`)→ skill 拒跑提示「請補進 `.csproj`」

**Verification**: stop-iis 跨 worktree 真的殺到別 worktree 的同 project instance(brainstorm 原 bug fix);別 project 同 port 不誤殺;site name 內含 identity hash 在 applicationhost.config + IIS Express process commandLine 兩處都對齊。

### U10. tp-suggest-ignore + tp-csharp-comment + tp-js-comment(lift)

**Goal**: 三個 lift-heavy skill;`tp-suggest-ignore` 為 agent-proactive(可逆 — ignore 寫錯可拿掉);comment skills 為 agent-proactive。

**Requirements**: R19(suggest-ignore 同時處理 git + svn)、R20(comment skills 改名加 `tp-`)

**Dependencies**: U1(shared lib `Resolve-RemoteWorktree` for svn-ignore 跨 remote-* worktree)

**Files**:
- `plugins/turbo-plugin/skills/tp-suggest-ignore/SKILL.md`(lift,改名 `tp-` prefix)
- `plugins/turbo-plugin/skills/tp-csharp-comment/SKILL.md`(lift)
- `plugins/turbo-plugin/skills/tp-csharp-comment/assets/example-with-comments.cs`(lift)
- `plugins/turbo-plugin/skills/tp-js-comment/SKILL.md`(lift)
- `plugins/turbo-plugin/skills/tp-js-comment/assets/example-with-comments.ts`(lift)
- `plugins/turbo-plugin/scripts/svn-ignore.ps1`、`.sh`(lift — list / add / remove `svn:ignore` 跨所有 remote-* worktrees)

**Approach**:
- `tp-suggest-ignore` lift 自 `plugins/turbo-git-with-remote-svn/skills/suggest-ignore/SKILL.md`(256 行,4 categories,direct + analysis 兩 mode,`AskUserQuestion` 確認 flow)— body 幾乎不改,僅 description 走 conservative
- `tp-csharp-comment` / `tp-js-comment` 內容直接 lift 自 `plugins/turbo-dev-pack/skills/csharp-comment/`、`js-comment/`;改名 + description conservative(避 collision with `tdp:csharp-comment` 同時 auto-trigger)
- `svn-ignore.ps1`/`.sh` lift verbatim — list / add / remove with `svn propset svn:ignore --file <tmp>` UTF-8 no-BOM pattern

**Patterns to follow**:
- 既有 `plugins/turbo-git-with-remote-svn/skills/suggest-ignore/SKILL.md`(整檔)
- 既有 `plugins/turbo-dev-pack/skills/csharp-comment/SKILL.md` + `assets/example-with-comments.cs`(整檔)
- 既有 `plugins/turbo-dev-pack/skills/js-comment/SKILL.md` + `assets/example-with-comments.ts`(整檔)

**Test scenarios**:
- Covers AE4: 使用者新增 `local-config.json`(明顯個人設定)→ Claude 偵測 untracked → `tp-suggest-ignore` 主動建議加入 `.gitignore` + `svn:ignore`,使用者確認後兩側都更新
- Manual: `tp-suggest-ignore` analysis mode 對全 repo 掃 untracked 提建議
- Manual: `tp-csharp-comment` 對指定 C# class / method 加 XML doc comment + 解釋性 comment,style 跟既有 tdp 對等
- Manual: `tp-js-comment` 對 `.vue` 內 `<script>` 區塊加 comment 正確處理(同既有 tdp)

**Verification**: 三 skill 跟既有版本對等(content 大量 lift,只改名);`svn-ignore` 跨 remote-* worktrees 一次更新所有。

### U11. End-to-end validation + Cutover dry-run + v0.1.0 release

**Goal**: 完整跑 F1/F2/F3 三 flow + 全部 AE1-AE10 manual 驗證;cutover criteria 達標後 disable / remove 既有 4 plugin;tag v0.1.0;規劃 v0.2.0 description 升 agent-proactive。

**Requirements**: Success Criteria 全部條目;Cutover criteria

**Dependencies**: U1-U10 全部完成

**Files**:
- `plugins/turbo-plugin/CHANGELOG.md`(改)— 確認 `[0.1.0] - 2026-05-22` 區段完整列出 Added 項
- `plugins/turbo-plugin/.claude-plugin/plugin.json`(改 if needed)— version 確認 `0.1.0`
- 無新 source files;本 unit 為驗證 + release 流程

**Approach**:
- **Step 1 — F1 onboarding flow**(覆蓋 AE8/AE9/AE10):
  - 在新 git+SVN 專案 + 既有 git-svn 設定環境驗 case (b) git-svn 警告
  - 在新環境驗 case (a) 從零 bootstrap + `TURBO_PLUGIN_*` env prompt
  - 在已 setup 環境驗 case (c) idempotent 補設定
  - 在 peer worktree 驗 case (d) peer-mode 行為
- **Step 2 — F2 commit → SVN push flow**(覆蓋 AE3/AE3b):
  - 製造 5 個含 mix type 的 commit + push 驗 subject 篩選
  - 製造 unknown type commit + push 驗三選一 prompt + amend 回拳
- **Step 3 — F3 IIS Express flow**(覆蓋 AE1/AE2):
  - 同 project 跨 worktree 啟動 + stop 驗 cross-worktree match
  - 別 project 同 port 衝突驗 prompt 三選一
- **Step 4 — Hook 行為**(覆蓋 AE6/AE6b):
  - Claude 原生 EnterWorktree 進 worktree 驗 PostToolUse 自動補
  - shell 手建 worktree + cd 後啟 Claude 驗 SessionStart 三分支提示
- **Step 5 — Pattern A/B / submodule / 非 git** 邊界:
  - 在 submodule 內啟 Claude 驗 silent exit
  - Pattern A vs Pattern B 啟動驗 dbhub.local.toml 解析路徑差異
- **Step 6 — Cutover criteria 評估**:
  - 完成上述 5 個 step 無 blocker
  - 連續 5 工作日日常使用 turbo-plugin(自動 + 手動觸發)無 blocker → 進 Step 7
- **Step 7 — Cutover**:
  - **Pre-cutover migration**:grep user-authored skills / prompts / docs / dotfiles / `~/.claude/projects/<repo>/memory/*.md` 搜「`mcp__dbhub__*`」使用,改成 `mcp__tp-dbhub__*`(或評估 cutover 後 rename 回 `dbhub` 同步)避免 silent break(decision 9 提及)
  - 在 `.claude/settings.json` 把既有 4 plugin(`tdp` / `tnf` / `tgs` / `tpi`)的 `enabledPlugins` 條目 disable
  - 觀察 1-2 個工作日無 regression(包括 `mcp__tp-dbhub__*` 使用全套件能 work)
  - 從 `.claude-plugin/marketplace.json` 移除既有 4 plugin entries(或保留 marketplace 標記為 deprecated,plugin 目錄保留以利回退)
  - 各 plugin CHANGELOG 加最終一條「<日期>: 由 turbo-plugin 取代,使用者建議移除」
- **Step 8 — 規劃 v0.2.0**:
  - description 升 agent-proactive 觸發語句(R2 完整三層 trigger mode 啟用)
  - 視情況把 dbhub MCP server 從 `tp-dbhub` rename 回 `dbhub`(若不影響使用者 workflow)
  - 寫 `[0.2.0] - <日期>` CHANGELOG 條目

**Execution note**: 此 unit 屬於驗收 + release 性質,不寫新 source。每個 step 在 real Claude Code session 跑 manual scenario。

**Test scenarios**:
- 全部 AE1-AE10 + brainstorm Success Criteria 對應 manual scenarios
- 5 工作日日常使用驗 — 真正用 turbo-plugin 開發 .NET FW Web + SVN bridged 專案,觀察是否有 silent failure / unexpected prompt / hook 沒觸發等

**Verification**: 全部 AE 跑通;cutover criteria 達標;v0.1.0 tag 釋出;既有 4 plugin disable 後無 regression;v0.2.0 description 升級計畫成文。

---

## Risk Analysis & Mitigation

| 風險 | likelihood | impact | mitigation |
|---|---|---|---|
| **Skill description auto-trigger 衝突** 過渡期既有 4 plugin 同時 enabled,`tp-` 跟 `tdp:`/`tnf:`/`tgs:` description 都 match 同條件 → agent 重複觸發或選錯 | 高 | 中 | v0.1.0 ship conservative descriptions(「使用者明確要求才執行」風格);使用者過渡期主要走 `/tp-<skill>` 手動觸發;cutover 後 0.2.0 升級 description。decision 15 已拍板 |
| **Pattern A/B 使用者誤判** 真的 use 起來時 user mental model 不一致,Pattern A 啟動後 EnterWorktree 到 peer 期望 dbhub 共用(成立),Pattern B 啟動後 EnterWorktree 到主期望 dbhub 切換(不成立 — MCP server 鎖定 session 啟動位置) | 中 | 中 | SessionStart 分支 (ii) prompt 已含 hybrid warning;Resolve Before Planning Resolved 條目寫明 Pattern 由 session 啟動位置鎖定;v0.1.0 README 也應有 Pattern A/B 圖解 |
| **MCP server `/compact` 後 relaunch 行為未驗** brainstorm probe 只測 single fresh session,relaunch behavior unknown | 中 | 中 | Deferred to Follow-Up Work 已列;v0.1.0 設計含 fallback「MCP server 找不到 dbhub.local.toml 時 fail loudly」;u4 test scenarios 涵蓋 Pattern B peer 沒檔時的 fail loud 行為 |
| **applicationhost.config 寫入 race** 兩 Claude session 同時 EnterWorktree 同 worktree | 低 | 中 | U2 已加 atomic write(temp + rename)+ idempotent(讀回比對若已正確 skip);race 仍可能但效果同步 |
| **`compute-project-identity` 跨平台 / 跨 Git 版本邊界** Windows junction / symlink / case 不正確 normalize → 同 project 跨 worktree 算出不同 identity → AE1 cross-worktree stop 失效 | 中 | 高(動搖 bug fix) | `Get-NormalizedAbsolutePath` 嚴格 normalize(lowercase drive + Resolve-Path);u1 test scenarios 含主/peer/submodule 三 context 驗;Git < 2.31 直接 fail loudly(Dependencies 已標) |
| **既有 4 plugin coexistence MCP collision** `tdp:dbhub` 跟 `tp-dbhub` 同 session 同時 launch 各自 Docker container 佔資源 | 低 | 低 | U4 改名避免命名碰撞;Docker resource 是兩個 container 但只是過渡期短暫;cutover 後消失 |
| **CLAUDE.md / `.commitlintrc.json` 注入非 idempotent 重複追加** | 中 | 低 | U3 tp-setup case (c) idempotent 偵測既有段不重複;u3 test scenarios 含跑兩次驗 |
| **SVN UTF-8 commit message 編碼錯誤(中文 mangle)** | 低 | 高 | U6 沿用既有 tgs UTF-8 no-BOM + `--encoding UTF-8` pattern;u6 test scenarios 含中文 message 驗 |
| **同事 onboarding 沒做** 使用者(你)親自帶,但若使用者忙著開發忘記帶 → 同事 silent 沒裝 / 沒 setup,Pattern A 假設 break | 中 | 中 | Scope Boundaries 已聲明同事 onboarding 為未來 skill;v0.1.0 README 寫清楚同事該怎麼裝 + setup 步驟;SessionStart 分支 (iii-b) 在 peer 啟動 + 無 marker 時主動引導去主 worktree |

---

## Dependencies / Prerequisites

- **Git ≥ 2.31**(2021-03)— `--path-format=absolute` flag。tp-setup 在 case (a)/(b)/(c)/(d) 開頭 probe,< 2.31 fail loudly + 升級訊息
- **PowerShell 5.1+**(Windows 標配)— `Set-StrictMode -Version Latest`、`$ErrorActionPreference = 'Stop'`、`Get-CimInstance Win32_Process`(IIS Express enum)、`Resolve-Path`(path normalize)
- **Bash + git + svn CLI**(Linux / macOS / Git Bash)— 提供 `.sh` 版的環境
- **MSBuild**(VS 標準位置 或 user-level `TURBO_PLUGIN_MSBUILD_PATH`)— .NET FW 建置
- **IIS Express**(`${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe` 或 user-level `TURBO_PLUGIN_IIS_EXPRESS_PATH`)— .NET FW run
- **SVN CLI**(`svn`)— SVN bridge 6 skill
- **Docker**(dbhub MCP container 啟動所需)
- **Claude Code** with deferred tool `EnterWorktree`(已實機驗證存在 + cwd 行為見 Resolve Before Planning Resolved)
- 不需要:node / npm(brainstorm Round 2 後砍 husky/commitlint hook)、Python(無相關)

---

## Outstanding Questions (Deferred to Implementation)

從 brainstorm Deferred to Planning 帶入,加 plan 階段補充:

- [Affects U9][Technical] **`.csproj` IIS port 設定的可能格式組合 parser**:VS-generated 的 `<DevelopmentServerPort>`、`<IISExpressSSLPort>`、`<IISUrl>`、舊版 `applicationhost.config` 引用等需窮舉並寫 parser。實作時遇到的格式可直接補進 `get-target-url.ps1` / `resolve-iis-settings.ps1`,逐步擴
- [Affects U10][Technical] **`tp-suggest-ignore` 偵測規則細節**:看副檔名、檔名 pattern、檔案內容、還是檔案位置;git/SVN 兩側 ignore 機制(line-based vs property-based)的同步策略;v0.1.0 從既有 tgs 抄過來的基礎規則為起點,實作時遇到的 case 補進去
- [Affects U7][Technical] **與既有 `tgs` plugin 是否可短期共用 worktree primitive 邏輯**:過渡期內可能直接複製貼上而非整合;cutover 後 turbo-plugin 內 scripts 為唯一來源
- [Affects U4, U6, U9][Needs verification] **MCP server lifecycle 補完驗證**:`/compact` / session resume / Claude Code update 期間 MCP relaunch 行為實機驗證(brainstorm 已標 Deferred to Planning);實作時建議再跑一次擴大 probe(在 U11 step 5 邊界驗證階段)
- [Affects U3][Technical] **`.commitlintrc.json` 注入 idempotent 演算法**:若使用者 repo 已有 `.commitlintrc.json` 含其他 type rules,tp-setup case (c) 應合併 type-enum 不覆寫整檔 — 實作時可用 JSON parse + array merge(`@commitlint/config-conventional` 11 類 + `db` 補進去),保留使用者既有 rules

---

## Success Metrics

- 全部 13 skill 完整實作 + 安裝跑通 + v0.1.0 tag
- 全部 AE1-AE10(brainstorm)在 real Claude Code session 跑通
- F1 (onboarding) / F2 (commit→SVN push) / F3 (IIS Express) 三 flow 各完整跑通一輪
- 5 工作日連續使用 turbo-plugin 無 blocker
- Cutover 完成:既有 4 plugin disable / remove 後無 regression
- brainstorm Success Criteria 全部達成:
  - 新環境裝 turbo-plugin + 跑一次 tp-setup 即可用(vs 既有「裝 4 plugin + 各自 setup」)
  - worktree A 跑 stop 殺得到 worktree B 的同 project IIS(原 bug 消失)
  - Pattern A `EnterWorktree` 後無需手動跑指令(PostToolUse hook 自動補)
  - SessionStart 分支 (iii) 主動引導 day-1 user 到主 worktree
  - tp-push-to-svn 為 SVN bridge 篩選 source-of-truth、unknown type 不靜默漏網

---

## Phased Delivery

| Phase | Units | 目標 |
|---|---|---|
| **P1 - Foundation** | U1, U2 | Plugin scaffold + shared lib + hooks 自帶安裝即 active |
| **P2 - Setup** | U3, U4 | tp-setup 四 case + `.mcp.json` + `.turbo-plugin/` 集中目錄 |
| **P3 - SVN bridge** | U5, U6, U7 | 全 SVN bridge skill,測試完整 F2 flow |
| **P4 - .NET FW Web** | U8, U9 | build / publish / run / stop + 新 IIS identity,測試完整 F3 flow |
| **P5 - Ignore / Comment** | U10 | 三 skill lift,測試 AE4 |
| **P6 - Validation + Cutover** | U11 | E2E + 5 工作日 dogfood + cutover + v0.1.0 release |

Dependencies graph(簡化):

```
U1 ──┬─► U2 ──┐
     ├─► U3 ──┴─► U4 ──┐
     ├─► U5         ┌──┴─► U11 (validation)
     ├─► U6         │
     ├─► U7         │
     ├─► U8 ──► U9  │
     └─► U10 ───────┘
```

U2 / U3 是 fan-in foundation;U5/U6/U7/U8/U10 是平行的 leaf;U9 跟 U8 順序相關(build 完才能 run);U11 收尾。
