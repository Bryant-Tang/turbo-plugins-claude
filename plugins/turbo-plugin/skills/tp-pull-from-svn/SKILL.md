---
name: tp-pull-from-svn
description: '從 SVN 拉新 revision 到 remote-svn/<branch>(`remote-svn-main` / `remote-svn-test-<n>` worktree)並 merge 進對應本地工作分支。使用者明確要求 pull / 偵測到 remote 有新 SVN commit 而本地 working branch 落後時建議執行;**不要自動觸發**(merge 衝突需使用者介入)。'
argument-hint: '--branch <main|test-<n>>'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-pull-from-svn

## Purpose

從 SVN 拉新 revision、commit 進對應 `remote-svn/*` git branch、merge 進本地工作 branch。

## Procedure

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Sync-FromSvn.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/sync-from-svn.sh`)帶 `--branch <main|test-<n>>` 參數。
2. 解讀 script 輸出:
   - `Already up to date at SVN r<rev>` → 完成
   - `Pulled SVN r<rev> into <branch>` → 完成
   - `Merge conflict detected. Resolve the following files...` → 列出衝突檔給使用者,提示「請在主 worktree 解衝突後 `git merge --continue`;**不要自動 abort**」

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- 必須在 main worktree 跑;script 內部會自動定位主 worktree。
- main worktree 不乾淨(`git status --porcelain` 非空)→ 拒跑,提示先 commit / stash。
- 衝突時 **不自動 abort**,讓使用者選擇手動解決。
- 跑兩次無 SVN 新 commit → 第二次回 "Already up to date" 不重做。

## Completion Checks

- `git log --oneline remote-svn/<branch>` 含新 `sync: svn r<rev>` commit(若有 SVN 變更)。
- 本地 working branch 已 merge `remote-svn/<branch>`,`git log --oneline` 含 `Merge branch 'remote-svn/<branch>' into <branch>` commit(若有變更)。
- main worktree clean,`git status --porcelain` 為空。

### After a merge conflict + rollback

If `/tp-pull-from-svn` aborts due to merge conflict, the script restores the working tree but **does not auto-retry the merge** on rerun (svn revision already matches, so the rerun sees "Already up to date" and skips the merge).

To complete the pull after resolving conflicts:
1. Manually merge: `git -C <main-worktree> merge remote-svn/<branch>` then resolve conflicts and commit
2. Confirm: `git log --oneline <branch>..remote-svn/<branch>` is empty (no unmerged SVN commits remain)

This workflow trade-off is intentional — auto-retry would loop indefinitely on persistent conflicts.

## Test Scenarios

- **Already up-to-date**: SVN HEAD == local HEAD → script印 `Already up to date.` 並 exit 0,git 沒 fast-forward。
- **Happy-path pull**: SVN HEAD 領先,跑 script → svn update + git fetch + git merge `remote-svn/<branch>` 完成,主 worktree HEAD 前進。
- **Merge conflict + 自動 rollback**: 故意製造一個本地 commit 改同行,SVN 同行也改 → script abort merge + 切回原 branch,emit `Merge conflict detected. ... Conflicting files: <list>`,working tree 為原 branch 乾淨狀態。
- **Rollback failure (inconsistent state)**: 故意鎖 `.git/index`(讓 `git merge --abort` 失敗)→ script emit `Working tree is in an inconsistent state. Resolve manually before re-running.`,exit 1。
