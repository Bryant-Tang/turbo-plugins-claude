# Known Issues — turbo-plugin v1.0.0 PR Validation

本檔記錄 v1.0.0 PR validation 期間發現的 known issue:

1. **R32 FAIL-known**:Script tests / Skill tests case 經 3 次 fix attempt 仍 FAIL,被升級為
   `FAIL-known` 並 acknowledge 為「不 block PR,進 follow-up backlog」。
2. **Skill tests manual case 確認的 plugin bug**:Skill tests 跑 real Claude Code session
   時觀察到 agent / skill / script 的問題,記為待修 backlog。

> Fail-then-fix 流程細節見
> [`../../docs/fail-then-fix-process.md`](../../docs/fail-then-fix-process.md)。

---

## 格式

每個 known issue 一個 `##` section:

```markdown
## I-<n> — <一句話描述>

- 發現時間: YYYY-MM-DD
- 類別: Script tests / Skill tests
- 對應 case ID: P1-... / P2-...
- 症狀: ...
- Fix attempts: ...
- 為何 acknowledge: ...
- Follow-up issue / commit: ...
```

---

## (尚未發現)

_v1.0.0 PR validation 跑完前若有 FAIL-known 或 plugin bug 在此 append section。_
