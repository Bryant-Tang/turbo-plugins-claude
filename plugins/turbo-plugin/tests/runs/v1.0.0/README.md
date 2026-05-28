# turbo-plugin v1.0.0 — PR Validation Run

本目錄為 **turbo-plugin v1.0.0 release PR readiness 測試的執行紀錄**(per-release
execution evidence)。所有檔案結構衍生自上層 `../../docs/` 的 schema templates,
本目錄填入實際執行結果。

## 目錄結構

```
runs/v1.0.0/
├── README.md             # 本檔
├── phase1-results.md     # Phase 1 自動測試結果(由 Run-Phase1.ps1 append rows)
├── phase2-results.md     # Phase 2 手動測試結果(使用者跑 session 時手動填 rows)
├── session-log.md        # 每 session 跑的 freeform notes
├── budget-tracker.md     # Phase 1 hr + Phase 2 session 累計
└── known-issues.md       # 本 release 期間發現的 R32 FAIL-known 與 plugin bug
```

## Schema 來源

- Phase 1 row schema + 中文字典 + per-script section:
  [`../../docs/phase1-scripts-schema.md`](../../docs/phase1-scripts-schema.md)
- Phase 2 row schema + 14 skill case spec + prompt 範本:
  [`../../docs/phase2-skills.md`](../../docs/phase2-skills.md)
- Phase 2 session 切分計畫:
  [`../../docs/phase2-session-plan.md`](../../docs/phase2-session-plan.md)
- Phase 2 rollback checklist:
  [`../../docs/rollback-checklist.md`](../../docs/rollback-checklist.md)
- Fail-then-fix(F5)流程細節:
  [`../../docs/fail-then-fix-process.md`](../../docs/fail-then-fix-process.md)
- Budget tracker template(本目錄 budget-tracker.md 的 source):
  [`../../docs/budget-tracker-template.md`](../../docs/budget-tracker-template.md)

## 如何跑 Phase 1

```powershell
# 從 repo root
powershell -NoProfile -ExecutionPolicy Bypass -File `
  plugins/turbo-plugin/tests/Run-Phase1.ps1
# 預設 -RunDir = plugins/turbo-plugin/tests/runs/v1.0.0
# 預設 -TargetDoc = <RunDir>/phase1-results.md
```

## 如何跑 Phase 2

依 `../../docs/phase2-session-plan.md` 的 session 切分,使用者:

1. 開新的 Claude Code session(在 `C:\Turbo\test-turbo-plugin` cwd)
2. 從 `../../docs/phase2-skills.md` 對應 skill section 抄 prompt 範本
3. 跑該 case,觀察錨點(觸發 / agent invocation / file write 等)
4. 轉述觀察給 orchestrator → orchestrator 寫 row 到 `phase2-results.md` 對應 skill section
5. 同 session 內可跑數個 case;每 session 結束在 `session-log.md` 寫 freeform notes
6. 累計 hr / session 次數到 `budget-tracker.md`
