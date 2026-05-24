---
name: tp-create-remote-test
description: '建立 SVN test 分支對應的 remote/test-<n> branch + remote-test-<n> worktree + svn checkout(或 svn-copy-from-trunk 若 target SVN URL 不存在)。**會建立永久 SVN 路徑,必須使用者明確要求才執行**;agent 偵測需要新 test 環境時可建議,但需明確確認。'
argument-hint: '--svn-url <url> [--n <number>]'
user-invocable: true
---

# tp-create-remote-test

## Purpose

建立新的 SVN test 分支與本機 git+SVN bridge worktree。

## Procedure

1. 確認當前在主 worktree(否則用 shared lib `Test-IsMainWorktree` / `test_is_main_worktree` 偵測,在 peer 跑 → 拒跑)。
2. 必傳 `--svn-url <url>`;可選 `--n <number>` 指定編號(省略則自動取最大現有 `remote-test-<n>` + 1)。先在本端 resolve 出實際會傳給 script 的 N、branch name、worktree path 與 SVN URL,呈現給使用者前不要先動 SVN。
3. **使用者確認 (destructive op gate)** — 用 `AskUserQuestion` 在執行 script *之前* 先確認:

   問題:`即將建立 SVN test branch。確認執行?`

   說明欄要列出 Step 2 解析出的具體參數:
   - N: `<n>`
   - Branch name: `remote/test-<n>`
   - Worktree path: `<resolved path>`
   - SVN URL: `<derived url>`

   選項:
   - **Confirm** — 跑 script 建立 worktree + SVN branch。
   - **Cancel** — 終止,不動 SVN。

   使用者若選 Cancel,直接結束,**不**呼叫 script。這個 gate 與 `tp-reset-remote-test` 的破壞性操作確認模式一致。
4. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/create-remote-test.{ps1,sh}` 帶上參數。
5. Script 會:
   - check branch / worktree 名稱不衝突
   - 從 init commit 建 `remote/test-<n>` branch(避免 SVN obstruction)
   - 從 `main` 建 `test-<n>` branch
   - `git worktree add` 建 `remote-test-<n>` worktree
   - SVN URL 不存在 → `svn copy <main-svn-url> <new-url>` 建出來
   - `svn checkout <url> <remote-path>`
   - 繼承 `remote-main` 的 `svn:ignore` 並 commit
6. 印出下一步建議:`/tp-pull-from-svn --branch test-<n>` 完成初次同步

## Decision Rules

- 必須在主 worktree 跑(否則 `Get-MainWorktree` 仍回主路徑,但建議拒跑 — script 不限,但本 skill body 應明確說「請到主 worktree 跑」)。
- `--svn-url` 必填。
- 衝突 branch / worktree → 拒跑,不嘗試 cleanup 舊狀態。
- SVN URL 不存在但 `remote-main` 有合法 URL → 用 svn copy 建出來。

## Completion Checks

- `git branch -a` 含 `test-<n>` 與 `remote/test-<n>`。
- `git worktree list` 含 `<proj>.worktrees/remote-test-<n>`。
- 該 worktree 內含 `.svn/` 目錄。
- `svn propget svn:ignore <remote-path>` 與 `remote-main` 一致。

## Test Scenarios

- **Cancel path**: 提供有效 SVN URL,SKILL 展示 N / branch name / worktree path / SVN URL 後使用者選 Cancel。確認 `git branch -a` 沒有 `test-<n>`、`git worktree list` 沒有 `remote-test-<n>`、SVN 上也沒新 branch。
- **Happy path Confirm**: Confirm 選後 4 個既有 Completion Checks 全 pass(branches 建好、worktree 連到 SVN test branch、`<proj>.code-workspace` 含新 worktree、初始 git history 含 SVN branch base commit)。
- **SVN URL invalid (rollback)**: 提供不存在的 SVN URL,Confirm 後 svn checkout 失敗。確認 (a) `git branch --list test-<n>` 為空、(b) `git branch --list remote/test-<n>` 為空、(c) `git worktree list` 沒有 `remote-test-<n>` 條目、(d) `<proj>.code-workspace` 沒新增該 worktree。.ps1 走 try/catch、.sh 走 ERR trap,行為一致。
