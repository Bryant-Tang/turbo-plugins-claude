---
name: tp-push-to-svn
description: '把本地工作分支推上 SVN(透過 remote-<branch> worktree),自 parse 每個 commit subject 篩 SVN history。**SVN 寫操作影響永久 history,必須由使用者明確要求才執行;agent 偵測到「使用者完成一輪改動準備 push」時可建議,但需明確確認**。'
argument-hint: '--branch <branch> [--svn-url <url>]'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-push-to-svn

## Purpose

把本地 git working branch 的新 commits push 上 SVN。為了讓 SVN history 保留可讀的程式碼變更紀錄,本 skill **自 parse 每個 commit subject**,依 commit type 篩選哪些進入 SVN message body。

**設計理念**:`.commitlintrc.json` 是純諮詢的 commit type 來源(無 husky / 無 commitlint hook 強制),enforce 由本 skill 在 push 時完成。

## Procedure

### Step 0 — First-push bootstrap pre-flight(gate 順序:detached → mismatch → bridge)

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Get-PushPreflight.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/get-push-preflight.sh`,依**執行路由**選工具)帶 `--branch <name>`。腳本只輸出**一行**以 `TP_TOKEN:` 為前綴的終結 token——**SKILL 只認以 `TP_TOKEN:` 開頭的行**(raw branch 名內嵌的假 token 不算),且**不要自己跑 git 判斷**,完全依此 token 路由:

- `TP_TOKEN:DETACHED_HEAD requested=<r>` → **拒絕**:HEAD 為 detached(或 `--branch HEAD`),沒有分支名可推導 bridge。提示使用者先 `git checkout <具名分支>` 再重跑。結束 skill,**不建任何東西**。
- `TP_TOKEN:BRANCH_MISMATCH_WARNING current=<c> requested=<r>` → `AskUserQuestion`:「你目前在 `<c>` branch,但要推 `<r>`。先確認沒有推錯分支?」
  - **取消** → 結束 skill。
  - **確認** → 請使用者切到 `<r>`(`git checkout <r>`)後重跑本 Step 0,避免誤推。
- `TP_TOKEN:BRIDGE_ABSENT requested=<r> target=<path>` → 進入**首推 bootstrap**(見下)。
- `TP_TOKEN:BRIDGE_PRESENT requested=<r>` → 已有 bridge,直接進 Step 1(正常 push)。

**首推 bootstrap(僅 `BRIDGE_ABSENT`)**:

1. 需要 `--svn-url <url>`(該分支對應的 SVN 路徑)。未提供 → 要求使用者提供後再續。
2. `AskUserQuestion` 明示風險:「這會建立一個**永久** SVN 路徑 `<url>`(SVN 路徑建立後無法刪除)。若建立過程後段失敗,該 SVN 路徑可能已經留下,可由**重跑首推** idempotent 接續(偵測到既有路徑→checkout,不重複建立);本機 git 端(分支/worktree)失敗會自動 rollback。確認建立?」
   - **取消** → 結束 skill,不建任何東西。
   - **確認** → 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/New-RemoteBridge.ps1`(或 `new-remote-bridge.sh`,依執行路由)帶 `--branch <r> --svn-url <url>`。
3. New-RemoteBridge 成功 → 進 Step 1 繼續正常 push。失敗 → 腳本已 rollback 本機 git 端;若訊息提到 SVN 路徑已建立,提醒使用者可重跑首推接續。

### Step 1 — Pre-flight clean check

- 跑 `git status --porcelain` 確認當前 main worktree 乾淨。非空 → 拒跑,提示先 commit / stash。
- `--branch` 接受**任意分支**(合法性 / 消毒由 Step 0 的 pre-flight 腳本以 allowlist 處理)。

### Step 2 — Prepare merge

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Build-SvnCommit.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/build-svn-commit.sh`)帶 `--branch <name>`。Script 會:
- check remote SVN up-to-date(local rev == HEAD rev)
- check 是否有 pending merge state(見下方 PENDING_MERGE_DETECTED 處理)
- 跑 `git merge --no-ff --no-commit` stage merge
- 把 source branch HEAD SHA 寫入 `<remote-path>/.git/MERGE_HEAD.tp_branch_sha`(供 commit 步驟驗證)
- 印出 `COMMITS\n<hash>|<subject>\n...\n\nFILES\n<diff_status>|<git_status>|<path>\n...`

**Script 已自動處理失敗情境**:
- `Nothing to push` → 直接結束
- remote SVN 不 up-to-date → fail loudly 提示先 `/tp-pull-from-svn`
- merge 衝突 → 列出衝突檔,**不自動 abort**(由使用者解或手動 `git merge --abort`)
- `PENDING_MERGE_DETECTED <remote-path>` → Script 輸出此 token 並 exit 0;SKILL 進入下方三選一 prompt
- `TP_TOKEN:BRANCH_MISMATCH_WARNING current=<current> requested=<requested>` → Build-SvnCommit 的 backstop(主要偵測已在 Step 0 pre-flight;此為正常 push 路徑上的二次防線),token 同以 `TP_TOKEN:` 前綴。Script 輸出此 token 並**繼續執行**;SKILL 進入下方確認 prompt

**BRANCH_MISMATCH_WARNING 處理** — 當 prepare 輸出含以 `TP_TOKEN:BRANCH_MISMATCH_WARNING` 開頭的行時,在繼續解析其他輸出之前,`AskUserQuestion` 詢問:

> 你目前在 `<current>` branch,但要推送 `<requested>`。確認推送 `<requested>`?

選項:
1. **Yes, push `<requested>`**:繼續執行 Step 3
2. **No, cancel**:跑 `git -C <remote-path> merge --abort` 清掉 prepare 已 stage 的 merge,結束 skill

**PENDING_MERGE_DETECTED 處理** — 當 prepare 輸出以 `PENDING_MERGE_DETECTED` 開頭時,`AskUserQuestion` 提示三選一:
1. **Abort + re-prepare**:跑 `git -C <remote-path> merge --abort`,再次跑 push-to-svn-prepare(返回本 Step)
2. **Continue to commit**:略過 prepare,直接進 Step 3(使用既有 staged merge)
3. **Cancel**:結束 skill,不做任何清理

### Step 3 — Parse subjects & 篩選

對 prepare 輸出的 `COMMITS` 區段每一行(格式 `<hash>|<subject>`):

#### 3.1 Subject 解析範圍

- **只看 subject 第一行**(`git log --format=%s` 已只給第一行)。
- regex 取 leading type:`^(?<type>[a-z]+)(\(.+\))?!?:` 從開頭抓 `<type>`(optional scope `(...)` + optional breaking `!` + `:`)。
- `revert: feat: ...` 等 nested type:**只看外層 `revert:`**,不解內層。

#### 3.2 載入 valid types(runtime,可動態同步使用者 `.commitlintrc.json`)

1. 找 `<repo-root>/.commitlintrc.json`(repo-root = `git rev-parse --show-toplevel`)。
2. 若**檔案存在 + JSON parse 成功 + `.rules['type-enum']` 是 `[level, applicable, [<types>]]` 形式 + `[2]` 是 array of strings**:用這個 array 為 `validTypes`。
3. 否則(檔不在 / parse 失敗 / 結構不對 / extends-only 寫法如 `{"extends":["@commitlint/config-conventional"]}` 不顯式 rules)→ **fallback 用 hard-coded default 12 類**(conventional commits 11 + `db`):
   ```
   feat, fix, refactor, perf, revert, docs, test, chore, style, build, ci, db
   ```
   並印 **stderr one-line notice**:
   ```
   tp-push-to-svn: using built-in default 12-type list; customize by adding `rules.type-enum` to `.commitlintrc.json`
   ```
4. **不靜默失敗**(沒檔不抓全空)、**不 fail 拒跑**(對 commitlint 標準 extends-only 寫法相容)。

#### 3.3 Kept-subset(turbo-plugin 篩選 source-of-truth — hard-coded,不從 `.commitlintrc.json` 讀)

```
feat, fix, refactor, perf, revert
```

這 5 類是「進得了 SVN message body 的 commit type」。固定在本 skill,**不**從 `.commitlintrc.json` 同步。

#### 3.4 篩選邏輯

對每個 commit:
- `Merge ` 開頭(無 conventional prefix)→ **篩除(silent)**:這是 git merge auto commit,SVN body 不需要。
- parse 出 `type`:
  - 若 `type` ∈ `keptSubset` → **保留**(進 SVN body)
  - 若 `type` ∈ `validTypes` 但 ∉ `keptSubset`(如 `docs` / `test` / `chore` / `style` / `build` / `ci` / `db`)→ **篩除(silent)**:SVN body 不需要這類紀錄
  - 若 `type` ∉ `validTypes`,或 parse 不出 leading type(如 `update parser logic`)→ **unknown type**,進 3.5
- 注:`git-svn-id:` trailer 不會在 subject 出現,本 skill 不處理。

#### 3.5 Unknown type prompt

對每個 unknown type commit,**逐筆** `AskUserQuestion`:

> Commit `<hash>` 的 subject「`<subject>`」沒有可辨識的 conventional commit type。應如何處理?

選項:
1. **保留進 SVN body**(本次 push 收這筆)
2. **篩除**(本次 push 略過)
3. **取消 push** — 讓使用者先 `git rebase -i` amend commit subject,然後重新跑 `/tp-push-to-svn`

選 3 → 立即跑 `git -C <remote-path> merge --abort` 清掉 prepare 階段 stage 的 merge,**結束 skill**。

### Step 4 — 組裝 SVN message body

```
<本次推送的高層 subject>(由使用者 propose 或 agent 從保留 commits 摘要)

本次送交內容:
- <subject1>
- <subject2>
...
```

若保留 commits 為 0(全被篩除):
```
<本次推送的高層 subject>

本次推送沒有程式碼層級的異動(僅文件 / 測試 / 設定 / 雜務)。
```

### Step 5 — 確認

`AskUserQuestion` 單頁確認,顯示:
- 保留的 commits(進 SVN body)
- 被篩除的 commits(僅留本地 git history)
- FILES section(prepare 階段的 svn status)
- 完整 SVN message(標題 + body)

選項:
- **Accept**:跑 Step 6
- **Edit message**:互動修改標題 / body 後回 Step 5
- **Cancel**:`git -C <remote-path> merge --abort`,結束 skill

> 注意:若此刻 confirm 前你新 commit 進 working branch,SKILL 會在 Step 6 偵測 git HEAD SHA 不符並 abort,提示重跑 prepare。請在 accept 前確認不會再 commit 新內容。

### Step 6 — Commit to SVN

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Submit-SvnCommit.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/submit-svn-commit.sh`)帶 `--branch <name> --message "<完整 SVN message>"`。Script 會:
- 再次 re-validate SVN HEAD(防止 race condition)
- `git commit --no-edit` 完成 stage merge
- 處理 `?` `!` `M` 的 svn add / delete
- 用 UTF-8 no-BOM temp file + `svn commit --file <tmp> --encoding UTF-8` push(避免中文 Big5 mangle)
- `svn update` 同步 working copy revision

Script 輸出 `Pushed to SVN r<rev>` 或 `No changes to commit to SVN`(全被 git-ignore 篩掉)。

### Step 7 — Optional release tag

**Trigger rule(KTD7 / R29 — 判準是「有無產出 git merge commit」,不是「svn commit 有無內容」)**:

- 只要 Step 2 的 prepare 階段找到 **≥1 個新 commit** 可 merge(即 `git log <remote-svn-ref>..<branch>` 非空、prepare 沒有印 `Nothing to push`,而是實際 stage 了一個 git merge commit)→ **詢問 release tag**。
- 這代表:即使 Step 6 回 `No changes to commit to SVN`(所有變更檔案都被 `svn:ignore`,svn commit 為空),**只要 git 那側仍產出了 merge commit,就照樣詢問** release tag。tag 指向的是 `remote-svn/<branch>` 這條 git 分支的 tip,與 svn 是否有內容無關。
- 反之,若 prepare 階段就 `Nothing to push`(git、svn 皆無變更、根本沒有 merge commit 產出)→ **直接跳過 Step 7**,不詢問。

當觸發條件成立時,用 `AskUserQuestion`:

- **Yes**:建立 release tag
- **No**:略過 tagging

選 Yes → 呼叫 `${CLAUDE_PLUGIN_ROOT}/scripts/Tag-Release.ps1`(或依執行路由改 `${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.sh`)帶 `--branch <name>`:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Tag-Release.ps1" -Branch "main"
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.sh" --branch "main"
```

Script 印出 `Created tag: <branch>-release-<yyyy-MM-dd>-<NNN>`(serial 同日自動遞增)。把建立的 tag 名回報給使用者。tag 指向 `remote-svn/<branch>` 的 tip。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **Valid type 動態讀取 + 安全 fallback**:每次跑都重讀 `.commitlintrc.json`,使用者改該檔加 / 移除 type 後本 skill 自動同步。fallback 用 default 12 類 + stderr notice,**不靜默失敗也不 fail 拒跑**。
- **Kept-subset hard-code 在本 skill,不從 `.commitlintrc.json` 讀**:`.commitlintrc.json` 定義「什麼是有效 commit type」(諮詢),turbo-plugin 定義「哪些 type 該進 SVN body」(篩選決策)。兩者刻意分離。
- **Unknown type 必須 prompt,不能猜**:SVN history 是永久紀錄,猜錯比明確問代價高。
- **Merge state 必須乾淨**:Step 2 開頭 check `MERGE_HEAD` 不存在;cancel 一律呼叫 `git merge --abort` 確保不留 stale state。
- **UTF-8 no-BOM commit message**:Step 6 script 已正確處理,**不要**改成 `svn commit -m "..."`(Windows CP_ACP 會 mangle 中文)。
- **不安裝 husky / commitlint hook**:本 skill 是篩選 source-of-truth,不需要 git hook enforce。
- **Pull-from-svn 是 prerequisite**:remote SVN HEAD 不 up-to-date 直接拒跑,讓使用者先 `/tp-pull-from-svn`。
- **Release tag 判準 = 有無 git merge commit**(Step 7):prepare 階段只要產出 merge commit 就詢問 tag,**即使 svn commit 為空**(檔案全被 `svn:ignore`)也照問;唯有 `Nothing to push`(根本無 merge commit)時才跳過。tag ref 用新命名 `remote-svn/<branch>`,不是舊的 `remote/<branch>`。

## Completion Checks

- 保留 commits 進 SVN body,被篩除的 commits 留本地 git history 但不在 SVN message。
- SVN log 顯示新 revision 含繁體中文正確編碼(no mangle)。
- 本地 `git log --oneline remote-svn/<branch>` 含 `Merge branch '<branch>' into remote-svn/<branch>` 自動 merge commit。
- Remote worktree 內 `git status --porcelain` 為空,`svn status` 為空(或只有 git-ignored 的本地檔案)。
- Unknown type commit 已透過 prompt 處理(保留 / 篩除 / 取消 push)。
- (Step 7,可選)若使用者選擇建立 release tag:`git tag -l "<branch>-release-*"` 出現新 tag,且 `git rev-parse <tag>` 等於 `git rev-parse remote-svn/<branch>`;若 prepare 為 `Nothing to push` 則不應出現詢問也不應有新 tag。

## Test Scenarios

- Manual: 設 `.commitlintrc.json` = `{"extends": ["@commitlint/config-conventional"]}` 不顯式 rules.type-enum → /tp-push-to-svn 應印 stderr notice 並用 default 12 類繼續 push,**不**靜默用空 type list 把所有 commit 篩光。
- **SHA pin guard (race protection)**: 跑 `/tp-push-to-svn --branch test-1` 進到 Step 5 Accept 前,在另一個 terminal `git commit` 新 commit 到 working branch。回 SKILL 按 Accept,push-to-svn-commit 應 throw `Branch '...' has new commits since prepare (pinned: ..., current: ...). Abort the merge...`。執行該指示,remote worktree `git status` clean。重跑 `/tp-push-to-svn` 應正常進。**.ps1 + .sh 兩條都要跑。**
- **SHA pin cleanup**: 成功 push 後,`<main>/.git/worktrees/<remote-name>/MERGE_HEAD.tp_branch_sha` 不應存在(`Test-Path` / `[[ -f ]]` 皆 false)。
- **PENDING_MERGE Continue path**: prepare 偵到既有 staged merge → SKILL 三選一選 Continue(option 2)→ 略過 prepare 直接進 Step 3,既有 staged content 推上 SVN,push 成功。
- **PENDING_MERGE Cancel path**: prepare 偵到既有 staged merge → SKILL 三選一選 Cancel(option 3)→ SKILL 結束,remote worktree `git status` 仍顯示 unstaged merge state(刻意不清,讓使用者手動處理)。

## Tool Preference

檔案 read / write 用 Read / Edit / Write;呼叫 `.commitlintrc.json` 用 JSON parse 解析(不要用 regex scan)。shell 操作限 `git` / `svn` / 跑 plugin scripts。
