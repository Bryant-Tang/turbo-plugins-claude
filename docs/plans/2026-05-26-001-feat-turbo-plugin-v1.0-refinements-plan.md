---
date: 2026-05-26
type: feat
origin: docs/brainstorms/2026-05-26-turbo-plugin-v1.0-refinements-requirements.md
status: completed
---

# feat: turbo-plugin v1.0 refinements

## Summary

實作 brainstorm 定義的 4 項 v1.0 收尾改動:把 `applicationhost.config` 從 VS 共生改成 turbo-plugin 自己擁有並動態渲染到 temp 檔案、重組 `tp-setup` 成 4 個 Phase 並加入 Claude Code 友善功能(LSP / compound-engineering / agent teams / TUI fullscreen)的推薦安裝、修正 `tp-suggest-ignore` SKILL 對跨 worktree commit 行為的文件描述、修正 `svn-log` 中文亂碼 + 預設量過大 + 加修訂號參數 + 互動分頁(non-AskUserQuestion)。

---

## Problem Frame

延續 [origin requirements](../brainstorms/2026-05-26-turbo-plugin-v1.0-refinements-requirements.md) 描述的 5 條痛點(apphost VS 共生負債、tp-setup 走走停停隱藏副作用、缺少 Claude Code 友善開發環境設定入口、svn-ignore 文件 bug、svn-log 體驗破洞)。本 plan 不重述產品決策,直接執行。

---

## High-Level Technical Design

> 以下是**指向性說明**,實作 agent 應視作 context,**不是**要原樣複製的程式碼。

### tp-setup 4-Phase 流程

```
[Phase 1 偵測] ──────────────────────────────────────────
  Pre-check (Probe-GitVersion / Test-IsSubmodule)
  Encoding profile detect (既有 Step 0.5,內嵌進 Phase 1)
  Case detect (a 新建 / b init-from-existing / c 補設定 / d peer-mode)
  ↓
  Phase summary emit (只列「會動到外部」的動作:SVN checkout 等)
  ↓
  AskUserQuestion: 繼續 / 取消 / 改執行其他 case

[Phase 2 case-specific bootstrap] ────────────────────────
  Execute case action sequence
  apphost.config bootstrap (R1):
    if .turbo-plugin/applicationhost.config exists → keep
    elif .vs/<sln>/config/applicationhost.config exists → copy in
    else → AskUserQuestion 三選一:
      (1) 暫停 setup,使用者去開 VS 產生 → 完成後重跑 tp-setup
      (2) 在 config.toml 寫 [iis] enabled = false,跳過 IIS skill
      (3) 取消 setup

[Phase 3 環境配置] ──────────────────────────────────────
  Probe all:
    外部依賴: MSBuild / IIS Express / SVN CLI / Docker / dotnet / npm
    Claude Code 既有設定: enabledPlugins / env keys / tui (user/project/local 三個 scope 都讀)
  ↓
  Emit "已啟用 (跳過)" list + "尚未配置 (以下會問)" list
  ↓
  AskUserQuestion: 繼續 / 取消
  ↓
  Per-item AskUserQuestion batches (max 4 題/batch):
    題: MSBuild path (若 missing)
    題: IIS Express path (若 missing)
    題: C# LSP 啟用 (若未啟用)
    題: TS/JS LSP 啟用 (若未啟用)
    題: compound-engineering 啟用 (若未啟用)
    題: agent teams 啟用 (若未啟用)
    題: TUI fullscreen 啟用 (若未啟用)
  ↓
  Execute per-item:
    Claude Code env / settings: 寫對應 scope 的 settings.json
    Plugin enable: 寫 extraKnownMarketplaces (CE only,內建 marketplace 跳過) + enabledPlugins
    LSP server binary auto-install (R17-R21):
      C# LSP 啟用 + dotnet ✓: dotnet tool install -g csharp-ls
      C# LSP 啟用 + dotnet ✗: 記入 Phase 4 補裝清單
      TS/JS LSP 啟用 + npm ✓: npm install -g typescript-language-server typescript
      TS/JS LSP 啟用 + npm ✗: 記入 Phase 4 補裝清單

[Phase 4 完成報告] ──────────────────────────────────────
  寫入位置清單
  外部安裝成功 / 失敗清單
  使用者仍須手動處理(LSP server / dbhub credentials / etc.)
  若 Phase 3 寫入了任何 ~/.claude/settings.json 變更(plugin 啟用、env、tui):
    請使用者「重啟 Claude Code 後才會生效。重啟後:
       - 跑 /plugin list 確認啟用的 plugin 都出現(verify schema 在當前版本被接受)
       - 看 TUI 是否變全螢幕(若有啟用)
       - LSP / agent teams 等 env 在新 session 才被讀取」
  下一步建議(tp-pull-from-svn / 開始開發)
```

### apphost runtime 渲染路徑

```
.turbo-plugin/applicationhost.config  (canonical,進 git,跨 worktree 共享)
                      │
                      │  start-iis.ps1:
                      │    1. Read canonical
                      │    2. Copy to %TEMP%\turbo-plugin-iis-<identity-hash>.config
                      │    3. Patch physicalPath in temp 為當前 worktree
                      │
                      ▼
%TEMP%\turbo-plugin-iis-<identity-hash>.config  (transient,per-worktree)
                      │
                      │  iisexpress -config:<temp> -site:<name>
                      ▼
              IIS Express runtime

VS UI 獨立使用:
.vs/<sln>/config/applicationhost.config  (VS owns;turbo-plugin 不讀不寫)
```

關鍵差異與目前實作:
- 目前 `start-iis.ps1` line 122 用 `Update-ApplicationhostConfig` 直接改寫 `.vs/<sln>/config/applicationhost.config`(canonical 跟 runtime 同一檔)
- 新設計 canonical(`.turbo-plugin/applicationhost.config`)永遠不被 physicalPath 改寫;只有 temp file 會被改

### Tool path 路徑來源(v1.0 首次 release)

```
turbo-plugin v1.0 是 plugin 第一次 release — 沒有 v0.2.x 既有 user,所以不存在「舊 env 需要 migration」的情境。

新建 / case (a)/(b)/(c) 都從乾淨狀態起:
  .turbo-plugin/config.local.toml:
    [tools]
    msbuild_path = "C:/.../MSBuild.exe"    (tp-setup Phase 3 互動填入)
    iis_express_path = "C:/.../iisexpress.exe"

Find-MSBuild / Find-IisExpressPath 只讀 config.local.toml [tools]:
  找不到就 throw,訊息引導跑 /tp-setup 補設定 path
```

### svn-log 互動分頁狀態管理

```
SKILL invocation 1:
  args: (none)
  → script svn-log --xml --limit 5
  → SKILL emit log 結果到 chat (markdown code block)
  → SKILL emit 選項清單到 chat:
       1. 下5筆 / 2. 指定修訂 / 3. 其他
  → end turn,等使用者下一輪訊息

User next turn: "1"
  → SKILL parse chat history,從本次 log 抓最舊 r<N>
  → script svn-log --xml --revision <N-1>:1 --limit 5
  → SKILL emit log + 選項
  → end turn

User next turn: "r5" 或 "2 r5"
  → SKILL parse → svn-log --revision r5
  → SKILL emit + 選項

User next turn: "其他" / "幫我看 build.ps1" / 完全 unrelated
  → SKILL 退出迴圈 (不再呼叫 script,不再 emit 選項)
  → 一般對話繼續
```

---

## Requirements

延續 [origin requirements](../brainstorms/2026-05-26-turbo-plugin-v1.0-refinements-requirements.md) R1-R32 全部。下方 implementation units 以 `Requirements:` 欄位標示對應 R-ID 與 AE-ID。

---

## Implementation Units

### U1. config schema 擴充 + Resolve-ConfigValue merge

**Goal:** 替 turbo-plugin 自己的設定(MSBuild path / IIS Express path 等)在 config.toml family 增設 `[tools]` 與 `[iis]` section,並讓 `Resolve-ConfigValue` 支援 `config.local.toml` 覆寫 `config.toml`,作為後續 unit 的 foundation。

**Requirements:** R5(`[iis] enabled`)、R11(config 集中化)、R13(merge 規則)

**Dependencies:** 無(foundation unit)

**Files:**
- `plugins/turbo-plugin/default-files/.turbo-plugin/config.toml` — 加 `[iis]` section 預設 `enabled = true`;`[tools]` section 保持註解狀態(machine-specific 不該進 git)
- `plugins/turbo-plugin/scripts/lib/common.ps1` — 修改 `Resolve-ConfigValue` 讀取邏輯:讀 `config.toml` 後再 merge `config.local.toml` over it(key-level shallow merge);extend `Read-TurboPluginConfig` 支援讀第二個 path
- `plugins/turbo-plugin/scripts/lib/common.sh` — bash 等價 merge 邏輯
- `plugins/turbo-plugin/tests/unit/scripts-lib/test_resolve_config_value_merge.ps1`(新檔)— unit test

**Approach:**
- 既有 `Read-TurboPluginConfig` 接 1 個 path,改成接 array of paths,依序讀,後者覆寫前者(in-place hashtable update)
- `Resolve-ConfigValue` 改 call site 傳 `[config.toml, config.local.toml]`
- `schema_version` 留在 2(僅新增 optional sections,不破壞 v1/v2 讀寫;無需 bump)
- `[tools]` section 的 keys:`msbuild_path` / `iis_express_path`(absolute paths,Windows 用 forward slash 或 backslash 都可,PS 透過 `Get-NormalizedAbsolutePath` 處理)
- `[iis]` section 的 keys:`enabled`(bool,預設 `true`)

**Patterns to follow:**
- 既有 `Read-TurboPluginConfig` line 271-316 of `common.ps1`
- 既有 `Resolve-ConfigValue` line 342-363 of `common.ps1`(已有 CLI > config > Default 三層 fallback)

**Test scenarios:**
- Happy: `config.toml` 只有 `[svn] force_bash = true`、`config.local.toml` 只有 `[tools] msbuild_path = "X"` → `Resolve-ConfigValue` 兩個 key 都取得到正確值
- Override: `config.toml` 設 `[tools] msbuild_path = "A"`、`config.local.toml` 同 key 設 `= "B"` → `Resolve-ConfigValue` 回 `"B"`(local 優先)
- Missing local: `config.local.toml` 不存在 → 只讀 `config.toml`,不 throw
- Both missing: 兩個檔案都不存在 → `Resolve-ConfigValue` 回 `Default`(若提供)或 `$null`

**Verification:** 跑 unit test,4 個 scenario 全綠;手動跑 `Resolve-ConfigValue` 帶 mock config 確認 merge 行為。

---

### U2. Find-MSBuild / Find-IisExpressPath 改讀 config(嚴格切)

**Goal:** `Find-MSBuild`(在 `common.ps1`)與 `Find-IisExpressPath`(在 `resolve-iis-settings.ps1`)只讀 `config.local.toml [tools]`;讀不到就 throw,**不**fallback 到 user-level env。Error message 引導使用者跑 `/tp-setup` 補上 path。

**Requirements:** R11(廢除 `TURBO_PLUGIN_*` env var 讀取)

**Dependencies:** U1

**Files:**
- `plugins/turbo-plugin/scripts/lib/common.ps1` — `Find-MSBuild` line 209-236 重寫
- `plugins/turbo-plugin/scripts/resolve-iis-settings.ps1` — `Find-IisExpressPath` line 6-20 重寫
- `plugins/turbo-plugin/scripts/build-web.ps1` — 若有直接讀 `$env:TURBO_PLUGIN_MSBUILD_PATH` 的呼叫點改走 `Find-MSBuild`
- `plugins/turbo-plugin/scripts/publish-web.ps1` — 同上

**Approach:**
- 兩個 helper 改成:
  1. 讀 `Resolve-ConfigValue -Section 'tools' -Key 'msbuild_path' / 'iis_express_path'`
  2. 找不到 → probe standard install paths(既有 candidates 邏輯保留)
  3. 都找不到 → throw 引導跑 `/tp-setup`:
     ```
     MSBuild 路徑未設定。請跑 /tp-setup 自動偵測或手動補設定。
     ```
- 移除既有對 `$env:TURBO_PLUGIN_MSBUILD_PATH` 與 `$env:TURBO_PLUGIN_IIS_EXPRESS_PATH` 的讀取碼

**Patterns to follow:**
- 既有 `Resolve-ConfigValue` 三層 fallback API

**Test scenarios:**
- Happy: `config.local.toml [tools] msbuild_path = "C:\Program Files\.../MSBuild.exe"` 存在 → `Find-MSBuild` 回該路徑
- Auto-probe: `config.local.toml` 缺 `[tools]` section 但機器上有 VS 2022 → `Find-MSBuild` 回 VS 2022 標準路徑
- Throw: `[tools]` 沒設 + 機器上完全沒裝 VS → `Find-MSBuild` throw 含 "請跑 /tp-setup" 訊息
- 不讀 env: 即使 `$env:TURBO_PLUGIN_MSBUILD_PATH` 設了一個假路徑,`Find-MSBuild` 也不會回它(回 auto-probe 結果或 throw)
- Same set for `Find-IisExpressPath`

**Verification:** 跑 unit test;手動在乾淨環境(無 config.local.toml + 無 env)跑 build-web.ps1 確認 throw 訊息正確引導。

---

### U3. apphost runtime 分離 — temp file 渲染

**Goal:** runtime IIS Express 啟動時改讀 `.turbo-plugin/applicationhost.config`(canonical,進 git),複製到 `%TEMP%\turbo-plugin-iis-<identity-hash>.config` 並在 temp 改寫 physicalPath,以 `iisexpress -config:<temp>` 啟動。Canonical 檔案不再被 physicalPath 改寫污染。

**Requirements:** R2(runtime 讀 .turbo-plugin)、R3(temp file physicalPath patch)、R4(posttooluse hook 移除 .vs 寫入)

**Dependencies:** U1(`[iis]` 設定 — 雖然 U3 不直接讀 enabled,但 U4 會 gate,需要 U1 schema 先就位)

**Files:**
- `plugins/turbo-plugin/scripts/resolve-iis-settings.ps1` — `Find-ApplicationhostTarget` line 22-28 改回傳 `.turbo-plugin/applicationhost.config`(不是 `.vs/<sln>/config/`)
- `plugins/turbo-plugin/scripts/start-iis.ps1` — 加 temp file 渲染步驟(read canonical → copy to temp → patch physicalPath in temp → launch with `-config:<temp>`);移除直接修改 canonical 的呼叫
- `plugins/turbo-plugin/scripts/stop-iis.ps1` — 停止 process 後刪除對應 temp file
- `plugins/turbo-plugin/scripts/cleanup-orphan-iis.ps1` — **移除** `.vs/<sln>/config/applicationhost.config` 的 XML orphan scan 分支(v1.0 後 turbo-plugin 不寫該檔,scan 變 dead code);只保留**殺孤兒 process** 邏輯。順手清掉 `%TEMP%\turbo-plugin-iis-*.config` 中找不到對應 process 的 file
- `plugins/turbo-plugin/scripts/lib/applicationhost-helpers.ps1` — **不新增**任何 helper;既有 `Update-ApplicationhostConfig` 可在 temp file 上重用(SetAttribute)。temp file 渲染邏輯直接 inline 進 `start-iis.ps1`(避免單一-caller helper 的過早抽象)
- `plugins/turbo-plugin/scripts/hooks/posttooluse-enterworktree.ps1` — **完全移除** `.vs/<sln>/config/applicationhost.config` 寫入邏輯,Emit-Json @{} + exit 0 即可
- `plugins/turbo-plugin/scripts/hooks/sessionstart.ps1` — Branch (i) 中對 `.vs/<sln>/config/` 的處理移除

**Approach:**
- temp file 命名:`%TEMP%\turbo-plugin-iis-<8-char identity-hash>.config`(identity-hash 由 `Get-ProjectIdentityHash` 算)
- 每次 `start-iis.ps1` 啟動時:刪舊 temp(若有)→ 從 canonical 複製 → 改 physicalPath(把 canonical 中的佔位符 `__TURBO_PLUGIN_PHYSICAL_PATH__` 替換為當前 worktree 的 csproj 所在目錄)→ 啟動 iisexpress
- **佔位符設計**:canonical(進 git)的 `<site>` 的 `physicalPath` 屬性值固定為 `__TURBO_PLUGIN_PHYSICAL_PATH__` — 確保 commit 內容跨機器 / 跨同事 portable。start-iis runtime 一律覆寫到 temp(同 worktree 重跑 idempotent)。U5 tp-setup 從 VS 複製進 canonical 時負責這個替換(見 U5 R1 option (1))
- 不需要在 start-iis 用 atomic write — **同專案在所有 worktree 之間只能啟動一個 IIS Express**(port / site / bindings 都從專案檔產生,跨 worktree 算出相同值,物理上不可能並發);切換 worktree 跑 tp-run 走 start-iis line 102-118 既有「同 site 已存在則先 stop 再重啟」邏輯,physicalPath 才是唯一 per-worktree 變化的 attribute
- VS UI 仍會自行維護 `.vs/<sln>/config/applicationhost.config`,turbo-plugin 不再讀寫該檔(VS user 修改 IIS 設定要回 `.turbo-plugin/applicationhost.config` 同步是 deferred 議題)

**Patterns to follow:**
- 既有 `Update-ApplicationhostConfig` line 69-138 of `applicationhost-helpers.ps1` (XML load + SetAttribute + atomic save)
- 既有 `Get-ProjectIdentityHash` 算 hash 方式

**Test scenarios:**
- Happy (.NET FW Web project): `start-iis.ps1` 跑完後 → `%TEMP%\turbo-plugin-iis-<hash>.config` 存在、其 `physicalPath` = 當前 worktree 路徑、iisexpress.exe process 含 `-config:<temp>`
- Canonical 不變: start-iis 跑完後 `.turbo-plugin/applicationhost.config` 的 mtime / hash 未變(canonical 完全不被改)
- Canonical 帶佔位符: `.turbo-plugin/applicationhost.config` 進 git 的 physicalPath 屬性值固定為 `__TURBO_PLUGIN_PHYSICAL_PATH__`(commit diff 跨同事 / 跨機器一致;runtime 由 start-iis 在 temp file 裡替換為實際 worktree 路徑)
- VS UI 隔離: 同時用 VS UI 跑 IIS Express,VS 改寫 `.vs/<sln>/config/applicationhost.config`(自己的),turbo-plugin 跑的 IIS Express 不受影響
- posttooluse hook: 進入 worktree 後 `.vs/<sln>/config/applicationhost.config` **沒有** turbo-plugin 寫入痕跡
- stop-iis: 跑完後對應 temp file 已刪
- cleanup-orphan-iis: orphan process 殺完後 `%TEMP%\turbo-plugin-iis-*.config` 找不到對應 PID 的 temp file 被清掉

**Verification:** 在 main 跑 `tp-run` → IIS Express 啟動,physicalPath = main worktree 路徑;切到 dev-1 跑 `tp-run` → start-iis 偵測同 hash 已有 instance(既有 line 102-118 邏輯),先 stop 舊的再用 dev-1 的 physicalPath 重啟。**同專案不會並發兩個 IIS Express**(這是 turbo-plugin 一貫設計)。canonical `.turbo-plugin/applicationhost.config` 在跑完一輪 start/stop 後 hash 未變(只有 temp file 被寫)。

---

### U4. `[iis] enabled = false` opt-out 機制

**Goal:** 提供 `[iis] enabled = false` 開關,讓沒有 .NET FW Web 專案或不需 IIS 的使用者完全跳過 IIS 相關 skill,跑 tp-build / tp-run / tp-stop / tp-publish 時 fail-loudly 友善訊息。

**Requirements:** R5(`[iis] enabled` + fail-loudly 訊息)

**Dependencies:** U1(`[iis]` section schema)

**Files:**
- `plugins/turbo-plugin/skills/tp-run-dotnet-framework-web/SKILL.md` — Procedure 開頭加 `[iis] enabled` check
- `plugins/turbo-plugin/skills/tp-stop-dotnet-framework-web/SKILL.md` — 同上
- `plugins/turbo-plugin/skills/tp-build-dotnet-framework-web/SKILL.md` — 同上
- `plugins/turbo-plugin/skills/tp-publish-dotnet-framework-web/SKILL.md` — 同上
- `plugins/turbo-plugin/skills/tp-cleanup-orphan-iis/SKILL.md` — 同上
- `plugins/turbo-plugin/scripts/start-iis.ps1` — 在 try block 開頭 check `Resolve-ConfigValue -Section 'iis' -Key 'enabled' -Default $true`,false 則 throw
- `plugins/turbo-plugin/scripts/stop-iis.ps1` — 同上
- `plugins/turbo-plugin/scripts/build-web.ps1` — build 本身不需 IIS,**不**加 check
- `plugins/turbo-plugin/scripts/publish-web.ps1` — publish 本身不需 IIS,**不**加 check(若 publish 包含 deploy 到 IIS Express 則需要,但 v1.0 不含)

**Approach:**
- `Resolve-ConfigValue -Default $true` — 沒設則視為 true(向下相容,既有 user 不需要動)
- Fail-loudly 訊息(統一措辭):
  ```
  IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
  若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定 (預設啟用)。
  ```
- check 點放在 SKILL Procedure 開頭(讓 agent 早期 fail);script 也 check 是 defensive layer

**Patterns to follow:**
- 既有 SKILL 的 Procedure 開頭結構(`Step 1 — 前置檢查`)

**Test scenarios:**
- Default behavior: 沒設 `[iis]` section → tp-run / tp-stop / etc. 正常運作
- Explicit true: `[iis] enabled = true` → 同 default
- Disabled: `[iis] enabled = false` → tp-run / tp-stop / tp-cleanup-orphan-iis throw 統一訊息;tp-build / tp-publish 不受影響
- Mismatch friendly: 訊息提及具體 config 檔案路徑 + 修正方式

**Verification:** Manual:在 sample 專案設 `[iis] enabled = false` 後跑 `/tp-run`,確認 chat 收到友善訊息;設回 true 後可正常啟動。

---

### U5. tp-setup SKILL 重組為 4 Phase

**Goal:** 把現在 `tp-setup/SKILL.md` 的堆疊式 Step 0/0.5/1/2-5/6/7/8 整個重寫為 4 個 Phase(偵測 / case bootstrap / 環境配置 / 完成報告),包含 apphost.config bootstrap 邏輯(R1)。新需求未來只能融入 Phase 內或開新 skill,不再 append 新 Step。

**Requirements:** R1(apphost bootstrap)、R6(廢除堆疊 Step)、R7(Phase 3 整合)、R8(已啟用偵測)、F1(整個 tp-setup 新流程)

**Dependencies:** U1(config schema)、U3(apphost runtime 已支援讀 .turbo-plugin/)、U4(`[iis] enabled` opt-out 機制存在,R1 三選一的選項 (2) 才能寫入有效設定)

**Files:**
- `plugins/turbo-plugin/skills/tp-setup/SKILL.md` — 整段 rewrite,結構成:
  - Phase 1: Pre-check + Encoding profile + Case detect + Phase summary
  - Phase 2: Case-specific bootstrap (a/b/c/d) + apphost bootstrap (R1 三選一)
  - Phase 3: 環境配置(U6 接手主要邏輯)
  - Phase 4: Completion report
- `plugins/turbo-plugin/skills/tp-setup/assets/` — 既有 commitlintrc-template.json / claudemd-convention-snippet.md 維持

**Approach:**
- 既有 case 偵測邏輯維持(submodule → no .git → not main worktree → no .turbo-plugin → else)
- Phase 1 結尾 emit phase summary,內容只列「會動到外部」的動作(SVN checkout 等);**不**列 repo 內 file write、git 本地 op、template copy
- AskUserQuestion: 繼續 / 取消 / 改執行其他 case(維持既有 4-option override)
- Phase 2 case (a)/(b)/(c) 進入後,在原本 step 6 之後(case a)或對等位置(case b/c)插入 apphost bootstrap:
  ```
  if test -f .turbo-plugin/applicationhost.config:
    pass (canonical 已存在)
  elif test -f .vs/<sln>/config/applicationhost.config:
    cp .vs/<sln>/config/applicationhost.config -> .turbo-plugin/applicationhost.config
    Phase 4 報告「已從 VS 複製 apphost.config」
  else:
    AskUserQuestion (三選一):
      (1) 暫停 setup,使用者執行下列步驟後重跑 /tp-setup:
            a. 打開 Visual Studio 並載入 .sln 一次(VS 會自動把
               applicationhost.config 寫到 .vs/<sln>/config/ 目錄 — 那是 VS 內部目錄)
            b. 完成後重跑 /tp-setup
            c. setup 偵測到 .vs/<sln>/config/applicationhost.config 存在,
               複製到 .turbo-plugin/applicationhost.config(進 git 共享)。
               **複製時必須把每個 <site> 的 physicalPath 屬性替換為佔位符**
               `__TURBO_PLUGIN_PHYSICAL_PATH__`(避免機器-specific 絕對路徑
                進版控 — Alice 的路徑 commit 後 Bob clone 看到會困惑;
                runtime 由 start-iis 在 temp file 裡替換為實際 worktree 路徑)
      (2) 在 config.toml 寫 [iis] enabled = false,跳過 IIS skill (本機無 .NET FW Web 開發需求時選)
      (3) 取消 setup
  ```
- Case (d) peer-mode 不做 apphost bootstrap(canonical 在 main worktree 已存在,peer 直接讀 — 由 U3 runtime 確保跨 worktree 讀同一 canonical)

**Patterns to follow:**
- 既有 tp-setup SKILL.md case (a) Step 6 sub-step 命名(6a-6f)的 transparency 風格
- 既有 AskUserQuestion override 模式(line 71-81)

**Test scenarios:**
- Case (a) fresh:既無 `.turbo-plugin/` 也無 `.vs/`,跑 tp-setup 走到 apphost bootstrap → 出現三選一 AskUserQuestion;選 (2) → 進入 Phase 4 時 config.toml 內含 `[iis] enabled = false`
- Case (b) existing git + .vs apphost:有 `.vs/<sln>/config/applicationhost.config`,跑 tp-setup → silent copy 到 `.turbo-plugin/applicationhost.config`,Phase 4 列出「已從 VS 複製」
- Case (c) idempotent:`.turbo-plugin/applicationhost.config` 已存在,跑 tp-setup case (c) → 不複製、不問
- Phase summary 內容: case (a) summary 只列 SVN checkout / svn commit 等 external actions,**不**列 `.gitignore` / `git init` 等
- AskUserQuestion override: 偵測為 case (c),使用者選「改執行 case (a)」 → 進入 case (a) 完整流程
- Covers AE1.

**Verification:** Manual:在 `SampleGitWithSvn` 測試資料夾跑 tp-setup case (a) → 完成 setup 後 `.turbo-plugin/applicationhost.config` 存在;跑兩次 tp-setup case (c) 結果一致(idempotent)。

---

### U6. Phase 3 環境配置 — 偵測 + AskUserQuestion batch + Claude Code 功能啟用 + LSP server 自動安裝

**Goal:** 實作 tp-setup Phase 3 完整流程:偵測 → 列出 → AskUserQuestion batch 詢問 → 執行寫入 + LSP server binary 自動安裝。涵蓋 MSBuild path、IIS Express path、C# LSP(+ csharp-ls binary)、TS/JS LSP(+ typescript-language-server binary)、compound-engineering、agent teams、TUI fullscreen。Transparency 規則 just-in-time disclosure。

**Requirements:** R7-R10(Phase 3 整合 + per-item scope choice)、R14-R16(transparency)、R17-R21(LSP server binary 自動安裝 + 偵測降階 + `ENABLE_LSP_TOOL` 寫入 + binary 無 scope)、R22-R24(compound-engineering / agent teams / TUI 啟用)

**Dependencies:** U5(Phase 3 入口框架)

**Files:**
- `plugins/turbo-plugin/skills/tp-setup/SKILL.md` — Phase 3 段落(填入 U5 留的 placeholder)
- ~~`assets/phase3-detection-checklist.md` / `assets/settings-json-writers.md`~~ — **不新增 asset 檔**。偵測指令清單與 settings.json key 對照表直接以 markdown table 形式 inline 進 `tp-setup/SKILL.md` 的 Phase 3 段落(只一個 consumer,沒有拆檔必要)

**Approach:**
- 偵測階段:
  - probe `Find-MSBuild` 結果(若 throw 則記為「未配置」)
  - probe `Find-IisExpressPath` 結果(同上)
  - probe `dotnet --version`、`npm --version`、`docker --version`、`svn --version`
  - 讀 user-level + project-level + local-level settings.json,列出已啟用的 Claude Code feature:
    - `enabledPlugins["csharp-lsp@claude-plugins-official"]` → C# LSP 已啟用
    - `enabledPlugins["typescript-lsp@claude-plugins-official"]` → TS/JS LSP 已啟用
    - `enabledPlugins["compound-engineering@compound-engineering-plugin"]` → CE 已啟用
    - `env.ENABLE_LSP_TOOL == "1"` → LSP tool 已啟用
    - `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"` → agent teams 已啟用
    - top-level `tui == "fullscreen"` → TUI 已啟用
- 列出:「✓ 已啟用 (跳過): ...」+ 「✗ 尚未配置 (以下會問): ...」
- Phase summary AskUserQuestion: 繼續 / 取消
- Per-item AskUserQuestion 詢問規則:
  - **Tool paths**(MSBuild / IIS Express):「跳過 / 輸入路徑」二選一,**無** scope 概念(都寫 `.turbo-plugin/config.local.toml`)
  - **Claude Code features**(C# LSP / TS/JS LSP / CE / agent teams / TUI):「跳過 / user-level / project-level / local-level」4 個選項
  - 最多 4 題/batch
- 各題 preview 只列「動到外部」的副作用:寫 `~/.claude/settings.json`(user-level scope 時)、Claude Code 從外部下載 plugin、安裝 binary 等。寫 `.turbo-plugin/config.local.toml` 是 repo 內 file write,**不**列(per R14)
- 設定寫入位置:
  - MSBuild / IIS Express path:寫 `.turbo-plugin/config.local.toml` `[tools] msbuild_path` / `iis_express_path`(internal,不列 transparency)
  - C# LSP: 寫所選 scope 的 settings.json:`enabledPlugins["csharp-lsp@claude-plugins-official"] = true` + `env.ENABLE_LSP_TOOL = "1"`(只當任一 LSP 啟用時寫)。**注意**:`claude-plugins-official` 是內建 marketplace,**不**需要寫 `extraKnownMarketplaces`
  - TS/JS LSP: 同上,`enabledPlugins["typescript-lsp@claude-plugins-official"] = true`
  - compound-engineering:**3 options 一次決定**(不另外問 sub-question,不走 per-item scope choice — CE scope 一律 user-level,因為 dev tool 通常 cross-project 共用,且 autoUpdate dimension 已佔 option slot):
    - **跳過** — 不啟用
    - **安裝(自動更新)** — 寫 user-level settings.json: `extraKnownMarketplaces["compound-engineering-plugin"] = {source: {source: "git", url: "https://github.com/EveryInc/compound-engineering-plugin.git"}, autoUpdate: true}` + `enabledPlugins["compound-engineering@compound-engineering-plugin"] = true`。Claude Code 啟動會自動 fetch 最新版,**注意 GitHub repo 被 hijack 時自動載入惡意 code 風險**
    - **安裝(不自動更新)** — 同上但 `autoUpdate: false`。要更新時手動跑 `/plugin update`
    - (`extraKnownMarketplaces` schema 由 sub-agent 從使用者本機 settings.json 驗證確認)
  - agent teams: 寫 `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`
  - TUI: 寫 top-level `tui = "fullscreen"`
- **LSP server binary 自動安裝**(原 U7 內容,合進此 unit):任一 LSP plugin 啟用後依 runtime 偵測自動跑安裝;runtime 缺失則記入 Phase 4 完成報告補裝清單:
  ```
  寫 enabledPlugins[<plugin-key>] = true to chosen scope's settings.json
  寫 env.ENABLE_LSP_TOOL = "1" to chosen scope's settings.json (idempotent — 兩個 LSP 都啟用時只寫一次)

  if csharp-lsp 啟用:
    if dotnet ✓: execute `dotnet tool install -g csharp-ls`
      success → 記 "C# LSP server (csharp-ls) 已安裝"
      failure → 記 Phase 4 補裝清單
    else: 記 Phase 4 補裝清單 + .NET SDK 安裝建議 (https://dotnet.microsoft.com/download)

  if typescript-lsp 啟用:
    if npm ✓: execute `npm install -g typescript-language-server typescript`
      success → 記 "TS/JS LSP server (typescript-language-server) 已安裝"
      failure → 記 Phase 4 補裝清單
    else: 記 Phase 4 補裝清單 + Node.js 安裝建議 (https://nodejs.org/)
  ```
- `dotnet tool install -g` 與 `npm install -g` 透過 `& <command>` invocation,**不**用 `Invoke-Expression`(避免 shell metachar,同 `pack-content.ps1` line 81-104 模式)
- 失敗訊息含「可手動跑 `<command>` 補裝」提示
- Binary 機器全域,**無** scope 概念 — 即使 LSP plugin 啟用在 project-level,binary 仍裝在電腦全域。preview 明寫「安裝在電腦上,不跟著專案走」

**Patterns to follow:**
- 既有 AskUserQuestion preview 字串平實白話 style(F-CR16 修正後的 svn-encoding 題)
- 既有 `Write-Utf8NoBom` for settings.json write
- JSON merge 模式(既有 `.commitlintrc.json` JSON merge `rules.type-enum[2]` 寫法,line 99-100 of current SKILL)— 為「不覆寫使用者既有的其它 keys」
- 既有 `pack-content.ps1` 對 `npm install` 的呼叫模式(line 81-104)

**Test scenarios:**
- Happy:乾淨機器跑 Phase 3,選 user-level 啟用 C# LSP + TS/JS LSP(dotnet ✓ / npm ✓ )→ `~/.claude/settings.json` 內出現兩個 plugin key + `ENABLE_LSP_TOOL = "1"`,並執行 `dotnet tool install -g csharp-ls` + `npm install -g typescript-language-server typescript`
- Per-item scope mix: C# LSP 選 user-level,compound-engineering 選「安裝(不自動更新)」,TUI 選 local-level → 不同寫入位置
- 已啟用跳過: 使用者 ~/.claude/settings.json 已有 `tui = "fullscreen"` → Phase 3 偵測列出「✓ TUI fullscreen (跳過 — user-level 已啟用)」,AskUserQuestion **不**出現 TUI 題
- npm 缺降階:`dotnet ✓ / npm ✗` → TS/JS LSP 題只有「跳過 / 我之後手動裝」二選一,Phase 4 列出補裝指令含 Node.js 連結
- Install command 失敗: dotnet ✓ 但 `dotnet tool install` 因網路問題 fail → 不阻塞 setup,Phase 4 報告失敗 + retry 指令
- ENABLE_LSP_TOOL idempotent: 兩個 LSP 都啟用 → env key 只寫一次,settings.json 結尾不重複
- Scope vs binary: C# LSP 選 project-level → `enabledPlugins` 寫到 `./.claude/settings.json`,但 `dotnet tool install -g` 仍裝機器全域
- Preview 透明度:點開 C# LSP 「user-level 啟用」 preview → 列出「啟用 csharp-lsp@claude-plugins-official、Claude Code 從網路下載 plugin、安裝 C# 語言伺服器(csharp-ls)到你的電腦」三項;**不**列 `.turbo-plugin/config.local.toml` 寫入(internal)
- Settings.json 不破壞: 使用者 settings.json 已有其它 env key(例如 `MY_PERSONAL_VAR`),Phase 3 寫入後該 key 還在
- Covers AE2、AE4、AE7

**Verification:** Manual:在 sandbox `~/.claude/settings.json` 跑 Phase 3 各 scope 組合;確認既有 keys 未被覆寫;npm missing 場景 fall through 到 Phase 4 補裝清單;跑完 setup 後手動驗證 `csharp-ls --version` 可執行。

---

### U8. ~~env → config.local.toml migration~~ — **整個 unit 移除**

turbo-plugin v1.0 是首次 release,**沒有任何 v0.2.x user**(plugin 從未推到 marketplace)。因此沒有「使用者既有 `TURBO_PLUGIN_*` env 需要搬遷」的 use case。Migration 邏輯整段拿掉:U2 Find-MSBuild error message 移除 migration hint;U5 Phase 1 不需要 migration probe;Risks / KTD 相關 migration 敘述同步刪除;AE3 在 origin brainstorm 中仍存在但本 plan 不實作(brainstorm 是基於原本「會有舊使用者」假設寫的)。

(原 U8 內容已刪除。U-ID gap 保留 per stability rule。)

---

### U9. tp-suggest-ignore 文件 bug 修正

**Goal:** `tp-suggest-ignore` SKILL.md 對 `--add-svn` / `--remove-svn` 的描述改成「one SVN commit per worktree (cross-worktree sync; propset failure rolls back all)」,與實際腳本 `svn-ignore.ps1` / `.sh` 行為一致。

**Requirements:** R25

**Dependencies:** 無(獨立小 unit)

**Files:**
- `plugins/turbo-plugin/skills/tp-suggest-ignore/SKILL.md` — line 34-35 文件修正

**Approach:**
- 直接 Edit 改兩行:
  - `--add-svn`: 「Add one or more patterns to `svn:ignore` on all remote worktrees in a single SVN commit」 → 「Add one or more patterns to `svn:ignore` on all remote worktrees, one SVN commit per worktree (cross-worktree sync; propset failure rolls back all)」
  - `--remove-svn`: 同 pattern

**Test scenarios:**
- Test expectation: none -- 純文件修正,行為不變,腳本零改動

**Verification:** 讀 SKILL.md 確認描述與 `svn-ignore.ps1` line 114-211(two-pass commit logic)語意一致。

---

### U10. svn-log 核心修正:XML 解析 + --limit 預設 + --revision 參數 + SKILL echo

**Goal:** `svn-log.ps1` / `.sh` 內部一律呼叫 `svn log --xml`,腳本自己解析 XML 並 format 純文字輸出(中文不變 `?`);`--limit` 預設 50 → 5;新增 `--revision <spec>` 參數透傳;SKILL.md Procedure 強化「必須 echo to chat」要求。

**Requirements:** R26(SKILL echo)、R27(XML)、R28(limit 5)、R29(revision 透傳)、AE5、AE6

**Dependencies:** 無(獨立 unit;`config.local.toml` 不需要 — svn-log 不讀 turbo-plugin 自己的設定)

**Files:**
- `plugins/turbo-plugin/scripts/svn-log.ps1` — 重寫:加 `-Revision` param、`--limit` 預設 5、改用 `svn log --xml`、`[xml]` cast 解析、format 輸出
- `plugins/turbo-plugin/scripts/svn-log.sh` — 重寫:加 `--revision` param、`--limit` 預設 5、改用 `svn log --xml`、偵測 xmllint 優先 / fallback grep+sed、format 輸出
- `plugins/turbo-plugin/skills/tp-svn-log/SKILL.md` — Procedure 加入「執行完 script 後**必須**把 stdout 內容包成 markdown code block 貼到對話訊息」要求;argument-hint 加 `[-r/--revision <spec>]`;限制預設值更新為 5

**Approach:**
- PS XML 解析:
  ```powershell
  $xml = (& svn log --xml --limit $Limit $revisionArgs $remote.Path | Out-String)
  $doc = [xml]$xml
  foreach ($entry in $doc.log.logentry) {
    $rev = $entry.revision
    $author = $entry.author
    $date = $entry.date
    $msg = $entry.msg.InnerText  # 取 InnerText 處理多行 msg
    Write-Output "r$rev | $author | $date | $msg"
  }
  ```
- bash xmllint 路徑(**index-based iteration**,避免 line-based `read` 對跨多行 XML element 失效):
  ```bash
  if command -v xmllint >/dev/null 2>&1; then
    count=$(xmllint --xpath "count(//logentry)" - <<< "$XML")
    for i in $(seq 1 "$count"); do
      rev=$(xmllint --xpath "string(//logentry[$i]/@revision)" - <<< "$XML")
      author=$(xmllint --xpath "string(//logentry[$i]/author)" - <<< "$XML")
      date=$(xmllint --xpath "string(//logentry[$i]/date)" - <<< "$XML")
      msg=$(xmllint --xpath "string(//logentry[$i]/msg)" - <<< "$XML")
      echo "r${rev} | ${author} | ${date} | ${msg}"
    done
  else
    # grep+sed fallback
    ...
  fi
  ```
- bash grep+sed fallback:
  ```bash
  # 用 awk 把每個 <logentry>...</logentry> 區段獨立處理
  echo "$XML" | awk '/<logentry/,/<\/logentry>/' | ...
  # 對單一 entry 抽 revision="N" / <author>X</author> / <date>X</date> / <msg>X</msg>
  ```
  - 限制:多行 msg 或含 XML 學骨字元的 msg 可能解析錯(實務上少見;若使用者真的 hit 到,降階 advice 是裝 xmllint)
- `--revision` 透傳:純粹 forward 字串給 svn,svn 接受 `5` / `r5` / `3:10` / `HEAD` / `{2026-01-01}:{2026-05-26}` 等格式;腳本不 validate
- **安全要求(實作 invariant)**:`--revision` 的值**必須**以 separate arg array element 傳給 svn,**不**字串拼接 — PS 用 `& svn log --xml --revision $Revision --limit $Limit $remotePath`(每個值獨立 arg),bash 用 `svn log --xml --revision "$REVISION" --limit "$LIMIT" "$REMOTE_PATH"`(每個值雙引號)。**禁止** `& svn log "--revision $val --limit $n ..."` 這種多 args 拼成單一字串的寫法。U11 pagination loop 從 chat parse 出的 spec 走同一條 separate-arg 路徑
- SKILL.md Procedure 改寫:
  ```
  2. 將 script stdout 完整 echo 到對話訊息(用 markdown code block 包起來),讓使用者直接讀到 log 內容;不要只依賴 tool result UI(可能折疊或截斷)。
  ```

**Patterns to follow:**
- 既有 PS `[xml]` cast 用法(`applicationhost-helpers.ps1` 已用過 XmlDocument)
- 既有 bash heredoc / command-v 偵測模式

**Test scenarios:**
- Happy zh-TW commit: SVN repo 有 r5 commit message「修正中文檔名」→ tp-svn-log 在 zh-TW Windows 顯示 `r5 | bryant | 2026-05-26T... | 修正中文檔名`,不變 `?`
- Default --limit: 不傳 `--limit` → 顯示最近 5 筆(不是 50)
- `--revision <r5>`: tp-svn-log `--revision r5` → 只顯示 r5 一筆
- `--revision <3:7>`: tp-svn-log `--revision 3:7` → 顯示 r3 到 r7,5 筆
- `--revision + --limit`: tp-svn-log `--revision 1:100 --limit 3` → svn 在範圍內取前 3 筆(從 r1 開始的 3 筆)
- bash xmllint 不存在:在 git-bash 環境(xmllint 沒裝)→ 走 grep+sed fallback,output 結構與 xmllint 路徑一致
- bash xmllint 存在:Mac / Linux → 走 xmllint 路徑
- Multi-line commit msg: SVN 有一筆 commit message 含換行 → PS 路徑用 `InnerText` 正確 preserve 換行;bash xmllint 路徑同;bash fallback 在 multi-line msg 警告失敗(明文 limitation)
- Invalid `--limit`: `--limit 0` 或 `--limit abc` → throw "Limit must be a positive integer"(既有檢查保留)
- Covers AE5、AE6

**Verification:** Manual:在 SampleGitWithSvn 跑各 `--revision` / `--limit` 組合確認;手動裝 / 卸 xmllint 跑 .sh 確認雙路徑都動。

---

### U11. svn-log 互動分頁(non-AskUserQuestion)

**Goal:** tp-svn-log SKILL 印出 log 後在對話訊息中 emit「下一步:1.下5筆 / 2.指定修訂 / 3.其他」選項清單(plain text,**不**使用 AskUserQuestion);SKILL 結束 turn 後等使用者下一輪訊息,解析下一輪意圖後決定是否續呼叫 script 或退出分頁迴圈。

**Requirements:** R30(emit options)、R31(parse 下一輪意圖)、R32(script 不維護分頁狀態)、AE8、AE9、AE10

**Dependencies:** U10(script 已支援 `--revision`)

**Files:**
- `plugins/turbo-plugin/skills/tp-svn-log/SKILL.md` — Procedure 增加 "Pagination loop" 段落,描述:
  - 每次跑完 script + echo log 後,emit 三選一選項清單(固定 template)
  - 列出 SKILL 對下一輪訊息的解析規則
  - 退出條件
- `plugins/turbo-plugin/skills/tp-svn-log/assets/pagination-template.md`(新檔)— 對話訊息固定 template,SKILL 引用

**Approach:**
- 選項清單 emit template(plain text appended in chat message after log):
  ```
  ──
  接下來想看什麼?
  1. 下 5 筆(更舊的 5 個 commit)
  2. 指定修訂(直接打 r5、3:10、{2026-01-01}:{2026-05-26} 等)
  3. 其他(換話題)

  回 1 / 2 / 3 或直接打你要的修訂號即可。
  ```
- SKILL 對下一輪訊息的解析規則(按優先序):
  1. 若訊息 trim 後正規化:
     - 是 "1" 或 "next" 或包含「下5筆」「下一頁」 → 走「下 5 筆」流程
  2. 若訊息匹配 revision spec pattern(`^r?\d+$` / `^r?\d+:r?\d+$` / `^\{[\d-]+\}:` / `^HEAD$` / `^BASE$` / 等)或以「2 」前綴帶 spec → 走「指定修訂」流程
  3. 若訊息以「3」開頭或含「其他」「取消」「不要」 → 退出
  4. 否則(不符合分頁意圖) → 退出,讓 agent 一般對話處理該訊息
- **Script trailer line(分頁 state 機制)**:svn-log script 在 stdout 最後 emit `# LAST_SHOWN_REV=<最小 revision>` 結構化 trailer(不會干擾使用者閱讀,SKILL 從 stdout 直接讀,不靠 chat memory — conversation compaction 也不會丟失 state)
- 「下 5 筆」流程:
  - SKILL 從前一次 script stdout 的 trailer 讀 `LAST_SHOWN_REV`(若 stdout 不可得 fallback 到 parse chat history 的 `r<n>` headers)
  - 呼叫 svn-log `--revision <n-1>:1 --limit 5`
  - emit log + 選項
- 「指定修訂」流程:
  - 直接呼叫 svn-log `--revision <spec>`(其中 spec 可能含或不含 `r` 前綴,直接 forward)
  - emit log + 選項
- 退出:不再呼叫 script,不 emit 選項
- script **零變動**(R32 — 維護分頁狀態是 SKILL 的事,script 介面保持單一目的)

**Patterns to follow:**
- 既有 SKILL 對下一輪訊息的「自由解讀」模式(無類似 precedent,本 unit 引入新模式)
- chat 訊息 plain-text 選項格式(對應 ce-doc-review walkthrough 的選項顯示風格)

**Test scenarios:**
- AE8 pagination forward: SVN repo r1-r20,跑 `/tp-svn-log`(顯示 r20-r16) → emit 選項 → 使用者回「1」 → SKILL 呼叫 `--revision 15:1 --limit 5`(顯示 r15-r11) → emit 選項 → 使用者回「1」 → `--revision 10:1 --limit 5`(顯示 r10-r6)
- AE9 jump to revision: 上題接續顯示 r10-r6,使用者回「r5」 → SKILL 呼叫 `--revision r5`(顯示單筆 r5) → emit 選項
- AE9 numeric without r: 使用者回「5」(無 r 前綴) → 因匹配 `^r?\d+$` pattern → 視為 revision spec → 呼叫 `--revision 5`
- AE9 range: 使用者回「3:10」 → 視為 revision spec → 呼叫 `--revision 3:10`
- AE9 with "2 " prefix: 使用者回「2 r5」 → SKILL 剝掉「2 」前綴 + 呼叫 `--revision r5`
- AE10 escape via "其他": 使用者回「其他」 → SKILL 退出,不再 emit 選項
- AE10 escape via unrelated: 使用者回「換個話題,幫我看 build.ps1」 → SKILL 退出
- AE10 escape via "3": 使用者回「3」 → SKILL 退出(視為「其他」)
- Reach SVN history boundary: 顯示到 r5-r1,使用者回「1」想看更舊 → svn log `--revision 0:1` 無結果 / 或 svn 報錯 → SKILL 顯示「已到歷史最舊」,emit 選項(讓使用者跳 revision 或退出)
- Covers AE8、AE9、AE10

**Verification:** Manual:在 SampleGitWithSvn(設好 >10 個 commits)跑 tp-svn-log,測試上述各個分頁與退出路徑。

---

### U12. CHANGELOG / version / README 更新

**Goal:** 整合所有 U1-U11 改動到 plugin 版本資訊:bump `plugin.json` version 到 1.0.0、CHANGELOG.md 寫入 [1.0.0] section、README.md 同步功能說明、marketplace.json 從 `turbo-plugins-claude-dev` 還原為正式 marketplace 名稱。

**Requirements:** 跨 unit 收尾,無新行為 requirement

**Dependencies:** U1-U11

**Files:**
- `plugins/turbo-plugin/.claude-plugin/plugin.json` — `version: "1.0.0"`
- `plugins/turbo-plugin/CHANGELOG.md` — 新增 `[1.0.0] - 2026-05-XX`(實際發布日填入)section,收斂 `[Unreleased]` + 所有 `[0.2.x]` 條目
- `plugins/turbo-plugin/README.md` — 安裝 / 使用章節更新:新增 LSP / CE / agent teams / TUI 推薦提示、SKILL 列表更新(若有新增 — 本次無新增 SKILL)、apphost runtime 變更說明
- `.claude-plugin/marketplace.json` — root level marketplace.json 還原(若處於 testing 狀態 — user 在本次 PR 自行手動處理)

**Approach:**
- plugin.json version bump:直接改字串
- CHANGELOG 結構(`[Keep a Changelog]` 繁中):
  ```
  ## [1.0.0] - 2026-05-XX
  
  ### Added
  - turbo-plugin 集中設定 `[tools]` / `[iis]` section
  - tp-setup 4-Phase 流程
  - LSP / compound-engineering / agent teams / TUI fullscreen 一鍵啟用
  - svn-log 互動分頁
  - svn-log 修訂號參數
  
  ### Changed
  - apphost.config 從 VS 共生改為 turbo-plugin canonical + temp file runtime
  - tp-setup 流程重組,廢除堆疊 Step
  - svn-log 預設 limit 50 → 5
  - svn-log 改用 `--xml` 內部解析(中文 commit message 不變 `?`)
  - turbo-plugin 自己設定改寫 `.turbo-plugin/config.toml` family,不再寫 user-level env(舊 `TURBO_PLUGIN_*` env 由 tp-setup 自動 migrate)
  
  ### Fixed
  - tp-suggest-ignore `--add-svn` / `--remove-svn` 文件描述跟實作對齊(individual commits per worktree)
  - tp-svn-log stdout 必須 echo 到 chat 訊息
  ```
- README 同步:加 LSP / CE / agent teams / TUI 推薦提示在「安裝」章節

**Test scenarios:**
- Test expectation: none -- 純文件 / metadata 更新

**Verification:** 讀 plugin.json 確認 version;讀 CHANGELOG 確認 1.0.0 section 完整;讀 README 確認新功能提示就位。

---

## Key Technical Decisions

- **Tool path 來源單一(`config.local.toml`)**:`Find-MSBuild` / `Find-IisExpressPath` 只讀 `config.local.toml [tools]`,**不**fallback 到任何 env。v1.0 首次 release,沒有「舊 env」要考量;path 在 tp-setup Phase 3 互動填入。讀不到就 throw 引導跑 `/tp-setup` 補設定。
- **`.sh` XML 解析: xmllint 優先 + grep+sed fallback**:雙路徑相容 Mac / Linux(xmllint 預設裝)與 Git Bash on Windows(xmllint 通常沒裝)。fallback 對 multi-line msg / XML 特殊字元的解析有 limitation,在 SKILL.md 註記建議裝 xmllint。
- **apphost 採 temp file 渲染(R3)**:canonical `.turbo-plugin/applicationhost.config` 永不被 physicalPath 改寫;每個 worktree 啟動時自己渲染 `%TEMP%\turbo-plugin-iis-<hash>.config`。避免 canonical 跨 worktree 衝突(目前 hash 跨 worktree 一致,但 physicalPath 不同,canonical 寫入會被其它 worktree 覆蓋)。
- **Marketplace add 只對 compound-engineering 做**:`claude-plugins-official`(C# LSP / TS-JS LSP)是 Claude Code 內建 marketplace,settings.json 不需要 `extraKnownMarketplaces` 條目。`compound-engineering-plugin` 是第三方 marketplace,必須寫 `extraKnownMarketplaces` 含 git URL + source kind。
- **Phase 3 per-item AskUserQuestion 4-題/batch**:平台限制 max 4 題;最壞情況(MSBuild + IIS Express + C# LSP + TS/JS LSP + CE + agent teams + TUI = 7 題)需 2 batches。實作時 batch 分組順序:第一 batch tool paths(MSBuild + IIS Express + C# LSP + TS/JS LSP)、第二 batch Claude Code features(CE + agent teams + TUI)。
- **Pagination state 由 script stdout trailer 提供**:svn-log script 在 stdout 最後 emit `# LAST_SHOWN_REV=<n>` 結構化 trailer line。SKILL 從 stdout 讀 state(主路徑),conversation compaction 不會丟失 state。Fallback:若 stdout 不可得,SKILL 從前一次 chat history parse `r<n>` headers 推算。
- **`[iis] enabled = false` 在 Procedure 開頭 check**:SKILL Procedure 與 script 雙層 check(defensive)。Procedure 開頭 check 讓 agent 早期 fail,不啟動任何 IIS 邏輯。

---

## Scope Boundaries

- **不包含** VS UI 端 apphost 設定回流到 `.turbo-plugin/`:VS 自己改寫 `.vs/<sln>/config/applicationhost.config` 時,turbo-plugin 不會自動同步回 canonical。使用者要 IIS 設定變更時手動 copy(或之後另開 brainstorm 討論 apphost unification)。
- **不包含** Claude Code plugin install 失敗的補救(git URL 不可達、cache 損毀):走 Claude Code 自己的錯誤路徑,turbo-plugin 不接手。
- **不包含** LSP server binary 安裝失敗的補救(超過 retry 提示):失敗時 emit stderr + Phase 4 報告補裝指令,不額外 retry 邏輯。
- **不包含** turbo-plugin 自動安裝 .NET SDK / Node.js / Docker / VS / IIS Express:只 probe + 提示安裝官方連結。
- **不包含** `tp-suggest-ignore` 行為 / API 修改:本次只修文件 bug,腳本零動。
- **不包含** svn-log 暴露 `--xml` flag 給使用者作為 raw 輸出:`--xml` 純 script 內部,使用者永遠看格式化純文字。

### Deferred to Follow-Up Work

- **apphost.config VS UI ⇄ turbo-plugin 雙向同步**:VS UI 改了 IIS port / binding 後自動寫回 `.turbo-plugin/applicationhost.config` 的機制(目前需手動 copy)。待另開 brainstorm。
- **既有 tdp / tnf / tgs / tpi plugin 的 PS 5.1 lint violations 清理**(11 處):隨 4 個舊 plugin retirement 時處理,**不**在本 v1.0 PR 內動。
- **plugins/turbo-plugin/.claude-plugin/plugin.json 的 dependencies 欄位確認**:本 plan 假設 turbo-plugin 是獨立 plugin 無對其它 plugin 依賴;若 .claude-plugin schema 有變需要 deferred 確認。

---

## Risks & Mitigations

- **Risk: apphost canonical 第一次寫入時 schema 不符 IIS Express 需求**:若 `.vs/<sln>/config/applicationhost.config` 內含 VS-only 自訂節點,IIS Express CLI 啟動可能 fail。**Mitigation**:U3 test scenarios 含 sample 專案的 `.vs/.../config/applicationhost.config` 直接 copy 後 iisexpress 啟動驗證;失敗則記錄為 implementation-time discovery。
- **Risk: bash grep+sed fallback 對 multi-line svn commit message 解析失敗**:user 在 SVN repo 有寫多行 commit msg + 沒裝 xmllint 時 svn-log 部分輸出可能截斷。**Mitigation**:SKILL.md / `--verbose` flag 註記建議裝 xmllint;Phase 4 完成報告若偵測 Git Bash + xmllint 缺,加一行「為了支援多行 SVN commit message 顯示,建議在 Git Bash 內安裝 xmllint」。
- **Risk: 跨 worktree 切換時 temp file 短暫 race**:同專案不會並發兩個 IIS Express(turbo-plugin 設計),切換 worktree 時 start-iis 既有邏輯(line 102-118)自動 stop 舊 instance 再用新 physicalPath 重啟。temp file 在 stop→restart 之間會被覆寫,**但這是預期行為**(舊 instance 已停)。**Mitigation**:U3 verification 含 main→dev-1 切換場景驗證 start-iis 的 stop-then-restart 流程在 temp file 設計下正確運作。
- **Risk: pagination SKILL 對下一輪訊息誤判**:使用者下一輪訊息既不是分頁意圖也不是 unrelated,而是介於兩者之間(例如「show me commits」沒指定 revision)。**Mitigation**:U11 test scenarios 補一條 ambiguous case → SKILL 視為 unrelated(退出迴圈),agent 一般對話處理。

---

## System-Wide Impact

- **所有 IIS 相關 SKILL**(tp-run / tp-stop / tp-build / tp-publish / tp-cleanup-orphan-iis):受 U3 apphost runtime 變更 + U4 `[iis] enabled` opt-out 影響。Procedure 段落都要在開頭加 enabled check。
- **所有 turbo-plugin 啟動的 IIS Express process**:U3 後改用 temp file `-config:<temp>` 啟動,monitoring / debugging 工具看到的 process commandline 會帶 `%TEMP%\turbo-plugin-iis-*.config` 路徑(非 `.vs/.../config/applicationhost.config`)。
- **Claude Code 整體 session**:Phase 3 寫 user-level settings.json 後,所有開啟的 Claude Code session(不只 turbo-plugin)**在使用者下次重啟 Claude Code 之後才生效** — `ENABLE_LSP_TOOL` / `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` / `tui = "fullscreen"` 等大多在 session 啟動時讀取,不會 mid-session hot-reload。Phase 4 完成報告會明示重啟需求,且使用者在 Phase 3 選 user-level 時 preview 明確告知此 side effect。
- **`~/.claude/plugins/cache/`**:Phase 3 啟用 plugin 後,Claude Code 自動從 marketplace git URL 下載 plugin 到 cache 目錄。第一次啟用會看到下載延遲。

---

## Documentation Plan

- **Code documentation**:U1-U11 各 unit 內的 `.ps1` / `.sh` / SKILL.md / config.toml comment 同步更新。
- **CHANGELOG.md**:U12 處理。
- **README.md**:U12 處理 — 加 LSP / CE / agent teams / TUI 推薦提示在「安裝」章節;說明 apphost runtime 變更(VS UI 與 turbo-plugin 從本版起分頭管理)。

---

## Operational Notes

- **Release validation**:v1.0 PR merge 前完成 manual smoke test:
  - 在 `SampleGitWithSvn` 上跑 tp-setup case (a) 全流程
  - 跑 tp-build → tp-run → 開瀏覽器確認 IIS Express 服務
  - 跑 tp-svn-log 確認中文不變 `?`、互動分頁、`--revision` 各格式
- **Rollback plan**:turbo-plugin v1.0 是首次 release,沒有先前版本可 rollback。若 v1.0 release 後爆嚴重 bug,emergency 處理是 hot-fix v1.0.1 或從 marketplace `/plugin disable turbo-plugin` 停用整個 plugin,等修好再啟用。
- **Monitor 指標**:無服務端 telemetry — turbo-plugin 是 local CLI plugin。Rely on user issue reports。
