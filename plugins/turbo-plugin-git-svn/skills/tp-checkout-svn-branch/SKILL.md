---
name: tp-checkout-svn-branch
description: '一步把「既有的 SVN 分支」匯入成本機 git↔SVN bridge + 一條已填好內容的工作分支,讓使用者直接在 git 上接著開發、日後用 /tp-pull-from-svn 同步。**對 SVN 端唯讀**(不建立、不寫入任何 SVN 路徑);只在本機 git 端建立 bridge / worktree / 工作分支,失敗會完全回滾。使用者說「把某個 SVN 分支拉下來 / checkout 既有 SVN branch 開始開發」時適用。'
argument-hint: '--svn-url <existing-svn-branch-url> [--branch <work-branch-name>]'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-checkout-svn-branch

## Purpose

匯入一個**已存在的 SVN 分支**(例如 `<repos-root>/branches/feature-x`)成為:
1. 一條 `remote-svn/<branch>` bridge 分支 + 對應 worktree(內含該 SVN 分支內容的 svn working copy)。
2. 一條**工作分支** `<branch>`,內容已填好、且 **descend from `remote-svn/<branch>`**(KTD5),所以第一次 `/tp-pull-from-svn` 不會撞 "unrelated histories"。

**對 SVN 端完全唯讀**:只 `svn checkout`(讀),不 `svn copy` / `svn propset` / `svn commit`。被匯入的 SVN 分支**不會新增任何 revision**。所有寫入都在本機 git 端,中途失敗一律完整回滾(bridge / worktree / 工作分支)。

> 與 `tp-push-to-svn` 首推 bootstrap 的差別:首推 bootstrap 是把**本機已有**的工作分支推上去、會**建立**新的 SVN 路徑;本 skill 是把**SVN 上已有**的分支拉下來、對 SVN 唯讀。

## Procedure

### Step 0 — 執行路由

依環境選工具(**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**):
- Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
- Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`(**單破折號參數 `-SvnUrl` / `-Branch`**;GNU 風格 `--svn-url` 在 `powershell -File` 下不可靠)。
- Linux / macOS → 用 **Bash 工具**跑 `.sh`。
Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL)。

### Step 1 — 前置確認

- 需要 `--svn-url <url>`(要匯入的既有 SVN 分支 URL)。未提供 → 要求使用者提供後再續。
- 前置條件:`remote-svn-main` bridge 必須已存在(本 skill 以它為信任錨,且**不**自行 bootstrap 主 bridge)。若不存在 / 損壞,腳本會 fail-closed 並導向先跑 git-svn `/tp-setup`。
- 工作分支名:預設 = SVN URL 的葉名(最後一段)消毒後;要自訂用 `--branch <name>`。

### Step 2 — 執行匯入

依執行路由跑:
```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Checkout-SvnBranch.ps1" -SvnUrl <url> [-Branch <name>]
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/checkout-svn-branch.sh" --svn-url <url> [--branch <name>]
```

Script 會(全部在任何 mutation 之前做完):
- 確認 `remote-svn-main` 是有效 svn working copy(訊息區分「目錄缺」vs「WC 損壞」並帶 svn info 原因)。
- 衍生 / 消毒工作分支名(葉名空或被 allowlist 拒 → 要求改用 `--branch`)。
- 碰撞 / 部分狀態守衛(同 dir 不同 ref、bridge 已存在、ref-XOR-dir 不一致)。
- **R20**:本機已有同名工作分支 → 拒絕、零副作用。
- **R18 信任檢查**:`Assert-TrustedSvnUrl`(錨 `remote-svn-main` repos-root-url),URL 不在受信任根下 → 拒絕、零副作用。
- 確認該 SVN 分支**確實存在**(唯讀,不建立)。

通過後(rollback-guarded):建 `remote-svn/<branch>`(根於 repo init commit)→ 加 worktree → `svn checkout --force`(讀)→ `svn rm --keep-local .git` → 同步 main 的 `.gitignore` → `git add -A` + commit 匯入內容到 bridge → 開工作分支 `<branch>`(由 bridge ref 開出)。任一步失敗 → 回滾本機 git 三件,SVN 端無新 revision。

### Step 3 — 回報

把腳本輸出的「Working branch / Bridge branch / SVN worktree / Next」原樣呈現給使用者,並提示下一步:`git checkout <branch>` 開始開發,日後用 `/tp-pull-from-svn --branch <branch>` 同步 SVN 後續變更。

## Decision Rules

- **執行路由**:同上 Step 0;PowerShell 一律用單破折號參數。
- **對 SVN 唯讀**:本 skill 永不對被匯入的 SVN 分支寫入(無 `svn copy` / `propset` / `commit`);失敗只回滾本機 git,SVN 端零變更。要**建立**新 SVN 分支請走 `tp-push-to-svn` 首推 bootstrap,不是本 skill。
- **工作分支必須 descend from bridge ref**(KTD5):工作分支由 `remote-svn/<branch>` 開出,確保第一次 `/tp-pull-from-svn` 的 merge 不是 unrelated histories。
- **同名工作分支零副作用拒絕**(R20):本機已有同名分支即拒絕、不動任何 git/svn 狀態;請改 `--branch` 或先處理既有分支。
- **remote-svn-main 是前置、不自行 bootstrap**:缺 / 壞 → fail-closed 導向 git-svn `/tp-setup`。
- **branch 名消毒走 `Resolve-RemoteWorktree`**:葉名衍生後若被 allowlist 拒,改要求 `--branch` 明確命名。

## Completion Checks

- `git branch --list <branch>` 出現工作分支;`git rev-parse <branch>` == `git rev-parse remote-svn/<branch>`(工作分支建立於 bridge tip)。
- `git merge-base <branch> remote-svn/<branch>` 非空(首次 pull 不會 unrelated histories)。
- bridge worktree(`remote-svn-<branch>`)存在且是該 SVN 分支的 working copy;其 `git status --porcelain` 乾淨(`.svn/` 已被 `.gitignore` 忽略)。
- 被匯入的 SVN 分支**無新 revision**(`svn log` 末筆未變)。
- 拒絕 / 失敗路徑:無殘留 bridge 分支 / worktree / 工作分支。

## Test Scenarios

- Manual(happy):對既有 `<repos-root>/branches/feature-x` 跑本 skill → 建 `remote-svn/feature-x` + `feature-x` 工作分支(內容已填)→ `git checkout feature-x` 看得到 SVN 內容 → `/tp-pull-from-svn --branch feature-x` 成功(無 unrelated histories)。SVN 端無新 revision。
- Manual(同名衝突,R20):先 `git branch feature-x`(內容不同)→ 跑本 skill → 拒絕、零副作用(無 bridge / worktree 建立、SVN 無新 revision)。
- Manual(無 remote-svn-main):未 setup 主 bridge → 跑本 skill → fail-closed,訊息導向先跑 git-svn `/tp-setup`,不建任何東西。
- Manual(信任邊界):`--svn-url` 指向受信任根外(或 `..` traversal / `repos-evil`)→ 拒絕、零副作用。
- Manual(自訂名):`--branch my-work` → 工作分支名用 `my-work`,worktree = `remote-svn-my-work`。

## Tool Preference

檔案 read / write 用 Read / Edit / Write。shell 操作限 `git` / `svn` / 跑 plugin scripts。
