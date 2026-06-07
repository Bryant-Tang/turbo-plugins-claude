# turbo-plugin 0.5.0 — Test Framework Migration Run

本目錄為 **turbo-plugin 0.5.0** 的測試執行證據(per-version evidence)。

## 框架(v0.5.0 起)

- **PowerShell 測試**:Pester 5（`Describe`/`It`/`Should`），由 `tests/Invoke-ScriptTests.ps1` 以 per-file 隔離（child process）執行;framework gate 缺 Pester 5 → exit 1。
- **bash 測試**:vendored shUnit2（`tests/lib/shunit2`, v2.1.8），由 `tests/invoke-script-tests.sh` 執行;framework gate 缺 vendored shUnit2 → exit 1。
- 不再產出舊式 per-case tracking 文件（`script-tests-results.md` 等)—改用 Pester / shUnit2 原生輸出。歷史紀錄見 `../0.4.0/`。

## 本機驗證結果（Windows PowerShell 5.1 + Pester 5.7.1 + git-bash svn）

PS orchestrator（`Invoke-ScriptTests.ps1`，涵蓋 .ps1 + .sh）：

```
Pester (.ps1): 288 passed / 0 failed / 6 skipped  (across 26 files)
Bash   (.sh):  25 passed / 0 failed / 0 skipped   (across 25 files)
EXIT: 0
```

SKIP 為 Unix×Windows-only-tool 或深層 worktree 路徑限制（CI 正常深度 checkout 會執行）。

## CI

`.github/workflows/tests.yml`：
- `test-windows`:WinPS 5.1 跑 PS orchestrator（裝 Pester 5;.sh 走 git-bash shUnit2）。
- `test-ubuntu`:bash orchestrator 跑 .sh（vendored shUnit2）+ pwsh 步驟跑 PS orchestrator 的 .ps1（裝 Pester 5,`-SkipPreflight`;BashPath 非 Windows 不解析,.sh 不雙跑）。
- framework 缺席 = job FAIL（R20）。
