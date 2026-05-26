---
name: tp-push-to-svn
description: '把本地工作分支推上 SVN(透過 remote-<branch> worktree),自 parse 每個 commit subject 篩 SVN history。**SVN 寫操作影響永久 history,必須由使用者明確要求才執行;agent 偵測到「使用者完成一輪改動準備 push」時可建議,但需明確確認**。'
argument-hint: '--branch <main|test-<n>>'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-push-to-svn

## Purpose

把本地 git working branch 的新 commits push 上 SVN。為了讓 SVN history 保留可讀的程式碼變更紀錄,本 skill **自 parse 每個 commit subject**,依 commit type 篩選哪些進入 SVN message body。

**設計理念**:`.commitlintrc.json` 是純諮詢的 commit type 來源(無 husky / 無 commitlint hook 強制),enforce 由本 skill 在 push 時完成。

## Procedure

### Step 1 — Pre-flight clean check

- 跑 `git status --porcelain` 確認當前 main worktree 乾淨。非空 → 拒跑,提示先 commit / stash。
- 確認 `--branch` 參數合法(`main` / `test-<n>`)。

### Step 2 — Prepare merge

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-prepare.{ps1,sh}` 帶 `--branch <name>`。Script 會:
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
- `BRANCH_MISMATCH_WARNING current=<current> requested=<requested>` → Script 輸出此 token 並**繼續執行**;SKILL 進入下方確認 prompt

**BRANCH_MISMATCH_WARNING 處理** — 當 prepare 輸出含 `BRANCH_MISMATCH_WARNING` 行時,在繼續解析其他輸出之前,`AskUserQuestion` 詢問:

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

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.{ps1,sh}` 帶 `--branch <name> --message "<完整 SVN message>"`。Script 會:
- 再次 re-validate SVN HEAD(防止 race condition)
- `git commit --no-edit` 完成 stage merge
- 處理 `?` `!` `M` 的 svn add / delete
- 用 UTF-8 no-BOM temp file + `svn commit --file <tmp> --encoding UTF-8` push(避免中文 Big5 mangle)
- `svn update` 同步 working copy revision

Script 輸出 `Pushed to SVN r<rev>` 或 `No changes to commit to SVN`(全被 git-ignore 篩掉)。

## Decision Rules

- **force_bash routing**: 呼叫 prepare / commit script 前,讀取 `.turbo-plugin/config.toml` 中 `[svn] force_bash` 的值(透過 `Resolve-ConfigValue -Section 'svn' -Key 'force_bash' -Default 'false'`)。若為 `true`,改以 Git Bash 執行對應的 `.sh` sibling 而非 `.ps1`(對應 Step 0.5 case (a) 的中文 Windows 使用者)。
- **Valid type 動態讀取 + 安全 fallback**:每次跑都重讀 `.commitlintrc.json`,使用者改該檔加 / 移除 type 後本 skill 自動同步。fallback 用 default 12 類 + stderr notice,**不靜默失敗也不 fail 拒跑**。
- **Kept-subset hard-code 在本 skill,不從 `.commitlintrc.json` 讀**:`.commitlintrc.json` 定義「什麼是有效 commit type」(諮詢),turbo-plugin 定義「哪些 type 該進 SVN body」(篩選決策)。兩者刻意分離。
- **Unknown type 必須 prompt,不能猜**:SVN history 是永久紀錄,猜錯比明確問代價高。
- **Merge state 必須乾淨**:Step 2 開頭 check `MERGE_HEAD` 不存在;cancel 一律呼叫 `git merge --abort` 確保不留 stale state。
- **UTF-8 no-BOM commit message**:Step 6 script 已正確處理,**不要**改成 `svn commit -m "..."`(Windows CP_ACP 會 mangle 中文)。
- **不安裝 husky / commitlint hook**:本 skill 是篩選 source-of-truth,不需要 git hook enforce。
- **Pull-from-svn 是 prerequisite**:remote SVN HEAD 不 up-to-date 直接拒跑,讓使用者先 `/tp-pull-from-svn`。

## Completion Checks

- 保留 commits 進 SVN body,被篩除的 commits 留本地 git history 但不在 SVN message。
- SVN log 顯示新 revision 含繁體中文正確編碼(no mangle)。
- 本地 `git log --oneline remote/<branch>` 含 `Merge branch '<branch>' into remote/<branch>` 自動 merge commit。
- Remote worktree 內 `git status --porcelain` 為空,`svn status` 為空(或只有 git-ignored 的本地檔案)。
- Unknown type commit 已透過 prompt 處理(保留 / 篩除 / 取消 push)。

## Test Scenarios

- Manual: 設 `.commitlintrc.json` = `{"extends": ["@commitlint/config-conventional"]}` 不顯式 rules.type-enum → /tp-push-to-svn 應印 stderr notice 並用 default 12 類繼續 push,**不**靜默用空 type list 把所有 commit 篩光。
- **SHA pin guard (race protection)**: 跑 `/tp-push-to-svn --branch test-1` 進到 Step 5 Accept 前,在另一個 terminal `git commit` 新 commit 到 working branch。回 SKILL 按 Accept,push-to-svn-commit 應 throw `Branch '...' has new commits since prepare (pinned: ..., current: ...). Abort the merge...`。執行該指示,remote worktree `git status` clean。重跑 `/tp-push-to-svn` 應正常進。**.ps1 + .sh 兩條都要跑。**
- **SHA pin cleanup**: 成功 push 後,`<main>/.git/worktrees/<remote-name>/MERGE_HEAD.tp_branch_sha` 不應存在(`Test-Path` / `[[ -f ]]` 皆 false)。
- **schema_version warning**: 在 `.turbo-plugin/config.toml` 加 `schema_version = 2`,跑 `/tp-push-to-svn`(或任何 SKILL),stderr 應出現一行 `turbo-plugin: ... schema_version=2 is not recognized ...`。同一 process 後續 read 不重複出現。
- **PENDING_MERGE Continue path**: prepare 偵到既有 staged merge → SKILL 三選一選 Continue(option 2)→ 略過 prepare 直接進 Step 3,既有 staged content 推上 SVN,push 成功。
- **PENDING_MERGE Cancel path**: prepare 偵到既有 staged merge → SKILL 三選一選 Cancel(option 3)→ SKILL 結束,remote worktree `git status` 仍顯示 unstaged merge state(刻意不清,讓使用者手動處理)。

## Tool Preference

檔案 read / write 用 Read / Edit / Write;呼叫 `.commitlintrc.json` 用 JSON parse 解析(不要用 regex scan)。shell 操作限 `git` / `svn` / 跑 plugin scripts。
