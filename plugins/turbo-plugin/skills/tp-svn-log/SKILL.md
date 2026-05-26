---
name: tp-svn-log
description: '在指定 remote-<branch> worktree 跑 svn log,顯示 SVN history。使用者明確要求查 SVN history 時執行;agent 在需要對齊 SVN revision / 確認新 SVN commit 時也可建議執行(read-only,可安全 auto-trigger)。'
argument-hint: '[--branch <main|test-<n>>] [--limit <n>] [--verbose]'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-svn-log

## Purpose

對指定 `remote-<branch>` worktree 跑 `svn log`,過濾掉 path-only annotations(`(from /trunk:r...)`)讓輸出乾淨。

## Procedure

1. 跑 script,參數依平台:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.ps1" [-Branch <main|test-<n>>] [-Limit <n>] [-VerboseOutput]
   ```
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.sh" [--branch <main|test-<n>>] [--limit <n>] [--verbose]
   ```

   可選參數(logical 名稱與行為):
   - branch(default `main`)
   - limit(default 50,正整數)
   - verbose(顯示變更檔案清單)

2. 將 script stdout 原樣呈現給使用者。

## Decision Rules

- 必須在 main worktree 跑;script 內部自動定位 main + 對應 remote worktree。
- `--limit` 必須是正整數,非法值 → script 拋錯。
- read-only 操作,**不會修改任何檔案 / branch / SVN state**,可安全在 agent 想對齊版本時自動執行。

## Completion Checks

- 輸出符合 svn log 格式(含 revision、作者、日期、訊息)。
- 過濾後不留 `(from /trunk:r...)` 等 path annotations。

## Test Scenarios

- **Default limit**: 不傳 limit → 顯示 default 50 條的 SVN log。
- **Custom limit**: PowerShell `-Limit 5` / bash `--limit 5` → 顯示最近 5 條 SVN revision。
- **Invalid limit**: PowerShell `-Limit 'abc'` → PS param binding 直接拒;`-Limit -5` 或 bash `--limit -5` → script 拋 `Limit must be a positive integer`。
- **Encoding**: 含中文 commit message 的 revision → 顯示為 UTF-8 不亂碼。
