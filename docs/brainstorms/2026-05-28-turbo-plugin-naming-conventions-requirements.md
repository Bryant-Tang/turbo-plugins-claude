---
date: 2026-05-28
topic: turbo-plugin-naming-conventions
status: planned
---

# turbo-plugin 全 script + test infra 命名統一

## Summary

把 `plugins/turbo-plugin/` 內**所有 PowerShell + Bash script(prod + test 含 lib / hooks / fixtures / orchestrator)** 統一改成 PS 官方命名規範,並消除測試端 4 種混亂的後綴(`.Tests.ps1` / `.sh.test.sh` / `test_*.ps1` / `_Common.ps1`)。

規則分層:
- **Entry script(被直接 invoke 的 .ps1)** — Verb-Noun PascalCase,verb 必在 `Get-Verb` approved 清單
- **Library 集合(被 dot-source 的多 function 容器)** — noun-only PascalCase(跟 PS module 慣例:`Pester.psm1` / `Microsoft.PowerShell.Utility.psm1`)
- **Library 單 function 包裝** — Verb-Noun PascalCase,file 名 = 內部 function 名
- **Bash sibling** — 同語意 kebab-lowercase

**前置狀態 commit:** `afad1fa`(`feat/turbo-plugin-v1.0` branch),包含 U1-U7 + F5 fixes + restructure + 1.0.0 lock。

**範圍仍屬 v1.0.0**,不 bump 版本。

---

## Problem Frame

ce-work 跑完後 user audit 發現的不一致:

1. **生產 script 全 kebab-lowercase**(`pull-from-svn.ps1` / `build-web.ps1`...)— 不符 PowerShell Verb-Noun 官方慣例。
2. **生產 script 有 7 個 unapproved verb**:`pull` / `pack` / `cleanup` / `compute` / `check` × 2 / `emit`(test 端)/ `run`(test 端) — PSScriptAnalyzer `PSUseApprovedVerbs` rule violation。
3. **`push-to-svn-prepare` / `push-to-svn-commit` 語意誤導** — 兩階段都帶 `push-to-svn` prefix,讓人以為各自獨立 push,實際上「兩階段合起來才是 push」。
4. **測試端 4 種命名 pattern 並存**:`.Tests.ps1`(Pester 殘留)/ `.sh.test.sh`(後綴位置怪)/ `test_<name>.ps1`(snake_case prefix)/ `_Common.ps1`(underscore-prefix discovery-avoidance)。
5. **`unit/scripts-lib/` flat 跟 `unit/scripts/hooks/` nested 不一致**(同樣 mirror source 結構,深淺卻不同)。
6. **`scripts/lib/` test coverage 不完整** — `common.ps1` 有 2 個 feature test,`common.sh` / `applicationhost-helpers.ps1` / `ps1-delegate.sh` 沒 test。
7. **`Run-Phase1.ps1` 沒 Bash sibling** — cross-platform 跑 test 缺對等。
8. **Phase 1 / Phase 2 內部 jargon 對外不直觀** — 從檔名看不出在跑什麼。
9. **R1「18 個 script」漏算 `scripts/hooks/` 兩個 hook script** — plan-level scope 細節,已在前一輪補。

---

## Key Decisions

### KD-1. 命名規則分四層

| 角色 | 規則 | 範例 |
|---|---|---|
| Entry script(.ps1) | Verb-Noun PascalCase,verb 必 approved | `Build-Web.ps1` / `Get-SvnLog.ps1` |
| Library 多 function 集合(.ps1) | noun-only PascalCase | `Common.ps1` / `AssertHelpers.ps1` |
| Library 單 function 包裝(.ps1) | Verb-Noun PascalCase,file 名 = function 名 | `Write-TrackingRow.ps1` / `Get-ScriptTestStatus.ps1` |
| Hook script(.ps1) | 視為 entry script,Verb-Noun | `Invoke-SessionStart.ps1` |
| Bash sibling(.sh) | 同語意 kebab-lowercase | `build-web.sh` / `get-svn-log.sh` |

**Trade-off 承認:** 此規則讓 `.ps1`(PascalCase)跟 `.sh`(kebab)在檔案管理員 / IDE 排序時不再緊鄰,grep 也要搜兩種大小寫各一次(如 `Sync-FromSvn` 跟 `sync-from-svn`)。**有意為之** — 選擇「各語言內部慣例優先」(PS 慣例 Verb-Noun PascalCase、Bash 慣例 kebab-lowercase)勝過「跨語言視覺對齊」。如果以後 grep 對齊變成痛點,可考慮一個 `tools/find-script.ps1` helper 同時搜兩種大小寫。

### KD-2. 7 個 unapproved verb 全改 approved

| 舊 verb | 新 verb | 理由 |
|---|---|---|
| Pull | Sync | Pull 非 approved;Sync 在 Data 類 ✓ |
| Pack | Compress | Pack 非 approved;Compress 語意對等 ✓ |
| Cleanup | Remove | Cleanup 非 approved;改更精確的 Remove ✓ |
| Compute | Get | Compute 非 approved;script 行為 = retrieve identity → Get ✓ |
| Check | Test | Check 非 approved;Test 在 Diagnostic 類,專用於 is-X-true check ✓ |
| Emit | Write | Emit 非 approved;Write 在 Communications 類 ✓ |
| Run | Invoke | Run 非 approved;Invoke 在 Lifecycle 類,專用於執行 ✓ |

### KD-3. Push-to-svn 兩階段改 Build / Submit

| 舊 | 新 | 動作 |
|---|---|---|
| push-to-svn-prepare | `Build-SvnCommit.ps1` | 把 git WIP 同步成 SVN working copy 上的 commit candidate,等使用者 review |
| push-to-svn-commit | `Submit-SvnCommit.ps1` | review 完後跑 `svn commit` 送出 |

共同 noun `SvnCommit` 維持「兩階段是一對」視覺。Build / Submit 都在 approved 清單(Build = Lifecycle,Submit = Lifecycle)且語意精準 — Build 描述「建出一個 commit candidate」,Submit 描述「送出去」。

### KD-4. Hook script 用 `Invoke-` prefix

| 舊 | 新 |
|---|---|
| posttooluse-enterworktree | `Invoke-PostToolUseEnterWorktree.ps1` |
| sessionstart | `Invoke-SessionStart.ps1` |

`Invoke-` 在 Lifecycle 類 ✓。

**注意 hook 設定改動範圍:**
- Hook 設定檔在 `plugins/turbo-plugin/hooks/hooks.json`(不是 `plugin.json`)。`command:` 欄位用 `bash "...scripts/hooks/<name>.sh"` 啟動 `.sh`(非直接呼 `.ps1`)。重命名後 `hooks.json` 內路徑要同步指到新 `.sh` 名(`invoke-posttooluse-enterworktree.sh` / `invoke-sessionstart.sh`)
- 每個 hook `.sh` 內部 hard-code 一行 `PS1_PATH="${PLUGIN_ROOT}/scripts/hooks/<name>.ps1"`,**`.sh` body 內這個 literal 也要改**到新 `.ps1` 名,否則 hook `.sh` 跑起來但找不到 `.ps1` → silent failure(`.sh` `exit 0`)

### KD-5. Test 檔後綴統一 `.test.ps1` / `.test.sh`

全 lowercase + suffix 位置一致,取代既有 4 種混雜 pattern。test file 名 = 對應 source 名 + `.test`。

### KD-6. `unit/scripts-lib/` rename 為 `unit/scripts/lib/`

對齊 `scripts/lib/` source 結構。`unit/scripts/{lib,hooks}/` 都 mirror `scripts/{lib,hooks}/`。

### KD-7. `common.ps1` 兩 feature test merge 為 `Common.test.ps1`

`test_resolve_config_value_merge.ps1` + `test_find_tools_strict_cut.ps1` → 合一進 `unit/scripts/lib/Common.test.ps1`,內部 section 區隔不同 feature。Source-to-test 1:1。

### KD-8. `_Common.ps1` → `tests/lib/ScriptsCommon.ps1`

集中 test helper 在 `tests/lib/`,移除 underscore-prefix。新名遵 KD-1 noun-only(多 function 集合)。

### KD-9. tests/lib 採混合規則

| 檔 | 內含 | 規則 | 新名 |
|---|---|---|---|
| Assert-Helpers.ps1 | 6 個 Assert-* function | 多 function → noun-only | **`AssertHelpers.ps1`** |
| Emit-TrackingRow.ps1 | 1 個 function | 單 function → Verb-Noun | **`Write-TrackingRow.ps1`**(Emit ✗ → Write ✓) |
| Get-Phase1Status.ps1 | 1 個 function | 單 function → Verb-Noun + Phase1 → ScriptTest | **`Get-ScriptTestStatus.ps1`** |
| Get-RawCommitDump.ps1 | 1 個 function | 單 function → Verb-Noun | 維持(Get ✓) |

### KD-10. Phase1 / Phase2 jargon 全清,改 Script Tests / Skill Tests

| 舊 | 新 |
|---|---|
| Phase 1(自動 script test)| **Script Tests** |
| Phase 2(手動 skill test)| **Skill Tests** |
| Run-Phase1.ps1 | `Invoke-ScriptTests.ps1` |
| Get-Phase1Status.ps1 | `Get-ScriptTestStatus.ps1` |
| tests/docs/phase1-scripts-schema.md | `tests/docs/script-tests-schema.md` |
| tests/docs/phase2-skills.md | `tests/docs/skill-tests.md` |
| tests/docs/phase2-session-plan.md | `tests/docs/skill-tests-session-plan.md` |
| tests/runs/v1.0.0/phase1-results.md | `tests/runs/v1.0.0/script-tests-results.md` |
| tests/runs/v1.0.0/phase2-results/ | `tests/runs/v1.0.0/skill-tests-results/` |
| docs 內文 "Phase 1" / "Phase 2" | "Script tests" / "Skill tests" |

### KD-11. Single-sibling 例外的 formal rule

CLAUDE.md 規定「所有 script 都要同時提供 .ps1 + .sh」。本 doc 開了幾個例外,須有判定規則,未來新增 script 才能 self-check 該不該配對。

**Formal rule — single-sibling 例外 if and only if 滿足任一條:**
- (a) **平台專屬:** script 操作的 OS 設施只有單一平台有(例如 Windows IIS Express 的 `applicationhost.config` XML、Windows Registry、macOS Keychain 等)
- (b) **單向語言橋:** script 是某語言到另一語言的單向 trampoline,反向沒這個需求

**現有 single-sibling 例外清單(套用 rule):**
- `ApplicationHostHelpers.ps1`(無 .sh)— 套 (a),操作 Windows-only `applicationhost.config`
- `IisHelpers.ps1`(無 .sh)— 套 (a),封裝 IIS Express + MSBuild 找路徑邏輯,Linux 沒對應
- `ps1-delegate.sh`(無 .ps1)— 套 (b),Bash → PS trampoline。PS 不需要反向 trampoline 因為 PS 直接 invoke bash 沒「找 binary」問題

未來新增 script 不符合 (a) 或 (b) 都要配對 .ps1 + .sh,sibling 缺一個就違反 CLAUDE.md。

**Enforcement(避免「自稱符合」):** 新增 single-sibling 例外時,PR 描述須明文 cite 是 (a) 還是 (b),並舉具體理由(平台 API 名 / trampoline 方向);reviewer 須在 PR review 時 cross-check 該理由成立才放行。例外清單(本 doc 列出的 3 項)是 baseline,未來新增以 PR 為憑。

### KD-12. Bash 端不補 assert-helpers.sh

接受 PS / Bash 不對等:PS 用 `AssertHelpers.ps1`(PS 文化偏好抽象 helper),Bash 用 inline assertion(Bash 慣例 OK)。理由:改寫 22 個 `.test.sh` 改用新 helper 風險高,且 inline 已能跑。

### KD-13. `Build-SeedRepo.ps1` 不寫 smoke test + 一次性 audit checklist

它是「一次性 builder」,output(`svn-repo-r1-r20.dump`)已 commit 進 git,日後跑測試只 LOAD 不重 BUILD。若 bug 只影響「未來想重建種子的人」,且 svnadmin load 失敗會立即 noisy(不像 assertion bug silent)。文件註記「Build-SeedRepo 是 builder script,output 是 frozen dump,信任邊界停這」。

**注意:** svnadmin load 只驗結構不驗語意 — 「dump 結構合法但 commit message 文字 / author / 檔內容亂」這種錯不會被 svnadmin 抓。所以**現版 dump 要做一次性 eyeball audit**(對 R1-R20 各 revision 驗:commit message 中文文字、author、預期檔內容)。Audit 結果記在 `tests/docs/script-tests-schema.md` 或 KD-13 註解,標明「已 audit 過 commit hash X」,後續若再重建 dump 重做 audit。

### KD-14. 單一 orchestrator = `Invoke-ScriptTests.ps1`(+ `invoke-script-tests.sh` sibling)

行為:
- recursive 掃 `tests/**/*.test.ps1`(及 `.test.sh`)
- **先跑 lint pre-flight**(`tools/lint-ps-compat.ps1` 對 `plugins/turbo-plugin/`,違規 → halt + exit 2,不進 infra gate)— 繼承自 `Run-Phase1.ps1` 既有行為
- 再跑 **infra test gate**(`tests/lib/` + `tests/fixtures/` 的 meta-test)
- gate 通過才跑 prod test(`tests/unit/scripts/` recursive 含 hooks + lib)

**Routing rule(discovery 後分類):**
- file path 開頭 `plugins/turbo-plugin/tests/lib/` 或 `plugins/turbo-plugin/tests/fixtures/` → **infra**(先跑當 gate)
- file path 開頭 `plugins/turbo-plugin/tests/unit/` → **prod**(gate 通過後跑)
- 其他路徑(若有)→ 報錯「unrecognized test location」,不執行
- Infra test FAIL 分兩層處理,且**有 ordering**:
  - **(1) 先跑** `tests/lib/AssertHelpers.test.ps1`;FAIL → **full halt**(assertion 本身壞了,所有測試結果都不可信),不進入第 2 步
  - **(2) 再跑** `tests/fixtures/*/`(如 `Reset-Fixture.test.ps1`);FAIL → **只 skip fixture-dependent prod test**,純 unit test(不碰 fixture 的)照常跑,exit code 反映 skip 但不全 halt
  - ordering 避免「兩個同時 fail 哪個贏」問題 — AssertHelpers 先 halt 就根本不會跑到 fixture gate

PS 跟 sh 版功能對等:Windows 跑 .ps1 版,Linux/Mac 跑 .sh 版;兩者都會跑 .ps1 + .sh 雙邊 test(.sh 透過 `ps1-delegate.sh` 反向呼叫 PS)。

**Scope 註記(承認 bundle):** 這條 KD 同時包含「命名改動」(`Run-Phase1` → `Invoke-ScriptTests`)與「行為改動」(infra-gate 順序 + halt logic)。嚴格說「行為改動」是 test infra design 變更,不屬於本次命名 refactor 的核心 scope。**bundle 是有意為之** — 改 orchestrator 名同時 review 它的行為設計效率較高,且 gate 行為缺失就會讓 hand-rolled assertion 出 bug 時測試集體說謊。如果未來要回退命名只能整條 KD-14 撤回(含 gate 行為);如要保留 gate 行為改命名,要拆 KD-14a / KD-14b。

### KD-15. Meta-test 緊鄰 source(非 unit/)

| 測試對象 | 位置 |
|---|---|
| 產品程式碼(`plugins/turbo-plugin/scripts/`)| `tests/unit/scripts/<mirror>/*.test.{ps1,sh}` |
| 測試 library 本身(`tests/lib/*.ps1`)| `tests/lib/*.test.ps1`(sibling)|
| Fixture helper 本身(`tests/fixtures/*/`)| `tests/fixtures/*/*.test.{ps1,sh}`(sibling)|

`unit/` 保留給「測產品」的測試;meta-test 緊鄰 source 一眼就知道測的是 it 隔壁那個。

只有 **Assert-Helpers** 跟 **Reset-Fixture** 需要 meta-test(它們失靈會造成 silent false PASS);`Write-TrackingRow` / `Get-ScriptTestStatus` / `Get-RawCommitDump` 失靈會 noisy fail,不需 smoke。

---

## 完整 Rename Mapping

### A. Production entry scripts(`scripts/`,18 對)

| 舊 .ps1 / .sh | 新 .ps1 / .sh |
|---|---|
| build-web.{ps1,sh} | `Build-Web.ps1` / `build-web.sh` |
| check-encoding-support.{ps1,sh} | `Test-EncodingSupport.ps1` / `test-encoding-support.sh` |
| check-iis-listening.{ps1,sh} | `Test-IisListening.ps1` / `test-iis-listening.sh` |
| cleanup-orphan-iis.{ps1,sh} | `Remove-OrphanIis.ps1` / `remove-orphan-iis.sh` |
| compute-project-identity.{ps1,sh} | `Get-ProjectIdentity.ps1` / `get-project-identity.sh` |
| create-remote-test.{ps1,sh} | `New-RemoteTest.ps1` / `new-remote-test.sh` |
| get-target-url.{ps1,sh} | `Get-TargetUrl.ps1` / `get-target-url.sh` |
| pack-content.{ps1,sh} | `Compress-Content.ps1` / `compress-content.sh` |
| publish-web.{ps1,sh} | `Publish-Web.ps1` / `publish-web.sh` |
| pull-from-svn.{ps1,sh} | `Sync-FromSvn.ps1` / `sync-from-svn.sh` |
| push-to-svn-prepare.{ps1,sh} | `Build-SvnCommit.ps1` / `build-svn-commit.sh` |
| push-to-svn-commit.{ps1,sh} | `Submit-SvnCommit.ps1` / `submit-svn-commit.sh` |
| reset-remote-test.{ps1,sh} | `Reset-RemoteTest.ps1` / `reset-remote-test.sh` |
| ~~resolve-iis-settings.{ps1,sh}~~ | **重新歸類到 Group C lib(見下)。`.ps1` 改 `IisHelpers.ps1` 搬進 `scripts/lib/`;`.sh` trampoline 刪除(它不再是 entry,沒人會直接 bash 呼叫)。5 個 dot-source caller 路徑同步更新。** |
| start-iis.{ps1,sh} | `Start-Iis.ps1` / `start-iis.sh` |
| stop-iis.{ps1,sh} | `Stop-Iis.ps1` / `stop-iis.sh` |
| svn-ignore.{ps1,sh} | `Set-SvnIgnore.ps1` / `set-svn-ignore.sh` |
| svn-log.{ps1,sh} | `Get-SvnLog.ps1` / `get-svn-log.sh` |

### B. Hook scripts(`scripts/hooks/`,2 對)

| 舊 | 新 |
|---|---|
| posttooluse-enterworktree.{ps1,sh} | `Invoke-PostToolUseEnterWorktree.ps1` / `invoke-posttooluse-enterworktree.sh` |
| sessionstart.{ps1,sh} | `Invoke-SessionStart.ps1` / `invoke-sessionstart.sh` |

### C. Production library(`scripts/lib/`,4 檔)

| 舊 | 新 |
|---|---|
| common.{ps1,sh} | `Common.ps1` / `common.sh` |
| applicationhost-helpers.ps1(無 .sh)| `ApplicationHostHelpers.ps1` |
| ps1-delegate.sh(無 .ps1)| `ps1-delegate.sh`(不變)|
| scripts/resolve-iis-settings.ps1(從 Group A 搬入)| `scripts/lib/IisHelpers.ps1`(無 .sh,內含 `Find-IisExpressPath` + `Find-ApplicationhostTarget` + `Resolve-IisSettings`,被 5 個 entry script dot-source)|

### D. Test orchestrator(`tests/`,1→2 檔)

| 舊 | 新 |
|---|---|
| Run-Phase1.ps1 | `Invoke-ScriptTests.ps1` |
|(無)| `invoke-script-tests.sh`(新增)|

### E. Test library(`tests/lib/`,5 檔)

| 舊 | 新 |
|---|---|
| Assert-Helpers.ps1 | `AssertHelpers.ps1` |
| Emit-TrackingRow.ps1 | `Write-TrackingRow.ps1` |
| Get-Phase1Status.ps1 | `Get-ScriptTestStatus.ps1` |
| Get-RawCommitDump.ps1 | 不變 |
| test_assert_helpers.ps1 | `AssertHelpers.test.ps1`(meta-test)|
|(新增,KD-8)| `ScriptsCommon.ps1`(從 `_Common.ps1` 搬來)|

### F. Test fixtures(`tests/fixtures/`)

| 舊 | 新 |
|---|---|
| fixtures/seed/build-seed-repo.{ps1,sh} | `Build-SeedRepo.ps1` / `build-seed-repo.sh` |
| fixtures/reset/Reset-Fixture.ps1 | 不變 |
| fixtures/reset/reset_fixture.sh | `reset-fixture.sh` |
| fixtures/reset/test_reset_fixture.ps1 | `Reset-Fixture.test.ps1`(meta-test)|
|(新增,KD-15)| `fixtures/reset/reset-fixture.test.sh`(meta-test)|

### G. Test cases — unit/scripts(對應 A,17 對)

每個 `<old>.Tests.ps1` + `<old>.sh.test.sh` → `<NewVerbNoun>.test.ps1` + `<new-verb-noun>.test.sh`。例:
- `svn-log.Tests.ps1` → `Get-SvnLog.test.ps1`
- `svn-log.sh.test.sh` → `get-svn-log.test.sh`
- `pull-from-svn.Tests.ps1` → `Sync-FromSvn.test.ps1`
- `pull-from-svn.sh.test.sh` → `sync-from-svn.test.sh`
- ...全 17 對依 Group A mapping 對齊

**`resolve-iis-settings` test 處理(隨 source 搬到 Group I):**
- `resolve-iis-settings.Tests.ps1` → 搬到 `unit/scripts/lib/IisHelpers.test.ps1`(對齊新 source 位置 `scripts/lib/IisHelpers.ps1`)
- `resolve-iis-settings.sh.test.sh` → **刪除**(對應 `resolve-iis-settings.sh` trampoline 已刪,沒對象可測)

`_Common.ps1` 從 `unit/scripts/` 移出,搬到 `tests/lib/ScriptsCommon.ps1`(KD-8)。

### H. Test cases — hooks(對應 B,2 對)

| 舊 | 新 |
|---|---|
| hooks/posttooluse-enterworktree.Tests.ps1 | `hooks/Invoke-PostToolUseEnterWorktree.test.ps1` |
| hooks/posttooluse-enterworktree.sh.test.sh | `hooks/invoke-posttooluse-enterworktree.test.sh` |
| hooks/sessionstart.Tests.ps1 | `hooks/Invoke-SessionStart.test.ps1` |
| hooks/sessionstart.sh.test.sh | `hooks/invoke-sessionstart.test.sh` |

### I. Test cases — scripts/lib(對應 C)

| 舊 / 動作 | 新 |
|---|---|
| `unit/scripts-lib/` 目錄 | rename → `unit/scripts/lib/` |
| test_resolve_config_value_merge.ps1 + test_find_tools_strict_cut.ps1 | merge → `unit/scripts/lib/Common.test.ps1` |
|(新增,KD-6 補缺)| `unit/scripts/lib/common.test.sh` |
|(新增,KD-6 補缺)| `unit/scripts/lib/ApplicationHostHelpers.test.ps1` |
|(新增,KD-6 補缺)| `unit/scripts/lib/ps1-delegate.test.sh` |

### J. Docs / runs jargon 清理(KD-10)

| 舊 | 新 |
|---|---|
| tests/docs/phase1-scripts-schema.md | `tests/docs/script-tests-schema.md` |
| tests/docs/phase2-skills.md | `tests/docs/skill-tests.md` |
| tests/docs/phase2-session-plan.md | `tests/docs/skill-tests-session-plan.md` |
| tests/runs/v1.0.0/phase1-results.md | `tests/runs/v1.0.0/script-tests-results.md` |
| tests/runs/v1.0.0/phase2-results/ | `tests/runs/v1.0.0/skill-tests-results/` |
| tests/docs/fail-then-fix-process.md | 檔名不變,內文「Phase 1/2」全替換 |
| tests/docs/rollback-checklist.md | 檔名不變,內文「Phase 1/2」全替換 |
| tests/docs/budget-tracker-template.md | 檔名不變,內文「Phase 1/2」全替換 |
| tests/runs/v1.0.0/budget-tracker.md | 檔名不變,內文「Phase 1/2」全替換 |
| tests/runs/v1.0.0/known-issues.md | 檔名不變,內文「Phase 1/2」全替換 |
| tests/runs/v1.0.0/session-log.md | 檔名不變,內文「Phase 1/2」全替換 |
|(各 .md 內文)| "Phase 1" → "Script tests";"Phase 2" → "Skill tests" |

**⚠ Carve-out:** `plugins/turbo-plugin/skills/tp-setup/SKILL.md` 內的「Phase 1 / Phase 2 / Phase 3 / Phase 4」是該 skill **自己的 setup 流程步驟標籤**(完全跟 test infra 無關),**不在本次 jargon 清理範圍**。R10 / R11 機械替換時要白名單排除 `tp-setup/SKILL.md`。

---

## Requirements

- **R1.** Group A 17 對 prod entry script rename 完成(原 18 對,`resolve-iis-settings` 改歸 Group C lib),verb 全在 approved list。
- **R2.** Group B 2 對 hook script rename + `plugins/turbo-plugin/hooks/hooks.json` 內 `command:` 路徑同步指向新 `.sh` 名 + 各 hook `.sh` body 內 hard-code 的 `PS1_PATH=` 同步指向新 `.ps1` 檔名。
- **R3.** Group C 4 個 prod lib rename(Common / ApplicationHostHelpers PascalCase 化 + `resolve-iis-settings.ps1` 搬入 `scripts/lib/IisHelpers.ps1` + 5 個 caller dot-source path 同步更新 + 刪除 `resolve-iis-settings.sh` trampoline)。
- **R4.** Group D orchestrator rename + 新增 Bash sibling。
- **R5.** Group E 6 個 test lib rename(混合規則 KD-9)。
- **R6.** Group F fixture rename + 新增 reset-fixture.test.sh meta-test。
- **R7.** Group G 17 對 unit/scripts test case rename + `_Common.ps1` 移出到 `tests/lib/ScriptsCommon.ps1`,**6 個 caller dot-source path 同步更新**(`create-remote-test.Tests.ps1` / `pack-content.Tests.ps1` / `pull-from-svn.Tests.ps1` / `push-to-svn-commit.Tests.ps1` / `reset-remote-test.Tests.ps1` / `svn-ignore.Tests.ps1`,這 6 個檔的 dot-source 從 `$PSScriptRoot _Common.ps1` 改成 `tests/lib/ScriptsCommon.ps1` 的對應 walk-up 相對路徑)。
- **R8.** Group H 2 對 hook test rename。
- **R9.** Group I scripts-lib 改 nested + 兩 feature test merge + 補 3 個缺的 lib test。
- **R10.** Group J Phase1/Phase2 jargon 全 docs / runs / .md 內文清理。
- **R11.** 全 plugin command / skill body / README / CLAUDE.md / brainstorm doc / plan doc 內 script path / "Phase 1/2" reference 同步更新(**`plugins/turbo-plugin/skills/tp-setup/SKILL.md` 除外** — 該檔內「Phase 1-4」是 setup 流程步驟名稱,跟 test infra 無關,不替換)。
- **R12.** `Invoke-ScriptTests.ps1` + `invoke-script-tests.sh` 行為:recursive `tests/**/*.test.{ps1,sh}` discovery + infra gate 先跑 + prod test 後跑 + halt-on-infra-fail。**註:`*.test.{ps1,sh}` 是 shell glob 寫法**;PS 端 `Get-ChildItem -Filter` 不支援 brace expansion,實作要分兩次 `Get-ChildItem -Recurse -Filter '*.test.ps1'` 與 `'*.test.sh'`,或用 `-Include` 配 `*`。Bash 端 `find ... -name '*.test.ps1' -o -name '*.test.sh'` 或 shopt globstar 都可。
- **R13.** 新增 `tools/verify-approved-verbs.ps1`(用 `Get-Verb` 內建 cmdlet 比對檔名 verb 是否在 approved 清單)。對全 `plugins/turbo-plugin/scripts/**/*.ps1` 跑通過,0 個檔名 verb 不在 `(Get-Verb).Verb` 清單。同樣比對 `tests/**/*.ps1`。CI 跑此 script 不需 install module。

  **演算法 spec(三條 edge case 規則):**
  1. **路徑 whitelist** — `scripts/lib/` 與 `tests/lib/` 下的 `.ps1` 跳過 verb 檢查(KD-1 定義為 library noun-only)。其他位置必須是 Verb-Noun 形狀。
  2. **Case-sensitive PascalCase 比對** — verb 部分(第一個 `-` 之前)必須**大寫開頭**;小寫 verb(如 `build-web.ps1` 殘留)算違規,避免 implementer 漏改 silent PASS。
  3. **單 hyphen 限制** — Verb-Noun 區的 `.ps1` 只能有一個 hyphen(`Get-SvnLog` 合;`Get-Svn-Log` 違規)。
- **R14.** Verification:
  - `lint-ps-compat.ps1 -Path plugins/turbo-plugin/` 0 violations
  - `Reset-Fixture.ps1` idempotent
  - `Invoke-ScriptTests.ps1` discovery 掃 `tests/**/*.test.{ps1,sh}` 找到所有 test;**source-to-test 1:1 對應**(每個 prod source 都有對應 test,沒 test orphan,沒 source orphan;單 sibling 例外只算單側)
  - 改名後每個 test 個別跑 PASS
  - Hook script 配置在 Claude Code 重新觸發測試:`Invoke-PostToolUseEnterWorktree` 在 EnterWorktree tool call 後被觸發
  - **Build-SeedRepo dump audit 記錄存在**:`tests/docs/script-tests-schema.md` 含 `## Build-SeedRepo audit` 段,記錄 dump file path + dump file SHA + audit commit hash + audited by + audit date + verified facts(R1-R20 revision 各自 commit message / author / 預期檔內容);**且 dump file 當前 SHA 等於 audit 記錄裡的 SHA**(若不等表示有人 regenerate dump 沒重做 audit,verification fail)

---

## Acceptance Examples

- **AE1.** *(R1)* Given `scripts/pull-from-svn.ps1`,when rename 完成,then `scripts/Sync-FromSvn.ps1` 存在,`scripts/pull-from-svn.ps1` 不存在,且 `Get-Verb 'Sync'` 返非空。
- **AE2.** *(R2)* Given `plugins/turbo-plugin/hooks/hooks.json` 內 `PostToolUse` 與 `SessionStart` 兩條 hook config,when rename 完成,then 三件事同時成立:(a) `command:` 含 `bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/invoke-posttooluse-enterworktree.sh"` 及對應 `invoke-sessionstart.sh`,(b) 該兩個 `.sh` 檔存在,(c) 每個 `.sh` body 內 `PS1_PATH=` literal **byte-for-byte**(含 PascalCase 大小寫)指向對應新 `.ps1` 名(`Invoke-PostToolUseEnterWorktree.ps1` / `Invoke-SessionStart.ps1`),且該 `.ps1` 檔存在。Negative case:故意把某 hook `.sh` 的 `PS1_PATH` 維持舊小寫,當在 case-sensitive filesystem(Linux / macOS)觸發該 hook,應 fail 且訊息含「No such file」。
- **AE3.** *(R3)* Given `scripts/lib/common.ps1`,when 跑 `Get-Content scripts/lib/Common.ps1`,then 內容跟 rename 前 byte-equal。
- **AE4.** *(R4 + R9)* Given `Invoke-ScriptTests.ps1`,when 跑 `Get-ChildItem -Recurse tests/**/*.test.ps1`,then 同時找到 `Common.test.ps1` / `Invoke-SessionStart.test.ps1` / `Sync-FromSvn.test.ps1` 等典型 case。3 個新 lib test 至少覆蓋:
  - `unit/scripts/lib/common.test.sh` ≥ 4 case(`probe_git_version` / `get_normalized_absolute_path` / `get_main_worktree` / `test_is_submodule` 各 1)
  - `unit/scripts/lib/ApplicationHostHelpers.test.ps1` ≥ 3 case(讀 `applicationhost.config` / 找 binding section / parse port number 各 1)
  - `unit/scripts/lib/ps1-delegate.test.sh` ≥ 3 case(成功 dispatch 一個簡單 .ps1 / 不存在 .ps1 報錯 / passthrough exit code 各 1)
- **AE5.** *(R5)* Given `tests/lib/`,when rename 完成,then 包含 `AssertHelpers.ps1` + `Write-TrackingRow.ps1` + `Get-ScriptTestStatus.ps1` + `Get-RawCommitDump.ps1` + `ScriptsCommon.ps1` + `AssertHelpers.test.ps1`,且 `Get-Phase1Status` 字串不出現在任何 `.ps1` 內部。
- **AE6.** *(R6 + R8)* Given `Reset-Fixture.ps1` 跟 `reset-fixture.sh` 修改檔,when 跑 `Reset-Fixture.test.ps1` + `reset-fixture.test.sh`,then 雙方 case 全 PASS;若 .sh 改壞,`reset-fixture.test.sh` 抓出。
- **AE7.** *(R9)* Given `unit/scripts/lib/Common.test.ps1`,when 跑,then **包含**原 7 case `resolve_config_value_merge` + 12 case `find_tools_strict_cut` = 19 case 全 PASS。
- **AE8.** *(R10)* Given 任何 .md 在 `tests/docs/` 或 `tests/runs/v1.0.0/`,when grep,then 找不到字串 "Phase 1" / "Phase 2"(除非引號內歷史 reference 標明已 rename)。
- **AE9.** *(R12)* Given `tests/lib/AssertHelpers.test.ps1` 故意改壞(`Assert-Equal` 永遠回 true),when 跑 `Invoke-ScriptTests.ps1`,then orchestrator 在 infra gate 階段 halt,**不跑** prod test,exit code 非 0,message 包含 "infra gate failed"。
- **AE10.** *(R13)* Given `scripts/**/*.ps1`,when 跑 `tools/verify-approved-verbs.ps1 -Path plugins/turbo-plugin/scripts`,then exit code 0 + 訊息「all verbs approved」。覆蓋 4 種 negative case:
  - **(a) unapproved verb**:故意建 `Pull-Foo.ps1`,then exit 非 0 + 列出該檔名 + 違規 verb `Pull`
  - **(b) 小寫 verb 殘留**:故意建 `build-web.ps1`(小寫,模擬漏改),then exit 非 0 + 訊息「verb must be PascalCase」
  - **(c) lib whitelist 生效**:`scripts/lib/Common.ps1` 跟 `tests/lib/AssertHelpers.ps1` 不算違規(雖然沒 hyphen)
  - **(d) 多 hyphen**:故意建 `Get-Svn-Log.ps1`,then exit 非 0 + 訊息「single hyphen only」
- **AE11.** *(R14)* Given 全部 rename + content move 完成,when 跑 `Invoke-ScriptTests.ps1`,then 全 test PASS、exit code 0、discovery 數 = source 數(source-to-test 1:1 對應,單 sibling 例外只算單側)。
- **AE12.** *(R1 + R3)* Given Group A 與 Group C 內每個有 trampoline pattern 的 `.sh`(內含 `exec "...ps1-delegate.sh" <script-name> "$@"` 那行),when grep 該字串 argument,then 每個 `.sh` 的 `<script-name>` byte-for-byte 等於對應新 `.ps1` 的 basename(含 PascalCase 大小寫)。Given 故意把某 `.sh` 內字串維持舊小寫,when 在 case-sensitive filesystem(Linux / macOS)跑該 `.sh`,then 應 fail 且訊息含「No such file」。

---

## Success Criteria

**人類觀點(plugin 作者 / 未來 contributor):**
- 全 `plugins/turbo-plugin/` 下的 `.ps1` 跟 `.sh` 命名一致 — entry script 用 Verb-Noun PascalCase,lib 用 noun-only PascalCase,Bash 都 kebab-lowercase。看到任何新檔能直接判斷該叫什麼。
- 7 個 unapproved verb 全清除;PowerShell 官方 `(Get-Verb).Verb` 清單對得起每個檔名 verb。
- 「Phase 1/2」內部 jargon 消失,改用對外清楚的「Script tests / Skill tests」。

**下游 implementer 觀點:**
- `tools/verify-approved-verbs.ps1` 可在 CI 上跑(無外部 module 依賴),用來持續守住命名規則。
- `Invoke-ScriptTests.ps1` discovery 自動找全 test,新增 test 直接放到對應位置即可,不用更新 orchestrator。
- ce-plan 拿這份 brainstorm doc 可直接產 plan(4-phase 拆法已建議);AE1-AE12 每條都有具體 verification path。

---

## Scope Boundaries

**In scope:**
- 全 `plugins/turbo-plugin/scripts/` + `plugins/turbo-plugin/tests/` 下 `.ps1` / `.sh` rename + 內部 reference 同步
- `plugin.json` 內 hook config path 更新
- 全 plugin command / skill body 內 script path 更新
- README / CHANGELOG / CLAUDE.md / brainstorm doc / plan doc 內 reference 更新
- `tests/docs/` 內文 Phase 1/2 jargon → Script/Skill tests rename
- 新增 `invoke-script-tests.sh`(orchestrator Bash sibling)
- 新增 3 個 lib test + 1 個 fixture meta-test(`reset-fixture.test.sh`)
- merge `common.ps1` 兩 feature test 為單一 `Common.test.ps1`

**Out of scope:**
- 既有 turbo-plugin script 內部 logic 變更(本次只是 rename + path ref)
- **CI wiring(GitHub Actions 設定 PR 前跑 `verify-approved-verbs.ps1` + 全 test)** — 本 PR 只新增 `tools/verify-approved-verbs.ps1` 這個工具檔本身,實際 CI workflow(`.github/workflows/*.yml`)留給後續 PR 處理。承認 `tools/` 是永久新增的 plugin surface 即使本 PR 後沒有 caller
- 補 `assert-helpers.sh`(KD-12 已決不補)
- 補 `Build-SeedRepo.test.ps1`(KD-13 已決不補)
- 補 `sh-delegate.ps1`(KD-11 已決不補)
- 補 `applicationhost-helpers.sh`(KD-11 已決不補)
- Skill test(Phase 2)真實執行(ship 後另開 session)
- 1.0.0 → 1.0.1 version bump(plan 一律 v1.0.0 ship)

---

## Considered Alternatives

### Minimal-rename(僅改 unapproved verb,維持 kebab)— 已拒絕

**內容:** 只改 7 個 unapproved-verb 檔,**保持 kebab-lowercase**(.ps1 跟 .sh 都不變大小寫):
- `pull-from-svn.{ps1,sh}` → `sync-from-svn.{ps1,sh}`
- `pack-content` → `compress-content`
- `cleanup-orphan-iis` → `remove-orphan-iis`
- `compute-project-identity` → `get-project-identity`
- `check-*` ×2 → `test-*`
- `emit-tracking-row` → `write-tracking-row`
- `run-phase1` → `invoke-script-tests`
- 其它檔(包含 PascalCase 化、Phase1/2 jargon 清理、orchestrator gate 行為、lib 重新分類)全留 v1.1

**規模:** ~30 個檔(對比現方案 ~100 個檔)。

**拒絕理由:**
- 趁 v1.0 ship 前無 publish / 無 user / 無 compat 包袱的時機點一次做完,避免未來再回頭碰
- 全方案的 Phase1/Phase2 jargon 清理 + orchestrator gate + lib 分類雖然各自獨立可拆,但實際 implement 時 mechanical 動作大重疊(都動 path / dot-source / discovery glob),拆兩 PR 反而 review overhead 高


---

## Dependencies / Assumptions

- 前置 commit:`afad1fa` 在 `feat/turbo-plugin-v1.0` branch
- 本次重整也屬 v1.0.0 範圍,plugin version **不 bump**
- 重整 commit message 用 `refactor(turbo-plugin): ...` 前綴
- Subagent 工作於 worktree isolation,結束後 orchestrator merge + clean up
- 已驗證 baseline:lint 0 violations / Reset-Fixture idempotent / 既有測 PASS
- 假設使用者尚未 publish v1.0.0;改名不需 backwards-compat shim
- **時機 trade-off 已知:** 在 v1.0 release 前夕做 ~100 檔 refactor 跟 ship-readiness work 競爭資源,reviewer 認為更穩做法是「先 ship v1.0 kebab 命名,留到 v1.1 加 deprecation shim refactor」。**選擇現在做** — 趁熱、無 compat 包袱、不用未來再回頭碰

---

## Risks

- **High touch count(~100 個檔)** — single subagent 一次 rewrite 風險高,建議拆 phase:
  - Phase A:Group A + B + C(prod script,影響 command / skill / hook config)
  - Phase B:Group D + E + F(orchestrator + test lib + fixture)
  - Phase C:Group G + H + I(test cases)
  - Phase D:Group J + R10/R11(docs jargon clean)
  - 每 phase 跑完 lint + 試跑 Invoke-ScriptTests.ps1 確認再下一 phase
- **Hook config path 改錯 → Claude Code 安裝後 hook 不觸發** — AE2 需嚴格驗證
- **PSScriptAnalyzer 可能挖出其他既存 violation** — 不在本範圍處理,只確認 PSUseApprovedVerbs 0 violation
- **`.test.sh` 內若 hard-code 引用 `.test.ps1` sibling(罕見但可能)需同步改**
- **`.sh` trampoline 的 case 一致性風險** — 每個 entry `.sh` 內傳給 `ps1-delegate.sh` 的字串 arg(如 `exec "...ps1-delegate.sh" build-web "$@"`)在 case-insensitive NTFS 上不會炸,但在 case-sensitive Linux / macOS filesystem 上 `build-web` 找不到 `Build-Web.ps1` → silent 失敗只有跨平台跑時抓得到。AE12 驗證這點。
- **In-flight Claude Code session cache** — rename PR merge 後若有未結束的 Claude session,session 內 cache 的舊 script 路徑會失效;agent 呼舊路徑會 tool error 但訊息可能不清楚是「rename」。緩解:CHANGELOG 標註 breaking rename;merge 後 user 主動 `/clear` 或開新 session。

---

## Resume protocol

無 outstanding question(都已 resolve)。下一步:

1. User 看完此 doc,confirm 所有 KD + Rename Mapping 無誤
2. 直接 dispatch `/compound-engineering:ce-plan` 從此 brainstorm doc 產 plan(建議拆 4 phase A-D)
3. plan headless review
4. /ce-work 執行 phase A-D
5. Verification(AE1-AE12)+ commit + clean up worktree
