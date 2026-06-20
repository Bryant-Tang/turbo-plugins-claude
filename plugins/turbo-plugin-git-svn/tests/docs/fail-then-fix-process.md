# F5 Fail-then-Fix Process

turbo-plugin v1.0 PR-readiness 手動測試的 **F5 fail-then-fix loop** 流程細節。
任 Script tests / Skill tests case 標 FAIL → 走本流程修復 → re-run 直到 PASS,或在 3 次仍 FAIL 後
escalate (R32)。

> 對應 plan:
> [`docs/plans/2026-05-27-001-feat-turbo-plugin-v1.0-manual-test-plan.md`](../../plans/2026-05-27-001-feat-turbo-plugin-v1.0-manual-test-plan.md)
> — F5 box(plan §Architecture flow diagram)、R32 / R33(plan §Requirements)、
> Trade-off 4 resolution(plan §K-Decision)。

---

## F5 觸發條件

- 任一 Script tests case(`P1-<script>-<case>`)在 per-release tracking doc
  (`runs/<release>/script-tests-results.md`,schema 來源 `script-tests-schema.md`)的對應
  row 出現 `result: FAIL`。
- 任一 Skill tests case(`P2-<skill>-<case>`)在 tracking doc(`skill-tests.md` —— U5 產生)
  的對應 row 出現 `result: FAIL` 或 `PARTIAL` 且使用者判定為 bug 而非 prompt 不清。
- 觸發後 **立即停止 current 測試類別的後續 case 推進**(orchestrator 不繼續排程下一個 case
  ,避免 fixture / shared state 污染擴散),先走 root-cause 流程。

---

## Root-cause 流程

1. 讀 case 對應的 script(`plugins/turbo-plugin-git-svn/scripts/<name>.ps1` / `.sh`)或 SKILL.md
   (`plugins/turbo-plugin-git-svn/skills/<skill>/SKILL.md`),找出測 case 期待的行為 vs. 實際輸出
   差異。
2. 讀 case 對應的 test driver(Script tests:`plugins/turbo-plugin-git-svn/tests/unit/scripts/<script>.Tests.ps1` 或
   `<script>.sh.test.sh`(hook script 在 `unit/scripts/hooks/` 子目錄);Skill tests:U5 產生的 `prompts/<skill>-case-<N>.md`),確認測試
   本身沒有 bug。
3. 在 fresh fixture 上 manual 重現 FAIL:
   - Script tests:`plugins/turbo-plugin-git-svn/tests/fixtures/reset/Reset-Fixture.ps1` 重置 →
     直接跑該 script + 相同 args(test driver 第一段 `arrange` block 已記錄)。
   - Skill tests:照 prompt 重跑 skill(注意 fixture 延續策略,見 Trade-off 1 resolution)。
4. 鎖定 bug 範圍:
   - `scripts/<name>.ps1` / `.sh` 內部邏輯
   - `scripts/lib/common.ps1` / `common.sh` shared helper(影響面大,見下文 Suspension trigger)
   - `skills/<skill>/SKILL.md` 流程描述
   - env-var contract(SKILL ↔ script 之間欄位名 / 預設值不一致)
   - 真實的 fixture 缺漏(回去補 `plugins/turbo-plugin-git-svn/tests/fixtures/base/`)
5. 若懷疑 root cause 在 fixture 污染(Trade-off 1 escalation 路徑):強制
   fresh-fixture re-run 該 case;PASS 則升級為 fixture isolation 不夠的真實
   bug,寫進 known issue 而非 fix script。

---

## 修復規則

- **Branch**:fix commit 直接在 `feat/turbo-plugin-v1.0` branch(這是 v1.0 PR 的 head
  branch,fail-then-fix 累積的 fix 都會走進這條 branch 的 squash-merge)。**不**另開
  branch / 不 cherry-pick。
- **Commit prefix**:`fix:` (或 `fix(turbo-plugin): ...` scope 形式),例:
  ```
  fix(turbo-plugin): svn-log codepage 950 中文輸出
  ```
- **CHANGELOG convention**(PL-4 plan correction):
  - 寫進 `plugins/turbo-plugin-git-svn/CHANGELOG.md` 的 **`[Unreleased]` section** 的 `Fixed:` 子分類。
  - **不**寫進 `[1.0.0]` section。`[1.0.0]` 是 immutable release record。
  - squash-merge v1.0.0 PR 時把 `[Unreleased]` 整段內容 move 進 `[1.0.0]`(per
    [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/) 慣例)。
  - **PL-4 取代** 早期 plan A6 hedge(認為 `[1.0.0]` 還沒 ship 所以 mutable 可寫)。
    現確認改採 `[Unreleased]` 路徑,因為 `[1.0.0]` 應為 immutable release record。
- **Version bump**:fail-then-fix 過程中**不**對 `plugin.json` `version` 重複 bump
  (尚未發布)。1.0.0 整段在 squash-merge 才 finalize。
- **不**修改:`plugins/turbo-plugin-git-svn/tests/` 內 test driver、`plugins/turbo-plugin-git-svn/tests/docs/` 內 tracking doc
  schema —— 修改這些屬於 test plan 變更,要回上層 plan doc 處理。
  - 例外:tracking doc 內 `actual` / `result` / `evidence` 欄位是 append-only
    執行紀錄,fail-then-fix 期間正常更新。

---

## Re-run + impact 評估

修完一個 case 後,根據改動 **scope** 決定 re-run 範圍。

### 改動 scope → re-run 範圍對照表

| 改動 scope | re-run 範圍 | 理由 |
|---|---|---|
| 單一 `scripts/<name>.ps1` / `.sh` 內部邏輯 | 該 script 所有 case(`P1-<script>-*`) | bug 可能不只觸發在當前 case |
| `scripts/lib/common.ps1` / `common.sh`(shared helper) | **此 unit(U3 / U4)所有 prior PASS case** + Skill tests 已跑過受影響 skill case | helper 改動 blast radius = 全部呼叫者 |
| `scripts/lib/applicationhost-helpers.ps1` | 所有 IIS lifecycle scripts(`start-iis` / `stop-iis` / `cleanup-orphan-iis` / `resolve-iis-settings` / `check-iis-listening`)的 prior PASS case | helper 專屬 IIS scripts |
| `skills/<skill>/SKILL.md` 流程描述 | 該 skill 所有 Skill tests prior PASS case | skill flow 改變 |
| env-var contract(SKILL ↔ script 欄位名 / 預設值) | **跨 unit** 所有 prior PASS case(Script tests + Skill tests 都要 re-run) | contract 改動跨整個 plugin |
| `plugins/turbo-plugin-git-svn/tests/fixtures/base/` 內容(真實補檔案) | 已跑過所有 Script tests case + Skill tests 已跑過 skill case | fixture 變更影響全部後續 case |
| 單一 case 的 test driver(`.Tests.ps1` / `.sh.test.sh`) | 該 case only | test logic only |
| Tracking doc / process doc | 不 re-run(純 doc) | 無 runtime impact |

### Impact radius heuristic

優先 re-run 順序(orchestrator 視 budget 自選):

1. **直接受影響**:同 script / 同 skill 的其他 case(高機率 catch regression)。
2. **shared helper consumer**:`grep -l 'common.ps1\|common.sh'` 列出的所有 caller。
3. **fixture sensitive**:case description 含「中文 / 編碼 / fixture state」關鍵字者。
4. **rest of unit**:該 unit 內剩餘 prior PASS case。
5. **cross-unit**:其他 unit 已跑完 case(只在 env-var contract / common.ps1 改動時觸發)。


跨 case 影響不確定時 default conservative 全 re-run;budget 緊則 surface 給使用者
AskUserQuestion 確認跳過哪一層。

---

## R32 Escalation

> 對應 plan §Requirements R32 + Trade-off 4 resolution。

當同一 case 已 fix **3 次** 仍 FAIL:

1. orchestrator 在 per-release tracking doc(`runs/<release>/script-tests-results.md` 對應 script
   section / `runs/<release>/skill-tests-results.md` 對應 skill section)的該 case row 把
   `result` 改為 `FAIL-known`。
2. 同 row `evidence` 欄寫 `修復 attempt #1 commit <hash1>, #2 <hash2>, #3 <hash3> 仍 FAIL;
   escalation: pending user confirmation`。
3. 在同一 tracking doc 的 `## Known Issues` section append 一條 bullet:
   ```
   - **P1-svn-log-中文** (FAIL-known after 3 fix attempts) — root cause: ...;
     follow-up issue: ...;user-confirmed not blocking v1.0 PR: <Y/N pending>
   ```
4. orchestrator emit AskUserQuestion 給使用者:
   - 「是否將 `<case ID>` 列入 v1.0 Known Issues 不 block PR?」
   - 三選:
     - **(a) 接受 known issue**:tracking doc `escalation` 欄改 `user-confirmed not
       blocking`,case fix 工作結束、繼續下一個 case。同時更新 PR description 的
       `## Known Issues` section。
     - **(b) 再試一次(最多 1 次延長)**:fix attempt #4。若再 fail 則強制走 (a) 或 (c)。
     - **(c) Block PR**:`feat/turbo-plugin-v1.0` PR 卡住,擇日重新 plan / 拉大 scope
       重做設計。
5. 在 v1.0 PR description 的 `## Known Issues` section 同步列入 case 摘要 +
   follow-up issue(plan 階段可建議)。

---

## Suspension trigger (optional, planning-time N = 3)

> 對應 plan Trade-off 4 partial resolution(R20 / K-Decision 5)。

**觸發條件**:在跑某個 unit(U3 / U4 / Skill tests 某 skill group)期間,
**連續 3 次** fix 改到 shared code(`common.ps1` / `common.sh` / SKILL.md framework /
env-var contract)。

**動作**:

1. orchestrator 暫停 case-by-case fail-then-fix loop。
2. **切換到 batch mode**:本 unit / skill group 剩下未跑 case 一次性全跑完(不論 FAIL),
   全部 FAIL 與 PASS 結果都先 emit 到 tracking doc。
3. 全跑完後,根據累積 FAIL row 集中 root-cause:多個 case 同樣 fail pattern 通常表示
   shared code 還有問題,一次性 fix 比 case-by-case 修便宜。
4. Batch fix 後對本 unit / skill group 做 **一次性 re-validate**:全部 case 一次跑完。
5. 仍 FAIL 的 case 回到正常 R32 路徑(累計 fix attempt 從 0 重新計,因為 batch fix 是新
   修復 vector)。

---

## F5 Walk-through 範例(planning simulation)

模擬 case `P1-svn-log-中文`:

1. **FAIL**:tracking doc emit `result: FAIL | actual: stdout 中文變 ?????`。
2. **F5 觸發**:orchestrator 停 Script tests 後續 case,進 root-cause。
3. **Root-cause**:讀 `svn-log.ps1` → 發現某段 `Out-String` 沒走 UTF-8 → 中文在
   PS 5.1 + codepage 950 console 變 `?`。
4. **Fix**:`svn-log.ps1` 改用 `[Console]::OutputEncoding = [Text.UTF8Encoding]::new()`
   bracket;commit:
   ```
   fix(turbo-plugin): svn-log codepage 950 中文輸出
   ```
   寫進 `CHANGELOG.md` `[Unreleased]` `Fixed:` 子分類。
5. **Re-run**:`P1-svn-log-中文` PASS。
6. **Impact 評估**:改動只在 `svn-log.ps1`(不在 common.ps1) → 只 re-run 該 script 其他 case
   (`P1-svn-log-pagination` 等)。全 PASS。
7. **Script tests 繼續**:orchestrator 繼續排下一個 case。

若上述 step 4 / 5 在 1st fix 仍 FAIL → 走 2nd fix(改 XML parser 路徑);仍 FAIL → 3rd
fix(改 `svn log --xml`);3 次仍 FAIL → **R32**:tracking doc `result: FAIL-known` + Known
Issues append + AskUserQuestion 給使用者。

若 1-3 次 fix 全在改 `common.ps1`(例如某 helper 對中文路徑處理 bug) → 觸發
**Suspension trigger**:切 batch mode → svn-log 剩下 case 全跑完看是否同樣 fail pattern
→ 一次性修 `common.ps1` → re-validate。
