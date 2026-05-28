# Budget Tracker — Phase 1 + Phase 2 (TEMPLATE)

turbo-plugin PR-readiness 手動測試 Phase 1(orchestrator wall time hr)與 Phase 2
(使用者 session 計數)的 budget 累計與 escalation trigger 紀錄 **template**。
Per-release 實際填值的 copy 在 `../runs/<release>/budget-tracker.md`。

> 對應 plan:
> [`docs/plans/2026-05-27-001-feat-turbo-plugin-v1.0-manual-test-plan.md`](../../../../docs/plans/2026-05-27-001-feat-turbo-plugin-v1.0-manual-test-plan.md)
> — R33 budget caps、R32 escalation、Trade-off 4 resolution(K-Decision)。
>
> 相關:[`fail-then-fix-process.md`](./fail-then-fix-process.md) — F5 流程 + R32 / suspension trigger 細節。

---

## Budget caps

| Phase | 度量單位 | Cap | 超過動作 |
|---|---|---|---|
| Phase 1 | orchestrator wall time (hr) | ~20 hr | AskUserQuestion「scope-cut?」三選 |
| Phase 2 | 使用者 session 次數 | ~12 session | AskUserQuestion「scope-cut?」三選 |

「scope-cut?」三選選項:

- **(a)** 砍剩下 case scope(明示哪些 script / skill 進 follow-up)
- **(b)** 繼續但跳過 X 類別(例:跳過所有 IIS lifecycle Phase 2 case)
- **(c)** 取消 PR 等下次(回 plan 階段重新切分 v1.0 / v1.1 scope)

---

## Phase 1 hour log

orchestrator session 跑 Phase 1 case 時的 wall time 累計。每次中斷 / 切換 / 繼續都 append 一 row。

| session | start time | end time | duration (hr) | scripts touched | notes |
|---|---|---|---|---|---|
| _(example)_ S1 | 2026-05-28 09:00 | 2026-05-28 12:30 | 3.5 | compute-project-identity, get-target-url, check-iis-listening | 3 個 read-only script 全 PASS |
|  |  |  |  |  |  |
|  |  |  |  |  |  |
|  |  |  |  |  |  |
|  |  |  |  |  |  |
|  |  |  |  |  |  |
|  |  |  |  |  |  |
|  |  |  |  |  |  |

**累計**:_(填 sum 的 duration,例 3.5 / 20)_

---

## Phase 2 session log

使用者執行 Phase 2(skill prompt 走 real session)的 session 計數。每個 session
不論時長都算一次,duration 為估計值供 reconciliation 用。

| session # | duration (min) | skills (cases) covered | result PASS / FAIL / PARTIAL | notes |
|---|---|---|---|---|
| _(example)_ 1 | 35 | tp-setup (cases 1, 2) | PASS, PASS | LSP / CE 安裝 OK |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |
|  |  |  |  |  |

**累計**:_(填 sum 的 session count,例 1 / 12)_

---

## Escalation triggers reached?

每跑完一個 case / session 後 orchestrator 檢查下方 checkbox。任一被 tick 立即 emit
AskUserQuestion / 切 batch mode / mark FAIL-known。

- [ ] **Phase 1 累計 hour > 20** → orchestrator emit AskUserQuestion「scope-cut?」三選
  (砍剩下 scope / 繼續但跳過 X 類別 / 取消 PR 等下次)。(R33)
- [ ] **Phase 2 累計 session > 12** → 同上 AskUserQuestion「scope-cut?」三選。(R33)
- [ ] **同 case fix > 3 次仍 FAIL** → mark `FAIL-known` 在對應 tracking doc + Known
  Issues section + AskUserQuestion 確認是否 block PR。(R32,細節見
  [`fail-then-fix-process.md`](./fail-then-fix-process.md) §R32 Escalation)
- [ ] **連續 3 次 fix 觸到 shared code**(`common.ps1` / `common.sh` /
  SKILL.md framework / env-var contract) → switch to batch mode:本 unit 剩下 case 全跑
  完 → 一次性 fix + re-validate。(suspension trigger,細節見
  [`fail-then-fix-process.md`](./fail-then-fix-process.md) §Suspension trigger)

---

## Final budget reconciliation

> Phase 1 + Phase 2 全部跑完 + v1.0 PR 開出後填本 section。

| 項目 | 計畫 | 實際 | 偏差 | 原因 |
|---|---|---|---|---|
| Phase 1 wall time (hr) | ~20 | _(actual)_ | _(diff)_ | _(notes)_ |
| Phase 2 session count | ~12 | _(actual)_ | _(diff)_ | _(notes)_ |
| FAIL-known case 數 | 0 | _(actual)_ | _(diff)_ | _(notes)_ |
| 觸發 suspension trigger 次數 | 0 | _(actual)_ | _(diff)_ | _(notes)_ |
| 觸發 scope-cut AskUserQuestion | 0 | _(actual)_ | _(diff)_ | _(notes)_ |

**Follow-up actions**(下次 v1.x plan 參考):

- _(actual)_
