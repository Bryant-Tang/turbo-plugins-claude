# Script tests — Results (v1.0.0 PR validation)

> **Per-release execution evidence** — turbo-plugin v1.0.0 release PR validation 的
> Script tests 自動測試實際執行紀錄。Row schema + 中文字典 + per-script section 來源見
> [`../../docs/script-tests-schema.md`](../../docs/script-tests-schema.md)。
>
> 本檔 append-only,`Invoke-ScriptTests.ps1` 每跑一個 case emit 一個 markdown table row 到
> 對應 `### <script>` section 下方。同 case 跑多次留多 row;Get-ScriptTestStatus.ps1
> dedup 時取最後一個為 authoritative(R29)。

---

## Tracking schema

每個 Script tests case 跑完後 orchestrator emit 一個 row 到下方對應 script section。schema:

| 欄 | 說明 |
|---|---|
| `case ID` | `P1-<script-stem>-<short-desc>` (例:`P1-svn-log-中文`) |
| `section` | 對應 script 名 (`svn-log`、`pull-from-svn` 等) |
| `fixture` | 預期 fixture 狀態 (`fresh-base` / `r21-dirty` / `[iis]=false` 等) |
| `expected` | 該 case 預期行為摘要 |
| `actual` | 觀察結果 (exit code + stdout 關鍵字 / 中文 byte hash) |
| `result` | `PASS` / `FAIL` / `FAIL-known` / `SKIP` / `BLOCKED-BY:...` |
| `evidence` | NUnit XML 行 / stdout snippet / 修復 commit hash |

> 完整 schema 說明 + 中文字典 + Row 範例見
> [`../../docs/script-tests-schema.md`](../../docs/script-tests-schema.md)。

---

## Per-script sections

### compute-project-identity

_(rows TBD)_

### get-target-url

_(rows TBD)_

### check-iis-listening

_(rows TBD)_

### check-encoding-support

_(rows TBD)_

### resolve-iis-settings

_(rows TBD)_

### push-to-svn-prepare

_(rows TBD)_

### svn-log

_(rows TBD)_

### start-iis

_(rows TBD)_

### stop-iis

_(rows TBD)_

### cleanup-orphan-iis

_(rows TBD)_

### build-web

_(rows TBD)_

### publish-web

_(rows TBD)_

### pull-from-svn

_(rows TBD)_

### push-to-svn-commit

_(rows TBD)_

### create-remote-test

_(rows TBD)_

### reset-remote-test

_(rows TBD)_

### svn-ignore

_(rows TBD)_

### pack-content

_(rows TBD)_

---

## Known Issues

(R32 escalation 用 — 同 case fix 3 次仍 FAIL 列在此。本 v1.0.0 run 期間發現的 known
issue 在此記。完整 cross-release known issue 整理見
[`known-issues.md`](./known-issues.md)。)
