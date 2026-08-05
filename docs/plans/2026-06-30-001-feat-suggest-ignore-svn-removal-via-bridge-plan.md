---
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
target_plugin: turbo-plugin-git-svn
created: 2026-06-30
---

# feat: tp-suggest-ignore 的 SVN 移除統一走 Remove-SvnFile 腳本(bridge reconcile,沿用 pull 的 commit 格式)

## Summary

把 `tp-suggest-ignore` 兩條會動到 SVN 的路徑(Un-track Option A、Inconsistency Option B)從「agent 裸下 `svn delete` + `svn commit`」改為**委派一支新的、測試過的統一腳本** `Remove-SvnFile.{ps1,sh}`。腳本在 bridge worktree 內對指定路徑做 `svn delete` + UTF-8 `svn commit`,並依 **pre-flight 分類**(該路徑在 bridge 是 git-tracked 還是 git-untracked)決定是否 reconcile:

- **git-tracked(Un-track A)** → svn delete 後 bridge git 端會出現刪除 → `git add -A` + commit + merge 進工作分支(**沿用 `Sync-FromSvn` 完全相同的 commit 格式**:`sync: svn r<rev>` + `Merge branch 'remote-svn/<branch>' into <branch>`),讓 `remote-svn/*` 的歷史與 pull 產生的無法區分、滿足「只有 sync + merge commit」的不變式。
- **git-untracked / git-ignored(Inconsistency B)** → 只做 svn delete + commit,bridge 本就乾淨、無需 reconcile。

**不走 `/tp-push-to-svn` 委派**(doc-review 證明該路徑結構上行不通,見 KTD2),也不動 `tp-push-to-svn` / `tp-pull-from-svn` 腳本行為。

---

## Problem Frame

實測:使用者跑 `/tp-suggest-ignore`,agent 偵測到 `XXX.csproj.user`(同被 git+SVN 追蹤)該 ignore,照現行 SKILL 在 main `git rm --cached` + 加 `.gitignore` + commit 後,**自己在 bridge worktree 裸下 `svn delete` + `svn commit`**——繞過正規腳本流程。

根因(已查證):

- `skills/tp-suggest-ignore/SKILL.md` Step 5 的 **Un-track Option A** 與 **Inconsistency Option B** 明文要 agent 裸下 `svn delete` + `svn commit`——是 SKILL 設計如此。
- 裸 `svn commit -m "..."` 有 Windows CP_ACP 把非 ASCII 檔名/訊息 mangle 的風險(push 腳本明文禁此寫法、改用 UTF-8 `--file`)。
- 對「同被 git+SVN 追蹤」的檔,裸 svn delete 還會留下 **bridge dirty**(檔案從磁碟+SVN 移除,但 `remote-svn/<branch>` git 分支仍追蹤),`Sync-FromSvn.ps1:36-39` 下次 pull 會因 bridge 不乾淨 throw、`:44-49` 還有 unmerged-sync 守衛。
- 對「已 git-ignored」的 Inconsistency 檔,bridge 端不會弄髒(該檔不在 git tree、`.svn/` 也 git-ignored),所以那條路徑的真正缺陷只有**編碼安全與可測試性**,不是不變式破壞。

使用者的不變式(設計約束):**`remote-svn/*` 系列分支只應有 merge commit 與 canonical `sync: svn r<rev>` commit;且這些 commit 要與 `/tp-pull-from-svn` 產生的格式一致。**

---

## Key Technical Decisions

**KTD1 — 統一腳本 + pre-flight 分類(svn delete 之前先分類)。** 一支 `Remove-SvnFile` 同時服務兩條路徑,在**任何 svn delete 之前**先 pre-flight:① bridge worktree 存在且 `<path>` 為 svn-tracked(`svn status` 空或 `M`;`?`/不存在 → fail loudly、零副作用)② 用 `git -C <bridge> ls-files --error-unmatch -- <path>` 判該路徑在 bridge 是否 **git-tracked**:tracked → reconcile 路徑(Un-track A,檔案在 `remote-svn/<branch>` tree);否則(git-untracked,含 ignored)→ no-reconcile 路徑(Inconsistency B)。**pre-flight 取代原 plan 把 guard 放在 svn delete 之後的設計**(doc-review F2/A2:post-commit guard 偵測得到、卻阻止不了已永久 svn-delete 且弄髒 bridge 的傷害)。

**KTD2 — 不走 `/tp-push-to-svn` 委派(doc-review F1/A1,跨 persona 同證)。** 委派 push 對 Un-track A 結構上死結:`git rm --cached`(留檔)後該檔在 main 是 `??`(未追蹤)→ push Step 1「main 不乾淨就拒跑」拒絕啟動;若先加 `.gitignore` 讓 main 乾淨,push 的 `git check-ignore` skip(`Submit-SvnCommit.ps1:146-154`)又會跳過、不刪。兩種狀態到不了「push 又啟動、又刪檔」。腳本自己 `svn delete`、不受 push 這兩條規則限制,故可**先加 `.gitignore`(main 乾淨)再呼叫腳本**,死結整個繞開。

**KTD3 — reconcile 的 git commit 沿用 pull(`Sync-FromSvn`)完全相同格式。** reconcile 路徑在 `remote-svn/<branch>` 上 `git add -A` 後 commit 訊息**必為** `sync: svn r<rev>`(`<rev>` = svn delete commit 後的新 revision,讀 `svn info --show-item revision`),併回工作分支用 `git -C <main> merge <remote.Branch> --no-ff -m "Merge branch '<remote.Branch>' into <branch>"`——與 `Sync-FromSvn.ps1:71,82` 一字不差。如此 `remote-svn/*` 只會有 `sync:` 與 merge commit,且與 pull 產生的歷史無法區分(使用者不變式)。

**KTD4 — Un-track A 保留本機檔靠 main 端 `git rm --cached` + 先加 `.gitignore`。** tp-suggest-ignore 在呼叫腳本前於 main:`git rm --cached <file>`(取消追蹤、**保留磁碟檔**)→ append `.gitignore` → commit(main 乾淨)。之後腳本的 merge(reconcile)把 `remote-svn/<branch>` 的刪除併進 main:因 main 已 `git rm --cached` 該檔,兩邊 git tree 皆無此檔 → merge 乾淨、**且不會刪掉 main 工作目錄的磁碟副本**(merge 不動 untracked 檔)。

**KTD5 — Inconsistency B 的理由是編碼安全/可測試/統一,非不變式(doc-review A4)。** Inconsistency 檔 git-untracked,`svn delete` 不弄髒 bridge、不變式自動成立;走腳本是為了 UTF-8 `--file` commit(避免裸 `svn commit -m` mangle 中文)+ 統一可測試路徑,而非修不變式。Problem Frame / 文案據此重述。

**KTD6 — PS 5.1 / 編碼一致性。** 新腳本遵守 repo `CLAUDE.md` 五禁忌;svn commit 走 UTF-8 no-BOM temp 檔 `--file <tmp> --encoding UTF-8`、svn-interacting 區把 `[Console]::OutputEncoding` 設系統 ANSI codepage(比照 `Submit-SvnCommit.ps1:33-34,129-133`,讓非 ASCII 路徑 argv 對齊);status `M` 的檔 `svn delete --force`;native exe 不用 `2>&1`;含中文 `.ps1` 存 UTF-8 BOM;`[System.IO.Path]::Combine`;單元素 pipeline 用 `@()`。

---

## High-Level Technical Design

```mermaid
flowchart TD
    subgraph SKILL[tp-suggest-ignore]
      cls{檔案分類}
      cls -- "同被 git+SVN 追蹤<br/>(Un-track A)" --> a1[git rm --cached + 先加 .gitignore + commit<br/>(main 乾淨、磁碟檔保留)]
      a1 --> call1[呼叫 Remove-SvnFile -Path file]
      cls -- "git-ignored + svn-tracked<br/>(Inconsistency B)" --> call2[呼叫 Remove-SvnFile -Path file]
      cls -- "git 停追蹤、SVN 保留 (Un-track B)" --> b1[git rm --cached + 立即 .gitignore + commit<br/>不動 SVN]
      cls -- "Inconsistency A:讓 git 也追蹤" --> d1[從 .gitignore 移除 + commit（不變）]
    end
    subgraph SCRIPT[Remove-SvnFile（統一）]
      pf[pre-flight:bridge 存在? path svn-tracked?<br/>git-tracked? — 任何 svn delete 之前]
      pf -- "非 svn-tracked / bridge 缺" --> rej[[拒絕、零副作用]]
      pf -- ok --> del[svn delete（M 用 --force）+ UTF-8 svn commit]
      del --> isTracked{path 在 bridge git-tracked?}
      isTracked -- "是(Un-track A)" --> rec[git add -A + commit 'sync: svn r&lt;rev&gt;'<br/>+ merge --no-ff 進工作分支]
      isTracked -- "否(Inconsistency B)" --> clean[驗證 bridge git status 乾淨]
    end
    call1 --> pf
    call2 --> pf
```

> 上述為設計方向示意,非實作規格。reconcile 的兩個 commit 格式以 `Sync-FromSvn` 為準(見 KTD3)。

---

## Requirements

- **R1.** 新增統一腳本 `Remove-SvnFile.{ps1,sh}`:對 bridge 內 svn-tracked 路徑做 `svn delete` + UTF-8 `svn commit`;git-tracked 路徑走 reconcile、git-untracked 路徑不 reconcile。
- **R2.** reconcile 的 git commit **沿用 `Sync-FromSvn` 格式**:`remote-svn/<branch>` 上 `sync: svn r<rev>`、併回工作分支 `Merge branch 'remote-svn/<branch>' into <branch>`(`--no-ff`);`remote-svn/*` 只會有 sync + merge commit。
- **R3.** pre-flight 在**任何 svn delete 之前**完成:bridge 缺 / 路徑非 svn-tracked → fail loudly、零副作用;並於此處判定 reconcile vs no-reconcile。
- **R4.** **不走 push 委派**;Un-track A 由 tp-suggest-ignore 先做 `git rm --cached` + `.gitignore` + commit(main 乾淨、保留磁碟檔)再呼叫腳本。
- **R5.** PS 5.1 五禁忌、UTF-8 `--file` commit、ANSI OutputEncoding 區、status-`M` 用 `--force`、native exe 不 `2>&1`。
- **R6.** 腳本兩層測試(Pester + shunit2,svn-gated;無 svn 自我 SKIP);SKILL prose 不補自動測試(靠腳本測試 + 人工)。
- **R7.** 更新 `tp-suggest-ignore` 的 Step 4/5、Decision Rules、Completion Checks、Test Scenarios;README + CHANGELOG 同步。不動 `tp-push-to-svn` / `tp-pull-from-svn` 腳本行為。

---

## Implementation Units

### U1. 統一腳本 `Remove-SvnFile.{ps1,sh}`

- **Goal**:把「對 bridge 內 svn-tracked 路徑做 svn delete + UTF-8 commit,並依 git-tracked 與否 reconcile」固定成可測試腳本(KTD1/KTD3/KTD6)。
- **Requirements**:R1, R2, R3, R5。
- **Dependencies**:無(可先行)。
- **Files**:
  - 建 `plugins/turbo-plugin-git-svn/scripts/Remove-SvnFile.ps1`
  - 建 `plugins/turbo-plugin-git-svn/scripts/remove-svn-file.sh`
  - 測試於 U2。
- **Approach**:
  - 參數:`-Branch`(預設 `main`)、`-Path`(必要,bridge 內相對路徑);`.sh` 用 `--branch` / `--path`。
  - **pre-flight(任何 mutation 之前,KTD1/R3)**:`Probe-GitVersion` → `Get-MainWorktree`/`Get-WorktreesDir`/`Resolve-RemoteWorktree` 定位 bridge(缺 → fail loudly)→ `<path>` 在 bridge 存在且 svn-tracked(`svn status` 空或 `M`;`?`/不存在 → fail loudly、零副作用)→ 以 `git -C <bridge> ls-files --error-unmatch -- <path>`(EAP-safe)判 **git-tracked?** 決定 reconcile vs no-reconcile。
  - **svn delete + commit**:在 bridge 內 `svn delete -- <path>`(status 為 `M` → 加 `--force`)→ 讀新 `svn info --show-item revision` → UTF-8 no-BOM temp 檔 `svn commit --file <tmp> --encoding UTF-8 -- <path>`(訊息如 `remove <path> from svn (turbo-plugin)`)。
  - **reconcile 路徑(git-tracked,KTD3)**:bridge 出現 ` D <path>` → `git -C <bridge> add -A` → `git -C <bridge> commit -m "sync: svn r<rev>"`(**完全沿用 Sync-FromSvn 格式**)→ `git -C <main> merge <remote.Branch> --no-ff -m "Merge branch '<remote.Branch>' into <branch>"`。merge 前 main 須乾淨(呼叫端負責);merge 衝突 → 比照 `Sync-FromSvn` 的回滾/回報姿態(abort + 還原 + 列衝突檔,不自動硬解)。
  - **no-reconcile 路徑(git-untracked / ignored)**:svn delete + commit 後**驗證** `git -C <bridge> status --porcelain` 乾淨(理應乾淨:檔案 git-untracked、`.svn/` ignored);若意外非空 → fail loudly(代表分類誤判,不靜默)。
  - **post**:`svn update` 後置 resync(EAP-soften,比照 `Submit-SvnCommit.ps1:200-207`)。
  - **rollback**:svn delete 已 commit 為永久(不回滾 svn);reconcile 階段(git add/commit/merge)若失敗,比照 sibling 腳本回滾本機 git 端(merge abort、必要時還原 HEAD)。
  - PS5.1:ANSI OutputEncoding 區包住 svn;含中文 `.ps1` 存 UTF-8 BOM;`[System.IO.Path]::Combine`;native exe 不 `2>&1`。
- **Execution note**:建議先補 U2 的失敗測試(非 svn-tracked → 拒絕、bridge 缺 → 拒絕)再收斂兩條 happy path。
- **Patterns to follow**:`scripts/Sync-FromSvn.ps1`(bridge 定位 + dirty 判斷 + `sync: svn r<rev>` commit + `Merge ...` merge + 衝突回滾,**reconcile 路徑直接鏡像其 tail**)、`scripts/Submit-SvnCommit.ps1`(UTF-8 `--file` commit、ANSI OutputEncoding 區、`svn delete`/`--force`、`svn update` EAP-soften)、`scripts/lib/Common.{ps1,sh}`。
- **Technical design**:見 HTD 的 SCRIPT 子圖。
- **Test scenarios**:見 U2。
- **Verification**:在 sandbox 對 bridge 內 git-tracked 檔跑 → `svn list` 不含該檔、`remote-svn/<branch>` 末筆為 `sync: svn r<rev>`、工作分支末筆為對應 `Merge branch ...`、bridge 乾淨;對 git-ignored 檔跑 → svn 移除、bridge 乾淨、無新 git commit;對非 svn-tracked 路徑 → 非零 exit、零副作用。

### U2. `Remove-SvnFile` 兩層測試

- **Goal**:覆蓋 U1 兩條路徑與 pre-flight,svn-gated,遵守嚴格隔離。
- **Requirements**:R6。
- **Dependencies**:U1。
- **Files**:
  - 建 `plugins/turbo-plugin-git-svn/tests/unit/scripts/Remove-SvnFile.test.ps1`
  - 建 `plugins/turbo-plugin-git-svn/tests/unit/scripts/remove-svn-file.test.sh`
  - 沿用 `tests/fixtures/seed/` 或在 sandbox `svnadmin create` + `Initialize-GitSvnBridge` 建 bridge。
- **Approach**:鏡像 `Initialize-GitSvnBridge.test.{ps1,sh}` / `New-RemoteBridge.test.{ps1,sh}` 腳手架:PS `New-Sandbox`/`Remove-Sandbox`(repo 相對、ReadOnly 清理)+ `Invoke-PsScript`;`.sh` repo 相對 sandbox(非 `mktemp`)+ `HAS_SVN`/`startSkipping`。**所有 svn client 帶 `--config-dir <sandbox>/.svnconfig`**。建 bridge 後分別放一個 git-tracked 檔與一個 git-ignored+svn-tracked 檔當受測對象。
- **Test scenarios**:
  - **Covers R1/R2(reconcile).** git-tracked 檔 → 跑腳本 → `svn list` 不含該檔;`remote-svn/<branch>` 末筆 commit message **正好** `sync: svn r<rev>`;工作分支末筆為 `Merge branch 'remote-svn/<branch>' into <branch>`;bridge `git status` 乾淨;`remote-svn/<branch>` 無任何非-sync/非-merge commit。
  - **Covers R1/R3(no-reconcile).** git-ignored + svn-tracked 檔 → svn 移除、bridge 乾淨、`remote-svn/<branch>` **無**新 commit(no-reconcile)。
  - **Covers R3(pre-flight).** 路徑為 svn `?`/不存在 → 非零 exit、無 svn commit、無副作用;bridge worktree 缺 → fail loudly。
  - **Covers R2(格式一致).** 斷言 reconcile commit 與一次真實 `Sync-FromSvn` 產生的 message 格式相同(`sync: svn r<rev>` / `Merge branch ...`)。
  - **Covers R5(編碼).** 非 ASCII(中文)檔名 → `svn commit --file ... --encoding UTF-8` 後 `svn log` 訊息與檔名編碼正確(no mangle);(若可)status-`M` 檔 → `--force` 成功。
  - **svn-gate**:無 svn → 全 svn 案 SKIP(非 FAIL);framework gate 仍綠。
  - **零污染**:跑完 `%APPDATA%\Subversion` 未被改、sandbox 外無殘留。
- **Verification**:`tests/Invoke-ScriptTests.ps1` / `tests/invoke-script-tests.sh` 自動探索並執行;有 svn 全 PASS、無 svn SKIP 計綠。
- **Patterns to follow**:`tests/unit/scripts/Initialize-GitSvnBridge.test.{ps1,sh}`、`tests/unit/scripts/New-RemoteBridge.test.{ps1,sh}`、`tests/fixtures/reset/Reset-Fixture.ps1`(`--config-dir` + ReadOnly 清理)、`tests/lib/ScriptsCommon.ps1`。

### U3. `tp-suggest-ignore` SKILL 重排(兩條 SVN 路徑改委派 `Remove-SvnFile`)

- **Goal**:把 Step 5 的裸 svn delete 換成委派統一腳本;更新規則/檢查/情境;移除 push 委派構想。
- **Requirements**:R4, R7。
- **Dependencies**:U1。
- **Files**:
  - 改 `plugins/turbo-plugin-git-svn/skills/tp-suggest-ignore/SKILL.md`(Step 4 選項描述、Step 5 執行段、Decision Rules、Completion Checks、Test Scenarios、Purpose 視需要)。
- **Approach**:
  - **Un-track Option A**(Step 5):① 在 main `git rm --cached <file>`(保留磁碟檔)② append `.gitignore` ③ `git add .gitignore` + commit(main 乾淨)④ 依執行路由委派 `Remove-SvnFile.{ps1,sh}`(`-Branch <branch>` `-Path <file>`)→ 腳本走 reconcile(svn delete + `sync: svn r<rev>` + merge)。**順序眉角**:這裡 `.gitignore` **可先加**(與 push 委派相反),因為腳本不受 check-ignore skip 影響(KTD2/KTD4)。
  - **Inconsistency Option B**(Step 5):直接依執行路由委派 `Remove-SvnFile`(`-Path <file>`)→ 腳本走 no-reconcile。取代裸 `svn delete`+`svn commit`。
  - **Un-track Option B**(Step 5,不動 SVN):維持純 git(`git rm --cached` + **立即** `.gitignore` + commit);加註「立即 ignore 是為了保護 SVN 副本:日後任意 push 會 merge 掉它 → bridge `!` → 但 check-ignore skip → 不會被 svn-delete」。
  - **Inconsistency Option A**:不變(從 `.gitignore` 移除、不動 SVN)。
  - **執行路由**:沿用 git-svn 既有「有 Git Bash 用 Bash 工具跑 `.sh`,否則 PowerShell 工具跑 `.ps1`(單破折號參數)」段;若該 SKILL 尚無此段則補上。
  - **移除**所有要求 agent 裸下 `svn delete`/`svn commit` 的 prose;**不**引入 `/tp-push-to-svn` 委派(KTD2 已證行不通)。
  - 更新 **Decision Rules**:新增「兩條 SVN 移除路徑一律委派 `Remove-SvnFile`、不裸 svn、不委派 push」「Un-track A 的 `.gitignore` 可先加(腳本不受 check-ignore 限制)」「remote-svn/* 只有 merge + `sync: svn r<rev>` commit、格式同 pull」;移除/改寫原裸 svn 規則。
  - 更新 **Completion Checks**:Un-track A → `svn list` 不含該檔、`remote-svn/<branch>` 末筆 `sync: svn r<rev>` + 工作分支 `Merge branch ...`、main `git ls-files` 不含該檔但檔案仍在 main 磁碟、`.gitignore` 含該 pattern;Inconsistency B → `svn list` 不含該檔、bridge 乾淨。
  - 更新 **Test Scenarios**(人工):Un-track A(同追蹤檔 → 委派腳本 → 檔留本機、SVN 移除、remote-svn/* 只多 sync+merge)、Inconsistency B(git-ignored 檔 → 委派腳本)。
- **Execution note**:agent-prose,無自動測試層;以 U2 腳本測試 + 一次真實 `/tp-suggest-ignore`(Un-track A 同追蹤檔、Inconsistency B git-ignored 檔)人工驗證為準。
- **Patterns to follow**:`skills/tp-checkout-svn-branch/SKILL.md`(委派腳本 + 執行路由)、`skills/tp-push-to-svn/SKILL.md`(執行路由寫法)、本 session「不洩漏內部術語 / 不輸出 Step N」白話原則。
- **Test scenarios**:`Test expectation: none — SKILL agent-prose;行為由 U2 + 人工 /tp-suggest-ignore 驗證`。
- **Verification**:真實 `/tp-suggest-ignore`:(a) 對同被 git+SVN 追蹤的 `*.csproj.user` → Un-track A 完成、檔案留本機、SVN 移除、`remote-svn/main` 只多 `sync:`+merge commit;(b) 對 git-ignored + svn-tracked 檔 → Inconsistency B 經腳本移除、bridge 乾淨。

### U4. README + CHANGELOG 同步

- **Goal**:文件反映新腳本與兩條路徑的新行為。
- **Requirements**:R7。
- **Dependencies**:U1, U3。
- **Files**:
  - 改 `plugins/turbo-plugin-git-svn/README.md`(腳本清單加 `Remove-SvnFile`;「從 SVN 移除/un-track」說明更新為委派腳本)。
  - 改 `plugins/turbo-plugin-git-svn/CHANGELOG.md`(0.1.0 種子:腳本對清單加 `Remove-SvnFile`、tp-suggest-ignore 條目補述「Un-track / Inconsistency 的 SVN 移除改委派 `Remove-SvnFile`〔reconcile 沿用 pull 的 sync+merge 格式〕,不再裸 svn delete」)。
- **Approach**:0.1.0 種子直接改(plugin 未發版);commit type 用 `feat`。
- **Test scenarios**:`Test expectation: none — 純文件`。
- **Verification**:README 腳本清單含 `Remove-SvnFile`;CHANGELOG 0.1.0 描述與最終行為一致。

---

## Scope Boundaries

**In scope**:統一腳本 `Remove-SvnFile.{ps1,sh}` + 兩層測試、`tp-suggest-ignore` 的 Un-track A(委派腳本、`.gitignore` 先加)/ Inconsistency B(委派腳本)/ Un-track B(`.gitignore` 時機釐清)、Decision Rules / Completion Checks / Test Scenarios、README/CHANGELOG。

**Out of scope / 不動**:
- `tp-push-to-svn` / `tp-pull-from-svn` 的腳本行為(`!`→delete、check-ignore skip、sync commit、merge 皆已正確;reconcile 沿用其格式但不改其碼)。
- `tp-suggest-ignore` 的 Direct mode(`--add-git` / `--remove-git`)、Git Ignore 分類、Inconsistency Option A。
- 其它 plugin(dotnet / db)。

### Deferred to Follow-Up Work
- **多檔批次**:一次分析出多個 Un-track A / Inconsistency B 檔時,目前每檔一次 `Remove-SvnFile`(各一 svn commit + 各一 sync+merge)。日後可加「多 `-Path` 單次 commit」批次模式減少 revision 數。
- 既有 per-case unit test 的 `.sh` sandbox / `--config-dir` 對齊嚴格隔離(預先存在偏差)。

---

## Risks & Dependencies

- **R-risk1 — pre-flight 分類錯判**:把 git-tracked 當 git-ignored(或反之)會走錯 reconcile 分支。緩解:以 `git ls-files --error-unmatch` 為單一判準(tracked 才 reconcile),no-reconcile 路徑事後再驗 bridge 乾淨當保險;U2 兩類各一案。
- **R-risk2 — reconcile merge 衝突**:理論上 main 與 `remote-svn/<branch>` 都刪同一檔 → 不應衝突;若因其它原因衝突,比照 `Sync-FromSvn` abort + 還原 + 回報,不自動硬解。U2 以乾淨刪除為主、衝突路徑沿用 sibling 既有覆蓋。
- **R-risk3 — status-`M` 檔**:svn delete 對有本機修改的檔可能需 `--force`。緩解:pre-flight 接受 `M`、delete 對 `M` 加 `--force`;U2(若環境可造)補一案。
- **R-risk4 — PS5.1 / 編碼**:非 ASCII 檔名 argv、`svn commit` mangle、BOM。緩解:遵五禁忌 + UTF-8 `--file` + ANSI OutputEncoding 區(比照 `Submit-SvnCommit`);U2 中文檔名案。
- **R-risk5 — Un-track A 保留磁碟檔的正確性**:必須是 `git rm --cached`(非 `git rm`)+ merge 不動 untracked,才會保留本機檔。緩解:U3 明定 `--cached`、Completion Check 驗「main 磁碟仍有該檔且 `git ls-files` 不含」。
- **Dependency**:Pester ≥5、shunit2(已 vendored)、svn/svnadmin(svn-gated)、git ≥2.31。

---

## Sources & Research

- 本 session 對話與查證:`Submit-SvnCommit.ps1:146-173`(`!`→svn delete、check-ignore skip、UTF-8 `--file`、`svn update` EAP-soften)、`Sync-FromSvn.ps1:36-49,63-82`(dirty/unmerged 守衛、`sync: svn r<rev>` commit、`Merge branch ...` merge、衝突回滾)、`tp-suggest-ignore/SKILL.md` Step 5、`tp-push-to-svn/SKILL.md` Step 1(main-clean gate)。
- doc-review(2026-06-30,coherence + feasibility + adversarial):F1/A1(push 委派 Un-track A 結構死結,跨 persona 同證)、F2/A2(guard 須 pre-flight)、A3(push 中途分支,放棄 push 委派後消解)、A4(Inconsistency B 理由重述為編碼/可測試)。
- 既有腳本範本:`scripts/Sync-FromSvn.ps1`、`scripts/Submit-SvnCommit.ps1`、`scripts/Initialize-GitSvnBridge.{ps1,sh}`、`scripts/New-RemoteBridge.{ps1,sh}`、`scripts/lib/Common.{ps1,sh}`。
- 測試慣例:`tests/Invoke-ScriptTests.ps1` / `tests/invoke-script-tests.sh`、`tests/unit/scripts/Initialize-GitSvnBridge.test.{ps1,sh}`、`tests/fixtures/reset/Reset-Fixture.ps1`(`--config-dir` + ReadOnly 清理)。
- 慣例:repo `CLAUDE.md`(PS5.1 五禁忌、測試標準)、`plugins/turbo-plugin-git-svn/README.md`。相關 memory:`project_git_svn_tp_setup_bootstrap`、`feedback_no_internal_jargon_in_user_prompts`。

---

## Product Contract preservation

Solo plan(`product_contract_source: ce-plan-bootstrap`);無上游 brainstorm,無 Product Contract 需保留。
