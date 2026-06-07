# Skill tests — Manual Test Results (v1.0.0 PR validation)

> **Per-release execution evidence** — turbo-plugin v1.0.0 release PR validation 的
> Skill tests 手動測試實際執行紀錄。Per-skill case spec / prompt 範本 / 失敗 patterns 來源見
> [`../../docs/skill-tests.md`](../../docs/skill-tests.md)。
>
> 本檔由使用者跑每個 Skill tests session 時手動 append row 到對應 `### <skill>` section
> 下方的 `### Row table`。每跑完一個 case row 即新增一筆。

---

## Tracking schema (簡覽)

| 欄 | 說明 |
|---|---|
| `case ID` | `P2-<skill-stem>-<case-N>` |
| `desc` | case 的短描述 |
| `fixture` | 預期 fixture pre-state |
| `prompt summary` | 使用者貼進 Claude Code 的 prompt 摘要 |
| `expected` | 預期 skill 觸發 / agent invocation chain / file write 等 |
| `observation` | 使用者轉述的 agent 行為與觀察錨點 |
| `result` | `PASS` / `FAIL` / `PARTIAL` / `FAIL-known` / `SKIP` / `BLOCKED-BY:...` |
| `evidence` | chat snippet / file diff path / agent 輸出 snippet / 修復 commit hash |

完整 schema + 案例 + Row 範例見
[`../../docs/skill-tests.md`](../../docs/skill-tests.md)。

---

## Per-skill row tables

### tp-setup

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-pull-from-svn

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-push-to-svn

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-create-remote-test

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-reset-remote-test

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-build-dotnet-framework-web

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-run-dotnet-framework-web

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-stop-dotnet-framework-web

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-publish-dotnet-framework-web

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-cleanup-orphan-iis

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-suggest-ignore

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-svn-log

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-csharp-comment

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-js-comment

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-merge-main-into-all

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

### tp-db-management

| case ID | desc | fixture | prompt summary | expected | observation | result | evidence |
|---|---|---|---|---|---|---|---|

---

## Known Issues

(R32 escalation 用 — Skill tests manual case 確認的 plugin bug 列在此。完整 cross-release
known issue 整理見 [`known-issues.md`](./known-issues.md)。)
