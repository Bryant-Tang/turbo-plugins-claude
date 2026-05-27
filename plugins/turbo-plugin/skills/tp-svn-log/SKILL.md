---
name: tp-svn-log
description: '在指定 remote-<branch> worktree 跑 svn log,顯示 SVN history。使用者明確要求查 SVN history 時執行;agent 在需要對齊 SVN revision / 確認新 SVN commit 時也可建議執行(read-only,可安全 auto-trigger)。'
argument-hint: '[--branch <main|test-<n>>] [--limit <n>] [-r/--revision <spec>] [--verbose]'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-svn-log

## Purpose

對指定 `remote-<branch>` worktree 跑 `svn log --xml`,腳本自己解析 XML 再格式化為純文字輸出。`--xml` 確保 svn 永遠以 UTF-8 emit 輸出(不看 console codepage),避免中文 commit message 在 zh-TW Windows 變 `?` 亂碼。

## Procedure

1. 跑 script,參數依平台:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.ps1" [-Branch <main|test-<n>>] [-Limit <n>] [-Revision <spec>] [-VerboseOutput]
   ```
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.sh" [--branch <main|test-<n>>] [--limit <n>] [--revision <spec>] [--verbose]
   ```

   可選參數(logical 名稱與行為):
   - branch(default `main`)
   - limit(default **5**,正整數)
   - revision(svn 修訂號規格,直接透傳給 svn,可用格式如 `5` / `r5` / `3:10` / `HEAD` / `BASE` / `{2026-01-01}:{2026-05-26}` 等)
   - verbose(顯示變更檔案清單)

2. **必須**把 script stdout 完整 echo 到對話訊息中,用 markdown code block 包起來,讓使用者直接讀到 log 內容:

   ```
   r5 | bryant | 2026-05-26T12:34:56.000Z | 修正中文檔名
   r4 | alice  | 2026-05-25T...           | another commit
   ...
   # LAST_SHOWN_REV=1
   ```

   **不要** 只依賴 tool result UI(可能被折疊或截斷);使用者必須能直接從對話訊息讀到 log。`# LAST_SHOWN_REV=<n>` trailer 行也一起 echo,讓使用者也看到分頁狀態 — U11 pagination loop 也讀此 trailer 行決定下一頁起點。

## Decision Rules

- 必須在 main worktree 跑;script 內部自動定位 main + 對應 remote worktree。
- `--limit` 必須是正整數,非法值 → script 拋錯。
- `--revision` 的值不經 script validate,直接透傳給 svn — 由 svn 自己決定接受與否。**禁止** 在組指令時把多個 args 拼成單一字串(security invariant per F10);PS / bash script 內部都以 array splatting 傳值。
- read-only 操作,**不會修改任何檔案 / branch / SVN state**,可安全在 agent 想對齊版本時自動執行。

## Completion Checks

- 輸出符合 `r<rev> | <author> | <date> | <msg>` 格式(每筆一行;`--verbose` 多印變更檔案清單)。
- 中文 commit message 顯示為正確 UTF-8,**不變 `?`**。
- 至少有一筆 entry 時 stdout 末尾出現 `# LAST_SHOWN_REV=<最小 revision>` trailer。
- script stdout 已被完整 echo 到對話訊息(markdown code block)。

## Test Scenarios

- **Default limit**: 不傳 limit → 顯示**最近 5 筆**(不是 50)的 SVN log。
- **Custom limit**: PowerShell `-Limit 3` / bash `--limit 3` → 顯示最近 3 筆 SVN revision。
- **Revision single**: `--revision r5` → 只顯示 r5 一筆。
- **Revision range**: `--revision 3:7` → 顯示 r3 到 r7。
- **Revision + Limit**: `--revision 1:100 --limit 3` → svn 在範圍內取前 3 筆。
- **Revision date range**: `--revision {2026-01-01}:{2026-05-26}` → svn 接受日期範圍格式。
- **Invalid limit**: PowerShell `-Limit 'abc'` → PS param binding 直接拒;`-Limit -5` 或 bash `--limit -5` → script 拋 `Limit must be a positive integer`。
- **Encoding (zh-TW)**: SVN repo 有 commit message「修正中文檔名」→ 顯示為正確 UTF-8 中文,**不變 `?`**(此為 XML 解析的主要驗證)。
- **Multi-line commit message**: SVN 有一筆 commit message 含換行 → PS [xml] / bash xmllint 路徑正確 preserve 換行;bash grep+awk fallback 對多行 msg 可能截斷至第一行(已知 limitation,建議裝 xmllint)。
- **Trailer emission**: 顯示完所有 entry 後 stdout 末尾出現 `# LAST_SHOWN_REV=<最小 revision>` 行。
- **Empty result**: `--revision 999999` 等指向不存在的 revision → stdout 空(無 trailer)、exit 0。
- **bash xmllint fallback**: Git Bash 未裝 xmllint → 走 grep+awk fallback,輸出格式與 xmllint 路徑相同。
