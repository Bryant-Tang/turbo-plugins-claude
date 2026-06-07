# Skill tests — Manual Test Tracking SCHEMA

turbo-plugin v1.0+ PR-readiness Skill tests 手動測試的 **schema + 15 skill case spec +
prompt 範本 + 失敗 patterns**。本檔為持久、可重複、path-free 的 schema reference;
per-release 的實際執行結果寫在
`plugins/turbo-plugin/tests/runs/<release>/skill-tests-results.md`(使用者跑每個
session 後手動 append rows)。

> 本檔下方各 skill section 的 `### Row table` 保留為空 template,不會被填;
> 實際 row 寫到 `runs/<release>/skill-tests-results.md`。

Skill tests case 由使用者貼 prompt 進 `<VALIDATION_ROOT>/proj`(見下方 `<VALIDATION_ROOT>`
慣例)內的 Claude Code session,使用者轉述 agent 回應 + 觀察錨點,orchestrator 判讀
PASS / FAIL / PARTIAL。

---

## `<VALIDATION_ROOT>` 慣例(path-free 前提)

本套件**完全 path-free**:所有 case 不寫死任何本機絕對路徑。

- `<VALIDATION_ROOT>` = 操作者在執行時自選的一個**真實本機目錄**,需在 **repo 之外**、
  且在 **plugin 開發樹(本 marketplace repo 的 checkout 位置)之外**(避免和 plugin 開發樹或既有測試遺留物混淆)。底下所有路徑
  都是**相對於 `<VALIDATION_ROOT>`** 表達。
- 操作者把 `<VALIDATION_ROOT>` 心裡換成自己挑的實際目錄(例如某個 scratch 資料夾),
  本檔不規定也不假設它在哪。
- 慣例佈局(相對 `<VALIDATION_ROOT>`):
  - `<VALIDATION_ROOT>/proj` — 受測專案 main worktree(fixture 重置的目標)。
  - `<VALIDATION_ROOT>/proj/.turbo-plugin/worktrees/remote-svn-main` — SVN trunk 橋接
    worktree(branch `remote-svn/main`)。
  - `<VALIDATION_ROOT>/proj/.turbo-plugin/worktrees/remote-svn-test-<n>` — SVN test 分支
    橋接 worktree(branch `remote-svn/test-<n>`)。
  - `<VALIDATION_ROOT>/svn-repo` — 本機 SVN repo(`svnadmin create` 出來的)。
- SVN URL 一律寫成 `file:///<VALIDATION_ROOT>/svn-repo/trunk` /
  `file:///<VALIDATION_ROOT>/svn-repo/branches/test-<n>` 這種 placeholder 形式;操作者把
  `<VALIDATION_ROOT>` 換成自己目錄的 `file:///` URL。
- 注意:turbo-plugin **不**維護 `.code-workspace` 檔(那是已退役的舊 tgs 行為),case
  不應假設或斷言任何 `.code-workspace`。

> 中文 fixture 字典(#1 路徑 / #2 檔名 / #3 commit msg / #4 source 註解 /
> #5 source string literal)— **single source of truth** 在
> [`script-tests-schema.md`](./script-tests-schema.md) 開頭 `## 中文 fixture
> 樣本` section,本檔不重複(R19 inline 字典 reference)。

> Skill tests session 切分建議與 case-count 對照表見
> [`skill-tests-session-plan.md`](./skill-tests-session-plan.md)。Skill tests 結束的 rollback
> 痕跡清單見 [`rollback-checklist.md`](./rollback-checklist.md)(per RBP Q3 = (b)
> — Skill tests 全部跑完才一次性 rollback)。

---

## Tracking schema

每個 Skill tests case 跑完後 orchestrator emit 一個 row 到下方對應 skill section。schema:

| 欄 | 說明 |
|---|---|
| `case ID` | `P2-<skill-stem>-<case-N>`(例:`P2-tp-setup-1`、`P2-tp-svn-log-3`) |
| `desc` | case 的短描述(happy / IIS missing / 中文 path / cross-worktree 等) |
| `fixture` | 預期 fixture pre-state(`fresh-base` / `inherits-prev-skill` / `iis-disabled` / `dirty-tree` 等) |
| `prompt summary` | 使用者貼進 Claude Code 的 prompt 摘要(對應本 section 的「Prompt 範本」其中之一) |
| `expected` | 預期 skill 觸發 / agent invocation chain / file write / AskUserQuestion / 中文輸出 round-trip 等 |
| `observation` | 使用者轉述的 agent 行為與觀察錨點實際命中情況 |
| `result` | `PASS` / `FAIL` / `PARTIAL` / `FAIL-known` / `SKIP` / `BLOCKED-BY:...` |
| `evidence` | chat snippet(quote) / file diff path / agent 輸出 stdout snippet / 修復 commit hash |

### Row 範例

```markdown
| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-setup-1 | case (a) 新建 happy | fresh-base + .git removed | 在 `<VALIDATION_ROOT>/proj` 空目錄請 agent 跑 /tp-setup | Phase 1 detect → AskUserQuestion 取 SVN URL → orphan remote-svn/main + svn checkout | agent 走 case (a) 6 sub-step + apphost bootstrap 三選一(已選 1) | PASS | chat r1234 / .turbo-plugin/ 目錄齊全 |
```

> **Round-trip text stability**(F-3 plan-time correction):中文 SVN-related case 不
> 驗 SVN propvalue byte-level(Windows + TortoiseSVN 不真存 UTF-8 byte),而是驗
> **svn log 透過 console codepage decode 後 = 字典預期文字**(text-equal 而非
> byte-equal)。Source body byte preserve(`pack-content` / `tp-build-dotnet-framework-web`
> 對應)仍是 byte-equal,filesystem bytes 是 UTF-8 canonical。

> **Surface-small skill 標記**:`tp-csharp-comment` / `tp-js-comment` / `tp-reset-branch-to-main`
> 各 2 case,低於 R12 通用 floor「1 happy + 2-3 error + 1 中文」的 4 case 最少數。
> 理由:這三個 skill 介面表面狹窄(comment 系列只有「跑 + verify XML/JSDoc 覆蓋」、
> reset 系列只有「diff-only preview / apply / cancel / already-equal 四條 path」),
> 同一 happy + error 不需要多個樣本就能覆蓋全部行為。

---

## tp-setup

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-setup-1 | case (a) 新建 git+SVN happy | fresh-base 但移除 `.git/` + 移除 `.turbo-plugin/` | Phase 1 detect → case (a) → 6 sub-step + apphost bootstrap 三選一(選 (1) 暫停 — 因 fresh fixture 無 `.vs/`) | `.git/` 重建 / `.gitignore` 含 turbo-plugin pattern(含 `.turbo-plugin/worktrees/`)/ `.turbo-plugin/` 目錄三檔齊 / `remote-svn/main` orphan branch + `.turbo-plugin/worktrees/remote-svn-main` worktree / svn checkout 完成 | AE8, AE9(case-detect happy) |
| P2-tp-setup-2 | case (c) 主 worktree 補設定(idempotent) | fresh-base 完整(`.turbo-plugin/` 已存在) | Phase 1 detect → case (c) → 6 個 idempotent sub-step 全 skip(已存在不覆寫)→ apphost bootstrap canonical-exists 分支 | 沒有新檔 / 既有 shared file 內容 byte-unchanged / Phase 4 報告「全部已存在,無變動」/ 第二次跑結果完全一致 | AE10(idempotency) |
| P2-tp-setup-3 | 中文 workspace path | fresh-base 複製到 `<VALIDATION_ROOT>/proj 測試 ™/` | Phase 1 detect → 中文路徑不 crash → case (c) 補設定 → apphost bootstrap → Phase 4 報告路徑 round-trip 正確 | `.turbo-plugin/config.toml` 寫入路徑顯示為中文 / agent chat 中顯示中文路徑無 mojibake / `applicationhost.config` 路徑替換不破壞 | AE9 extended(中文 path) |
| P2-tp-setup-4 | Phase 3 推薦項目實際安裝 — LSP(C# + TS/JS) | 已跑完 case 1 或 case 2 + dotnet / npm 兩個 CLI 都 ✓ | Phase 3 detect → batch 1 prompt(C# LSP / TS/JS LSP 兩題)→ 使用者選 user-level → `~/.claude/settings.json` 寫入 enabledPlugins + env.ENABLE_LSP_TOOL → `dotnet tool install -g csharp-ls` + `npm install -g typescript-language-server typescript` 兩個外部安裝實際跑 | `dotnet tool list -g` 含 csharp-ls / `npm list -g` 含 typescript-language-server / `~/.claude/settings.json` 含兩個 enabledPlugins / Phase 4 報告「✓ 已安裝」兩條 | AE15(real-install) |
| P2-tp-setup-5 | Phase 3 推薦項目實際安裝 — compound-engineering + agent teams + TUI fullscreen | 接續 case 4 完成後 | Phase 3 detect → batch 2 prompt(CE 三選一 / agent teams 四選一 / TUI fullscreen 四選一)→ 使用者選 CE「安裝(不自動更新)」+ agent teams user-level + TUI fullscreen user-level → `~/.claude/settings.json` 寫入 extraKnownMarketplaces + env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS + top-level tui | `~/.claude/settings.json` 含 `extraKnownMarketplaces["compound-engineering-plugin"]` + `enabledPlugins["compound-engineering@compound-engineering-plugin"] = true` + `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"` + `tui = "fullscreen"` / Phase 4 提示「請重啟 Claude Code 後才會生效」 | AE15(real-install) |

### 失敗常見 patterns

- **AskUserQuestion 文字露技術術語**:SKILL.md 1.2 明文要求不要對使用者用 CP_ACP / CreateProcessA / DBCS 等。若使用者轉述「agent 問了我 CP_ACP 是什麼」→ FAIL(skill 沒照 SKILL.md `Note for SKILL implementer` 寫)。
- **Phase summary 列了 internal 動作**:SKILL.md `## Decision Rules` 明確列「Phase summary 只列會動到外部的 unconditional 動作」。若使用者轉述「agent 列了 `.gitignore` 寫入 / template copy」→ FAIL(過度揭露 internal,違反 R14/R15/R16)。
- **case 偵測順序錯**:fresh-base 但 `.git/` 不存在情境下若被偵測為 case (b) / (c) / (d) → FAIL(Decision Rule 「Case 偵測順序固定」)。
- **Phase 3 沒問就裝**:LSP / CE / TUI 任一項目沒透過 AskUserQuestion 就寫進 settings.json → FAIL。
- **`extraKnownMarketplaces` 覆寫使用者其它 marketplace**:case 5 CE 寫入時把使用者既有的其它 marketplace 條目刪掉 → FAIL(SKILL.md 3.4.C 明文「整個物件覆寫 compound-engineering-plugin entry,使用者既有的其它 marketplace 條目必須保留」)。
- **idempotency 違反**:case 2 第二次跑出現新檔 / 重複追加 CLAUDE.md 區段 → FAIL。
- **case (d) peer-mode 寫進 shared file**:若 SKILL 在 peer worktree 跑時動到 `.commitlintrc.json` / `CLAUDE.md` / `.turbo-plugin/config.toml` 等 → FAIL(Decision Rule)。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1`,然後手動移除 `<VALIDATION_ROOT>/proj/.git` 與 `<VALIDATION_ROOT>/proj/.turbo-plugin`(`Remove-Item -Recurse -Force`)。然後在 `<VALIDATION_ROOT>/proj` 開 Claude Code session,確認 turbo-plugin 已啟用。
>
> **Prompt**:
> ```
> 請幫我跑 /tp-setup,SVN URL 是 file:///<VALIDATION_ROOT>/svn-repo/trunk
> ```
>
> **觀察重點**:
> - agent 是否觸發 tp-setup skill(SessionStart 不應自動跑,要明確 prompt 才觸發)
> - Phase 1 是否偵測為 case (a)
> - apphost bootstrap 三選一是否出現,使用者選 (1) 暫停後 setup 是否乾淨結束
> - `.turbo-plugin/` 目錄是否含 `config.toml` / `applicationhost.config` / `dbhub.example.local.toml` 三檔
> - `.gitignore` 在任何 `git worktree add` 之前已含 `.turbo-plugin/worktrees/`(主 worktree `git status --porcelain` 乾淨)
> - `remote-svn/main` orphan branch + `.turbo-plugin/worktrees/remote-svn-main` worktree 是否建立(`git worktree list` 確認)
> - 跑完後 `git log --oneline remote-svn/main` 至少 1 個 commit「init: remote-svn/main branch」
> - chat 中 agent 沒列出 internal 動作(.gitignore 寫入等),只列「從 SVN 抓取」「設定 SVN ignore 並推送」

> **Setup**(case 2):orchestrator 跑 `Reset-Fixture.ps1` 重置 fixture,fixture base 已含 `.turbo-plugin/` 完整三檔。
>
> **Prompt**:
> ```
> 請跑 /tp-setup
> ```
>
> **觀察重點**:
> - Phase 1 偵測為 case (c)
> - 6 個 idempotent sub-step 全 skip(agent 報告「全部已存在,無變動」)
> - 沒有新檔出現(`git status --porcelain` 為空)
> - 隔幾秒重跑同 prompt → 第二次結果完全相同(idempotent 驗證)

> **Setup**(case 3):orchestrator 跑 `Reset-Fixture.ps1`,然後把 `<VALIDATION_ROOT>/proj` 改名為 `<VALIDATION_ROOT>/proj 測試 ™`(`Rename-Item`),在新路徑下開 Claude Code。
>
> **Prompt**:
> ```
> 請跑 /tp-setup,確認 turbo-plugin 在中文路徑下能正常運作
> ```
>
> **觀察重點**:
> - agent chat 中顯示中文路徑無 mojibake(`測試 ™` 三字 round-trip 正確)
> - `.turbo-plugin/config.toml` `tools` section(若有寫)路徑欄不破壞
> - `applicationhost.config` runtime physicalPath 替換成中文路徑無 escape 問題
> - Phase 4 報告中含完整中文路徑

> **Setup**(case 4):case 1 或 case 2 跑完。確認 `dotnet --version` 與 `npm --version` 兩個 CLI 都正常回應。
>
> **Prompt**:
> ```
> 請跑 /tp-setup,我想啟用 C# LSP 跟 TypeScript LSP
> ```
>
> **觀察重點**:
> - Phase 3 batch 1 prompt 出現,4 個選項 per question(跳過 / user-level / project-level / local-level)
> - 使用者選 user-level 兩次
> - agent 實際跑 `dotnet tool install -g csharp-ls` 與 `npm install -g typescript-language-server typescript`(等個 30-60 秒)
> - 跑完後 `dotnet tool list -g | findstr csharp-ls` 有結果
> - `npm list -g --depth=0 | findstr typescript-language-server` 有結果
> - `~/.claude/settings.json` 含 `enabledPlugins["csharp-lsp@claude-plugins-official"] = true` + `enabledPlugins["typescript-lsp@claude-plugins-official"] = true` + `env.ENABLE_LSP_TOOL = "1"`
> - 使用者既有的其它 settings.json keys 未被刪除(check key count before / after)

> **Setup**(case 5):case 4 跑完之後直接接續(不 reset fixture,不關 Claude Code session)。
>
> **Prompt**:
> ```
> 我也想啟用 compound-engineering(不自動更新)、agent teams、跟 TUI fullscreen
> ```
>
> **觀察重點**:
> - Phase 3 batch 2 prompt 出現,3 個 question
> - CE 題目顯示 3 個選項(跳過 / 安裝自動更新 / 安裝不自動更新),使用者選「安裝不自動更新」
> - agent teams + TUI 兩題各 4 個選項(跳過 / user-level / project-level / local-level)
> - `~/.claude/settings.json` 含完整 5 個 keys:
>   - `extraKnownMarketplaces["compound-engineering-plugin"].source.url = "https://github.com/EveryInc/compound-engineering-plugin.git"`
>   - `extraKnownMarketplaces["compound-engineering-plugin"].autoUpdate = false`
>   - `enabledPlugins["compound-engineering@compound-engineering-plugin"] = true`
>   - `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`
>   - `tui = "fullscreen"`(top-level)
> - Phase 4 emit 提示「請重啟 Claude Code 後才會生效」
> - case 4 寫進的 LSP keys 沒被覆蓋(check 5 個 LSP-related keys 仍存在)

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-setup-1 | case (a) 新建 happy | fresh-base + .git/.turbo-plugin removed | /tp-setup with --svn-url | Phase 1→case(a)→6 sub-step + apphost bootstrap 三選一 | _(TBD U6→merged here)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-setup-2 | case (c) 主 worktree 補設定 idempotent | fresh-base 完整 | /tp-setup(無參數) | Phase 1→case(c)→6 idempotent sub-step skip | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-setup-3 | 中文 workspace path | fresh-base 改名為「proj 測試 ™」 | /tp-setup | 中文路徑 round-trip 不破壞 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-setup-4 | Phase 3 LSP 實際安裝 | case 1/2 完成 + dotnet/npm 可用 | /tp-setup 啟用 C# LSP + TS/JS LSP | batch 1 prompt + 兩個外部 install + settings.json 寫入 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-setup-5 | Phase 3 CE + agent teams + TUI 實際安裝 | case 4 接續 | /tp-setup 啟用 CE 不更新 + agent teams + TUI fullscreen | batch 2 prompt + settings.json 5 keys | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-pull-from-svn

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-pull-from-svn-1 | Happy SVN-ahead pull | fresh-base + SVN r20 base + 已 setup;SVN 多 r21 commit(orchestrator 預先用 svn ci 推進去) | /tp-pull-from-svn --branch main → script:`svn update`+`git fetch`+`git merge remote-svn/main` → 主 worktree HEAD 前進 | `Pulled SVN r21 into main` stdout / `git log --oneline main` 含 sync commit + merge commit / `git status --porcelain` 為空 | AE5 |
| P2-tp-pull-from-svn-2 | 中文 commit pull | 接 case 1 完成後 + orchestrator 推 r22 中文 commit「修正中文 commit 訊息亂碼」(字典 3.1) | /tp-pull-from-svn --branch main → svn update r22 → git fetch / merge | `git log --oneline remote-svn/main` r22 commit msg 顯示「修正中文 commit 訊息亂碼」**text-equal**(round-trip stable,不 byte-equal — Windows codepage 限制) | AE5 + R18 中文 |
| P2-tp-pull-from-svn-3 | Main dirty refuse | fresh-base + 主 worktree 多新檔 `extras/garbage.txt`(untracked) | /tp-pull-from-svn --branch main → script 偵測 `git status --porcelain` 非空 → 拒跑 fail-loudly | stderr 含「please commit / stash first」/ exit 非 0 / 沒動 SVN / `extras/garbage.txt` 仍在 | (Decision Rule cover) |
| P2-tp-pull-from-svn-4 | remote-svn-main missing | fresh-base 後手動 `git worktree remove --force .turbo-plugin/worktrees/remote-svn-main` | /tp-pull-from-svn --branch main → script 偵測 remote-svn-main worktree 不存在 → fail-loudly | stderr 提示「先跑 /tp-setup」/ exit 非 0 / 沒動 SVN | (Decision Rule cover) |

### 失敗常見 patterns

- **agent 自動 abort merge conflict**:SKILL.md 明文「衝突時不自動 abort,讓使用者選擇手動解決」。若 agent 在 case 1 變體(故意造衝突)下自動 `git merge --abort` → FAIL。
- **沒驗 `force_bash` config**:SKILL.md Decision Rule 「呼叫 script 前讀 `.turbo-plugin/config.toml [svn] force_bash`」。fixture 改 `force_bash = true` 後若 agent 仍跑 `.ps1` → FAIL(這個是個 sub-variant 沒列為獨立 case,但常見漏洞)。
- **中文 commit msg 亂碼**:case 2 若 round-trip 顯示「修正?? commit ????」→ FAIL(可能 script 用 `svn log` 不帶 `--xml`,被 console codepage mangle)。
- **rollback failure 時繼續往下**:script emit「Working tree is in an inconsistent state」之後 agent 繼續跑後續 step → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑完一輪 `/tp-setup` case (a)(在 orchestrator session 預先做)。然後 orchestrator 在 `<VALIDATION_ROOT>/svn-repo` 上手動 `svn import` 多一個 r21 commit。確認 main worktree clean。
>
> **Prompt**:
> ```
> 請跑 /tp-pull-from-svn --branch main 拉 SVN 最新 commit
> ```
>
> **觀察重點**:
> - agent 是否觸發 tp-pull-from-svn skill
> - script stdout 出現 `Pulled SVN r21 into main`
> - `git log --oneline main` 至少含一個 `sync: svn r21` commit + 一個 `Merge branch 'remote-svn/main' into main` commit
> - `git status --porcelain` 為空
> - agent 沒主動 commit / amend 任何使用者沒授權的東西

> **Setup**(case 2):case 1 跑完之後,orchestrator 在 `<VALIDATION_ROOT>/svn-repo` 推 r22 中文 commit(在 SVN repo root 用 svn commit with `--message "修正中文 commit 訊息亂碼"` 推 r22)。
>
> **Prompt**:
> ```
> SVN 又有新 commit 了,幫我 pull 過來
> ```
>
> **觀察重點**:
> - agent 觸發 tp-pull-from-svn
> - script stdout 含 r22 msg 顯示「修正中文 commit 訊息亂碼」(text-equal,可能 console codepage decode 後比對)
> - `git log -1 --format=%s remote-svn/main` 也是「修正中文 commit 訊息亂碼」
> - 沒亂碼(無 `?` 取代字元)

> **Setup**(case 3):case 1 / 2 跑完後在主 worktree 多建 `extras/garbage.txt`(untracked,**不要 commit**)。
>
> **Prompt**:
> ```
> 請跑 /tp-pull-from-svn --branch main
> ```
>
> **觀察重點**:
> - script 拒跑,stderr 含「working tree dirty」/「please commit or stash」
> - exit 非 0
> - `extras/garbage.txt` 仍存在(不被 stash)
> - agent 不自動 `git stash`(SKILL 不應該做這個決定)

> **Setup**(case 4):case 1 / 2 跑完之後 orchestrator 手動 `git worktree remove --force .turbo-plugin/worktrees/remote-svn-main`(或直接刪資料夾)。
>
> **Prompt**:
> ```
> 請跑 /tp-pull-from-svn --branch main
> ```
>
> **觀察重點**:
> - script fail-loudly,stderr 含「remote-svn-main worktree missing」/「先跑 /tp-setup」
> - exit 非 0
> - 沒嘗試自動修復(setup 由使用者明確觸發,不該被 pull 自動帶入)

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-pull-from-svn-1 | Happy SVN-ahead | fresh-base + r21 預推 | /tp-pull-from-svn --branch main | r21 → main HEAD 前進 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-pull-from-svn-2 | 中文 commit pull | 接 case 1 + r22 中文 commit | /tp-pull-from-svn 拉新 commit | r22 中文 msg round-trip 正確 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-pull-from-svn-3 | Main dirty refuse | fresh-base + untracked garbage | /tp-pull-from-svn | 拒跑 fail-loudly | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-pull-from-svn-4 | remote-svn-main missing | fresh-base + remote-svn-main 移除 | /tp-pull-from-svn | fail-loudly 提示先 setup | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-push-to-svn

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-push-to-svn-1 | Happy push 含 feat / fix / refactor commits | fresh-base 已 setup + main 多 3 commit(feat / fix / refactor 各一)+ SVN HEAD = r20 | /tp-push-to-svn --branch main → prepare → parse 3 commits → 全部 kept-subset → Step 5 confirm Accept → commit → SVN r21 | prepare stdout 含 `COMMITS\n<hash>\|feat:...\n<hash>\|fix:...\n<hash>\|refactor:...` / Step 4 SVN body 含三條 bullet / SVN r21 寫入 / `svn log -r 21` msg 完整 | AE7 |
| P2-tp-push-to-svn-2 | 中文 commit push | 接 case 1 + main 多 1 commit subject 「fix: 處理 SVN 中文檔名相容性」(字典 3.4) | /tp-push-to-svn --branch main → SVN body 含中文 → svn commit --file UTF-8 no-BOM | SVN r22 寫入 / `svn log -r 22` text-equal「fix: 處理 SVN 中文檔名相容性」(text-equal not byte-equal — Windows propvalue codepage 限制) | AE7 + R18 中文 |
| P2-tp-push-to-svn-3 | docs/chore 全篩除(empty body) | 接 case 2 + main 多 2 commit(`docs: 更新 README` + `chore: bump version`) | /tp-push-to-svn → 兩 commit 都被 silent 篩除 → Step 4 body 寫「本次推送沒有程式碼層級的異動」 | Step 5 confirm 顯示 kept = 0 / removed = 2 / SVN body 含 fallback 字串 / r23 寫入 | (Step 3.4 silent-filter behavior) |
| P2-tp-push-to-svn-4 | Unknown type prompt 取消 | 接 case 3 + main 多 1 commit subject `update parser logic`(無 conventional prefix) | /tp-push-to-svn → prepare → unknown type 偵測 → AskUserQuestion(保留 / 篩除 / 取消)→ 使用者選「取消」→ `git merge --abort` cleanup | AskUserQuestion 出現 / 使用者選取消 / remote-svn-main worktree `git status` 為空(merge 已 abort)/ SVN 沒新 revision | (Step 3.5 cancel path) |
| P2-tp-push-to-svn-5 | Step 7 release tag — 檔案全 svn:ignore 仍產出 merge commit | 接 case 1 後重置 push 環境 + main 多 1 commit,該 commit 只新增一個已被 `svn:ignore` 的檔(如 `obj/junk.tmp`,先用 tp-suggest-ignore 把 `obj/` 加進 svn:ignore)| /tp-push-to-svn --branch main → prepare 產出 git merge commit(`git log remote-svn/main..main` 非空)→ Step 6 svn commit 為空(`No changes to commit to SVN`)→ **Step 7 仍詢問** release tag → 使用者選 Yes → Tag-Release 建 `main-release-<date>-NNN` | prepare stage 了 merge commit / Step 6 stdout 含 `No changes to commit to SVN` / Step 7 AskUserQuestion 出現(Yes/No)/ 選 Yes 後 `git tag -l "main-release-*"` 出現新 tag / `git rev-parse <tag>` == `git rev-parse remote-svn/main` | AE1(merge commit → 仍問 tag) |
| P2-tp-push-to-svn-6 | Step 7 nothing-to-push → 不問 tag | 接 case 5 後不再多任何 commit(main 與 remote-svn/main 已對齊) | /tp-push-to-svn --branch main → prepare 印 `Nothing to push`(無 merge commit 產出)→ **直接跳過 Step 7**,不詢問 release tag | prepare stdout 含 `Nothing to push` / **沒有** Step 7 AskUserQuestion / `git tag -l "main-release-*"` 數量與 case 5 後相同(無新增) | AE2(無新 commit → 不問 tag) |

### 失敗常見 patterns

- **agent 自動猜 unknown type**:SKILL.md Decision Rule「Unknown type 必須 prompt,不能猜」。若 case 4 agent 自動「reasoning: 看起來像 refactor,保留」未 ask → FAIL。
- **沒 cleanup merge state**:case 4 取消後 remote-svn-main worktree 仍 stage merge → FAIL。
- **`.commitlintrc.json` 不在時靜默全篩光**:SKILL.md 明文「fallback 用 default 12 類 + stderr notice,不靜默失敗」。若 fixture 中 `.commitlintrc.json` 刪掉測 happy case agent 把所有 commit 篩光 → FAIL。
- **中文 commit msg mangle**:case 2 SVN r22 msg 變「fix: 處理 SVN ?? 檔名 ???」→ FAIL(可能 script 沒用 `--file <utf8-no-bom-tmp> --encoding UTF-8`,改成 `-m "..."`,中文被 CP_ACP mangle)。
- **race condition guard 失效**:SHA pin guard 沒做 → 在 Step 5 Accept 前手動 `git commit` 新 commit → Step 6 commit 沒 throw `Branch ... has new commits since prepare` → FAIL(這個 test 在 Test Scenarios manual case,P2 不必硬編但可順便驗)。
- **Step 7 判準用「svn commit 有無內容」而非「有無 merge commit」**:case 5 檔案全 `svn:ignore`、svn commit 為空,但 prepare 仍產出 git merge commit → 若 agent 因 `No changes to commit to SVN` 就**不問** release tag → FAIL(KTD7 / R29 判準是「有無產出 git merge commit」)。
- **nothing-to-push 仍問 tag**:case 6 prepare 印 `Nothing to push`(根本無 merge commit)→ 若 agent 仍跳出 Step 7 release tag prompt → FAIL。
- **tag ref 用舊命名**:Step 7 建的 tag 指向 `remote/main`(舊命名)而非 `remote-svn/main` → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a),然後在 main worktree 預製 3 個 git commit:
> ```
> # 1. echo "feat code 1" > new1.cs; git add .; git commit -m "feat: 新增 feature 1"
> # 2. echo "fix bug 1" > new2.cs; git add .; git commit -m "fix: 修正 bug 1"
> # 3. echo "refactor" > new3.cs; git add .; git commit -m "refactor: 整理結構"
> ```
> 確認 main worktree clean、SVN HEAD = r20(reset 後 base seed)。
>
> **Prompt**:
> ```
> 我有 3 個新 commit 想推到 SVN,幫我跑 /tp-push-to-svn --branch main
> ```
>
> **觀察重點**:
> - prepare 列 3 個 COMMITS 行
> - Step 4 SVN body 含 3 條 bullet「feat: 新增 feature 1」「fix: 修正 bug 1」「refactor: 整理結構」
> - Step 5 confirm 出現
> - 使用者 Accept 後 SVN r21 寫入
> - 跑完 `svn log -r 21` msg 完整

> **Setup**(case 2):接 case 1 完成。在 main 多 1 commit:
> ```
> echo "i18n fix" > i18n.cs; git add .; git commit -m "fix: 處理 SVN 中文檔名相容性"
> ```
>
> **Prompt**:
> ```
> 再幫我把剛剛這個中文 commit 推上去 — /tp-push-to-svn --branch main
> ```
>
> **觀察重點**:
> - SVN r22 寫入
> - `svn log -r 22` 顯示「fix: 處理 SVN 中文檔名相容性」**text-equal**(可能 console codepage decode 後正確,SVN propvalue 內部 byte format 不檢驗)
> - 沒亂碼

> **Setup**(case 3):接 case 2。在 main 多 2 commit:
> ```
> git commit --allow-empty -m "docs: 更新 README"
> git commit --allow-empty -m "chore: bump version"
> ```
>
> **Prompt**:
> ```
> /tp-push-to-svn --branch main
> ```
>
> **觀察重點**:
> - prepare 列 2 個 COMMITS 行
> - Step 4 body 寫「本次推送沒有程式碼層級的異動(僅文件 / 測試 / 設定 / 雜務)。」
> - Step 5 confirm 顯示 kept = 0 / removed = 2
> - SVN r23 仍寫入(body 是 fallback 字串,但 still push)

> **Setup**(case 4):接 case 3。在 main 多 1 commit subject 無 conventional prefix:
> ```
> git commit --allow-empty -m "update parser logic"
> ```
>
> **Prompt**:
> ```
> /tp-push-to-svn --branch main
> ```
>
> **觀察重點**:
> - AskUserQuestion 出現「Commit `<hash>` 的 subject「update parser logic」沒有可辨識的 conventional commit type」
> - 三選一:保留 / 篩除 / 取消
> - 使用者選「取消」
> - agent 跑 `git merge --abort` cleanup
> - remote-svn-main worktree `git status --porcelain` 為空(merge 已 abort)
> - SVN log 仍只有 r23(沒 r24)

> **Setup**(case 5):接 case 4 後重置 push 環境(orchestrator 跑 `Reset-Fixture.ps1` + setup case (a),SVN HEAD = r20)。先用 `/tp-suggest-ignore --add-svn "obj/"` 把 `obj/` 加進 remote-svn-main 的 svn:ignore。然後在 main 多 1 commit,內容只新增一個被忽略的檔:
> ```
> # 新增 obj/junk.tmp(會被 svn:ignore obj/ 忽略),git add . ; git commit -m "chore: 暫存產物"
> ```
> 確認 main worktree clean。
>
> **Prompt**:
> ```
> /tp-push-to-svn --branch main
> ```
>
> **觀察重點**:
> - prepare 階段產出 git merge commit(`git log remote-svn/main..main` 非空)
> - Step 6 svn commit stdout 含 `No changes to commit to SVN`(檔案全被 `svn:ignore`)
> - **Step 7 仍詢問** release tag(AskUserQuestion Yes/No)— 判準是「有 merge commit」非「svn 有內容」
> - 使用者選 Yes
> - Tag-Release 印 `Created tag: main-release-<yyyy-MM-dd>-NNN`
> - `git tag -l "main-release-*"` 出現新 tag
> - `git rev-parse <tag>` == `git rev-parse remote-svn/main`(tag 指向 remote-svn/main tip,新命名)

> **Setup**(case 6):接 case 5 直接續(main 與 remote-svn/main 已對齊,**不**再多任何 commit)。
>
> **Prompt**:
> ```
> /tp-push-to-svn --branch main
> ```
>
> **觀察重點**:
> - prepare stdout 含 `Nothing to push`(沒有任何新 commit、沒有 merge commit 產出)
> - skill **直接結束**,**沒有** Step 7 release tag 詢問
> - `git tag -l "main-release-*"` 數量與 case 5 跑完後相同(無新 tag)

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-push-to-svn-1 | Happy 3-commit push | fresh-base+setup + 3 commit(feat/fix/refactor) | /tp-push-to-svn --branch main | prepare 3 commit + body 3 bullet + r21 寫入 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-push-to-svn-2 | 中文 commit push | 接 1 + 中文 fix commit | /tp-push-to-svn --branch main | r22 中文 msg text-equal | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-push-to-svn-3 | docs/chore 全篩除 | 接 2 + 2 commit (docs/chore) | /tp-push-to-svn --branch main | body 是 fallback 字串 / r23 寫入 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-push-to-svn-4 | Unknown type 取消 | 接 3 + 1 commit (`update parser`) | /tp-push-to-svn --branch main | AskUserQuestion 取消 / merge --abort | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-push-to-svn-5 | Step 7 tag — svn:ignore 仍有 merge commit | reset+setup + obj/ svn:ignore + 1 commit 只加忽略檔 | /tp-push-to-svn --branch main | svn 空但仍問 tag → 建 main-release-* on remote-svn/main | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-push-to-svn-6 | Step 7 nothing-to-push 不問 tag | 接 5,無新 commit | /tp-push-to-svn --branch main | `Nothing to push` → 跳過 Step 7,無新 tag | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-reset-branch-to-main

> **Surface-small skill**:2 case(below R12 通用 floor「1 happy + 2-3 error + 1 中文」的 4 最少數)。理由:reset 操作只有四條 path(diff-only preview / Apply / Cancel / already-equal),每條 path 行為極為穩定。中文層面對齊 SVN history 不會在這裡新增 surface(已被 tp-svn-log + tp-push-to-svn 覆蓋)。

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-reset-branch-to-main-1 | Apply path with LOSE/GAIN diff | fresh-base + setup(a) + 建工作分支 test-1 後用 `New-RemoteBridge` 建 test-1 bridge + test-1 branch 領先 main 3 commit + main 領先 test-1 5 commit | /tp-reset-branch-to-main --branch test-1 → Step 1 --diff-only → script 印 LOSE/GAIN/FILES_LOST_AFTER_PUSH → AskUserQuestion → 使用者選 Apply → Step 3 actual reset → `Reset test-1 to main.` | Step 1 stdout 含 `LOSE` 3 commits + `GAIN` 5 commits + `FILES_LOST_AFTER_PUSH` non-empty / AskUserQuestion description 含「重設後下次推送 SVN 會刪除 N 個檔案」/ Apply 後 `git log test-1..main` 為空(等齊) | (Apply happy) |
| P2-tp-reset-branch-to-main-2 | Cancel + already-equal short-circuit | (a) cancel:同 case 1 fixture 但使用者選 Cancel;(b) already-equal:fresh-base + 用 `New-RemoteBridge` 建 test-1 bridge 後 test-1 直接 == main(沒有 LOSE/GAIN)| (a) /tp-reset-branch-to-main --branch test-1 → --diff-only → AskUserQuestion → Cancel → 不動 git;(b) /tp-reset-branch-to-main --branch test-1 → --diff-only → 印「already equals main. Nothing to reset.」→ 略過 AskUserQuestion 直接結束 | (a) test-1 HEAD 未動 / LOSE/GAIN 仍不平衡;(b) stdout 含「already equals」/ 沒 AskUserQuestion / exit 0 | (Cancel + short-circuit) |

### 失敗常見 patterns

- **跳過 --diff-only preview 直接 reset**:SKILL.md Procedure 明文 Step 1 用 `--diff-only`,Step 2 AskUserQuestion,Step 3 才 actual reset。若 agent 一步到位跑 reset → FAIL。
- **already-equal 還問 AskUserQuestion**:case 2 (b) 若 agent 還跳出 modal → FAIL(SKILL.md 明文「early exit, no Step 2 needed」)。
- **FILES_LOST_AFTER_PUSH 沒解析**:script 印該 section,SKILL 沒 parse 沒顯示給使用者 → 使用者不知道 reset 會刪 SVN 檔 → FAIL。
- **Cancel 還動了 git**:case 2 (a) 選 Cancel 後 test-1 HEAD 被搬走 → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a),然後在主 worktree 先建工作分支 `git checkout -b test-1`,再呼叫 `${CLAUDE_PLUGIN_ROOT}/scripts/New-RemoteBridge.ps1 -Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`(`.sh` 等價 `new-remote-bridge.sh --branch test-1 --svn-url file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge(helper 不建工作分支,故須先 `git checkout -b test-1`);完成後 `git checkout main`。然後在 main worktree commit 5 個 commit(模擬 main 進 5 步),`git checkout test-1` 後 commit 3 個不同 commit(模擬 test-1 自己進 3 步),會造成 main 領先 5 / test-1 領先 3(divergent)。確認都 commit、worktree clean。
>
> **Prompt**:
> ```
> 幫我把 test-1 重設成 main — /tp-reset-branch-to-main --branch test-1
> ```
>
> **觀察重點**:
> - agent 觸發 tp-reset-branch-to-main
> - Step 1 先跑 `--diff-only`,stdout 含 `LOSE` 3 條 commit subject + `GAIN` 5 條 + `FILES_LOST_AFTER_PUSH` 區段(因為 test-1 加了 3 個檔案,reset 後下次 push 會刪)
> - AskUserQuestion description 含「重設後下次推送 SVN 會刪除 N 個檔案」並列出檔名
> - 使用者選 Apply
> - Step 3 跑 actual reset → `Reset test-1 to main.`
> - 跑完 `git log test-1..main` 為空(已等齊)

> **Setup**(case 2 — split into two sub-runs):
>
> **(a) Cancel sub-run**:跟 case 1 一樣 fixture(orchestrator 預先建 LOSE/GAIN 差異)。
>
> **Prompt**(a):
> ```
> /tp-reset-branch-to-main --branch test-1
> ```
>
> **觀察重點**(a):
> - --diff-only 印 LOSE/GAIN(非空)
> - AskUserQuestion 出現
> - 使用者選 Cancel
> - test-1 HEAD 未動(`git rev-parse test-1` 跑前跑後相同)
>
> **(b) Already-equal sub-run**:orchestrator 重 reset fixture + 重跑 setup + 在主 worktree 先 `git checkout -b test-1` 再呼叫 `New-RemoteBridge`(`-Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge(test-1 從 main 起跳,SHA 完全相同),建完 `git checkout main`。**不**多任何 commit。
>
> **Prompt**(b):
> ```
> /tp-reset-branch-to-main --branch test-1
> ```
>
> **觀察重點**(b):
> - --diff-only 直接 stdout「already equals main. Nothing to reset.」
> - 沒 AskUserQuestion modal 出現
> - exit 0
> - 沒任何 git 改動

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-reset-branch-to-main-1 | Apply with LOSE/GAIN/FILES_LOST | fresh-base+setup(a)+test-1 divergent | /tp-reset-branch-to-main --branch test-1 | --diff-only → Apply → reset 後等齊 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-reset-branch-to-main-2 | Cancel + already-equal short-circuit | sub-run (a) divergent / (b) equal | /tp-reset-branch-to-main --branch test-1 | (a) Cancel 不動 / (b) skip modal exit 0 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-build-dotnet-framework-web

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-build-dotnet-framework-web-1 | Happy build with MSBuild | fresh-base + setup(a) + `.csproj` 完整 + `[iis] enabled = true` | /tp-build-dotnet-framework-web → script:detect csproj → detect MSBuild → 跑 msbuild /restore /t:Build → exit 0 | stdout 含 `Build succeeded` / `<project>\bin\Debug\` 含 `.dll` / agent 沒被 TRUST_REQUIRED 卡(本 fixture 沒設 frontend) | (Happy build) |
| P2-tp-build-dotnet-framework-web-2 | [iis] disabled refuse | fresh-base + setup(a) + `.turbo-plugin/config.toml` 設 `[iis] enabled = false` | /tp-build-dotnet-framework-web → Step 0 偵測 → 不呼叫 script → 回報「IIS 已停用」訊息 | agent 沒跑 msbuild / chat 中含「IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)」 | AE2 consistency |
| P2-tp-build-dotnet-framework-web-3 | 中文 source body 編譯 | fresh-base + setup(a) + 在 `.csproj` 對應 `Controllers/HelloController.cs` 加中文字串 literal `var msg = "你好,turbo-plugin";`(字典 5.1)+ 中文註解(字典 4.1) | /tp-build-dotnet-framework-web → build OK → `.dll` 內 string section 含中文 byte | stdout `Build succeeded` / `Get-Content -Raw bin/Debug/HelloApp.dll -Encoding Byte` substring 含中文 UTF-16 bytes(.NET assembly string table 用 UTF-16 內部)/ 編譯不報 encoding error | R18 source body |

### 失敗常見 patterns

- **沒先 Step 0 check `[iis] enabled`**:case 2 agent 直接跑 msbuild,沒理會 `enabled = false` → FAIL(SKILL.md Step 0 明文)。
- **`Build succeeded` 訊息錯位**:script 報 exit 0 但 stdout 是 `Build FAILED` → FAIL(常見:msbuild 在 stdout 印 FAILED 但 exit 0,script 解讀錯)。
- **多個 .csproj 沒提示**:fixture 故意放兩個 .csproj 不指定 `-Project` → 應 fail-loudly 列候選。若 agent 自選一個 → FAIL。
- **TRUST_REQUIRED 沒擋**:fixture 加 `[frontend]` 設定,但 install_command 是危險指令(`rm -rf ~/`)→ script 應 emit `TRUST_REQUIRED hash=<h>` → agent AskUserQuestion 顯示完整指令。若 agent 直接寫 trust 後重跑 → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a) 完成。fixture base 已含 `HelloApp.csproj` + `HelloApp.sln`,標準 .NET Framework 4.7.2 Web App。確認 `.turbo-plugin/config.toml` `[iis] enabled = true` 或未設(預設 true)。
>
> **Prompt**:
> ```
> 幫我 build 這個專案 — /tp-build-dotnet-framework-web
> ```
>
> **觀察重點**:
> - agent 觸發 tp-build-dotnet-framework-web
> - script stdout 含 `Build succeeded`
> - `<project>\bin\Debug\` 含 `HelloApp.dll`
> - exit 0
> - 沒 TRUST_REQUIRED prompt(fixture 沒設 frontend)

> **Setup**(case 2):接 case 1 fixture(已 build 過一次也沒關係)。orchestrator 編輯 `.turbo-plugin/config.toml` 加入:
> ```toml
> [iis]
> enabled = false
> ```
>
> **Prompt**:
> ```
> /tp-build-dotnet-framework-web
> ```
>
> **觀察重點**:
> - agent 觸發 tp-build-dotnet-framework-web
> - Step 0 detect [iis] enabled = false
> - 沒呼叫 build-web script(沒跑 msbuild)
> - chat 中含完整訊息「IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定(預設啟用)。」
> - exit 0(disable 不是 error)

> **Setup**(case 3):接 case 1 fixture(回復 `[iis] enabled = true` 或拿掉該 section)。orchestrator 編輯 `Controllers/HelloController.cs` 加入:
> ```csharp
> // 中文註解:確認 HelloController 回傳值 byte-level 一致
> public string Index()
> {
>     var msg = "你好,turbo-plugin";
>     return msg;
> }
> ```
>
> **Prompt**:
> ```
> /tp-build-dotnet-framework-web
> ```
>
> **觀察重點**:
> - `Build succeeded`
> - 編譯不報 encoding 警告 / error
> - `bin/Debug/HelloApp.dll` 中可用 binary tool 找到中文「你好,turbo-plugin」UTF-16 string(byte-level preserve,filesystem-bytes-to-assembly-string 是 UTF-16 canonical)

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-build-dotnet-framework-web-1 | Happy build | fresh-base+setup(a) | /tp-build-dotnet-framework-web | msbuild exit 0 / .dll 產出 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-build-dotnet-framework-web-2 | [iis] disabled refuse | iis-disabled | /tp-build-dotnet-framework-web | Step 0 拒跑訊息 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-build-dotnet-framework-web-3 | 中文 source body | 中文 source modified | /tp-build-dotnet-framework-web | build OK + .dll 含中文 byte | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-run-dotnet-framework-web

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-run-dotnet-framework-web-1 | Happy IIS Express start with listening check | fresh-base + setup(a) + apphost canonical 已建(已過 Step 6 VS pre-touch) + 沒舊 iisexpress instance | /tp-run-dotnet-framework-web → script:detect csproj → parse IISUrl → compute identity hash → no existing instance → Start-Process iisexpress → polling netstat → LISTENING | stdout 含 `Started IIS Express (site: <name>, PID: <pid>)` + `Listening on http://localhost:<port>` / `netstat -ano \| findstr :<port>` 顯示 LISTENING / process tree 含 iisexpress.exe | (Happy run + listening check) |
| P2-tp-run-dotnet-framework-web-2 | Cross-worktree self-heal | case 1 跑完,iisexpress 跑在主 worktree → 切換 cwd 到 peer worktree(任一非 main 的 linked worktree),peer 也 tp-setup 過 | /tp-run-dotnet-framework-web from peer → script 偵測同 project 在主 worktree 已啟 → 自動 Stop-Process 舊 instance → 啟新 in peer | stdout 含 `Stopping previous instance(s)` / 主 worktree PID 被殺 / 新 instance PID 在 peer worktree path / `Listening on` 出現 | AE15a(self-heal) |
| P2-tp-run-dotnet-framework-web-3 | [iis] disabled refuse | fresh-base + setup(a) + `[iis] enabled = false` | /tp-run-dotnet-framework-web → Step 0 拒跑 | 沒呼叫 start-iis / chat 中含「IIS 已停用」訊息 | AE2 consistency |

### 失敗常見 patterns

- **沒做 listening 健康檢查**:SKILL.md Decision Rule「listening 健康檢查 incorporated 進 run」。若 stdout 只有 `Started PID xxx` 沒 `Listening on` → FAIL。
- **跨 worktree self-heal 反向**:case 2 應該自動殺舊,若 agent 詢問使用者 → FAIL(R15a 明文「不詢問使用者」)。
- **別 project 撞 port 仍啟**:若 fixture 預先有別 project 同 port LISTENING,本 case 應 fail-loudly 不殺別 project,但若 agent 殺了 → FAIL。
- **timeout = 0 退回 default**:Test Scenarios 有 manual case,SKILL.md Decision Rule 提到「timeout 預設 30s,可調」。若 `[run] listening_timeout_seconds = 0` 變 30 → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a)。fixture base 已預先 stub `.turbo-plugin/applicationhost.config` 帶 `__TURBO_PLUGIN_PHYSICAL_PATH__` 佔位符 + site `HelloApp-<hash>`。確認沒 iisexpress 在跑(`Get-Process iisexpress -ErrorAction SilentlyContinue` 為空)。
>
> **Prompt**:
> ```
> 幫我啟動本機 IIS 跑這個 project — /tp-run-dotnet-framework-web
> ```
>
> **觀察重點**:
> - agent 觸發 tp-run-dotnet-framework-web
> - stdout 含 `Started IIS Express (site: HelloApp-<8hex>, PID: <pid>)`
> - stdout 含 `Listening on http://localhost:<port>`
> - `netstat -ano | findstr :<port>` 顯示 LISTENING
> - 可用瀏覽器或 `Invoke-WebRequest http://localhost:<port>` 取得回應

> **Setup**(case 2):case 1 跑完(iisexpress 跑在主 worktree)。orchestrator 在一個 peer worktree(任一非 main 的 linked worktree,例如 `<VALIDATION_ROOT>/proj-peer`)開 Claude Code session。確認該 peer worktree 已過 `/tp-setup` case (d) peer-mode(orchestrator 預先做)。
>
> **Prompt**:
> ```
> 我在 peer worktree 也想跑這個 project — /tp-run-dotnet-framework-web
> ```
>
> **觀察重點**:
> - script 偵測同 project 已在主 worktree 跑(commandLine match `/site:HelloApp-<同 hash>`)
> - stdout 含 `Stopping previous instance(s)`
> - 主 worktree 的 iisexpress PID 不見(被 Stop-Process)
> - 新 iisexpress 啟在 peer worktree applicationhost.config(physicalPath = peer 路徑)
> - `Listening on` 仍然出現(port 重新 bind)
> - agent **沒詢問**使用者該不該殺(self-heal 是自動的)

> **Setup**(case 3):orchestrator 編輯 `.turbo-plugin/config.toml` 加 `[iis] enabled = false`。
>
> **Prompt**:
> ```
> /tp-run-dotnet-framework-web
> ```
>
> **觀察重點**:
> - Step 0 拒跑訊息
> - 沒呼叫 start-iis
> - chat 中含完整「IIS 已停用」訊息

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-run-dotnet-framework-web-1 | Happy IIS start | fresh-base+setup(a) | /tp-run-dotnet-framework-web | Started + Listening on | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-run-dotnet-framework-web-2 | Cross-worktree self-heal | case 1 + peer worktree | /tp-run-dotnet-framework-web (from peer) | 主 worktree PID 被殺 / 新 instance 在 peer | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-run-dotnet-framework-web-3 | [iis] disabled refuse | iis-disabled | /tp-run-dotnet-framework-web | Step 0 拒跑訊息 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-stop-dotnet-framework-web

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-stop-dotnet-framework-web-1 | Cross-worktree stop happy | tp-run case 1 跑完(iisexpress LISTENING)+ 切換 cwd 到 peer worktree | /tp-stop-dotnet-framework-web from peer → script 計算 project identity → 用 Get-CimInstance 找 iisexpress with `/site:<name>` → Stop-Process -Force | stdout 含 `Stopped IIS Express` / 主 worktree 該 PID 不見 / `netstat -ano \| findstr :<port>` 不再 LISTENING(可能延遲 1-2 秒) | (Cross-worktree stop) |
| P2-tp-stop-dotnet-framework-web-2 | No-op when not running | 沒 iisexpress 在跑 | /tp-stop-dotnet-framework-web → script 找不到 instance → 印 info | stdout 含 `No IIS Express process found for site '<name>'.` / exit 0 / 不是 error | (idempotent) |
| P2-tp-stop-dotnet-framework-web-3 | [iis] disabled refuse | `[iis] enabled = false` | /tp-stop-dotnet-framework-web → Step 0 拒跑 | 沒呼叫 stop-iis / chat 中「IIS 已停用」訊息 | AE2 consistency |

### 失敗常見 patterns

- **誤殺別 project**:fixture 同時跑 project A(target)和 project B(不同 csproj),`/tp-stop` 對 A 不應殺 B。若 B 被殺 → FAIL。
- **無 instance 報 error**:case 2 應 exit 0,不報 error。若 exit 非 0 或顯示「error: no process」→ FAIL。
- **site name 比對錯**:若 script filter 用 `/site:HelloApp` 不含 hash,會誤殺同名不同 hash 的 orphan instance → FAIL。

### Prompt 範本

> **Setup**(case 1):承 tp-run case 1 fixture 跑完(iisexpress LISTENING)。orchestrator 切換 cwd 到 peer worktree(任一非 main 的 linked worktree)。
>
> **Prompt**:
> ```
> 我在 peer 想把本機 IIS 停了 — /tp-stop-dotnet-framework-web
> ```
>
> **觀察重點**:
> - script 計算 project identity hash → 找到主 worktree 的 iisexpress PID
> - Stop-Process -Force
> - stdout 含 `Stopped IIS Express` 或類似訊息
> - 該 PID 在 `Get-Process iisexpress` 不再出現
> - `netstat -ano | findstr :<port>` 不再 LISTENING

> **Setup**(case 2):orchestrator 確認沒 iisexpress 在跑(`Get-Process iisexpress -ErrorAction SilentlyContinue` 為空)。fresh-base + setup(a)。
>
> **Prompt**:
> ```
> /tp-stop-dotnet-framework-web
> ```
>
> **觀察重點**:
> - stdout 含 `No IIS Express process found for site 'HelloApp-<hash>'.`
> - exit 0
> - 不是 error message

> **Setup**(case 3):orchestrator 設 `.turbo-plugin/config.toml [iis] enabled = false`。
>
> **Prompt**:
> ```
> /tp-stop-dotnet-framework-web
> ```
>
> **觀察重點**:
> - Step 0 拒跑訊息
> - 沒呼叫 stop-iis

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-stop-dotnet-framework-web-1 | Cross-worktree stop | tp-run case 1 LISTENING + peer cwd | /tp-stop-dotnet-framework-web | PID 被殺 + port 釋放 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-stop-dotnet-framework-web-2 | No-op when not running | no iisexpress | /tp-stop-dotnet-framework-web | info msg + exit 0 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-stop-dotnet-framework-web-3 | [iis] disabled refuse | iis-disabled | /tp-stop-dotnet-framework-web | Step 0 拒跑 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-publish-dotnet-framework-web

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-publish-dotnet-framework-web-1 | Happy publish with .pubxml | fresh-base + setup(a) + `<project>/Properties/PublishProfiles/Local.pubxml`(WebPublishMethod=FileSystem,PublishUrl=`bin/Publish/`) | /tp-publish-dotnet-framework-web → script:detect csproj / msbuild / pubxml → 跑 pack-content(no frontend → skip)→ msbuild /p:DeployOnBuild=true → 後處理 emit PUBLISH_OUTPUT_PATH | stdout 含 `Published to: <bin/Publish/>` + `PUBLISH_OUTPUT_PATH=<absolute path>` / `bin/Publish/` 含完整 artifact / msbuild exit 0 | (Happy publish) |
| P2-tp-publish-dotnet-framework-web-2 | No .pubxml fail-loudly | fresh-base + setup(a),把 `Properties/PublishProfiles/` 整個刪掉 | /tp-publish-dotnet-framework-web → script:detect csproj OK → detect pubxml 失敗 → fail-loudly | stderr 含「No .pubxml found in ...Properties\PublishProfiles\」+ 建議「先用 VS 建 publish profile」/ exit 非 0 | (No .pubxml) |
| P2-tp-publish-dotnet-framework-web-3 | [iis] disabled refuse | `[iis] enabled = false` | /tp-publish-dotnet-framework-web → Step 0 拒跑 | 沒呼叫 publish-web / chat 中「IIS 已停用」訊息 | AE2 consistency |

### 失敗常見 patterns

- **TRUST_REQUIRED 沒擋**:fixture 加 `[frontend]` 危險 install_command → script emit TRUST_REQUIRED → agent 應 AskUserQuestion 顯示完整指令。若 agent 直接寫 trust 後重跑 → FAIL。
- **多個 .pubxml 沒提示**:fixture 兩個 .pubxml 不指定 → 應 fail-loudly 列候選。若 agent 自選一個 → FAIL。
- **Default platform 寫錯**:SKILL.md「內建 default:Configuration = Release,Platform = Any CPU(刻意不同於 tp-build 的 Debug default)」。若 agent 跑 Debug → FAIL(對 publish 是 bug)。
- **PUBLISH_OUTPUT_PATH stdout token 沒 emit**:Test Scenarios 列出 `PUBLISH_OUTPUT_PATH=<absolute-path>` 是契約。若 stdout 沒這行 → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a)。fixture base 已含 `HelloApp/Properties/PublishProfiles/Local.pubxml`(FileSystem profile,PublishUrl=`bin/Publish/`)。
>
> **Prompt**:
> ```
> 幫我跑 publish 把 release 包出來 — /tp-publish-dotnet-framework-web
> ```
>
> **觀察重點**:
> - agent 觸發 tp-publish-dotnet-framework-web
> - script stdout 含 `Build succeeded` 與 `Published to: bin/Publish/` 或類似
> - stdout 含 `PUBLISH_OUTPUT_PATH=<absolute-path-to-Publish-dir>`(契約 token)
> - `bin/Publish/` 含 `bin/`、`Views/` 等 publish artifact
> - msbuild exit 0
> - 沒 TRUST_REQUIRED(fixture 無 frontend 設定)

> **Setup**(case 2):接 case 1 fixture,orchestrator 刪除 `Properties/PublishProfiles/` 整個目錄。
>
> **Prompt**:
> ```
> /tp-publish-dotnet-framework-web
> ```
>
> **觀察重點**:
> - script fail-loudly
> - stderr 含「No .pubxml found in ...Properties\PublishProfiles\」
> - 訊息建議「先用 VS 建 publish profile」
> - exit 非 0
> - 沒跑 msbuild

> **Setup**(case 3):orchestrator 設 `[iis] enabled = false`。
>
> **Prompt**:
> ```
> /tp-publish-dotnet-framework-web
> ```
>
> **觀察重點**:
> - Step 0 拒跑訊息
> - 沒呼叫 publish-web

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-publish-dotnet-framework-web-1 | Happy publish | fresh-base+setup(a)+.pubxml | /tp-publish-dotnet-framework-web | PUBLISH_OUTPUT_PATH + bin/Publish/ | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-publish-dotnet-framework-web-2 | No .pubxml fail | fresh-base+setup(a), PublishProfiles 刪除 | /tp-publish-dotnet-framework-web | fail-loudly + 建議 VS 建 profile | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-publish-dotnet-framework-web-3 | [iis] disabled refuse | iis-disabled | /tp-publish-dotnet-framework-web | Step 0 拒跑 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-cleanup-orphan-iis

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-cleanup-orphan-iis-1 | Both kinds orphan(process + xml)選擇性清除 | fresh-base + setup(a) + orchestrator 預製 2 個 orphan:`HelloApp-deadbeef`(process + xml,叫 iisexpress 帶該 site 跑)+ `HelloApp-cafe1234`(xml-only,只塞 applicationhost.config) | /tp-cleanup-orphan-iis → script 列舉 → 2 個 ORPHAN 行 → AskUserQuestion 多選 → 使用者選兩個 → script `-RemoveSite` 跑兩次 | stdout 含 `ORPHAN: HelloApp-deadbeef both pid=<n>` + `ORPHAN: HelloApp-cafe1234 xml pid=-` / AskUserQuestion 列兩項 + cancel option / 使用者選兩個 → script 清完 → 再跑 enumerate 為空 | (Both kinds + multi-select) |
| P2-tp-cleanup-orphan-iis-2 | Cancel path | 同 case 1 fixture | /tp-cleanup-orphan-iis → 列舉 → AskUserQuestion → 使用者選 Cancel → 不執行任何刪除 | applicationhost.config 不變 / iisexpress process 不變 / script 沒以 -RemoveAll / -RemoveSite 模式呼叫 | (Cancel path) |
| P2-tp-cleanup-orphan-iis-3 | [iis] disabled refuse | `[iis] enabled = false` | Step 0 拒跑 | 沒呼叫 cleanup-orphan-iis / chat「IIS 已停用」訊息 | AE2 consistency |

### 失敗常見 patterns

- **自動 `-RemoveAll`**:SKILL.md Decision Rule「不自動清除,絕不在沒有明確選擇下呼叫 -RemoveAll」。若 agent 略過 AskUserQuestion 直接 -RemoveAll → FAIL。
- **清除別 project 的 site**:script 應 filter `<csproj-stem>-<8hex>` 格式。若 fixture 預製 site name `MyOtherApp-1234abcd`,agent 應略過。若 agent 列入清單 → FAIL。
- **PARTIAL_FAILURE 沒區分**:Test Scenarios 有 partial failure case(file locked)。若 agent 把 exit 2 當 exit 1 報「全部失敗」→ FAIL。
- **沒呈現 stderr per-site reason**:script PARTIAL_FAILURE 時 stderr 有 per-site reason。若 agent 只 echo stdout → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a)。然後預製兩個 orphan:
> 1. 啟動一個 dummy iisexpress 帶 `/site:HelloApp-deadbeef`(用 `Start-Process iisexpress /site:HelloApp-deadbeef /path:C:\Temp\dummy /port:9999`)
> 2. 手動編輯 `.turbo-plugin/applicationhost.config` 加入 `<site name="HelloApp-deadbeef">...</site>` + `<site name="HelloApp-cafe1234">...</site>` 兩個 site nodes
>
> **Prompt**:
> ```
> 我看到 IIS Express 有一些奇怪的 site,幫我清掉 — /tp-cleanup-orphan-iis
> ```
>
> **觀察重點**:
> - agent 觸發 tp-cleanup-orphan-iis
> - script 列舉,stdout 含:
>   - `ORPHAN: HelloApp-deadbeef both pid=<n>`(整數 pid)
>   - `ORPHAN: HelloApp-cafe1234 xml pid=-`(literal `-`)
> - AskUserQuestion 列兩個 site + Cancel option
> - 使用者選兩個都清
> - script `-RemoveSite HelloApp-deadbeef` 再 `-RemoveSite HelloApp-cafe1234`
> - 兩個 site 都從 applicationhost.config 移除
> - dummy iisexpress PID 被 Stop-Process
> - 再次跑 enumerate 為空(`No orphan...` 訊息)

> **Setup**(case 2):重置 fixture,重新預製 case 1 兩個 orphan(orchestrator 跑相同 setup)。
>
> **Prompt**:
> ```
> /tp-cleanup-orphan-iis
> ```
>
> **觀察重點**:
> - script 列舉 2 個 ORPHAN
> - AskUserQuestion 出現
> - 使用者選 Cancel
> - script 沒以 -RemoveAll / -RemoveSite 模式呼叫
> - applicationhost.config 不變(2 個 site 仍在)
> - dummy iisexpress 仍在跑
> - agent 顯式報告「已取消」

> **Setup**(case 3):orchestrator 設 `[iis] enabled = false`。
>
> **Prompt**:
> ```
> /tp-cleanup-orphan-iis
> ```
>
> **觀察重點**:
> - Step 0 拒跑訊息

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-cleanup-orphan-iis-1 | Both kinds + multi-select | 2 orphan(both + xml) | /tp-cleanup-orphan-iis | 列舉 + 多選 + 清除 + re-enumerate 為空 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-cleanup-orphan-iis-2 | Cancel | 2 orphan | /tp-cleanup-orphan-iis | Cancel 不動 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-cleanup-orphan-iis-3 | [iis] disabled | iis-disabled | /tp-cleanup-orphan-iis | Step 0 拒跑 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-suggest-ignore

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-suggest-ignore-1 | Analysis mode happy(Git Ignore + SVN Ignore) | fresh-base + setup(a) + 用 `New-RemoteBridge` 建 test-1 bridge + 主 worktree 多新檔 `.env`(untracked) + 主 worktree git-tracked `.claude/settings.json` | /tp-suggest-ignore(無參數)→ analysis mode → Step 2-3 classify → Git Ignore 列 `.env` / SVN Ignore 列 `.claude/` → Step 4 prompt(option A apply all / B per-item / C skip) → 使用者 apply all → Step 5 寫 .gitignore + commit + svn-ignore.ps1 -Add `.claude/` 全 remote worktree | `.gitignore` 末尾含 `.env` 與 `.claude/` / `git log --oneline` 含 `chore: update .gitignore` commit / `svn propget svn:ignore .` 在 remote-svn-main + remote-svn-test-1 都含 `.claude/` / 2 個 SVN commit(r21 + r22)| AE13(2-worktree propset) |
| P2-tp-suggest-ignore-2 | Direct mode --add-svn cross-worktree | fresh-base + setup(a) + 用 `New-RemoteBridge` 建 test-1 bridge | /tp-suggest-ignore --add-svn "obj/" → Direct mode → script svn-ignore.ps1 -Add "obj/" → 對 remote-svn-main + remote-svn-test-1 兩個 worktree propset + 各 commit | `svn propget svn:ignore` 在 remote-svn-main + remote-svn-test-1 都含 `obj/` / 2 個 SVN commit(r21 + r22)/ 每 commit msg 各對應一個 worktree | AE13(2-worktree propset) |
| P2-tp-suggest-ignore-3 | Rollback when remote-svn-test-1 propset 失敗 | fresh-base + setup(a) + 用 `New-RemoteBridge` 建 test-1 bridge + 手動 corrupt remote-svn-test-1 的 `.svn/wc.db`(讓 propset 失敗) | /tp-suggest-ignore --add-svn "obj/" → svn-ignore.ps1 對 remote-svn-main propset OK(r21)→ 對 remote-svn-test-1 propset 失敗 → rollback remote-svn-main r21 | `svn propget svn:ignore` 在 remote-svn-main **不**含 `obj/`(rollback 成功)/ 在 remote-svn-test-1 也不含 / SVN log 最後 revision 是 baseline(無 r21 / r22) | AE13(rollback) |
| P2-tp-suggest-ignore-4 | 中文 svn:ignore pattern | fresh-base + setup(a) + 用 `New-RemoteBridge` 建 test-1 bridge | /tp-suggest-ignore --add-svn "中文資料夾/" → script propset → 兩 worktree commit | `svn propget svn:ignore` 兩 worktree 都含 `中文資料夾/`(text-equal,中文 svn property 透過 svn cli round-trip 後在 console codepage decode 後正確)/ SVN commit msg(若含中文)同樣 round-trip 正確 | AE13 + R18 中文 |

### 失敗常見 patterns

- **`&&` chain 過 git 指令**:SKILL.md 開頭 NOTE 明文「treat as two separate steps — run `git add` first, observe success, then run `git commit`」。若 fixture / agent 用 `&&` chain → FAIL(CLAUDE.md prohibition)。
- **`.gitignore` 不存在沒先建**:SKILL.md Decision Rule「If `.gitignore` does not exist, create it before editing」。若 fixture 刪 `.gitignore` 後 agent crash → FAIL。
- **rollback 不完全**:case 3 應 rollback remote-svn-main(undo r21)。若只是「propset 失敗訊息報出來」但 remote-svn-main r21 仍存在 → FAIL。
- **2-worktree propset 變 3-worktree(含 main)**:SKILL.md 明文 svn:ignore 只動 remote-svn worktrees,main 不是 SVN-tracked。若 agent 對 main 跑 propset → FAIL。
- **Inconsistency / Un-track 沒個別 confirm**:SKILL.md Decision Rule「An Inconsistency or Un-track file must be confirmed individually — no "apply all" option」。若 agent 提供「apply all」option for Inconsistency → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a),然後在主 worktree 先 `git checkout -b test-1` 再呼叫 `${CLAUDE_PLUGIN_ROOT}/scripts/New-RemoteBridge.ps1 -Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`(`.sh`:`new-remote-bridge.sh --branch test-1 --svn-url file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge,建完 `git checkout main`(helper 不建工作分支,故須先 `git checkout -b test-1`)。在主 worktree 預製:
> - untracked: 建 `.env` 檔(內容 `SECRET=foo`)
> - git-tracked: `.claude/settings.json`(stage + commit)
>
> **Prompt**:
> ```
> 幫我看看 ignore 設定有沒有要清的 — /tp-suggest-ignore
> ```
>
> **觀察重點**:
> - agent 觸發 tp-suggest-ignore analysis mode
> - Step 2 read-only 資料收集
> - Step 3 classify:Git Ignore 候選含 `.env`;SVN Ignore 候選含 `.claude/`
> - Step 4 出兩個 AskUserQuestion:
>   1. Git Ignore:option A / B / C
>   2. SVN Ignore:同上,description 含 per-directory limitation note
> - 使用者兩個都選 option A(apply all)
> - Step 5:
>   - `.gitignore` 末尾追加 `.env`
>   - `git -C <main> commit -m "chore: update .gitignore"`(commit on main)
>   - 對 remote-svn-main + remote-svn-test-1 各跑 propset + commit `.claude/`
> - 跑完:
>   - `git log --oneline main` 含新 commit
>   - `svn propget svn:ignore .` 在 remote-svn-main + remote-svn-test-1 都列 `.claude/`
>   - SVN log r21 (remote-svn-main) + r22 (remote-svn-test-1) 兩 commits

> **Setup**(case 2):orchestrator 跑 reset + setup,然後在主 worktree `git checkout -b test-1` 後呼叫 `New-RemoteBridge`(`-Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge,建完 `git checkout main`。主 worktree clean,沒新檔。
>
> **Prompt**:
> ```
> /tp-suggest-ignore --add-svn "obj/"
> ```
>
> **觀察重點**:
> - agent 觸發 Direct mode --add-svn
> - 沒跑 analysis(沒 prompts about Git Ignore / SVN Ignore)
> - script svn-ignore.ps1 -Add "obj/" 一次 invocation
> - 對 remote-svn-main + remote-svn-test-1 兩 worktree propset + commit
> - 2 個 SVN commit(r21 + r22),msg 各對應一個 worktree
> - `svn propget svn:ignore` 兩 worktree 都含 `obj/`

> **Setup**(case 3):orchestrator 跑 reset + setup,然後在主 worktree `git checkout -b test-1` 後呼叫 `New-RemoteBridge`(`-Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge,建完 `git checkout main`。然後手動 corrupt remote-svn-test-1 的 SVN working copy:刪除 `<VALIDATION_ROOT>/proj/.turbo-plugin/worktrees/remote-svn-test-1/.svn/wc.db`(`Remove-Item`)讓 svn propset 失敗。
>
> **Prompt**:
> ```
> /tp-suggest-ignore --add-svn "obj/"
> ```
>
> **觀察重點**:
> - script 對 remote-svn-main propset OK,commit r21
> - 對 remote-svn-test-1 propset 失敗(`.svn/wc.db` missing)
> - 觸發 rollback:把 remote-svn-main 剛 commit 的 r21 也回退(svn revert / 重新 propset 不含 obj/ 等 mechanism)
> - 跑完:
>   - `svn propget svn:ignore .` 在 remote-svn-main **不**含 `obj/`
>   - SVN log 最高 revision 仍是 baseline(無 r21 / r22)
> - agent 回報「rollback 成功,SVN 狀態回到操作前」

> **Setup**(case 4):orchestrator 跑 reset + setup,然後在主 worktree `git checkout -b test-1` 後呼叫 `New-RemoteBridge`(`-Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge,建完 `git checkout main`。主 worktree clean。
>
> **Prompt**:
> ```
> /tp-suggest-ignore --add-svn "中文資料夾/"
> ```
>
> **觀察重點**:
> - script propset 中文 pattern
> - `svn propget svn:ignore .` 兩 worktree decode 後顯示「中文資料夾/」**text-equal**(不 byte-equal — Windows propvalue 內部 codepage 限制)
> - 沒 mojibake
> - 2 個 SVN commit(commit msg 可能含中文也可能不含,看 script 實作 — 但若含中文應 round-trip 正確)

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-suggest-ignore-1 | Analysis mode happy | fresh-base+setup+test-1 + .env untracked + .claude tracked | /tp-suggest-ignore | analysis → Git Ignore + SVN Ignore apply all | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-suggest-ignore-2 | Direct --add-svn cross-worktree | fresh-base+setup+test-1 | /tp-suggest-ignore --add-svn "obj/" | 2-worktree propset + 2 commits | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-suggest-ignore-3 | Rollback when test-1 fail | fresh-base+setup+test-1 + corrupt .svn/wc.db | /tp-suggest-ignore --add-svn "obj/" | remote-svn-main r21 rollback | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-suggest-ignore-4 | 中文 svn:ignore | fresh-base+setup+test-1 | /tp-suggest-ignore --add-svn "中文資料夾/" | text-equal round-trip | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-svn-log

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-svn-log-1 | Default limit + 中文 commit msg | fresh-base + setup(a) + SVN seed r1-r20(其中 r5/r10/r15 有中文 commit msg per 字典 3.1 / 3.2 / 3.3) | /tp-svn-log → script `--xml` → echo log 5 entries(r20-r16)+ trailer `# LAST_SHOWN_REV=16` + emit 三選一選項清單 | stdout 含 r20-r16 5 行 / trailer 行 `# LAST_SHOWN_REV=16` / 中文 commit msg(若範圍內)顯示為正確 UTF-8 text(不變 `?`)/ 同一則訊息結尾附加「下 5 筆 / 指定修訂 / 其他」三選一 | AE3 + AE8 |
| P2-tp-svn-log-2 | Pagination forward(分頁迴圈) | case 1 跑完之後,使用者下一輪訊息回「1」 | SKILL 從 trailer 讀 16 → 呼叫 `--revision 15:1 --limit 5` → echo r15-r11 + trailer 11 + emit 選項 | r15-r11 5 行 / trailer `# LAST_SHOWN_REV=11` / 中文 commit msg(r15)顯示正確 / 重新 emit 三選一 | AE8 |
| P2-tp-svn-log-3 | Jump to revision spec | case 2 跑完後,使用者下一輪回「r5」 | SKILL 匹配 `^r?\d+$` → 呼叫 `--revision r5` → echo r5 1 行 + trailer 5 + emit 選項 | r5 1 行 / r5 中文 commit msg(字典 3.1)顯示正確 / trailer / 重新 emit | AE9 |
| P2-tp-svn-log-4 | Escape via「其他」+ revision boundary | (a) case 3 完使用者回「其他」 → SKILL 退出分頁迴圈,不再 emit 選項;(b) fresh re-run /tp-svn-log,連續回「1」直到 LAST_SHOWN_REV=1,再回「1」 → SKILL 偵測 boundary 不呼叫 script | (a) 使用者回「其他」後 agent 不再 emit 選項,讓對話一般進行;(b) 顯示「已到歷史最舊(r1 是最早的 commit)」訊息 + 重新 emit 選項(讓使用者跳 revision 或退出) | AE10 + boundary |

### 失敗常見 patterns

- **沒 echo stdout 到對話訊息**:SKILL.md 明文「必須把 script stdout 完整 echo 到對話訊息中」。若 agent 只 say「跑完了,結果見 tool output」→ FAIL(使用者看不到 log 內容)。
- **用 AskUserQuestion 做分頁**:SKILL.md 明文「不用 AskUserQuestion — modal UI 對輕量分頁互動太重」。若 agent 用 modal → FAIL。
- **中文 mangle**:`svn log` 不帶 `--xml`,console codepage 把中文變 `?` → FAIL。
- **「2」alone 追問**:SKILL.md Decision Rule「視為模糊,降階為退出;不追問」。若 agent 對 「2」 alone 追問「請指定 revision spec」→ FAIL。
- **boundary 還呼叫 script**:case 4 (b) `LAST_SHOWN_REV=1` 再「1」應 short-circuit,不再呼叫 script。若 agent 呼叫 `--revision 0:1` → FAIL。
- **`--revision` 字串拼接**:SKILL.md Decision Rule「禁止把多個 args 拼成單一字串(security invariant per F10)」。若 agent 跑 `script.ps1 "--revision 3:10"` 把整個當一個 arg → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1`(會 svnadmin load seed dump → r1-r20 含 r5/r10/r15 中文)+ 跑 setup case (a)。確認 `svn log -r 5 file:///<VALIDATION_ROOT>/svn-repo/trunk` 顯示「修正中文 commit 訊息亂碼」。
>
> **Prompt**:
> ```
> 幫我看一下 SVN 最近的 log — /tp-svn-log
> ```
>
> **觀察重點**:
> - agent 觸發 tp-svn-log
> - chat 中含 markdown code block 包夾的 log,5 行 r20-r16 格式 `r<rev> | <author> | <date> | <msg>`
> - 含 `# LAST_SHOWN_REV=16` trailer 行
> - 同一則訊息結尾附加固定 template:
>   ```
>   ──
>   接下來想看什麼?
>   1. 下 5 筆(更舊的 5 個 commit)
>   2. 指定修訂(直接打 r5、3:10、{2026-01-01}:{2026-05-26} 等)
>   3. 其他(換話題)
>   ```
> - agent 退出本輪 turn(沒繼續呼叫 script)

> **Setup**(case 2):接 case 1 完成(分頁迴圈 active,等待使用者下一輪訊息)。
>
> **Prompt**(使用者下一輪):
> ```
> 1
> ```
>
> **觀察重點**:
> - SKILL 從前一輪 trailer 讀 16 → 呼叫 `--revision 15:1 --limit 5`
> - echo r15-r11(其中 r15 是中文「重構伺服器組態載入流程」)
> - 中文顯示正確
> - trailer `# LAST_SHOWN_REV=11`
> - 重新 emit 三選一選項清單

> **Setup**(case 3):接 case 2(分頁迴圈仍 active)。
>
> **Prompt**(使用者下一輪):
> ```
> r5
> ```
>
> **觀察重點**:
> - SKILL 匹配 `^r?\d+$` → 呼叫 `--revision r5`
> - echo r5 一行,msg 顯示「修正中文 commit 訊息亂碼」**text-equal**
> - trailer `# LAST_SHOWN_REV=5`
> - 重新 emit 選項

> **Setup**(case 4 — split into two sub-runs):
>
> **(a) Escape**:接 case 3。
>
> **Prompt**(a):
> ```
> 其他
> ```
>
> **觀察重點**(a):
> - SKILL 退出分頁迴圈
> - **不**再 emit 選項清單
> - 對話自然結束本話題,使用者下一輪可以說其它事(agent 一般處理,不再續分頁)
>
> **(b) Boundary**:orchestrator 重新跑 `/tp-svn-log -Limit 5 -Revision 5:1`(故意 short pagination to reach boundary fast)→ trailer 是 `# LAST_SHOWN_REV=1`。
>
> **Prompt**(b 使用者下一輪):
> ```
> 1
> ```
>
> **觀察重點**(b):
> - SKILL 偵測 `LAST_SHOWN_REV=1`(n <= 1)
> - **不**呼叫 script
> - 直接 emit「已到歷史最舊(r1 是最早的 commit)」訊息
> - 重新 emit 三選一選項(讓使用者跳 revision 或退出)

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-svn-log-1 | Default limit + 中文 | fresh-base+setup+r1-r20 seed | /tp-svn-log | 5 行 r20-r16 + trailer 16 + 選項 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-svn-log-2 | Pagination forward | 接 1 | 「1」 | r15-r11 + trailer 11 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-svn-log-3 | Jump to r5 | 接 2 | 「r5」 | r5 + 中文正確 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-svn-log-4 | Escape + boundary | (a) 接 3 / (b) trailer=1 | (a)「其他」 / (b)「1」 | (a) 退出無選項 / (b) boundary 訊息 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-csharp-comment

> **Surface-small skill**:2 case(below R12 通用 floor)。理由:comment skill 表面只有「scan changed C# symbols → write XML doc + 解釋註解 → verify 覆蓋率」。一個 happy(覆蓋 type + member)+ 一個中文 mixed(驗證繁中註解 + XML doc 中英 mix 風格 detection)足以覆蓋 SKILL.md 列出的所有 Coverage Rule 與 Decision Rule。

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-csharp-comment-1 | Happy:新增 class + members 全 XML doc 覆蓋(繁中) | fresh-base + setup(a) + 在 `Controllers/HelloController.cs` 新增 1 public class `OrderService` 含 1 field / 1 property / 1 constructor / 2 method(其中一個有 generic + return value) | /tp-csharp-comment → Read 該檔 → 認出新類別 → 寫 XML `///` doc 對 type + 5 members(field / prop / ctor / 2 method)+ method 都有 `<param>` + return method 有 `<returns>` + generic method 有 `<typeparam>` | 該 class 與 5 個 members 都有 `///` summary / `<param>` 對應每個 parameter / `<returns>` 在有 return value 的 method / `<typeparam>` 在 generic method / 註解用繁體中文(domain meaning,非 chat-context wording) | (Coverage Rule + 繁中) |
| P2-tp-csharp-comment-2 | English-only context detection | fresh-base + setup(a) + 在 `Models/User.cs` 新檔(class + 屬性)其中既有檔案是 English-only doc(file 開頭有 1 個 English-only `/// <summary>` 範例 class)→ 新加 class 進來 | /tp-csharp-comment → 偵測 file 既有 doc 是 English-only → 新加的 class XML doc 用 English(SKILL.md Core Rule「unless the surrounding file already uses English consistently and mixing languages would cause obvious style conflicts」) | 新 class doc 是 English / 沒被強制改成繁中 / 既有英文 doc 沒被改成中文 | (Style consistency exception) |

### 失敗常見 patterns

- **fragment doc**:SKILL.md Decision Rule「If a changed class has undocumented members in the changed scope, do not leave them partially documented」。若 only type doc,members 沒 doc → FAIL。
- **chat-context leak**:SKILL.md Core Rule「Do not mention the current request, goal, plan, task, test, temporary workaround, or chat context in the comments」。若 XML doc 出現「per the current task」「for the v1.0 PR」→ FAIL。
- **TypeScript-style 在 C#**:agent 用 `@param` 取代 `<param name="...">` → FAIL(這個 skill 是 C# specific)。
- **強制改既有風格**:case 2 既有 English-only,被 agent 改成繁中 → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 reset + setup(a)。然後 orchestrator 編輯 `Controllers/HelloController.cs` 新增 class(完全沒註解):
> ```csharp
> public class OrderService
> {
>     private readonly ILogger _logger;
>     public int MaxRetries { get; set; }
>     public OrderService(ILogger logger) { _logger = logger; MaxRetries = 3; }
>     public string PlaceOrder(string itemId, int quantity) { return $"{itemId}:{quantity}"; }
>     public T Map<T>(string raw) where T : class, new() { return new T(); }
> }
> ```
>
> **Prompt**:
> ```
> 我剛新增了一個 OrderService class 在 HelloController.cs,幫我加上註解 — /tp-csharp-comment
> ```
>
> **觀察重點**:
> - agent 觸發 tp-csharp-comment
> - 該 class 加上 `/// <summary>...</summary>`(繁中,描述責任)
> - `_logger` field 有 `///`
> - `MaxRetries` property 有 `///`
> - constructor 有 `///` + `<param name="logger">`
> - `PlaceOrder` method 有 `///` + `<param name="itemId">` + `<param name="quantity">` + `<returns>`
> - `Map<T>` method 有 `///` + `<typeparam name="T">` + `<param name="raw">` + `<returns>`
> - 註解用繁體中文
> - 沒提到「current task」/「v1.0」/ chat context

> **Setup**(case 2):orchestrator 重置 fixture + setup(a)。然後 orchestrator 建 `Models/User.cs`:
> ```csharp
> namespace HelloApp.Models;
>
> /// <summary>
> /// Represents a baseline data row used by older controllers as a reference shape.
> /// </summary>
> public class LegacyBaseline { }
>
> public class User
> {
>     public int Id { get; set; }
>     public string Name { get; set; }
> }
> ```
>
> **Prompt**:
> ```
> User class 缺註解,幫我加 — /tp-csharp-comment
> ```
>
> **觀察重點**:
> - agent 偵測既有 `LegacyBaseline` doc 是 English-only
> - 對 User class doc 用 English(maintain consistency)
> - `Id` / `Name` property doc 用 English
> - 既有 `LegacyBaseline` doc 沒被改

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-csharp-comment-1 | Class + member full coverage 繁中 | fresh-base+setup+OrderService stub | /tp-csharp-comment | type + 5 members 全 doc + `<param>` + `<returns>` + `<typeparam>` | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-csharp-comment-2 | English-only context detection | fresh-base+setup+English LegacyBaseline | /tp-csharp-comment | 新 class 用 English maintain consistency | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-js-comment

> **Surface-small skill**:2 case(below R12 通用 floor)。理由同 tp-csharp-comment — surface 表面狹窄。涵蓋 plain `.ts` 與 `<script>` block 兩個 entry path 即足以驗證 SKILL 的 file-type detection 與 JSDoc 覆蓋規則。

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-js-comment-1 | Happy:plain `.ts` exported function + class(繁中) | fresh-base + setup(a) + 新增 `Scripts/order-service.ts` 含 1 exported function(with type generic + return value)+ 1 exported class(1 field / 1 prop / 1 ctor / 1 method) | /tp-js-comment → Read 該檔 → 對 exported function 寫 JSDoc + `@template` + `@param` + `@returns`;對 class 寫 JSDoc + members 全覆蓋 | 該 function 有 `/** */` JSDoc + `@template T` + `@param` for each + `@returns` / class 與 4 members 都有 JSDoc / 繁中 prose / 沒重複 TypeScript type annotation(SKILL.md Core Rule) | (Coverage Rule + 繁中) |
| P2-tp-js-comment-2 | `<script>` block in `.cshtml` | fresh-base + setup(a) + 編輯 `Views/Home/Index.cshtml` 在 `<script>` 區塊內加 exported function `formatPrice(price)` | /tp-js-comment → 偵測 .cshtml 內 `<script>` → 對該 function 加 JSDoc | `<script>` 區塊內 `formatPrice` 上方有 JSDoc 含 `@param` / 繁中 / `.cshtml` 其它部分(Razor markup)未動 | `<script>` 區塊覆蓋 |

### 失敗常見 patterns

- **TypeScript type 在 JSDoc 重複**:SKILL.md Core Rule「TypeScript types already carry type information — do not restate them」。若 doc 含 `@param {string} name` 對應已有 `name: string` → FAIL(redundant)。
- **`<script>` 區塊內加 CSS / HTML comment 語法**:agent 對 `.cshtml` 內 JS 用 `<!-- -->` 而非 `/** */` → FAIL。
- **Razor 部分被動**:case 2 若 agent 改了 `@RenderBody()` 或其它 Razor markup → FAIL。
- **chat-context leak**:同 tp-csharp-comment。
- **`@returns` 漏在有 return value 的 function**:Coverage rule violation → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 reset + setup(a)。新增 `Scripts/order-service.ts`(無註解):
> ```ts
> export function map<T>(raw: string): T {
>     return JSON.parse(raw) as T;
> }
>
> export class OrderClient {
>     private endpoint: string;
>     public defaultRetry: number;
>     constructor(endpoint: string) {
>         this.endpoint = endpoint;
>         this.defaultRetry = 3;
>     }
>     public placeOrder(itemId: string, quantity: number): string {
>         return `${itemId}:${quantity}`;
>     }
> }
> ```
>
> **Prompt**:
> ```
> 我剛建了一個 order-service.ts,幫我加註解 — /tp-js-comment
> ```
>
> **觀察重點**:
> - agent 觸發 tp-js-comment
> - `map<T>` function 上方有 JSDoc:`@template T` + `@param raw` + `@returns`
> - `OrderClient` class 上方有 JSDoc `/** ... */`
> - `endpoint` field + `defaultRetry` prop + constructor + `placeOrder` method 都有 JSDoc
> - constructor JSDoc 含 `@param endpoint`
> - `placeOrder` JSDoc 含 `@param itemId` + `@param quantity` + `@returns`
> - 繁中 prose,沒 chat-context wording
> - 沒重複 TypeScript type annotation(domain meaning only)

> **Setup**(case 2):orchestrator 編輯 `Views/Home/Index.cshtml` 在既有 `<script>` 區塊內加:
> ```html
> @{
>     ViewBag.Title = "Home";
> }
> <h2>歡迎</h2>
> <script>
>     function formatPrice(price) {
>         return price.toFixed(2) + " 元";
>     }
> </script>
> ```
>
> **Prompt**:
> ```
> Index.cshtml 的 script 區塊有 formatPrice 沒註解,幫我加 — /tp-js-comment
> ```
>
> **觀察重點**:
> - agent 觸發 tp-js-comment
> - 偵測 .cshtml 內 `<script>`
> - `formatPrice` 上方有 JSDoc(在 `<script>` 區塊內)
> - JSDoc 含 `@param price` + `@returns`
> - Razor markup(`@{ }` / `<h2>歡迎</h2>`)沒被動

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-js-comment-1 | .ts function + class full coverage 繁中 | fresh-base+setup+order-service.ts stub | /tp-js-comment | function + class + members 全 JSDoc | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-js-comment-2 | `<script>` in .cshtml | fresh-base+setup+Index.cshtml stub | /tp-js-comment | `<script>` 區塊 JSDoc + Razor 未動 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-merge-main-into-all

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-merge-main-into-all-1 | Happy:多分支落後 main 一起 merge | fresh-base + setup(a)(已有 `remote-svn/main`)+ 用 `New-RemoteBridge` 建 test-1 bridge(已有 `remote-svn/test-1`)+ 在 main 多 2 commit 領先 + 另建兩個本地分支 `feature-a` / `feature-b`(從 main 較舊的 commit 起跳,落後 main) | /tp-merge-main-into-all(無參數)→ script 列目標分支(排除 `main` 與 `remote-svn/*`)→ 逐支 `checkout` + `git merge main` + 還原原分支 → summary | stdout 末尾含 `Merged cleanly: feature-a, feature-b`(順序不拘)/ `feature-a` / `feature-b` 都含 main tip(`git log feature-a..main` 為空)/ `main` 與 `remote-svn/main` / `remote-svn/test-1` **不**在目標、未被動 / 跑完 HEAD 回開跑時原分支 | (Happy multi-branch merge) |
| P2-tp-merge-main-into-all-2 | Exclude:`remote-svn/*` 與 main 被跳過 | 同 case 1 fixture(可接 case 1 後直接續) | /tp-merge-main-into-all → script 目標清單不含 `main` / `remote-svn/main` / `remote-svn/test-1` | summary 的 `Merged cleanly:` 不列任何 `remote-svn/*` 或 `main` / `git log -1 remote-svn/main` 與 `remote-svn/test-1` 的 tip 跑前跑後 SHA 不變 | (Exclude filter) |
| P2-tp-merge-main-into-all-3 | Conflict:衝突分支中止、其餘照常 | fresh-base + setup(a) + 在 main 改 `shared.txt` 某行 + commit;另建 `feature-conflict`(改同一行造成衝突)與 `feature-clean`(改不相干檔,可乾淨 merge) | /tp-merge-main-into-all → `feature-conflict` merge 衝突 → 對該分支 `git merge --abort` → 標 CONFLICT → 繼續 merge `feature-clean` → summary | stdout 末尾含 `CONFLICT (aborted): feature-conflict` + `Merged cleanly: feature-clean` / `feature-conflict` 仍是衝突前的 tip(未含 main、無殘留衝突狀態 `git status` 乾淨)/ `feature-clean` 含 main tip / script exit 1 / 跑完 HEAD 回原分支 | (Conflict per-branch abort) |

### 失敗常見 patterns

- **動到 `remote-svn/*`**:SKILL.md Decision Rule「`remote-svn/*` 是 SVN 橋接分支,絕不動」。若 summary 把任何 `remote-svn/*` 列入 merge 目標 → FAIL。
- **動到 main 自己**:exclude filter 須同時排除 `main`。若 agent 對 `main` 跑 `git merge main` → FAIL。
- **衝突沒 abort 留下髒狀態**:case 3 衝突分支應 `git merge --abort` 還原乾淨。若衝突狀態殘留、或整個 run 中斷不續跑其餘分支 → FAIL。
- **沒還原原分支**:跑完 HEAD 沒回到開跑時所在分支 → FAIL。
- **dirty main 仍跑**:main worktree 有未 commit 變更時 script 應拒跑;若仍 merge 進髒樹 → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a),然後在主 worktree 先 `git checkout -b test-1` 再呼叫 `${CLAUDE_PLUGIN_ROOT}/scripts/New-RemoteBridge.ps1 -Branch test-1 -SvnUrl file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`(`.sh`:`new-remote-bridge.sh --branch test-1 --svn-url file:///<VALIDATION_ROOT>/svn-repo/branches/test-1`)建 test-1 bridge,建完 `git checkout main`(helper 不建工作分支,故須先 `git checkout -b test-1`)。然後在 main worktree:在 main 多 2 commit(模擬 main 前進);再從較早的 commit 建兩個落後分支:
> ```
> # git branch feature-a <main 的較早 commit>
> # git branch feature-b <main 的較早 commit>
> ```
> 確認 main worktree clean,HEAD 回到 main。
>
> **Prompt**:
> ```
> 幫我把 main 同步進所有分支 — /tp-merge-main-into-all
> ```
>
> **觀察重點**:
> - agent 觸發 tp-merge-main-into-all
> - script 列目標分支 = `feature-a` / `feature-b`(不含 `main`、不含 `remote-svn/main` / `remote-svn/test-1`)
> - stdout 末尾 `Merged cleanly: feature-a, feature-b`(順序不拘)
> - `git log feature-a..main` 與 `git log feature-b..main` 皆為空(都含 main tip)
> - `remote-svn/main` / `remote-svn/test-1` tip SHA 跑前跑後不變
> - 跑完 HEAD 回到開跑時原分支(`main`)

> **Setup**(case 2):接 case 1 跑完(或同 case 1 fixture)。記下 `git rev-parse remote-svn/main` 與 `git rev-parse remote-svn/test-1`。
>
> **Prompt**:
> ```
> /tp-merge-main-into-all
> ```
>
> **觀察重點**:
> - summary 的 `Merged cleanly:` / `CONFLICT (aborted):` 兩行都**不**出現任何 `remote-svn/*` 或 `main`
> - `git rev-parse remote-svn/main` / `remote-svn/test-1` 與跑前相同
> - main 自己也沒被 merge 進去(`main` 不在目標)

> **Setup**(case 3):orchestrator 跑 `Reset-Fixture.ps1` + setup case (a)。在 main 改 `shared.txt` 第 1 行並 commit。然後:
> ```
> # 從 main 改動前的 commit 建 feature-conflict,改 shared.txt 同一行（會衝突）並 commit
> # 從 main 改動前的 commit 建 feature-clean,改不相干檔 other.txt 並 commit（可乾淨 merge）
> ```
> 確認 main worktree clean,HEAD 回 main。
>
> **Prompt**:
> ```
> /tp-merge-main-into-all
> ```
>
> **觀察重點**:
> - `feature-conflict` merge 衝突 → script 對它 `git merge --abort`
> - 繼續 merge `feature-clean`(乾淨)
> - stdout 末尾:`CONFLICT (aborted): feature-conflict` + `Merged cleanly: feature-clean`
> - `feature-conflict` 仍是衝突前 tip、`git status` 乾淨(無殘留衝突)
> - `feature-clean` 含 main tip
> - script exit 1(至少一支 CONFLICT)
> - 跑完 HEAD 回原分支

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-merge-main-into-all-1 | Happy multi-branch merge | fresh-base+setup+test-1 + feature-a/b 落後 | /tp-merge-main-into-all | feature-a/b 含 main tip / remote-svn/* + main 排除 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-merge-main-into-all-2 | Exclude remote-svn/* + main | 同 case 1 | /tp-merge-main-into-all | remote-svn/* + main 不被動 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-merge-main-into-all-3 | Conflict per-branch abort | feature-conflict + feature-clean | /tp-merge-main-into-all | conflict 分支 abort + clean 分支 merge / exit 1 | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## tp-db-management

### Cases

| Case ID | 描述 | Fixture pre-state | Expected agent invocation chain | Observation anchors | AE coverage |
|---|---|---|---|---|---|
| P2-tp-db-management-1 | Happy:唯讀檢視 + 標準化 SQL 落 `.turbo-plugin/sql/<env>-db/<branch>/` | fresh-base + setup(a)(`.turbo-plugin/dbhub.local.toml` 已設、`tp-dbhub` MCP 可用、docker 在跑、連 local DB)+ 當前 branch = `main` | /tp-db-management → 用 `tp-dbhub` 唯讀 MCP tool 查 schema/資料(只讀)→ 需寫入側變更時產 `.sql` → 算分組鍵(`git rev-parse --abbrev-ref HEAD` = `main`)→ 檔案落 `.turbo-plugin/sql/local-db/main/<order>-<db>-<purpose>.sql` | agent 只用 `tp-dbhub` **唯讀** MCP tool(沒有透過 MCP 跑 INSERT/UPDATE/CREATE 等)/ 產出的 `.sql` 落在 `.turbo-plugin/sql/local-db/main/` / 檔名遵循 `<order>-<database>-<purpose>.sql` / 該檔出現在 `git status`(非 gitignored)/ 最終回報區分「唯讀檢視到的事實」與「準備供手動執行的 SQL」 | R31(db-management) read-only + 落點 |
| P2-tp-db-management-2 | Branch 名含 `/` → slash→dash 轉換 | 同 case 1 環境,但當前 branch = `feature/x`(orchestrator 先 `git checkout -b feature/x`) | /tp-db-management → 算分組鍵 `git rev-parse --abbrev-ref HEAD` = `feature/x` → 把 `/` 換 `-` → `feature-x` → 檔案落 `.turbo-plugin/sql/local-db/feature-x/` | 分組子資料夾是 `feature-x`(單層,**不是** 巢狀 `feature/x/`)/ `.sql` 落 `.turbo-plugin/sql/local-db/feature-x/` / 該檔在 `git status` 出現 | KTD10 slash→dash |
| P2-tp-db-management-3 | dbhub MCP 不可用 → fail loudly | fresh-base + setup(a) 但 `tp-dbhub` MCP 不可用(docker 未起或 `dbhub.local.toml` 未設) | /tp-db-management → 偵測無 `tp-dbhub` MCP tool → fail loudly 提示先跑 `/tp-setup` 設 `dbhub.local.toml` + 確認 docker 在跑 | agent 明確告知「dbhub MCP server 不可用」/ **不**靜默改用猜測或假裝查到資料庫 / 沒產出捏造的 SQL | (fail-loudly Decision Rule) |
| P2-tp-db-management-4 | Detached HEAD → 拒用 HEAD 當分組鍵 | 同 case 1 環境,但 orchestrator 先 `git checkout <某 commit SHA>`(detached HEAD,`git rev-parse --abbrev-ref HEAD` 回 `HEAD`) | /tp-db-management → 偵測 detached HEAD → fail loudly,請使用者先 checkout 一個具名 branch 再跑 | agent **不**用 `HEAD` 字面當分組鍵 / 沒在 `.turbo-plugin/sql/.../HEAD/` 產檔 / 明確要求 checkout 具名 branch | (detached HEAD guard) |

### 失敗常見 patterns

- **透過 MCP 執行寫操作**:SKILL.md Fixed Constraints「絕不透過 MCP tool 執行 INSERT / UPDATE / DELETE / CREATE / ALTER / DROP」。若 agent 用 `tp-dbhub` MCP 直接改資料庫而非產 `.sql` → FAIL。
- **SQL 落錯位置**:檔案沒落在 `.turbo-plugin/sql/<env>-db/<branch>/`(如落在舊 dev-flow 的 `sql files/` 或 spec/slug 結構)→ FAIL(de-couple 失敗)。
- **branch 名沒做 slash→dash**:case 2 子資料夾變成巢狀 `feature/x/` 而非 `feature-x/` → FAIL。
- **detached HEAD 用 `HEAD` 當鍵**:case 4 在 `.turbo-plugin/sql/.../HEAD/` 產檔而非 fail loudly → FAIL。
- **把 `.turbo-plugin/sql/` 當 gitignored**:產出的 SQL 沒出現在 `git status`(被當成 worktrees/ 一樣忽略)→ FAIL(SKILL.md 明文 `.turbo-plugin/sql/` 進版控)。
- **MCP 不可用時靜默猜測**:case 3 agent 沒 fail loudly,改用想像的 schema 編 SQL → FAIL。

### Prompt 範本

> **Setup**(case 1):orchestrator 跑 `Reset-Fixture.ps1` + 跑 setup case (a),並確認 `.turbo-plugin/dbhub.local.toml` 已設好、docker 在跑、`tp-dbhub` MCP server 在當前 session 暴露唯讀 tool、連的是一個 local 測試資料庫(含至少一張可查的 table)。當前 branch = `main`。
>
> **Prompt**:
> ```
> 幫我看一下資料庫某張表的結構,然後幫我準備一支補資料的 SQL — /tp-db-management
> ```
>
> **觀察重點**:
> - agent 觸發 tp-db-management
> - 只用 `tp-dbhub` **唯讀** MCP tool 查 schema / 資料(沒透過 MCP 跑任何寫 SQL)
> - 寫入側需求改為產 `.sql` 檔
> - 算分組鍵跑 `git rev-parse --abbrev-ref HEAD` = `main`
> - 產出檔落 `.turbo-plugin/sql/local-db/main/<order>-<database>-<purpose>.sql`
> - 檔名符合 `<order>-<database>-<purpose>.sql`(如 `01-AppDb-補資料.sql`)
> - 該檔出現在 `git status`(`.turbo-plugin/sql/` 非 gitignored)
> - 最終回報區分「唯讀檢視到的事實」與「準備供手動執行的 SQL(含落點路徑)」

> **Setup**(case 2):接 case 1 環境。orchestrator 先 `git checkout -b feature/x`(製造含 `/` 的 branch 名),main worktree clean。
>
> **Prompt**:
> ```
> 在這個 feature branch 上幫我準備一支改 schema 的 SQL — /tp-db-management
> ```
>
> **觀察重點**:
> - agent 算分組鍵 `git rev-parse --abbrev-ref HEAD` = `feature/x`
> - 把 `/` 換 `-` 得 `feature-x`
> - `.sql` 落 `.turbo-plugin/sql/local-db/feature-x/`(**單層**,不是巢狀 `feature/x/`)
> - 該檔出現在 `git status`

> **Setup**(case 3):orchestrator 跑 `Reset-Fixture.ps1` + setup case (a),但**不**讓 `tp-dbhub` 可用(docker 不起、或 `dbhub.local.toml` 未設),確認當前 session 沒有 `tp-dbhub` MCP tool。
>
> **Prompt**:
> ```
> 幫我查一下資料庫 schema — /tp-db-management
> ```
>
> **觀察重點**:
> - agent 偵測 `tp-dbhub` MCP tool 不可用
> - fail loudly:明確告知「dbhub MCP server 不可用,請先跑 `/tp-setup` 設定 `.turbo-plugin/dbhub.local.toml` 並確認 docker 在跑」
> - **不**靜默改用猜測或假裝查到資料庫
> - 沒產出捏造 schema 的 SQL

> **Setup**(case 4):接 case 1 環境。orchestrator 先 `git checkout <某具體 commit SHA>` 進入 detached HEAD(`git rev-parse --abbrev-ref HEAD` 回 `HEAD`)。
>
> **Prompt**:
> ```
> 幫我準備一支 SQL — /tp-db-management
> ```
>
> **觀察重點**:
> - agent 偵測 detached HEAD(分組鍵會是 `HEAD` 字面)
> - fail loudly,請使用者先 checkout 一個具名 branch 再跑
> - **不**在 `.turbo-plugin/sql/.../HEAD/` 產檔

### Row table

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|
| P2-tp-db-management-1 | Happy 唯讀 + SQL 落點 | fresh-base+setup + dbhub 可用 + branch=main | /tp-db-management | 唯讀檢視 + `.sql` 落 local-db/main/ + 進版控 | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-db-management-2 | branch 含 `/` slash→dash | dbhub 可用 + branch=feature/x | /tp-db-management | 子資料夾 `feature-x`（單層） | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-db-management-3 | dbhub MCP 不可用 fail loudly | setup but dbhub unavailable | /tp-db-management | fail loudly 提示先 setup dbhub | _(TBD)_ | _(TBD)_ | _(TBD)_ |
| P2-tp-db-management-4 | detached HEAD guard | dbhub 可用 + detached HEAD | /tp-db-management | 拒用 HEAD 當鍵 / fail loudly | _(TBD)_ | _(TBD)_ | _(TBD)_ |

---

## Summary

Skill tests 全部跑完後填(per-skill PASS / FAIL / SKIP 統計)。

| Skill | Cases | PASS | FAIL | SKIP / FAIL-known | 備註 |
|---|---|---|---|---|---|
| tp-setup | 5 | _ | _ | _ | |
| tp-pull-from-svn | 4 | _ | _ | _ | |
| tp-push-to-svn | 6 | _ | _ | _ | case 5/6 = Step 7 release tag |
| tp-reset-branch-to-main | 2 | _ | _ | _ | surface-small |
| tp-build-dotnet-framework-web | 3 | _ | _ | _ | |
| tp-run-dotnet-framework-web | 3 | _ | _ | _ | |
| tp-stop-dotnet-framework-web | 3 | _ | _ | _ | |
| tp-publish-dotnet-framework-web | 3 | _ | _ | _ | |
| tp-cleanup-orphan-iis | 3 | _ | _ | _ | |
| tp-suggest-ignore | 4 | _ | _ | _ | |
| tp-svn-log | 4 | _ | _ | _ | |
| tp-csharp-comment | 2 | _ | _ | _ | surface-small |
| tp-js-comment | 2 | _ | _ | _ | surface-small |
| tp-merge-main-into-all | 3 | _ | _ | _ | parity 補(v1.0.0) |
| tp-db-management | 4 | _ | _ | _ | parity 補(v1.0.0) |
| **Total** | **51** | _ | _ | _ | |

---

## Known Issues

(R32 escalation 用 — 同 case fix 3 次仍 FAIL 列在此。U5 階段為空。)
