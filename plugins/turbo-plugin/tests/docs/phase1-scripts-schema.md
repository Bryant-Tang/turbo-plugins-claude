# Phase 1 — Script Test Tracking SCHEMA

turbo-plugin v1.0+ PR-readiness Phase 1 自動測試的 **schema + 中文字典 + per-script
section template**。本檔為持久 schema reference;per-release 的實際執行結果寫在
`plugins/turbo-plugin/tests/runs/<release>/phase1-results.md`(由 `Run-Phase1.ps1`
append rows)。

> 本檔 **不會被 orchestrator append rows**;若看到 row 出現代表 -TargetDoc 設錯。
> Per-release 執行結果應寫到 `runs/<release>/phase1-results.md`。

---

## 中文 fixture 樣本

下方 25 條為 turbo-plugin Phase 1 + Phase 2 測試共用的 **single source of truth**
中文字典。任何 script / SKILL / fixture 要用中文 sample 時都從這裡抽,不要 inline 自己的版本。

`build-seed-repo.ps1` 內 `$zhDict` 必須與本表保持一致 (commit msg #1 / #2 / #3 對應
SVN seed r5 / r10 / r15)。

### #1 路徑 (folder path 含中文)

| # | 樣本 | 預期用途 |
|---|---|---|
| 1.1 | `路徑/含中文` | 一般中文層級 |
| 1.2 | `使用者文件/測試案例` | 多層中文夾 |
| 1.3 | `專案/伺服器/組態` | 中文 + 英文 mixed segment |
| 1.4 | `舊版/相容性/設定` | 中文 + 數字 mixed (隱含 — 中文形式) |
| 1.5 | `中文資料夾/sub-層` | 中文 + ASCII subfolder |

### #2 檔名 (file name 含中文)

| # | 樣本 | 預期用途 |
|---|---|---|
| 2.1 | `測試說明.md` | 一般中文檔名 |
| 2.2 | `使用者手冊.cshtml` | 中文 + Web view 副檔 |
| 2.3 | `報表範本.cs` | 中文 + C# source |
| 2.4 | `組態設定.toml` | 中文 + config 副檔 |
| 2.5 | `中文檔案 (含空白).txt` | 中文 + 空白 + 半形括弧 |

### #3 Commit message (SVN / git commit 含中文)

| # | 樣本 | SVN seed mapping |
|---|---|---|
| 3.1 | `修正中文 commit 訊息亂碼` | **r5** (build-seed-repo.ps1 `$Revisions[4].Msg`) |
| 3.2 | `新增繁體中文範例文件` | **r10** (build-seed-repo.ps1 `$Revisions[9].Msg`) |
| 3.3 | `重構伺服器組態載入流程` | **r15** (build-seed-repo.ps1 `$Revisions[14].Msg`) |
| 3.4 | `處理 SVN 中文檔名相容性` | reserved for /tp-push-to-svn case |
| 3.5 | `加入中文 Razor view 範本` | reserved for /tp-push-to-svn case |

### #4 Source 註解 (in-file comment 含中文)

| # | 樣本 | 對應語法 |
|---|---|---|
| 4.1 | `// 中文註解:確認 HelloController 回傳值 byte-level 一致` | C# / JS line comment |
| 4.2 | `// 中文註解:此函式處理中文 commit msg 的編碼問題` | C# / JS line comment |
| 4.3 | `# 中文 PS 註解:本 script 由 build-seed-repo.ps1 產生` | PowerShell / Bash |
| 4.4 | `// 中文註解:相容 Big5 / CP950 Windows` | C# / JS line comment |
| 4.5 | `// 中文註解:加入中文 string literal 測試` | C# / JS line comment |

### #5 Source string literal (in-file 字串含中文)

| # | 樣本 | 對應語法 |
|---|---|---|
| 5.1 | `"你好,turbo-plugin"` | C# / JS string |
| 5.2 | `"伺服器啟動成功"` | C# / JS string |
| 5.3 | `"中文錯誤訊息:檔案不存在"` | C# / JS string |
| 5.4 | `"請輸入有效的中文使用者名稱"` | C# / JS string |
| 5.5 | `"組態載入完成 — 中文路徑支援已啟用"` | C# / JS string + em-dash |

---

## Tracking schema

每個 phase 1 case 跑完後 orchestrator emit 一個 row 到 `runs/<release>/phase1-results.md`
對應 script section。schema:

| 欄 | 說明 |
|---|---|
| `case ID` | `P1-<script-stem>-<short-desc>` (例:`P1-svn-log-中文`) |
| `section` | 對應 script 名 (`svn-log`、`pull-from-svn` 等) |
| `fixture` | 預期 fixture 狀態 (`fresh-base` / `r21-dirty` / `[iis]=false` 等) |
| `expected` | 該 case 預期行為摘要 |
| `actual` | 觀察結果 (exit code + stdout 關鍵字 / 中文 byte hash) |
| `result` | `PASS` / `FAIL` / `FAIL-known` / `SKIP` / `BLOCKED-BY:...` |
| `evidence` | NUnit XML 行 / stdout snippet / 修復 commit hash |

### Row 範例

```markdown
| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-svn-log-中文 | svn-log | fresh-base + r5 中文 commit | stdout 顯示 r5 訊息 byte-level 等於字典 3.1 | exit 0;byte-compare OK | PASS | `<RunDir>/_artifacts/phase1/svn-log/zh.nunit.xml` |
| P1-svn-log-pagination | svn-log | fresh-base | 第 1 頁 5 筆 + `LAST_SHOWN_REV=16` trailer | exit 0;trailer 正確 | PASS | `... pagination.nunit.xml` |
```

> **Append-only**:同 case 跑多次會留多個 row;orchestrator 取最後一個為 authoritative
> (重複跑通常是 F5 fail-then-fix 後 re-run)。

---

## 預留 per-script section

下方 18 個 script 各保留一個 section。Per-release runs/ 版本的 doc 在執行 `Run-Phase1.ps1`
之後 emit row 到對應 section 下方。

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

(R32 escalation 用 — 同 case fix 3 次仍 FAIL 列在此。空白 schema template。)
