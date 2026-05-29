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

### Get-ProjectIdentity


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Get-ProjectIdentity.test | Get-ProjectIdentity | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Get-ProjectIdentity.test.ps1 |
| P1-get-project-identity.test | Get-ProjectIdentity | fresh-base | script exit 0 + last line OK | exit 0; last: OK: all bash cases pass | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\get-project-identity.test.sh |

_(rows TBD)_

### Get-TargetUrl


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Get-TargetUrl.test | Get-TargetUrl | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Get-TargetUrl.test.ps1 |
| P1-get-target-url.test | Get-TargetUrl | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\get-target-url.test.sh |

_(rows TBD)_

### Test-IisListening


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Test-IisListening.test | Test-IisListening | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Test-IisListening.test.ps1 |
| P1-test-iis-listening.test | Test-IisListening | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\test-iis-listening.test.sh |

_(rows TBD)_

### Test-EncodingSupport


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Test-EncodingSupport.test | Test-EncodingSupport | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Test-EncodingSupport.test.ps1 |
| P1-test-encoding-support.test | Test-EncodingSupport | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\test-encoding-support.test.sh |

_(rows TBD)_

### IisHelpers


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-IisHelpers.test | IisHelpers | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\lib\IisHelpers.test.ps1 |

_(rows TBD)_

### Build-SvnCommit


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Build-SvnCommit.test | Build-SvnCommit | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Build-SvnCommit.test.ps1 |
| P1-build-svn-commit.test | Build-SvnCommit | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\build-svn-commit.test.sh |

_(rows TBD)_

### Get-SvnLog


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Get-SvnLog.test | Get-SvnLog | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Get-SvnLog.test.ps1 |
| P1-get-svn-log.test | Get-SvnLog | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\get-svn-log.test.sh |

_(rows TBD)_

### Start-Iis


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Start-Iis.test | Start-Iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Start-Iis.test.ps1 |
| P1-start-iis.test | Start-Iis | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\start-iis.test.sh |

_(rows TBD)_

### Stop-Iis


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Stop-Iis.test | Stop-Iis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Stop-Iis.test.ps1 |
| P1-stop-iis.test | Stop-Iis | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\stop-iis.test.sh |

_(rows TBD)_

### Remove-OrphanIis


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Remove-OrphanIis.test | Remove-OrphanIis | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Remove-OrphanIis.test.ps1 |
| P1-remove-orphan-iis.test | Remove-OrphanIis | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\remove-orphan-iis.test.sh |

_(rows TBD)_

### Build-Web


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Build-Web.test | Build-Web | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Build-Web.test.ps1 |
| P1-build-web.test | Build-Web | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\build-web.test.sh |

_(rows TBD)_

### Publish-Web


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Publish-Web.test | Publish-Web | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Publish-Web.test.ps1 |
| P1-publish-web.test | Publish-Web | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\publish-web.test.sh |

_(rows TBD)_

### Sync-FromSvn


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Sync-FromSvn.test | Sync-FromSvn | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Sync-FromSvn.test.ps1 |
| P1-sync-from-svn.test | Sync-FromSvn | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\sync-from-svn.test.sh |

_(rows TBD)_

### Submit-SvnCommit


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Submit-SvnCommit.test | Submit-SvnCommit | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Submit-SvnCommit.test.ps1 |
| P1-submit-svn-commit.test | Submit-SvnCommit | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\submit-svn-commit.test.sh |

_(rows TBD)_

### New-RemoteTest


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-New-RemoteTest.test | New-RemoteTest | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\New-RemoteTest.test.ps1 |
| P1-new-remote-test.test | New-RemoteTest | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\new-remote-test.test.sh |

_(rows TBD)_

### Reset-RemoteTest


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Reset-RemoteTest.test | Reset-RemoteTest | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Reset-RemoteTest.test.ps1 |
| P1-reset-remote-test.test | Reset-RemoteTest | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\reset-remote-test.test.sh |

_(rows TBD)_

### Set-SvnIgnore


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Set-SvnIgnore.test | Set-SvnIgnore | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Set-SvnIgnore.test.ps1 |
| P1-set-svn-ignore.test | Set-SvnIgnore | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\set-svn-ignore.test.sh |

_(rows TBD)_

### Compress-Content


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Compress-Content.test | Compress-Content | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\Compress-Content.test.ps1 |
| P1-compress-content.test | Compress-Content | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\compress-content.test.sh |

_(rows TBD)_

### Invoke-PostToolUseEnterWorktree


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Invoke-PostToolUseEnterWorktree.test | Invoke-PostToolUseEnterWorktree | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\hooks\Invoke-PostToolUseEnterWorktree.test.ps1 |
| P1-invoke-posttooluse-enterworktree.test | Invoke-PostToolUseEnterWorktree | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\hooks\invoke-posttooluse-enterworktree.test.sh |

_(rows TBD)_

### Invoke-SessionStart


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Invoke-SessionStart.test | Invoke-SessionStart | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\hooks\Invoke-SessionStart.test.ps1 |
| P1-invoke-sessionstart.test | Invoke-SessionStart | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\hooks\invoke-sessionstart.test.sh |

_(rows TBD)_

### Common


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-Common.test | Common | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\lib\Common.test.ps1 |
| P1-common.test | Common | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\lib\common.test.sh |

_(rows TBD)_

### ApplicationHostHelpers


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-ApplicationHostHelpers.test | ApplicationHostHelpers | fresh-base | all Assert-* PASS | exit 0 | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\lib\ApplicationHostHelpers.test.ps1 |

_(rows TBD)_

### ps1-delegate


| case ID | section | fixture | expected | actual | result | evidence |
|---|---|---|---|---|---|---|
| P1-ps1-delegate.test | ps1-delegate | fresh-base | script exit 0 + last line OK | exit 0; last: OK | PASS | C:\Turbo\turbo-plugins-claude\.claude\worktrees\turbo-plugin-brainstorm\plugins\turbo-plugin\tests\unit\scripts\lib\ps1-delegate.test.sh |

_(rows TBD)_

---

## Known Issues

(R32 escalation 用 — 同 case fix 3 次仍 FAIL 列在此。本 v1.0.0 run 期間發現的 known
issue 在此記。完整 cross-release known issue 整理見
[`known-issues.md`](./known-issues.md)。)
