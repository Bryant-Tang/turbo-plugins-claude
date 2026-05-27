# Phase 1 — Script Test Tracking

turbo-plugin v1.0 PR-readiness Phase 1 自動測試的紀錄。本檔 append-only,orchestrator
跑每個 case 之後 emit 一個 markdown table row。

> Schema 與 case ID 慣例見 `## Tracking schema` section 末段。

---

## 中文 fixture 樣本

下方 25 條為 turbo-plugin v1.0 Phase 1 + Phase 2 測試共用的 **single source of truth**
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

每個 phase 1 case 跑完後 orchestrator emit 一個 row 到下方對應 script section。schema:

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
| P1-svn-log-中文 | svn-log | fresh-base + r5 中文 commit | stdout 顯示 r5 訊息 byte-level 等於字典 3.1 | exit 0;byte-compare OK | PASS | `tests/v1.0/_artifacts/phase1/svn-log/zh.nunit.xml` |
| P1-svn-log-pagination | svn-log | fresh-base | 第 1 頁 5 筆 + `LAST_SHOWN_REV=16` trailer | exit 0;trailer 正確 | PASS | `... pagination.nunit.xml` |
```

> **Append-only**:同 case 跑多次會留多個 row;orchestrator 取最後一個為 authoritative
> (重複跑通常是 F5 fail-then-fix 後 re-run)。

---

## 預留 per-script section

下方 18 個 script 各保留一個 section。實作 U3 / U4 時 emit row 到對應 section 下方。
(目前空白;U1 階段只 stub headings。)

### compute-project-identity


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-compute-project-identity.Tests | compute-project-identity | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-compute-project-identity.sh.test | compute-project-identity | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-compute-project-identity.Tests | compute-project-identity | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\compute-project-identity.Tests.ps1 |
| P1-compute-project-identity.sh.test | compute-project-identity | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/compute-project-identity.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\compute-project-identity.sh.test.sh |
| P1-compute-project-identity.Tests | compute-project-identity | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\compute-project-identity.Tests.ps1 |
| P1-compute-project-identity.sh.test | compute-project-identity | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/compute-project-identity.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\compute-project-identity.sh.test.sh |

_(rows TBD by U3)_

### get-target-url


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-get-target-url.Tests | get-target-url | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-get-target-url.sh.test | get-target-url | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-get-target-url.Tests | get-target-url | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\get-target-url.Tests.ps1 |
| P1-get-target-url.sh.test | get-target-url | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/get-target-url.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\get-target-url.sh.test.sh |
| P1-get-target-url.Tests | get-target-url | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\get-target-url.Tests.ps1 |
| P1-get-target-url.sh.test | get-target-url | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/get-target-url.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\get-target-url.sh.test.sh |

_(rows TBD by U3)_

### check-iis-listening


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-check-iis-listening.Tests | check-iis-listening | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-check-iis-listening.sh.test | check-iis-listening | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-check-iis-listening.Tests | check-iis-listening | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-iis-listening.Tests.ps1 |
| P1-check-iis-listening.sh.test | check-iis-listening | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/check-iis-listening.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-iis-listening.sh.test.sh |
| P1-check-iis-listening.Tests | check-iis-listening | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-iis-listening.Tests.ps1 |
| P1-check-iis-listening.sh.test | check-iis-listening | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/check-iis-listening.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-iis-listening.sh.test.sh |

_(rows TBD by U3)_

### check-encoding-support


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-check-encoding-support.Tests | check-encoding-support | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-check-encoding-support.sh.test | check-encoding-support | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-check-encoding-support.Tests | check-encoding-support | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-encoding-support.Tests.ps1 |
| P1-check-encoding-support.sh.test | check-encoding-support | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/check-encoding-support.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-encoding-support.sh.test.sh |
| P1-check-encoding-support.Tests | check-encoding-support | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-encoding-support.Tests.ps1 |
| P1-check-encoding-support.sh.test | check-encoding-support | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/check-encoding-support.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\check-encoding-support.sh.test.sh |

_(rows TBD by U3)_

### resolve-iis-settings


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-resolve-iis-settings.Tests | resolve-iis-settings | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-resolve-iis-settings.sh.test | resolve-iis-settings | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-resolve-iis-settings.Tests | resolve-iis-settings | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\resolve-iis-settings.Tests.ps1 |
| P1-resolve-iis-settings.sh.test | resolve-iis-settings | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/resolve-iis-settings.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\resolve-iis-settings.sh.test.sh |
| P1-resolve-iis-settings.Tests | resolve-iis-settings | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\resolve-iis-settings.Tests.ps1 |
| P1-resolve-iis-settings.sh.test | resolve-iis-settings | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/resolve-iis-settings.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\resolve-iis-settings.sh.test.sh |

_(rows TBD by U3)_

### push-to-svn-prepare


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-push-to-svn-prepare.Tests | push-to-svn-prepare | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-push-to-svn-prepare.sh.test | push-to-svn-prepare | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-push-to-svn-prepare.Tests | push-to-svn-prepare | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\push-to-svn-prepare.Tests.ps1 |
| P1-push-to-svn-prepare.sh.test | push-to-svn-prepare | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/push-to-svn-prepare.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\push-to-svn-prepare.sh.test.sh |
| P1-push-to-svn-prepare.Tests | push-to-svn-prepare | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\push-to-svn-prepare.Tests.ps1 |
| P1-push-to-svn-prepare.sh.test | push-to-svn-prepare | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/push-to-svn-prepare.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\push-to-svn-prepare.sh.test.sh |

_(rows TBD by U3)_

### svn-log


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-svn-log.Tests | svn-log | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-svn-log.sh.test | svn-log | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-svn-log.Tests | svn-log | fresh-base | all Assert-* PASS | exit 1 | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\svn-log.Tests.ps1 |
| P1-svn-log.sh.test | svn-log | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/svn-log.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\svn-log.sh.test.sh |
| P1-svn-log.Tests | svn-log | fresh-base | all Assert-* PASS | exit 1 | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\svn-log.Tests.ps1 |
| P1-svn-log.sh.test | svn-log | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/svn-log.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\svn-log.sh.test.sh |

_(rows TBD by U3)_

### start-iis


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-start-iis.Tests | start-iis | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-start-iis.sh.test | start-iis | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-start-iis.Tests | start-iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\start-iis.Tests.ps1 |
| P1-start-iis.sh.test | start-iis | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/start-iis.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\start-iis.sh.test.sh |
| P1-start-iis.Tests | start-iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\start-iis.Tests.ps1 |
| P1-start-iis.sh.test | start-iis | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/start-iis.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\start-iis.sh.test.sh |

_(rows TBD by U3)_

### stop-iis


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-stop-iis.Tests | stop-iis | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-stop-iis.sh.test | stop-iis | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-stop-iis.Tests | stop-iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\stop-iis.Tests.ps1 |
| P1-stop-iis.sh.test | stop-iis | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/stop-iis.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\stop-iis.sh.test.sh |
| P1-stop-iis.Tests | stop-iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\stop-iis.Tests.ps1 |
| P1-stop-iis.sh.test | stop-iis | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/stop-iis.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\stop-iis.sh.test.sh |

_(rows TBD by U3)_

### cleanup-orphan-iis


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-cleanup-orphan-iis.Tests | cleanup-orphan-iis | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-cleanup-orphan-iis.sh.test | cleanup-orphan-iis | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-cleanup-orphan-iis.Tests | cleanup-orphan-iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\cleanup-orphan-iis.Tests.ps1 |
| P1-cleanup-orphan-iis.sh.test | cleanup-orphan-iis | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/cleanup-orphan-iis.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\cleanup-orphan-iis.sh.test.sh |
| P1-cleanup-orphan-iis.Tests | cleanup-orphan-iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\cleanup-orphan-iis.Tests.ps1 |
| P1-cleanup-orphan-iis.sh.test | cleanup-orphan-iis | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/cleanup-orphan-iis.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\cleanup-orphan-iis.sh.test.sh |

_(rows TBD by U3)_

### build-web


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-build-web.Tests | build-web | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-build-web.sh.test | build-web | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-build-web.Tests | build-web | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\build-web.Tests.ps1 |
| P1-build-web.sh.test | build-web | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/build-web.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\build-web.sh.test.sh |
| P1-build-web.Tests | build-web | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\build-web.Tests.ps1 |
| P1-build-web.sh.test | build-web | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/build-web.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\build-web.sh.test.sh |

_(rows TBD by U3)_

### publish-web


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-publish-web.Tests | publish-web | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-publish-web.sh.test | publish-web | reset-failed | fixture reset to base | Reset-Fixture exit 1 | FAIL | Reset-Fixture.ps1 exit 1 |
| P1-publish-web.Tests | publish-web | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\publish-web.Tests.ps1 |
| P1-publish-web.sh.test | publish-web | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/publish-web.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\publish-web.sh.test.sh |
| P1-publish-web.Tests | publish-web | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\publish-web.Tests.ps1 |
| P1-publish-web.sh.test | publish-web | fresh-base | script exit 0 + last line OK | exit 99; last: The term ' '/' + $args[0].Groups[1].Value.ToLower() /Turbo/turbo-plugins-claude/.claude/worktrees/agent-ad78e689810d6e9c4/tests/v1.0/phase1/publish-web.sh.test.sh' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and try again. | FAIL | C:\Turbo\turbo-plugins-claude\.claude\worktrees\agent-ad78e689810d6e9c4\tests\v1.0\phase1\publish-web.sh.test.sh |

_(rows TBD by U3)_

### pull-from-svn

_(rows TBD by U4)_

### push-to-svn-commit

_(rows TBD by U4)_

### create-remote-test

_(rows TBD by U4)_

### reset-remote-test

_(rows TBD by U4)_

### svn-ignore

_(rows TBD by U4)_

### pack-content

_(rows TBD by U4)_

---

## Known Issues

(R32 escalation 用 — 同 case fix 3 次仍 FAIL 列在此。U1 階段為空。)
