---
date: 2026-05-27
topic: turbo-plugin-v1.0-manual-test-plan
---

# turbo-plugin v1.0 PR 前手動測試計畫

## Summary

兩階段的 v1.0.0 PR 驗證計畫。**Phase 1**(由 orchestrator 自動跑):18 個 `.ps1`(Windows PowerShell 5.1)+ 18 個 `.sh`(Git Bash for Windows)共 36 個 script,完整覆蓋每一條 happy / error / decision branch / 中文 edge,**全綠才進下一階段**。**Phase 2**(使用者手動跑):14 個 skill 各跑 1 個快樂路徑 + 2-3 個主要錯誤路徑 + 中文 edge,使用者在 `C:\Turbo\test-turbo-plugin` 開 Claude Code 執行 prompt 並把 agent 回覆轉述回來;orchestrator 準備 fixture / prompt / SVN repo / tracking,並在 case fail 時即停 root-cause + 修 turbo-plugin + 重跑該 case。

---

## Problem Frame

- **14 skill + 36 個 script(18 對 `.ps1` / `.sh`)剛實作完,完全沒有驗證**:從 v0.2.7 走到 1.0.0 的 11 個 implementation unit 全部只跑過 lint 與型別檢查,沒有任何 end-to-end 觸發。push v1.0.0 到 marketplace 之前必須對核心 path 有信心。
- **中文 path 是最高風險區**:Windows PowerShell 5.1(.NET Framework 4.x + system codepage 950)在處理 UTF-8 BOM、`.ps1` 含中文字串、`svn log` 輸出、commit message、檔名 / 路徑時有多層 encoding 風險。U10(svn-log)雖然已用 `--xml` 修了 console codepage 風險,但其他 script / skill 沒有系統性驗證。
- **沒有既有使用者 = 沒有災難**:1.0.0 是第一個 marketplace release,沒有 v0.2.x 既有使用者要遷移;這降低了 regression 範圍的必要性 — 不需要建立全分支 regression suite,但需要驗證使用者第一次裝、第一次跑的 happy path + 主要錯誤路徑乾淨。
- **Skill 觸發必須是真實 Claude Code session**:Skill 的核心邏輯包含 agent 對 SKILL.md 的判讀與互動(AskUserQuestion、subagent 派發、回覆解析),自動化會 mock 掉測試目的。Phase 2 必須由真人在 Claude Code 觸發。
- **跨 worktree 同步沒有手動驗證過**:`tp-suggest-ignore --add-svn` 跨多個 `remote-*` worktree 做 per-worktree commit + rollback 是 v1.0 一個關鍵 invariant,但純看程式碼無法驗證 propset 失敗時的 rollback 真的有跑、main worktree 沒留下髒狀態。
- **tp-setup 推薦項目實際裝出去會影響使用者 user-level Claude Code 設定**:LSP plugin(csharp-lsp / typescript-lsp)啟用 + LSP server binary 安裝 + compound-engineering 自動更新 + agent teams 都會真實寫到使用者 `~/.claude/settings.json` 與本機 `dotnet tool` / `npm -g`。dry-run 沒辦法驗證實際安裝是否成功,但實際安裝會在使用者環境留下需要手動清的痕跡 — 這個取捨需要使用者知情。

---

## Key Flows

- F1. **Phase 1 script 自動測試循環**
  - **Trigger:** Phase 1 啟動。
  - **Actors:** A1(orchestrator)。
  - **Steps:**
    1. orchestrator 在 `C:\Turbo\test-turbo-plugin` 建立 base fixture(`.sln` + 樣本 `.csproj` + 樣本 source + `applicationhost.config` + `.turbo-plugin/` 結構 + `.git` + SVN bridge worktree skeleton)。
    2. SVN repo 建立在 `C:\Turbo\test-turbo-plugin-svn-repo`(test-turbo-plugin 外面),seed 包含中文 commit msg 樣本的 r1-r20 歷史。
    3. 對每個 `.ps1` script,逐個 case 從一個乾淨的 fixture snapshot 開始 → orchestrator 用 `powershell.exe -File <script>.ps1 <args>` 直接 invoke → 收集 exit code / stdout / stderr / fixture 結果差異 → 對照預期 assertion → 標 PASS/FAIL。
    4. 對應的 `.sh` script 用 Git Bash(`C:\Program Files\Git\bin\bash.exe -c "..."`)同樣方式 invoke。
    5. case fail → 進 F5 fail-then-fix loop;PASS → 換下一個 case。
    6. 36 個 script × 所有 case 全部 PASS → tracking doc 標 Phase 1 完成 → 進 Phase 2。
  - **Outcome:** 18 對 script 的 happy / error / 中文 path 都有 evidence-bound PASS 紀錄,turbo-plugin 程式層基礎穩固。
  - **Covered by:** R1-R10, R20-R23, R27-R29

- F2. **Phase 2 skill 手動測試循環**
  - **Trigger:** Phase 1 全綠後 + 使用者準備好開始 Phase 2。
  - **Actors:** A1(orchestrator)、A2(使用者)、A3(test-turbo-plugin 的 Claude Code agent)。
  - **Steps:**
    1. orchestrator 預先準備本 session 要跑的 1-2 個 skill 的 fixture 狀態(SVN state、env、檔案結構),直接寫到 `C:\Turbo\test-turbo-plugin`。
    2. orchestrator 給使用者一個 prompt + 預期觀察點(「應該觸發 X skill,應該問 Y 問題,應該寫 Z 檔案」)。
    3. 使用者在 `C:\Turbo\test-turbo-plugin` 開 Claude Code,貼入 prompt,讓 agent 跑完。
    4. 使用者把 agent 完整回覆(text + 主要 tool calls 摘要 + 任何問題)轉述回來。
    5. orchestrator 判讀 → 標 PASS/FAIL/PARTIAL + 紀錄 evidence(轉述摘要、檔案差異)。
    6. case fail → 進 F5;PASS → 換下一個 case。
    7. 14 skill × 各自 1 happy + 2-3 error + 中文 edge 全部處理完 → tracking doc 標 Phase 2 完成。
  - **Outcome:** 14 skill 的核心 user-facing 行為有真實 Claude Code session 的驗證紀錄。
  - **Covered by:** R11-R17, R20-R23, R24-R26, R27-R29

- F3. **中文 edge case 驗證**
  - **Trigger:** 跨 Phase 1 / Phase 2,任何含中文輸入 / 輸出 / 路徑的 case。
  - **Actors:** A1, A2, A3。
  - **Steps:**
    1. 一份共用「中文樣本字典」(路徑片段、檔名、commit msg、log 樣本、註解樣本)在 tracking doc 內維護。
    2. 每個 script / skill 至少從字典挑 1 個樣本注入(路徑、檔名、commit msg、輸出解碼、`.ps1` UTF-8 BOM 等對應)。
    3. 驗證點:不 crash(exit code 0 或 fail-loudly 正確 throw)、輸出文字不變 `?`、檔案 byte-level 為 UTF-8 BOM(`.ps1` 含中文時)、SVN propset / commit 含中文字元正確保留。
  - **Outcome:** 中文跨層(filesystem path、檔名、source content、stdout 輸出、SVN 屬性與 commit 訊息)無 mojibake / data loss。
  - **Covered by:** R18, R19

- F4. **跨 worktree 同步驗證(suggest-ignore)**
  - **Trigger:** tp-suggest-ignore 對應的 Phase 2 case。
  - **Actors:** A1, A2, A3。
  - **Steps:**
    1. orchestrator 準備 test-turbo-plugin main worktree + `.worktrees/remote-main` + `.worktrees/remote-test-1` 三個 worktree 各有不同的 untracked 檔案。
    2. 使用者跑 `/tp-suggest-ignore --add-svn <pattern>`(或 agent 自動觸發)。
    3. 驗證:**兩個 `remote-*` worktree** 跑了 `svn propset svn:ignore` + **兩個 SVN commit**(per-worktree 各一個 revision);main worktree 是 fixture context 但**不是** propset target(無 `.svn` 目錄,svn-ignore.ps1 的篩選器 `^remote-(main|test-\d+)$` by design 跳過)。
    4. 另一個 case:故意讓其中一個 `remote-*` worktree 的 propset 失敗(e.g., SVN credentials 改錯)→ 驗證 rollback 跑了 + 其他 `remote-*` worktree 沒留下髒狀態。
  - **Outcome:** 跨 worktree propset + per-worktree commit + 失敗 rollback 機制驗證符合 SKILL.md U9 修正後的「one SVN commit per worktree」描述。
  - **Covered by:** R11, AE13

- F5. **Fail-then-fix 即停修復循環**
  - **Trigger:** 任一 Phase 任一 case 標 FAIL。
  - **Actors:** A1(主導)、A2(必要時提供環境資訊)、A3(N/A)。
  - **Steps:**
    1. orchestrator 停止當前 phase 推進。
    2. 讀失敗 script / skill 程式碼 + 重現 failure(必要時加 trace log)+ root-cause。
    3. 修 turbo-plugin code(在 `feat/turbo-plugin-v1.0` branch 上 commit)。
    4. 同 case re-run → PASS 才解除 stop。
    5. 評估修復是否影響其他已 PASS case;影響的 case re-run。
  - **Outcome:** bug 不堆積到最後,v1.0.0 PR 不帶已知 failure。
  - **Covered by:** R20-R23

---

## Requirements

**Phase 1 — Script 自動測試**

- R1. Phase 1 **必須**涵蓋 `plugins/turbo-plugin/scripts/` 底下全部 18 個 `.ps1` + 18 個 `.sh` = 36 個 script。
- R2. 每個 script **必須**至少測試:(a) happy path 最常見參數組合 1 個、(b) 該 script 程式碼中每個顯式 error / fail-loudly 分支各 1 個、(c) 跨平台共用的 invariant(如 exit code、stdout 結構)、(d) 含中文輸入或輸出的 1 個 case、(e) **透過該 script 在 SKILL.md 中宣告的入口路徑** invoke 的 1 個 case(或經過讀同樣 env var 的 canonical wrapper),確保 SKILL/script 的 arg name / env var / stdout contract drift 在 Phase 1 就被 exercised — 避免「Phase 1 全綠 = script 層穩」這個推論被 SKILL/script 介面不一致 silently 推翻。
- R3. `.ps1` script **必須**在 Windows PowerShell 5.1(`powershell.exe`,內建版本)環境跑;**不**測試 PowerShell 7+(雖支援但非主流安裝)。
- R4. `.sh` script **必須**在 Git Bash for Windows(隨 Git for Windows 安裝的 `bash.exe`)環境跑;**不**測試 WSL / Linux native / macOS。
- R5. 每個 script case **必須**在獨立 fixture snapshot 上跑(從 base fixture 複製出工作目錄,跑完後丟棄),避免互相污染。
- R6. base fixture **必須**包含完整代表性 test-turbo-plugin 環境:(a) 一個合法 `.sln` + `.csproj` + 樣本 C# / JS source、(b) `.turbo-plugin/applicationhost.config`(含 `__TURBO_PLUGIN_PHYSICAL_PATH__` placeholder)、(c) `.turbo-plugin/config.toml`(`[iis] enabled = true`)、(d) 樣本 `config.local.toml` 模板、(e) git repo 已 init、(f) SVN bridge worktree skeleton(`.worktrees/remote-main` 等 placeholder)。
- R7. SVN repo **必須**建立在 `C:\Turbo\test-turbo-plugin-svn-repo`(`test-turbo-plugin` 路徑**外面**,避免被 fixture reset 誤刪),seed 包含至少 r1-r20 的歷史,其中至少 r5 / r10 / r15 三筆 commit message 含中文(分別含繁中常用字、半形符號 + 中文混排、SVN 換行 commit msg)。
- R7a. SVN repo **必須**在每個 SVN-touching case 跑之前 reset 到 seed (r1-r20) — orchestrator 維護一份 `svnadmin dump` 形式的 snapshot,case 開始前用 `svnadmin load` 還原(或砍掉重建 + 重跑 seed script,擇一)。對應的 `.worktrees/remote-*` 本機 SVN working copy 在 case 開始前也要還原(`svn update -r 20` 或重新 `svn checkout`),確保跨 case 的 SVN state 為 known baseline,assertion 不被 prior case 的 mutation 污染。
- R8. Phase 1 assertion 在 `.ps1` 採 **Pester**(隨 Windows PowerShell 5.1 內建出貨,Win 10 / 11 預設可用,**不**算額外環境依賴);`.sh` 在 Git Bash 採 inline `if [ ... ]; then echo OK; else echo FAIL; exit 1; fi` 對應(bats 不引入 — 那才會真正增加環境依賴)。Pester 的 structured PASS/FAIL 輸出(`Invoke-Pester -OutputFile TestResult.xml -OutputFormat NUnitXml`)直接餵 R9 / R28 的 evidence row,免手寫 Assert helper。
- R9. Phase 1 tracking row 寫到 `plugins/turbo-plugin/tests/runs/<release>/phase1-results.md`(schema 來源:`plugins/turbo-plugin/tests/docs/phase1-scripts-schema.md`;每個 script 一個 section,每個 case 一個 row:case ID / 描述 / 輸入摘要 / 預期 / 實際 / PASS-FAIL / evidence link 或 inline 摘要);**進 git**(此測試紀錄為 v1.0 release 的一部分,值得 commit 與 push)。
- R10. Phase 1 **必須**全部 case 標 PASS 才允許進 Phase 2;有 FAIL 即進 F5 fail-then-fix loop。

**Phase 2 — Skill 手動測試**

- R11. Phase 2 **必須**涵蓋 14 個 skill:`tp-setup`、`tp-pull-from-svn`、`tp-push-to-svn`、`tp-create-remote-test`、`tp-reset-remote-test`、`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`、`tp-suggest-ignore`、`tp-svn-log`、`tp-csharp-comment`、`tp-js-comment`。
- R12. 每個 skill **必須**至少測試:(a) 1 個快樂路徑 case、(b) 2-3 個主要錯誤路徑 case(從 SKILL.md 的 Decision Rules / Procedure 直接挑常見錯誤點)、(c) 1 個中文相關 case(如不適用則明確標 N/A 並說明)。
- R13. 每個 case orchestrator **必須**事先在 `C:\Turbo\test-turbo-plugin` 準備完整的 fixture 狀態(檔案結構、git state、SVN state、`.turbo-plugin/config.toml`、`.claude/settings.local.json` env),使用者只需開 Claude Code 跑 prompt。
- R14. 每個 case orchestrator **必須**提供:(a) 完整 prompt 字串(可直接 copy-paste 給 Claude Code)、(b) 預期 agent 行為摘要(該觸發哪個 SKILL、預期問什麼 AskUserQuestion、預期寫什麼檔案)、(c) 使用者轉述時的觀察重點。
- R15. 使用者轉述格式:agent 主要文字回覆 + tool call 摘要(skill 觸發 / file write / bash 執行)+ 任何 AskUserQuestion 提示 + 任何視覺異常(中文亂碼、檔名亂掉)。orchestrator **不**要求使用者貼完整 raw log,但要求關鍵觀察點都有覆蓋。
- R16. Phase 2 tracking row 寫到 `plugins/turbo-plugin/tests/runs/<release>/phase2-results.md`(schema + case spec + prompt 範本 + 失敗 patterns 來源:`plugins/turbo-plugin/tests/docs/phase2-skills.md`;每個 skill 一個 section,case ID / 描述 / fixture 摘要 / prompt 摘要 / 預期 / 實際轉述 / PASS-FAIL-PARTIAL / evidence)。**進 git**。
- R17. Phase 2 session 切分:每 session 1-2 個 skill,預估 8-12 個 session 跑完。session 間 fixture 可以延續(避免重複設定 tp-setup);但跨 session 之間 orchestrator 必須在 tracking doc 紀錄當前 fixture 狀態以利下次 resume。

**中文測試(跨階段共用)**

- R18. 中文測試**必須**覆蓋以下面向(每個 script / skill 至少挑 1 個適用面向,不適用標 N/A):
  - 工作目錄路徑含中文(e.g., `C:\Turbo\test-turbo-plugin\測試專案 ™\src\...`)
  - 檔名含中文(e.g., `中文檔名.cs`)
  - SVN commit message 含中文
  - SVN log / svn-log 輸出含中文(驗證 console codepage 950 vs UTF-8 不變 `?`)
  - `.ps1` / `.sh` 含中文字串(驗證 UTF-8 BOM 在 PS 5.1 不 mojibake)
  - svn:ignore 屬性值含中文(`tp-suggest-ignore` 對應 case)
  - C# / JS 程式碼註解含中文(`tp-csharp-comment` / `tp-js-comment` 對應 case)
  - **Source code body 含中文字串字面值**(`.cs` 的 `string s = "..."` literal、`.js` / `.vue` 的 template / 內文、`.cshtml` 的 view body)通過 `tp-build` / `tp-publish` / `pack-content.ps1` 等流程 byte-level 不變 — `tp-build` 與 `tp-publish` 的 Phase 2 各加一個 fixture 含中文 string literal 的 case 驗證(註解面向跟 string literal 面向是不同 build pipeline 處理 path,不能 conflate)
- R19. 「中文樣本字典」**必須** inline 在 `plugins/turbo-plugin/tests/docs/phase1-scripts-schema.md` 開頭的 `## 中文 fixture 樣本` section 維護(進 git,與 case 同 doc),`phase2-skills.md` reference 同一份字典 — **不**另開 `zh-samples.md`(避免一次性測試產生 3rd tracked artifact)。字典含至少:5 個路徑片段(含 BMP / 補充字 / 半形數字混排)、5 個檔名、5 個 commit msg(短 / 長 / 多行)、5 個 source 註解樣本、5 個 source string literal 樣本(對應 R18 的 source body 面向)。每個 case 從字典挑樣本,**不**現場編。

**Fail 處理**

- R20. case fail **必須**立刻停止當前 phase 推進(不繼續跑下一個 case)。
- R21. Root-cause **必須**由 orchestrator 主導:讀 script / skill 程式碼、必要時加 trace log、重現 failure、找出 bug。
- R22. 修 turbo-plugin code **必須** commit 在 `feat/turbo-plugin-v1.0` branch(或從該 branch 開的子 branch 然後 merge 回來),不可在其他 branch 修。
- R23. 修復 commit 後 **必須** re-run 同一個 case 直到 PASS;同時評估修復是否影響其他已 PASS case(改 `common.ps1` 或 SKILL.md 框架時尤其要 re-run 受影響者)。

**tp-setup 推薦項目實際安裝**

- R24. Phase 2 跑 `tp-setup` 對應 case 時,LSP plugin 啟用 / LSP server binary 安裝 / compound-engineering plugin 自動更新 / agent teams 啟用 **必須實際執行**(不 mock、不 dry-run),驗證真正寫到使用者 `~/.claude/settings.json` + `~/.claude/plugins/...` + `dotnet tool` / `npm -g` 全域 binary。
- R25. orchestrator **必須**在 Phase 2 開始**前**對使用者明示:跑 tp-setup 推薦項目 case 會在使用者 user-level Claude Code settings 與機器全域 binary 留下實際安裝痕跡;Phase 2 結束後使用者需要手動 rollback(關閉 plugin、移除 LSP plugin、`dotnet tool uninstall -g csharp-ls` / `npm uninstall -g typescript-language-server`)。
- R26. tp-setup case 跑完後,後續依賴該設定的 skill case(`tp-build`、`tp-run`、`tp-publish` 等)**必須**在 tp-setup 留下的安裝環境上繼續跑,避免重複裝拆裝。

**Tracking 與證據**

- R27. 兩個 tracking doc(`plugins/turbo-plugin/tests/docs/phase1-scripts-schema.md`(含 inline 中文字典)/ `plugins/turbo-plugin/tests/docs/phase2-skills.md`)**必須 commit 到 `feat/turbo-plugin-v1.0` branch**(任一掛在此 branch 的 worktree 都能 commit,目前的 `turbo-plugin-brainstorm` 是其中之一 — branch / worktree 是同一個 git context)。預期跟 plugin 程式碼一起進 v1.0.0 PR;squash-merge 時 tracking doc 內容會 squash 進 release commit message 摘要(完整 doc 保留在 branch history)。
- R28. 每個 case 紀錄**必須**包含:case ID(`P1-<script>-<case>` 或 `P2-<skill>-<case>`)、輸入 fixture 摘要、預期、實際、結果(PASS / FAIL / PARTIAL / SKIP-N/A)、若失敗則對應的修復 commit hash。
- R29. evidence 形式:script PS / Bash invocation 的 stdout 摘要、檔案 diff 摘要、agent 回覆轉述摘要、必要時截圖路徑。**不**要求 raw log 全文(避免 doc 爆量),但要求每個 PASS 都有可驗證的觀察錨點。

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given Phase 1 跑 `start-iis.ps1` 的 happy path case,fixture 含合法 `.turbo-plugin/applicationhost.config` + `[iis] enabled = true`,when orchestrator `powershell.exe -File start-iis.ps1`,then exit code = 0、stdout 含 launched IIS Express process ID、`%TEMP%` 下出現 `turbo-plugin-iis-<identity-hash>.config` 且 placeholder 已替換為當前 fixture 工作目錄路徑。
- AE2. **Covers R1, R2, R5.** Given Phase 1 跑 `start-iis.ps1` 的 `[iis] enabled = false` error case,when orchestrator invoke,then exit code != 0、stderr 含明確 "IIS 已停用" 或同等提示、`%TEMP%` 下**沒**建立 temp config file。
- AE3. **Covers R1, R2, R18.** Given Phase 1 跑 `svn-log.ps1` 的中文 case,SVN repo r5 commit msg = "修正中文檔名 — 測試 ™ 樣本",when orchestrator invoke `svn-log.ps1 -Limit 5`,then stdout 含 `r5 | <author> | <date> | 修正中文檔名 — 測試 ™ 樣本`,中文字元逐字元 byte-compare 等於原始輸入,**不**含 `?` / `??` mojibake。
- AE4. **Covers R1, R2, R4.** Given Phase 1 跑 `svn-log.sh` 在 Git Bash 的相同中文 case,when orchestrator `bash.exe -c "./svn-log.sh --limit 5"`,then stdout 同樣含正確中文 commit msg,內容與 AE3 一致(`.ps1` / `.sh` 跨平台行為 invariant)。
- AE5. **Covers R6, R7, R8.** Given Phase 1 跑 `pull-from-svn.ps1` 的 happy path,fixture 含 `.worktrees/remote-main` + SVN repo seed,when orchestrator invoke,then exit code = 0、SVN repo r20 後沒新 revision、main worktree 的 git HEAD 跟 SVN trunk 對得上(`git log --oneline -1` 對應 SVN r20 內容)。
- AE6. **Covers R9, R28, R29.** Given Phase 1 跑完 `build-web.ps1` 的 3 個 case(happy / sln 不存在 / MSBuild path 未設定),when orchestrator 寫入 `runs/<release>/phase1-results.md` 對應 row(schema 來源 `docs/phase1-scripts-schema.md`),then row 含 case ID(`P1-build-web-ps1-happy` 等)、輸入摘要、預期、實際 stdout 摘要、結果欄,所有 3 row 標 PASS。
- AE7. **Covers R10.** Given Phase 1 跑 `push-to-svn-commit.ps1` 出現中文 commit msg 變 `?` 的 FAIL,when orchestrator 評估,then **不**繼續跑下一個 script,進 F5 fail-then-fix。
- AE8. **Covers R11, R12, R13.** Given Phase 2 跑 `tp-setup` 的 case (a) 新建,fixture 為 empty workspace `C:\Turbo\test-turbo-plugin\fresh`,when 使用者貼入 orchestrator 給的 prompt 「我剛開了一個新專案,幫我設定 turbo-plugin」,then agent 觸發 tp-setup SKILL、跑完 4 個 Phase、Phase 4 完成報告列出寫入的設定檔位置,使用者轉述後 orchestrator 標 PASS。
- AE9. **Covers R12, R18.** Given Phase 2 跑 `tp-setup` 中文路徑 case,fixture 工作目錄 = `C:\Turbo\test-turbo-plugin\測試專案 ™`,when 使用者跑相同 prompt,then agent 不 crash、`.turbo-plugin/config.toml` 與 `.claude/settings.local.json` 順利寫入、檔案 byte-level 為 UTF-8 (BOM 對 `.ps1` 適用),使用者轉述後 orchestrator 標 PASS。
- AE10. **Covers R12.** Given Phase 2 跑 `tp-setup` 的 IIS Express 未安裝 error case,fixture 預先把 IIS Express 從 PATH 移除(或 mock 用空殼 `.exe`),when 使用者跑 prompt,then agent 觸發 AskUserQuestion 三選一(R1 對應 doc 1.0-refinements 已實作),使用者選 (2) 接受沒有 IIS → `config.toml` 寫入 `[iis] enabled = false`,使用者轉述後 orchestrator 標 PASS。
- AE11. **Covers R14, R15.** Given Phase 2 跑 `tp-push-to-svn` 中文 commit msg case,orchestrator prompt 摘要:「改一個檔,commit msg 寫『修正中文編碼 bug』,然後 push 到 SVN」,when 使用者跑完轉述「agent 跑了 push-to-svn-prepare → 顯示 commit msg → 跑 push-to-svn-commit → SVN r21 已寫入」,then orchestrator 用 `svn log -r 21` 驗證 SVN repo r21 的 msg 正確含中文,標 PASS。
- AE12. **Covers R12.** Given Phase 2 跑 `tp-svn-log` 下一頁互動 case,fixture SVN repo r1-r20,orchestrator prompt:「幫我看 SVN log」,when 使用者跑後 agent 顯示 r20-r16 + 下一步選項,使用者再回「1」,then agent 重新跑 svn-log 顯示 r15-r11,使用者轉述後 orchestrator 標 PASS。
- AE13. **Covers R11, R12, F4.** Given Phase 2 跑 `tp-suggest-ignore --add-svn` 跨 worktree case,fixture 有 main + `.worktrees/remote-main` + `.worktrees/remote-test-1` 三個 worktree 各有不同 untracked(main 是 fixture context,不是 propset target),when 使用者跑 `/tp-suggest-ignore --add-svn obj/`,then **兩個 `remote-*` worktree** 跑了 propset + **兩個 SVN commit**(可從 `svn log` 看到 per-worktree revision),使用者轉述後 orchestrator 用 `svn pg svn:ignore` 對兩個 `remote-*` worktree 各自驗證,標 PASS。
- AE14. **Covers R20, R21, R22, R23.** Given Phase 2 跑 `tp-build` 中文路徑 case 標 FAIL(假設 MSBuild 對中文路徑 crash),when orchestrator 進 F5,then 停止後續 case → 讀 `build-web.ps1` 找路徑處理 → 改為 quote / escape → 在 `feat/turbo-plugin-v1.0` commit 修復 → re-run 同 case 標 PASS → 評估是否影響 `publish-web` / `start-iis`(都有路徑處理)→ re-run 受影響 case 都 PASS → 解除 stop 繼續 Phase 2。
- AE15. **Covers R24, R25.** Given Phase 2 跑 `tp-setup` 推薦項目實際安裝 case,當使用者選「user-level 啟用 C# LSP」,when agent 跑完,then `~/.claude/settings.json` 真的多了 `csharp-lsp@claude-plugins-official` 在 `enabledPlugins`、`~/.claude/plugins/cache/` 真的下載了 plugin、`dotnet tool list -g` 真的列出 `csharp-ls`,使用者轉述後 orchestrator 標 PASS;Phase 2 完成後 orchestrator 在 tracking doc 列出需要使用者手動 rollback 的清單。
- AE16. **Covers R27, R28.** Given Phase 1 + Phase 2 都跑完,when orchestrator commit tracking doc,then `feat/turbo-plugin-v1.0` branch 含 `plugins/turbo-plugin/tests/docs/phase1-scripts-schema.md` + `docs/phase2-skills.md` + `runs/v1.0.0/phase1-results.md` + `runs/v1.0.0/phase2-results.md`,所有 case row 都有結果欄,所有 FAIL 都有對應修復 commit hash。

---

## Success Criteria

- 36 個 script 在 PowerShell 5.1 + Git Bash for Windows 上跑完所有 case(happy + error + 中文)都 PASS,有 evidence-bound 紀錄。
- 14 個 skill 各自的 1 個快樂 + 2-3 個錯誤 + 中文 case 由真實 Claude Code session 觸發跑過,使用者轉述後 orchestrator 標 PASS。
- 中文跨層(filesystem path、檔名、source content、stdout 輸出、SVN propset / commit msg / log)都 byte-level 完整保留,**沒**任何 `?` / `??` mojibake 觀察點。
- 跨 worktree 同步(suggest-ignore --add-svn)在三個 worktree 都跑了 per-worktree propset + commit;故意觸發部分 worktree 失敗時 rollback 機制正確復原。
- 所有 FAIL 都有對應的 turbo-plugin 修復 commit + re-run PASS 紀錄;v1.0.0 PR push 時帶零個已知 failure。
- `feat/turbo-plugin-v1.0` branch push 前,tracking doc(`docs/phase1-scripts-schema.md` / `docs/phase2-skills.md` / `runs/v1.0.0/phase1-results.md` / `runs/v1.0.0/phase2-results.md`)都已 commit,任何審查者都能從 doc 還原驗證過的範圍。

---

## Scope Boundaries

- **不包含** Bash script 在 Linux / macOS native 上跑 — `.sh` 只在 Git Bash for Windows 跑;真正的 cross-platform Linux / Mac 驗證在 1.0 後另開 session(需要對應平台環境)。
- **不包含** Performance / stress testing — 沒有 throughput / memory / latency 目標,只驗證功能正確。
- **不包含** Concurrent / race condition testing — 整個 turbo-plugin 設計是 single-user single-session,沒並發場景。
- **不包含** Network failure 模擬(SVN server 不可達、Claude Code plugin marketplace 不可達等)— 走 svn cli / Claude Code 自己的 error 路徑,turbo-plugin 不接手。
- **不包含** tdp / tnf / tgs / tpi 4 個舊 plugin 的測試 — 已在 v1.0 被 retire(plan 中 deferred to follow-up work)。
- **不包含** CI / 自動化整合 — Phase 1 是 orchestrator 一次性手動觸發,**不**目標化為可重複的 CI suite。若未來想 promote 為 CI,在 1.0 PR 之後另開 brainstorm。
- **不包含** 已 deprecated 或計畫移除的 script / skill — 14 skill + 18 對 script 是 1.0.0 plugin.json 列的最終 surface,不測試任何超出此 surface 的東西。
- **不包含** PowerShell 7+ 環境 — 雖然 script 在 PS 7+ 也能跑,但主流安裝是 PS 5.1,測試 surface 對齊 R3。

---

## Key Decisions

- **分兩階段(script 自動 / skill 手動)而非統一跑** — script 共 36 個 × 多個 case ≈ 100+ invocation,手動成本不可接受;反之 skill 觸發本質包含 agent 對 SKILL.md 的判讀與 AskUserQuestion 互動,自動化會 mock 掉測試目的(等於沒測)。
- **Phase 1 全綠才進 Phase 2** — script 是 skill 觸發的實際做事層;基礎沒 PASS,skill 測試的 noise 來自不確定是 SKILL.md / agent 判讀 / script bug 哪一層的問題,定位成本暴增。
- **`.sh` 在 Git Bash for Windows 跑(全測 18 個,跳過 Linux/Mac native)** — Git Bash 是 `.sh` 在 Windows 上**唯一**的 production execution path;`.sh` 程式碼存在的意義就是給 Git Bash 跑(未來 Linux / Mac 是 follow-up)。跳過 = 等於不測這 18 個檔案。為什麼「Git Bash 全測 18 個」是 sweet spot:
  - **不是只測 3-5 個 encoding-divergent**:那會失去其他 13 個的 syntax 基線保證 — 即使是「薄 wrapper」script 也可能有未發現的 PS/Bash 行為差異(line ending、quoting、locale defaults),全測 18 個能撐住整個 `.sh` surface 的 happy-path syntactic correctness。
  - **不是 Git Bash 18 + WSL Ubuntu smoke**:WSL Ubuntu 不在 1.0 預期使用環境(`marketplace.json` 沒承諾 Linux 支援);為了未發布的 platform 加 ~30% 工作量不合理。Linux / macOS native 留到 1.0 後另開 brainstorm 補(需對應平台環境)。
- **使用真實 SVN repo(`file:///...`)而非 mock** — SVN 的中文 codepage / locale / propset / commit msg 行為只在真實 svn cli 才現形;mock 一層就等於不測。SVN repo 放在 test-turbo-plugin **外面**(`C:\Turbo\test-turbo-plugin-svn-repo`)避免 fixture reset 誤刪。
- **Fail 即停 + root-cause + 修 + re-run** — v1.0 PR 前的 default。Batch 留到最後等於把每個 bug 的 context 都 page-out 一次,修復成本反而高;且累積 N 個 bug 之後修一個改一段,可能其他 N-1 個的觀察都失效。
- **tp-setup 推薦項目實際安裝(不 mock)** — 整個 tp-setup R24-R25 的核心驗證點就是「真的裝得起來嗎」、「使用者選了 user-level 真的寫到 user-level 嗎」、「LSP plugin 真的 enable 並能用嗎」。mock 沒辦法答這些。代價是使用者 user-level settings + 機器 binary 留下實際痕跡,事前明示 + 事後列出手動 rollback 清單作為補救。
- **Tracking doc 進 git** — 此測試紀錄等同 v1.0 release 的 evidence trail,值得 commit + push 到 `feat/turbo-plugin-v1.0`,後續 PR review 可審查、上線後出 bug 可回查當時驗證範圍。
- **中文字典集中維護而非每 case 現編** — 中文 fixture 樣本要有 BMP / 補充字 / 半形混排 / 多行 / commit msg 樣本的代表性,逐 case 編品質不一;集中字典 + 每 case 挑一個樣本,確保 surface 覆蓋。
- **使用者轉述格式採摘要 + 觀察錨點而非 raw log 全文** — raw log 進 tracking doc 會爆量到無法 review;摘要 + 預先列好的觀察錨點(`應觀察 X / Y / Z`)即可達成 evidence-bound,且更接近真實 PR 審查時讀的形態。
- **選 near-comprehensive coverage 而非 80/20 cheapest validation** — 雖然 1.0 是首個 marketplace release、沒既有使用者要保護,但 marketplace 首發品質直接影響 plugin 信任度:使用者第一次裝起來撞 bug 會直接放棄,沒有「使用者反饋指出哪些 path 重要」這個 luxury(沒既有使用者 = 也沒既有 bug 報告 channel)。Trade-off 接受:一次性投入更大(36 script 全分支 + 14 skill 主錯誤路徑 + 中文 + 跨 worktree),換 ship 後 marketplace 第一印象的可信度;Problem Frame 的「不需全分支 regression」是相對於「未來 1.x patch 不必每次都全測」,不是相對於「首發可以 80/20」。

---

## Dependencies / Assumptions

- 假設 `C:\Turbo\test-turbo-plugin` 內所有檔案可任意改 / 砍 / 重建(使用者已明確確認)。
- 假設 `C:\Turbo\test-turbo-plugin-svn-repo` 可建立為 SVN 檔案庫(使用者有 `svnadmin create` 權限,svn cli 在 PATH 中可用)。
- 假設 Windows PowerShell 5.1 是預設 `powershell.exe`;若使用者改裝過 PS 7 為預設 shell,需要明確 `powershell.exe -File` 觸發 5.1。
- 假設 Git for Windows 已安裝(因為 turbo-plugin 本身依賴 git),Git Bash 隨之安裝於 `C:\Program Files\Git\bin\bash.exe` 或同等位置。
- 假設 svn cli 已安裝在 PATH 中,且支援 `--xml` flag(>= 1.10)。
- 假設使用者本機有 IIS Express 安裝;若 Phase 1 / Phase 2 需要測 IIS 相關 path,則對應 case 才需要 IIS;某些 fixture(`[iis] enabled = false`)不需要。
- 假設 `.NET Framework 4.x` SDK + MSBuild 已安裝(Phase 1 / Phase 2 build / run / publish path 需要)。
- 假設 Visual Studio install 提供 MSBuild;若使用者無 VS 但有 Build Tools,效果等同。
- 假設使用者願意接受 tp-setup 推薦項目實際安裝在 user-level + 機器全域(R24-R25);事前明示後若不同意,該 case 改跑「全部跳過」變體,實際安裝路徑由其他 case 在獨立 fixture 上跑(orchestrator 評估時程)。
- 假設 `feat/turbo-plugin-v1.0` branch 在 Phase 1 + Phase 2 進行期間維持可寫;修復 commit 直接落在這個 branch 上(或從這個 branch 開的子 branch merge 回來)。
- 假設使用者每個 Phase 2 session 願意提供 10-30 分鐘集中時間(開 Claude Code、貼 prompt、轉述、等下一個 case)。

---

## Outstanding Questions

### Resolve Before Planning

- [Affects R6, R7][Needs decision] `C:\Turbo\test-turbo-plugin` 目前的內容要全清重建,還是保留某些當基礎 fixture?如果使用者之前已經在裡面手動裝過 turbo-plugin / 開過 IIS / 有 .git,從乾淨重建會比較單純(可重複);保留可能會混進 unintended state。建議:全清重建,fixture 設置流程進 tracking doc 以利重現。需要使用者確認。
- [Affects R7][Needs decision] SVN repo 的 seed 內容由 orchestrator 自動產生(寫一個 PowerShell setup script 跑 `svnadmin create` + 20 個 dummy commit),還是使用者提供現成 SVN repo 拷貝過來?自動產生最可重現;使用者提供可能更接近真實使用情境。建議:orchestrator 自動產生,但 seed 內容明文寫在 tracking doc 內(任何人都可重現)。
- [Affects R24, R25][Needs decision] Phase 2 tp-setup 推薦項目實際安裝 case,跑完之後是 (a) 立刻 rollback 還繼續其他 Phase 2 case、(b) 留著直到所有 Phase 2 結束再一次性 rollback、(c) 不主動 rollback,使用者自己決定要不要留著繼續用?建議 (b),因為 (a) 後續依賴 LSP / CE 的 skill case 沒辦法在真實環境上跑;但需要使用者確認 user-level 痕跡留到 Phase 2 全程的接受度。

### Deferred to Planning

- [Affects R5][Technical] fixture snapshot 機制的具體實作 — 用 `robocopy` mirror、`git stash`、或 git worktree 切 branch?planning 階段決定;預估 robocopy 較簡單但較慢,git worktree 較快但 fixture 內含 git 結構會 confuse。
- [Affects R7, R18, R19][Technical] 中文 commit msg seed 的具體內容(哪 3 筆 revision 用哪個中文樣本?)+ 中文字典初版的具體樣本選擇,planning 階段定。
- [Affects R9, R16, R27][Technical] tracking doc 內每個 case row 的 markdown 表格 schema vs 條列 schema 的取捨,planning 階段定 — 大量 row 用表格較易掃,但中文 + 多欄會欄寬不齊;條列較鬆但好讀。
- [Affects R11][Sequencing] 14 個 skill 在 Phase 2 的執行順序(建議:`tp-setup` → `tp-pull-from-svn` / `tp-create-remote-test` / `tp-suggest-ignore` → `tp-build` / `tp-run` / `tp-stop` / `tp-publish` / `tp-cleanup-orphan-iis` → `tp-push-to-svn` / `tp-reset-remote-test` → `tp-svn-log` / `tp-csharp-comment` / `tp-js-comment` — 依依賴 + IIS 互斥約束排),planning 階段確認。
- [Affects R13, R17][Sequencing] session 切分的具體 skill 配對(誰跟誰一起測比較順)+ fixture 跨 session 延續的 checkpoint 設計,planning 階段定。
- [Affects R20, R21, R22][Process] Fail-then-fix loop 觸發後,若同一個 bug 修了 N 次仍 FAIL,何時 escalate 或調整 case 範圍?planning 階段考慮 escalation 規則(預設:同 case 修 > 3 次仍 FAIL 則 mark FAIL-known、列入 Known Issues 不 block PR,但要 user 確認)。
- [Affects R29][Process] evidence 摘要的字數上限 / 截圖儲存位置,planning 階段定。

### From 2026-05-27 ce-doc-review

- [Affects R5, R17, R26][Architecture] **fixture isolation 政策衝突** — Phase 1 (R5) 強制 per-case snapshot,但 Phase 2 (R17/R26) 允許 fixture 跨 session 延續 + 共用 tp-setup 環境,兩種 isolation 政策同時生效會讓 Phase 2 case fail 的 root-cause 變極難定位(不知是 case 本身 bug、tp-setup 留下半 broken 環境、累積污染、還是 fixture-resume hiccup)。Planning 階段擇一明示:**(a) Phase 2 也跑 per-case snapshot**,例外只給機器全域狀態(LSP / `dotnet -g` / `~/.claude/settings.json`)— 失去 R26「避免重複裝」效率;或 **(b) 接受 fixture 延續**,加 R-level「F5 若懷疑跨 case state 污染,升級為 fresh fixture re-run」+ 文件明示這個 trade-off。
- [Affects R24, R25, Key Decisions item 6][Architecture] **tp-setup containment 替代方案未檢視** — doc 從「mock 不可行」直接跳到「使用者主機 + 手動 rollback」,沒看 Windows Sandbox(Win 11 Enterprise 內建)/ Hyper-V VM snapshot / `dotnet tool --tool-path` scoped install / 第二個 Windows user profile。Planning 階段評估:Sandbox 是否 persist `~/.claude` across runs、VM setup cost 是否高於 rollback cost、`--tool-path` 對 LSP server / Claude Code plugin 是否可行;選最便宜的 containment 方案,或若仍選主機 + 手動 rollback,在 K-Decision 6 補 reject reason(rollback checklist 漏項風險、daily-driver 機器累積 cruft 干擾正常使用 — 而使用者**正是 turbo-plugin 主要使用者**)。
- [Affects R10, Key Decisions item 2][Architecture] **Phase 1 global gate vs per-skill gate** — R10 的「全綠才進 Phase 2」是 global,svn-log.ps1 的 obscure 中文 edge case fail 會 block 全部 14 skill 的 Phase 2,包含完全無依賴的 tp-csharp-comment。對 1.0 PR on deadline 來說,total wall time 不必要地延長,而 Phase 2 是 signal value 最高的層。Planning 階段選 **(a) per-skill dependency mapping**(某 script PASS 才 unlock 對應 skill 的 Phase 2 case)或 **(b) 保留 global gate 加 escalation**(「若 Phase 1 fail 與當前 Phase 2 session 預計測的 skill 無依賴關係,orchestrator 在 tracking doc 標 known-issue 後可繼續 Phase 2」)。
- [Affects R20, R21, R23, Key Decisions item 5][Process] **Fail-fast cascading 無界 + 沒 escape hatch** — Problem Frame 自己承認「11 unit 只跑過 lint」,預期 bug count 可能十幾起跳;修 `common.ps1` 一次可能 invalidate 20 個 prior PASS → 20 個 re-run → 每個可能 fail in different bug → 無界 cascade,schedule risk 無上限。Planning 階段加 **(a) suspension trigger**(連續 N 次 fix 觸到 shared code 如 `common.ps1` / SKILL.md framework / env-var contract → switch to batch mode for the remainder of current script/skill group,then re-validate group end-to-end)+ **(b)** 把 Outstanding Questions 「同 case > 3 次 fix → mark FAIL-known」escalation rule promote 為 R-level requirement + **(c)** budget Success Criterion(`Phase 1 max X 小時 / Phase 2 max Y session`,超過即 orchestrator 暫停 surface scope-cut recommendation 給使用者)。
- [Affects R12, R17][Sizing] **R12 統一 formula 忽略 skill 複雜度差距** — `tp-setup`(4 phase × 多選項 × LSP / CE / agent teams / TUI / 4-case detection)跟 `tp-stop`(殺 process)用同樣 formula。AE 自己已超出 formula(AE8/AE9/AE10/AE15 = 4 個 tp-setup AE,formula 只規格 4-5 個 case)— tp-setup 算 1 個 PASS 還是 4 個 PASS,Success Criterion 模糊。Planning 階段選 **(a) per-skill case-count table**(planning 階段列具體數字:tp-setup: 5-6 / tp-stop: 2-3 / ...,取代 R12 統一 formula)或 **(b) R12 改為 floor not ceiling**(orchestrator 在 Phase 2 開跑前在 tracking doc 預列每個 skill 的 case count,使用者依此重估 R17 session 預算)。
