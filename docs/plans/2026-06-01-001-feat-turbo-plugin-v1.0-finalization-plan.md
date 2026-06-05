---
type: feat
status: active
date: 2026-06-01
origin: docs/brainstorms/2026-06-01-turbo-plugin-v1.0-finalization-requirements.md
---

# feat: turbo-plugin v1.0.0 收尾

## Summary

把 turbo-plugin 從「功能堪用」收斂到「可發版」:測試完全 repo 相對、零污染、可在 GitHub CI(慣例自動探索)與本地兩邊跑;worktree 收進 `.turbo-plugin/worktrees/` 並改用 `remote-svn` 命名;補回漏搬的 push-to-svn release tag 與兩項 parity 能力(`merge-main-into-all`、`db-management`);CLAUDE.md 改成 plugin-agnostic 的 marketplace 通用規範;最後在 parity 簽核 + 無外部使用者確認的複合 gate 後退役四個舊 plugin。全部進同一個 v1.0.0 PR,PR 前先跑完人工 skill 驗證 gate。

## Problem Frame

turbo-plugin(`plugins/turbo-plugin/`)已在 `feat/turbo-plugin-v1.0` 分支累積到接近可發版,但收尾階段暴露幾個彼此牽連、不修完就不能發版的問題(完整背景見 origin):

- 測試把工作根寫死成 `C:\Turbo\test-turbo-plugin`(orchestrator、ScriptsCommon、reset fixture 共 4 處),既污染環境也讓 CI / 換機不可行;先前一次 containment 重構只是換成另一條寫死路徑。
- skill 層驗證從未被當成常駐、可重複的測試,只有一份含寫死路徑、結構過時的草稿。
- consolidation 靜默漏搬能力:已確認 push-to-svn 的 release tag 整個不見,且 `tp-reset-remote-test` SKILL 還在宣稱「丟掉的 commit 可用 release tag 找回」這個空頭支票。
- CLAUDE.md 塞滿 plugin 專屬內容並硬列 plugin 清單,每次增刪都要改;CI 同理不該每加一個 plugin 就手寫一支 workflow。
- worktree 用 sibling 目錄 + `remote/*` 命名不夠直覺。

## Key Technical Decisions

- **KTD1 — worktree 容器集中在 lib helper。** 新增 `Get-WorktreesDir` / `get_worktrees_dir`,一次定義 `<mainWorktree>/.turbo-plugin/worktrees`;7 對 SVN script 目前各自硬編 `"$projName.worktrees"`(sibling),全改成呼叫 helper,消除漂移。(see origin: R21, R26)
- **KTD2 — `remote-svn` 改名集中在 resolve 層。** 目錄名(`remote-svn-main` / `remote-svn-test-<n>`)與 branch ref(`remote-svn/main` / `remote-svn/test-<n>`)**兩維度都改**,集中在 `Resolve-RemoteWorktree` / `resolve_remote_worktree`;所有 `git log/diff "remote/..."`、SHA-pin 路徑、seed dump 的 trunk/branches 對應一併連動。(see origin: R24, R25)
- **KTD3 — `.code-workspace` 移除是 no-op。** turbo-plugin 全域 0 個 `.code-workspace` 出現(它是舊 tgs 的東西),此項只需「確認 setup/README 不引入」,無程式變更面。(see origin: R22, R23)
- **KTD4 — 測試工作根 = repo 內 gitignored `tests/.sandbox/`,空格容忍。** 以長形 `[System.IO.Path]::GetFullPath` 解析、對 `svnadmin`/`cmd` 重導/`Push-Location` 傳長形 quoted LiteralPath,避免重現先前寫死 `C:\Turbo` 所迴避的 PS 5.1 8.3 短檔名 tilde bug;`svn` client 用 sandbox-local `--config-dir`(`svnadmin`/`svnlook` 無此選項也不讀 `%APPDATA%`)。(see origin: R1–R5)
- **KTD5 — 兩種 powershell 依賴分流。** SUT 真的需要 PowerShell/MSBuild/IIS → 缺工具時在任何 `powershell` 呼叫前 SKIP;fixture 只是順手用 powershell 做 GUID/cleanup(如 `get-target-url.test.sh`)→ 改寫 powershell-free(`uuidgen` / `rm -rf`)讓它在 ubuntu 照常 RUN。(see origin: R9, R10)
- **KTD6 — CI 慣例自動探索,group 由測試自我 SKIP 實現。** 單一 workflow 用 matrix 掃 `plugins/*/tests/` 跑各 plugin 標準入口;ubuntu 上「哪些跑/SKIP」純由每個測試依能力自我 SKIP 決定,discovery 不帶 group marker、不需逐 plugin 寫 yml。(see origin: R6–R10, KD3)
- **KTD7 — release tag 判準 = 有無產出 git merge commit。** 以 `git log <remote>..<branch>` 是否 ≥1 新 commit 為準(含「檔案全被 svn:ignore、svn commit 為空但 merge commit 仍產出」);移植 tag-release 的 ref 解析改用 `remote-svn/*`。(see origin: R29, R30)
- **KTD8 — CLAUDE.md plugin-agnostic。** 只留 marketplace 通用規約 + 一句「每個 plugin 規範寫在各自 README.md」+ 明訂測試標準;plugin 專屬內容先搬進 turbo-plugin README 再從 CLAUDE.md 移除。(see origin: R15–R19)
- **KTD9 — 退役複合 gate。** 刪四個舊 plugin 目錄 + marketplace 只列 turbo-plugin,受「parity 簽核(本 plan 已完成)AND owner 確認 dev marketplace 無外部 clone/訂閱」雙條件 gate。(see origin: R20, R21, KD12)
- **KTD10 — `tp-db-management` de-couple dev-flow。** 標準化 SQL 落在 `.turbo-plugin/sql/<env>-db/<branch-name>/*.sql`(以當前 git branch 名為分組鍵,取代舊 dev-flow slug);**branch 名中的 `/` 以 `-` 取代(`feature/x` → `feature-x`)維持單層分組鍵、避免巢狀路徑與 `x` vs `feature/x` 混淆**;`.turbo-plugin/sql/` 進版控(與 gitignored 的 `worktrees/` 區隔)。

---

## Parity Audit & Decisions（R31 交付物）

四個舊 plugin 的能力對照盤點與逐項裁決(完整盤點見研究紀錄):

| 舊能力 | 來源 | 裁決 | 處置 |
|---|---|---|---|
| tnf 全部(build/run/stop/publish + setup) | tnf | 已搬 ✅ | 無需動作;另淨增 `tp-cleanup-orphan-iis` |
| pull/push/svn-log/create-remote-test/reset-remote-test/suggest-ignore | tgs | 已搬 ✅ | 無需動作 |
| csharp-comment / js-comment | tdp | 已搬 ✅ | 無需動作 |
| **release tag / `tag-release`** | tgs | **補** | U9(R29/R30) |
| **`merge-main-into-all`** | tgs | **補(v1.0.0)** | U10;語意更新為 merge 進所有非 `remote-svn/*` 分支 |
| **`db-management`** | tdp | **補(v1.0.0)** | U11;de-couple dev-flow |
| `create-dev-worktree` | tgs | 刻意不要 | KD9/R25:turbo-plugin 只管 `remote-svn-*`、不碰 `dev-<n>` |
| `release`(完整發佈編排) | tgs | 刻意不要 | 與 dev-flow 撤退一致;發佈改自選流程 plugin + 手動 `tp-push-to-svn` |
| `cleanup-remote-test` | tgs | 刻意不要 | test slot 只增/reset,手動清即可 |
| `create-branch` / `archive` | tgs | 刻意不要 | dev-flow primitive,呼叫者已撤 |
| dev-flow skills / commit-msg / frontend / markitdown / memory | tdp | 刻意不要 | brainstorm 2026-05-20 已明列撤退 |
| tpi `setup-all` / `teach-me` / `dependency-check` | tpi | 刻意不要 | 整併進 `tp-setup` + hook,或留待未來 |
| `create-project` 新專案 bootstrap | tgs | 待驗證 | U3 驗證 `tp-setup` case (a) 是否完整涵蓋,缺則補 |

---

## High-Level Technical Design

### worktree 佈局:before → after（directional）

```
BEFORE (sibling 容器 + remote/* 命名)
<proj>/
<proj>.worktrees/
  ├─ remote-main/        branch: remote/main
  └─ remote-test-<n>/    branch: remote/test-<n>

AFTER (收進 .turbo-plugin/、remote-svn 命名)
<proj>/
├─ .turbo-plugin/
│   ├─ config.toml            ← 進 git
│   ├─ config.local.toml      ← gitignored
│   ├─ sql/<env>-db/<branch>/ ← 進 git（tp-db-management 輸出）
│   └─ worktrees/             ← gitignored 整個（先於首次 worktree add 寫入）
│       ├─ remote-svn-main/        branch: remote-svn/main
│       └─ remote-svn-test-<n>/    branch: remote-svn/test-<n>
└─ (專案檔案…)
```

### CI 矩陣（「能跑的就跑」）

```
workflow（掃 plugins/*/tests/，matrix over plugin × OS）
├─ windows-latest : powershell.exe(PS5.1) 跑全部 .ps1 + git-bash 跑全部 .sh
└─ ubuntu-latest  : bash 跑可移植 SVN/git .sh；缺工具的測試自我 SKIP（非 fail）
   SKIP ≠ FAIL；新增遵循標準佈局的 plugin → 零改 .yml
```

---

## Output Structure（新增/重整的關鍵檔案）

```
.github/workflows/
  └─ tests.yml                         ← U7 新增（自動探索測試 CI）
plugins/turbo-plugin/
├─ scripts/
│   ├─ lib/Common.ps1 / common.sh      ← U1 加 Get-WorktreesDir；U2 改 Resolve-RemoteWorktree
│   ├─ Tag-Release.ps1 / tag-release.sh ← U9 新增（移植自 tgs）
│   ├─ Merge-MainIntoAll.ps1 / merge-main-into-all.sh ← U10 新增
│   └─ (7 對 SVN script 改呼叫 helper)
├─ skills/
│   ├─ tp-merge-main-into-all/SKILL.md ← U10 新增
│   ├─ tp-db-management/SKILL.md        ← U11 新增
│   └─ (既有 skill 改 remote-svn 命名/路徑)
├─ tests/
│   ├─ .sandbox/                        ← U4 新增（gitignored 測試工作根）
│   ├─ Invoke-ScriptTests.ps1 / invoke-script-tests.sh ← U4 去硬編
│   ├─ lib/ScriptsCommon.ps1            ← U4 sandbox 機制
│   ├─ fixtures/reset/*                 ← U4/U6 去硬編 + 新佈局
│   ├─ docs/skill-tests.md / skill-tests-session-plan.md ← U8 重寫
│   └─ runs/v1.0.0/skill-tests-results.md ← U8 path-free 模板
├─ README.md                            ← U12 接收 plugin 專屬規範
CLAUDE.md                               ← U12 改 marketplace 通用規範
.claude-plugin/marketplace.json         ← U13 只列 turbo-plugin
```

---

## Implementation Units

### Phase A — worktree 結構與命名（基礎，多數後續依賴）

### U1. 抽 worktree 容器 lib helper

- **Goal**:消除 7 對 script 各自硬編 sibling 容器路徑,集中到一個 helper。
- **Requirements**:R21, R26。
- **Dependencies**:無。
- **Files**:`plugins/turbo-plugin/scripts/lib/Common.ps1`、`plugins/turbo-plugin/scripts/lib/common.sh`;7 對 caller:`Build-SvnCommit`、`Get-SvnLog`、`New-RemoteTest`、`Reset-RemoteTest`、`Set-SvnIgnore`、`Sync-FromSvn`、`Submit-SvnCommit`(各 `.ps1` + `.sh`);測試 `tests/unit/scripts/lib/Common.test.ps1`、`tests/unit/scripts/lib/common.test.sh`。
- **Approach**:新增 `Get-WorktreesDir`(回 `<mainWorktree>/.turbo-plugin/worktrees`,內部用 `Get-MainWorktree` + `[System.IO.Path]::Combine`)/ `get_worktrees_dir`。7 對 script 把 `Join-Path (...) "$projName.worktrees"` / `"$ROOT_DIR/$PROJ_NAME.worktrees"` 改成呼叫 helper。
- **Patterns to follow**:既有 `Get-MainWorktree` / `get_main_worktree`(Common.ps1 L52、common.sh L51)。
- **Test scenarios**:happy — helper 回傳 `<main>/.turbo-plugin/worktrees`;edge — 從 remote worktree 內呼叫仍正確定位 main;**Covers AE9**(配合 U2)。`.ps1` + `.sh` 兩條都測。
- **Verification**:7 對 script 不再出現 `.worktrees` 字面;helper 單測綠。

### U2. `remote-svn` 改名 + gitignore worktrees + nested 語意驗證

- **Goal**:目錄與 branch 兩維度改 `remote-svn`,worktrees 容器先於首次 worktree-add 加入 gitignore,並驗證 nested worktree 不破壞 main 定位。
- **Requirements**:R22, R24, R25, R27;AE9。
- **Dependencies**:U1。
- **Files**:`scripts/lib/Common.ps1`(`Resolve-RemoteWorktree` L107-129)、`scripts/lib/common.sh`(`resolve_remote_worktree` L106-122);`skills/tp-setup/SKILL.md`(gitignore case a/b/c + Completion Check + svn:ignore 6f);`scripts/Reset-RemoteTest.ps1`/`reset-remote-test.sh`(`git diff main..remote/test-$n` 等 ref);**`scripts/New-RemoteTest.ps1`/`new-remote-test.sh`**(硬編 `remote-main`/`remote/test-$IDX`/`remote-test-$IDX`,且用 `^remote-test-(\d+)$` regex / `remote-test-*` glob **掃目錄算 next index**——改名後此 regex 須同步改成 `^remote-svn-test-(\d+)$`,否則 next index 永遠算成 1);測試對應。
- **Approach**:`Resolve-RemoteWorktree` 的 Name → `remote-svn-main`/`remote-svn-test-$n`、Branch → `remote-svn/main`/`remote-svn/test-$n`、Path 經 helper。tp-setup 在**寫 `.turbo-plugin/worktrees/` 的 ignore 規則於任何 `git worktree add` 之前**;驗證 `Test-IsMainWorktree`(`dirname(common-dir)==show-toplevel`)在 nested linked worktree 下仍正確。
- **Patterns to follow**:既有 gitignore idempotent merge(tp-setup L126-133)。
- **Test scenarios**:resolve 回新命名;建 remote worktree 後主 worktree `git status --porcelain` 為空(**Covers AE9**);`Test-IsMainWorktree` 在 nested 佈局回 true;ref 改名後 `git diff` 仍能比對。
- **Verification**:`git branch -a` 出現 `remote-svn/*`;`git worktree list` 出現 `.turbo-plugin/worktrees/remote-svn-*`;主 worktree status 乾淨。

### U3. 更新 skills 的 worktree 路徑/命名引用 + 修 reset SKILL 空頭支票

- **Goal**:所有 skill 文案與 completion check 改用新佈局/命名;修正 `tp-reset-remote-test` 引用不存在的 release tag;驗證 `tp-setup` 涵蓋新專案 bootstrap(parity create-project)。
- **Requirements**:R22, R25;parity create-project 驗證。
- **Dependencies**:U2、(U9 提供 release tag 後回填 reset SKILL 措辭)。
- **Files**:`skills/tp-setup/SKILL.md`、`skills/tp-create-remote-test/SKILL.md`、`skills/tp-pull-from-svn/SKILL.md`、`skills/tp-reset-remote-test/SKILL.md`、`skills/tp-suggest-ignore/SKILL.md`、`skills/tp-push-to-svn/SKILL.md`。
- **Approach**:文字替換 `remote-main`→`remote-svn-main`、`<proj>.worktrees`→`.turbo-plugin/worktrees`、`remote/main`→`remote-svn/main` 等;確認 tp-setup case (a) 有建 remote-svn-main orphan worktree 的新專案流程。reset SKILL 的「release tag 找回」措辭**拆成獨立的 post-U9 回填子步驟**:U3 在 Phase A 先完成命名/路徑替換,該句先留 TODO 佔位;待 U9 落地後回填指向真正的 tag-release 機制(phase 排序執行時,在 U9 完成前不可把這句標 COMPLETE)。
- **Test expectation**:none -- 文件變更,行為由 U2/U9 的 script 測試涵蓋;以人工 skill 驗證(U8)把關。

---

### Phase B — 測試可攜與零污染

### U4. sandbox 工作根 repo 相對化 + 空格容忍 + svn config 隔離

- **Goal**:測試工作根改 `plugins/turbo-plugin/tests/.sandbox/`,**消除所有 `C:\Turbo` 硬編(grep 驗證約 97 處、橫跨 31 檔——不是只有 4 處)**,容忍含空格路徑,SVN 全域狀態隔離。
- **Requirements**:R1, R2, R3, R4, R5;AE4, AE5, AE8。
- **Dependencies**:無(可與 Phase A 平行,但 U6 依賴本單元 + U2)。
- **Files**:`tests/lib/ScriptsCommon.ps1`(`$TpSandboxBase` L63、`New-Sandbox`、`Invoke-PsScript` 重導 tempfile L132-134)、`tests/Invoke-ScriptTests.ps1`(L102 硬編 mkdir)、`tests/fixtures/reset/Reset-Fixture.ps1`(L23/157)、`tests/fixtures/reset/reset-fixture.sh`(L18/91)、**所有 `tests/unit/scripts/**/*.test.ps1` 各自硬編的 `$testRoot` / sandbox 字面**(含 `hooks/Invoke-SessionStart.test.ps1`、`hooks/Invoke-PostToolUseEnterWorktree.test.ps1`、`lib/IisHelpers.test.ps1`、`lib/ApplicationHostHelpers.test.ps1`、`Test-IisListening.test.ps1`)、`tests/fixtures/base/.turbo-plugin/config.toml`;`.gitignore`(加 `tests/.sandbox/`)。實作前先 `grep -rn 'C:\\Turbo'` 全面盤點,逐一路由到 `New-Sandbox` / sandbox-relative base。**註**:`tests/fixtures/seed/Build-SeedRepo.ps1`(L42-43 硬編 `C:\Turbo\turbo-plugin-seed-build` 以避 PS 5.1 8.3 bug)刻意保留無空格 work root——dump 再生是 developer-only 路徑、CI 用 committed dump,不在零污染 gate 內(於 Scope Boundaries 註明)。
- **Approach**:sandbox base 由 `$PSScriptRoot` 往上推到 `tests/.sandbox/`,以 `GetFullPath` 取長形;`svn` client 呼叫加 `--config-dir <sandbox>/.svnconfig`;svnadmin 只給長形 quoted 路徑。
- **Patterns to follow**:既有 `Invoke-PsScript` 的 cmd 重導(ScriptsCommon L143-145)。
- **Test scenarios**:**Covers AE4**(新增遵循佈局的 plugin 被 CI 探索——由 U7 驗);**Covers AE5**(跑完零測試導向產物在 sandbox 外);**Covers AE8**(clone 到含空格路徑跑完整測試綠燈,含 Invoke-PsScript 重導 tempfile 讀寫);grep PR 樹零本機絕對路徑(AE6 部分)。
- **Verification**:`C:\Turbo` 頂層零殘留;sandbox 在 `tests/.sandbox/`;含空格 parent 路徑下完整測試綠。

### U5. powershell 依賴分流 + bash fixture 去硬編

- **Goal**:真跨平台測試在 ubuntu 能跑(fixture powershell-free),SUT-需工具的測試乾淨 SKIP。
- **Requirements**:R9, R10;AE3。
- **Dependencies**:U4。
- **Files**:`tests/unit/scripts/build-web.test.sh`、`get-target-url.test.sh`、`test-iis-listening.test.sh`、`start-iis.test.sh`、`publish-web.test.sh`、`get-project-identity.test.sh`(fixture powershell → `uuidgen`/`rm -rf`);delegate-smoke 類(`compress-content`、`remove-orphan-iis`、`test-encoding-support`、`ps1-delegate`、hooks)加 SUT 能力 SKIP gate。
- **Approach**:fixture 用 `uuidgen`(已是 get-project-identity 的 fallback 模式)+ `rm -rf`;SUT-需-powershell 的測試開頭偵測 `command -v powershell`/msbuild/IIS,缺則印 SKIP 標記並 exit skip 碼。
- **Test scenarios**:**Covers AE3**(ubuntu 跑 `build-web.test.sh` → fixture 前偵測缺 PowerShell → SKIP → job 綠);`get-target-url.test.sh` 在 ubuntu 實際 RUN 並通過(powershell-free)。
- **Verification**:ubuntu 上 SVN/git + get-target-url 類 RUN、.NET/IIS 類 SKIP、無 fixture-時 fail。

### U6. 既有 script 測試 + reset fixture 對齊新 worktree 佈局/命名

- **Goal**:單元測試與 reset fixture 反映 `remote-svn` + `.turbo-plugin/worktrees/`。
- **Requirements**:R3, R13(部分)。
- **Dependencies**:U2, U4。
- **Files**:`tests/lib/ScriptsCommon.ps1`(`New-GitMainRepo` L107-114 的 worktrees/remote-main)、`tests/fixtures/reset/Reset-Fixture.ps1`/`reset-fixture.sh`(worktrees + remote-main/test-1)、`tests/unit/scripts/*`(Sync/Set-SvnIgnore/Get-SvnLog/Build/Submit/Reset/New-RemoteTest + `.sh` 對應)。
- **Approach**:fixture 造 `.turbo-plugin/worktrees/remote-svn-main`、branch `remote-svn/main`;斷言路徑同步更新。
- **Test scenarios**:orchestrator 全套(36 case)在新佈局下綠;reset fixture meta-test 綠。
- **Verification**:`Invoke-ScriptTests.ps1` / `invoke-script-tests.sh` 全綠且零硬編路徑。

---

### Phase C — CI 自動化

### U7. GitHub Actions 自動探索測試 workflow

- **Goal**:單一 workflow 慣例自動探索並跑各 plugin 測試,windows 全跑、ubuntu 跑可移植 .sh。
- **Requirements**:R6, R7, R8, R9, R10;AE3, AE4。
- **Dependencies**:U4, U5, U6(測試須先 path-free + 可 SKIP)。
- **Files**:`.github/workflows/tests.yml`(新增)。
- **Approach**:matrix 掃 `plugins/*/tests/` 找標準入口(`Invoke-ScriptTests.ps1` / `invoke-script-tests.sh`);windows-latest 跑 `.ps1`(powershell.exe)+ `.sh`(git-bash),ubuntu-latest 跑 `.sh`;runner 裝 svn;SKIP 不算 fail(orchestrator 已有 SKIP/PASS/FAIL 區分)。明確呼叫 `powershell.exe`(非 pwsh)以鎖 PS 5.1。
- **Test scenarios**:**Covers AE4**(假想新 plugin 遵循佈局 → 不改 yml 被納入);**Covers AE3**(ubuntu .NET .sh SKIP、job 綠)。
- **Verification**:PR 上 CI 兩 job 綠;SKIP 數正確顯示;不需 per-plugin yml。

---

### Phase D — 兩層常駐測試套件

### U8. 重寫 skill-test 套件為常駐、可重複、path-free

- **Goal**:skill test 成為 script test 的人工版常駐套件,去硬編、反映新結構。
- **Requirements**:R11, R12, R13, R14, R15;AE6。
- **Dependencies**:U2, U9(case 要反映新命名 + release tag step)。
- **Files**:`tests/docs/skill-tests.md`、`tests/docs/skill-tests-session-plan.md`、`tests/runs/v1.0.0/skill-tests-results.md`(path-free 模板)。
- **Approach**:所有 `C:\Turbo\test-turbo-plugin\...` → `<VALIDATION_ROOT>\...` placeholder;case 結構統一為「agent 建 fixture → 給操作指示 → 使用者跑 → 記錄」;更新 case 反映 `remote-svn/*`、`.turbo-plugin/worktrees/`、push-to-svn Step 7 release tag、無 `.code-workspace`;新增 tp-merge-main-into-all、tp-db-management 的 case。
- **Test expectation**:none -- 文件;**Covers AE6**(grep PR 樹零本機路徑);本套件即 PR 前人工 gate 的腳本。
- **Verification**:grep `C:\Turbo` / `/c/Users` 在 PR 樹零命中;任何人可照 case 重跑。

---

### Phase E — push-to-svn release tag

### U9. 移植 tag-release + tp-push-to-svn Step 7

- **Goal**:補回 release tag 能力,判準為「有無產出 git merge commit」。
- **Requirements**:R28, R29, R30;AE1, AE2。
- **Dependencies**:U2(ref 命名)。
- **Files**:`scripts/Tag-Release.ps1`、`scripts/tag-release.sh`(移植自 `plugins/turbo-git-with-remote-svn/scripts/tag-release.*`);`skills/tp-push-to-svn/SKILL.md`(加 Step 7);測試 `tests/unit/scripts/Tag-Release.test.ps1` + `.sh`。
- **Approach**:ref 映射改 `remote-svn/main`、`remote-svn/test-<n>`;tag 命名沿用 `<branch>-release-<date>-<NNN>`;Step 7 在「prepare 產出 merge commit(`git log <remote>..<branch>` ≥1 commit)」時詢問 Yes/No,svn commit 為空也照問;git/svn 皆無變更時不問。對齊 `Get-MainWorktree`(用 `--path-format=absolute`,別沿用 tgs 舊版)。
- **Test scenarios**:**Covers AE1**(檔案全 svn:ignore → merge commit 產出 → 仍問 tag → 建 `remote-svn/<branch>-release-*`);**Covers AE2**(無新 commit → 不問 tag);tag 指向 `remote-svn/test-<n>`。`.ps1` + `.sh` 都測。
- **Verification**:Step 7 在兩情境行為正確;tag ref 用新命名;`tp-reset-remote-test` 的「release tag 找回」承諾現在有實體支撐。

---

### Phase F — parity 補項

### U10. tp-merge-main-into-all（新語意）

- **Goal**:把 main merge 進所有非 `remote-svn/*` 分支。
- **Requirements**:R31(merge-main-into-all 補)。
- **Dependencies**:U2。
- **Files**:`scripts/Merge-MainIntoAll.ps1`、`scripts/merge-main-into-all.sh`;`skills/tp-merge-main-into-all/SKILL.md`;測試 `tests/unit/scripts/Merge-MainIntoAll.test.ps1` + `.sh`。
- **Approach**:列出 `git branch`,exclude filter 同時排除 **`main` 本身**與 `remote-svn/*`(對應參考腳本的 `-ne 'main' -and -notmatch '^remote/'`,把 `remote/` 換 `remote-svn/`;舊的 `^archives/` 排除因 dev-flow/archive worktree 已撤而移除)。逐分支 `git merge main`;**衝突時對該分支 `git merge --abort`、標記 CONFLICT、繼續下一支**(對齊參考腳本 per-branch abort,避免遺留衝突狀態污染後續分支)。turbo-plugin 無 dev/archive worktree,**移除參考腳本的 `Get-BranchWorktreeMap` worktree-aware 路徑**,只在 main worktree 逐分支 checkout+merge+checkout-back。參考 `plugins/turbo-git-with-remote-svn/scripts/merge-main-into-all.*`。
- **Test scenarios**:happy — 多個 test 分支都 merge 到 main tip;edge — `remote-svn/*` 被排除不動;error — 衝突分支列出且中止該分支不影響其他。
- **Verification**:跑後非 `remote-svn/*` 分支皆含 main tip;`remote-svn/*` 不被動。

### U11. tp-db-management（de-couple dev-flow）

- **Goal**:DBHub 唯讀檢視 + SQL 標準化到 `.turbo-plugin/sql/<env>-db/<branch>/`,不綁 dev-flow slug。
- **Requirements**:R31(db-management 補)。
- **Dependencies**:無(dbhub MCP 既有)。
- **Files**:`skills/tp-db-management/SKILL.md`(+ 視需要 `scripts/` helper);`.turbo-plugin/sql/` 不列入 gitignore(與 worktrees/ 區隔)。
- **Approach**:保留 DBHub 唯讀檢視;SQL 標準化輸出落 `.turbo-plugin/sql/<env>-db/<current-branch>/*.sql`,branch 名以 `git rev-parse --abbrev-ref HEAD` 取得後**把 `/` 換成 `-`**(見 KTD10);移除舊的 spec/slug/`sql files/` 耦合。
- **Test scenarios**:happy — 產出的 SQL 落在 `.turbo-plugin/sql/<env>-db/<branch>/`;edge — branch 名含 `/`(如 feature/x)時路徑安全處理;檔案進版控(非 gitignored)。
- **Verification**:SQL 落點正確、不依賴 dev-flow 結構。

---

### Phase G — 治理與退役

### U12. CLAUDE.md 改 marketplace 通用規範

- **Goal**:CLAUDE.md plugin-agnostic;plugin 專屬內容搬進 turbo-plugin README;明訂測試標準。
- **Requirements**:R15, R16, R17, R18, R19;AE7。
- **Dependencies**:無(但 U7/U8 定義的測試標準要先成形,規範才寫得準)。
- **Files**:`CLAUDE.md`(根)、`plugins/turbo-plugin/README.md`。
- **Approach**:先把 CLAUDE.md 內僅存的 plugin 專屬內容(worktree 模型、AC 7 類、csharp/js-comment 規則、env 前綴等)確認/搬進 turbo-plugin README;CLAUDE.md 留版本號規則、標準 plugin 結構、skill/command/script 三層分工、跨平台 + PS 5.1 規則、設定檔分層、changelog 規約、marketplace manifest 規則 + 「每個 plugin 規範寫在各自 README.md」+ 明訂「每個 plugin 必須有兩層測試 + CI、擺在慣例路徑」。
- **Test expectation**:none -- 文件;**Covers AE7**(讀 CLAUDE.md 找不到特定 plugin 名/清單、有 README 指向句、有測試 mandate 段)。
- **Verification**:grep CLAUDE.md 無特定 plugin 名/清單;README 接收專屬內容無遺失。

### U13. 退役四個舊 plugin（複合 gate）

- **Goal**:刪四個舊 plugin 目錄 + marketplace 只列 turbo-plugin。
- **Requirements**:R20, R21;AE10。
- **Dependencies**:**U9、U10、U11**(三者都從將被刪的舊 plugin 移植——U9/U10 自 tgs、U11 自 turbo-dev-pack——須全部完成再刪)、U12(CLAUDE.md 不再依賴舊 plugin);**複合 gate**:parity 簽核(本 plan 已完成)AND owner 確認 dev marketplace 無外部 clone/訂閱。
- **Files**:刪 `plugins/turbo-dev-pack/`、`plugins/turbo-dotnet-framework-commands/`、`plugins/turbo-git-with-remote-svn/`、`plugins/turbo-plugins-integration/`;`.claude-plugin/marketplace.json`(只留 turbo-plugin);README 安裝章節同步。
- **Approach**:**這是本 PR 最後執行的單元之一**,排在 **U9/U10/U11**(分別從 tgs 與 turbo-dev-pack 移植完 tag-release / merge-main-into-all / db-management 參考)之後,確保所有需要參考舊碼的移植都完成;刪除前 owner 確認 gate(b)。
- **Test expectation**:none -- 刪除 + manifest;**Covers AE10**(PR 內可見完整簽核的 parity 清單,刪除時序晚於簽核)。
- **Verification**:`plugins/` 只剩 turbo-plugin;marketplace 只列 turbo-plugin;舊碼參考的移植(U9/U10)已落地。

---

## Scope Boundaries

**本 plan 範圍內**:上述 8 主軸 + 2 項 parity 補(merge-main-into-all、db-management)+ release tag,全部進同一 v1.0.0 PR。

**刻意不做(parity 裁決)**:
- `release` 完整發佈編排、`cleanup-remote-test`、`create-dev-worktree`、`create-branch`/`archive`、dev-flow skills、commit-msg、frontend-standard、markitdown、memory、tpi 三 skill。

**Deferred to Follow-Up Work**:
- 無(本輪所有「補」項都裁決進 v1.0.0;若 U10/U11 實作中發現超出預期的非 trivial 工作,依 origin R31 規則移 follow-up 並開追蹤 issue)。

**不做**:舊結構→新結構遷移程式(全新對待)、v0.2.x 相容、PR 前先把測試獨立推上 GitHub、人工 skill 驗證的**執行**(本 plan 只產出可重複套件;執行是 PR 前最後 gate,等 U1–U13 落地後跑)。

---

## Risks & Dependencies

- **R-1 nested worktree git 語意**:worktree 從 sibling 改 main 內部,`git status`/`Test-IsMainWorktree`/`git worktree add` 行為須在 U2 實證(repo 自身 `.claude/worktrees/` 已證可行,主要風險是 gitignore 順序——U2 已涵蓋)。
- **R-2 branch ref vs dir name 兩維度**:KTD2 已明確兩者都改;漏改 ref 會讓 `git log/diff "remote/..."`、tag-release、seed dump 對應失效。
- **R-3 CI runner 工具**:windows-latest 需內含 PS 5.1(明呼 `powershell.exe`);兩 OS 都需裝 svn——U7 的 workflow 要含安裝步驟。
- **R-4 退役 gate (b)**:owner 須在 U13 前確認 dev marketplace 無外部訂閱;此為人工確認,非程式可驗。
- **R-5 db-management 重設計**:de-couple dev-flow 後 SQL 落點已定(`.turbo-plugin/sql/<env>-db/<branch>/`),但舊 skill 其餘 dev-flow 假設需逐一剝離。
- **依賴鏈**:U1→U2→{U3,U6,U9,U10};U4→{U5,U6};{U4,U5,U6}→U7;{U2,U9}→U8;{U9,U10,U11,U12}→U13。U3 的 reset-SKILL release-tag 措辭子步驟須待 U9 落地後回填(見 U3),phase 排序時不可在 U9 前把該句標 COMPLETE。

---

## Open Questions（Deferred to Implementation）

- `tp-setup` case (a) 是否已完整涵蓋「全新專案 bootstrap」(建 remote-svn-main orphan worktree)——U3 實作時驗證,缺則於 U3 補。
- CI matrix 同時跨 plugin × OS 的精確 YAML 形狀(R7 × R8/R9)——U7 實作時定。
- `tp-db-management` 是否需要獨立 `.ps1`/`.sh` script,或純 skill + dbhub MCP 即可——U11 實作時定。
- 既有 36 個 script test case 去硬編後,是否有 case 因新 worktree 佈局需改測試邏輯(非只改路徑)——U6 實作時定。
