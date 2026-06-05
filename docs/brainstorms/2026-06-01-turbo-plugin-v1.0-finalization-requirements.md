---
date: 2026-06-01
topic: turbo-plugin-v1.0-finalization
---

# turbo-plugin v1.0.0 收尾需求

## Summary

在發 turbo-plugin v1.0.0 PR 之前,把測試基建、worktree 結構、分支命名、push-to-svn 行為與 marketplace 治理一次收齊:測試可在 GitHub CI 與本地兩邊跑且零本機痕跡、舊的四個 plugin 正式退役、CLAUDE.md 改成 plugin-agnostic 的 marketplace 規範並明訂測試標準。全部一起進同一個 v1.0.0 PR,且 PR 前要先跑完一輪人工 skill 驗證作為 gate。

## Problem Frame

turbo-plugin 是用來取代 tdp/tnf/tgs/tpi 四個舊 plugin 的整併產物,目前在 `feat/turbo-plugin-v1.0` 分支累積到接近可發版。但收尾階段暴露出幾個彼此牽連的問題:

- 既有 script test 把工作根寫死成 `C:\Turbo\test-turbo-plugin`,跑的過程甚至會在 `C:\Turbo` 同層建立暫存物再刪除——既污染使用者環境,也讓「上 GitHub CI 自動跑」與「換一台機器就能跑」變不可能。先前一次 containment 重構只是把寫死路徑換成另一個寫死路徑,沒解決可攜性。
- skill 層的驗證從沒被當成常駐、可重複的測試;它只有一份含寫死路徑、結構已過時的草稿文件,沒辦法在「以後每次改 plugin」時重跑。
- consolidation 過程靜默漏搬了能力(已確認 push-to-svn 的 release tag 整個不見),退役舊 plugin 前若不盤點,會造成靜默失能。
- CLAUDE.md 目前塞滿 plugin 專屬內容並硬列 plugin 清單,每次增刪 plugin 都得改它;它應該是整個 marketplace 的通用規範。CI 同理:不該每加一個 plugin 就手寫一支 workflow。
- worktree 用 sibling 目錄 + `.code-workspace` 聚合,以及 `remote/*` 分支命名,都不夠直覺。

這些不修完就發版,等於把一個無法在 CI 驗證、會污染環境、且可能靜默失能的 v1.0.0 推出去。

## Key Decisions

- **KD1 — 測試工作根 = repo 內 gitignored sandbox。** 所有測試產物只寫進 `plugins/turbo-plugin/tests/.sandbox/`(列入 `.gitignore`),路徑 repo 相對。CI runner checkout 的工作目錄可寫且用完即丟,本地失敗也好原地翻查。**任何進 GitHub 的檔案都不得含本機絕對路徑。**
- **KD2 — CI 原則「能跑的就跑」。** `windows-latest` 跑全部 `.ps1`(真 PS 5.1)+ 全部 `.sh`(git-bash,.NET 組 delegate 回 ps1);`ubuntu-latest` 只跑真跨平台的 SVN/git 橋接 `.sh`。環境缺工具的測試**乾淨 SKIP 而非 fail**,CI 把 SKIP 視為非失敗。
- **KD3 — CI 以慣例自動探索,免逐 plugin 寫 workflow。** 單一(或固定一組)workflow 以 matrix 掃 `plugins/*/tests/`,對每個遵循標準測試佈局的 plugin 自動跑其標準入口;新增 plugin 不需新增/修改任何 `.yml`。
- **KD4 — 兩層常駐測試套件。** script test(自動)與 skill test(人工)對等並存於 `plugins/turbo-plugin/tests/`,皆可重複、path-free。skill test 是 script test case 的人工版對應物。
- **KD5 — CLAUDE.md 改 marketplace 通用規範。** 不點名任何 plugin、不列 plugin 清單;單一 plugin 細節規範寫在該 plugin 自己的 `README.md`,CLAUDE.md 只放通則指向 README。
- **KD6 — CLAUDE.md 明訂測試標準。** 未來每個 plugin 都必須有完整測試 + CI 自動化,遵循 KD2/KD3/KD4 的同一套規格(含「測試擺在慣例路徑 + 標準入口」以支援自動探索)。
- **KD7 — v1.0.0 正式退役舊 plugin。** 刪除 tdp/tnf/tgs/tpi 目錄、`marketplace.json` 只列 turbo-plugin 並進 PR。不寫遷移、視為全新(舊 plugin 靠 git history / main 作備份)。
- **KD8 — worktree 收進 `.turbo-plugin/worktrees/`。** 取消 `.code-workspace`;`tp-setup` 將該目錄加入 `.gitignore`。
- **KD9 — 分支與目錄命名。** 分支 `remote-svn/main`、`remote-svn/test-<n>`;worktree 目錄 `remote-svn-main`、`remote-svn-test-<n>`。turbo-plugin 只管 `remote-svn-*`,不碰 `dev-<n>`。
- **KD10 — release tag 判準 = 有無產出 git merge commit。** 不以「svn 是否有變更」為準。
- **KD11 — placeholder 化的驗證 proof 進 PR。** 人工 skill 驗證在 repo 外 & `C:\Turbo` 外的真實目錄跑,計畫與結果一律以 `<VALIDATION_ROOT>` 等 placeholder 表示;結果進 PR 但 path-free。
- **KD12 — 單一 v1.0.0 PR + PR 前 gate。** 以上全部進同一個 PR;人工 skill 驗證的「執行」是發 PR 前最後的 gate,在其餘修正全部落地後才跑。

## Requirements

### 測試可攜與零污染（主題 1）

- R1. 測試**自己導向的寫入**(測試直接寫、或傳給工具的路徑)只能落在 `plugins/turbo-plugin/tests/.sandbox/`(repo 樹內);執行全程不得在 `C:\Turbo` 或 repo 樹內 sandbox 以外的位置建立檔案/目錄,**即使「建立後又刪除」也不允許**。此規範涵蓋測試直接導向的寫入;工具自身的全域狀態(如 `%APPDATA%\Subversion` 的 config/servers skeleton——測試全走 `file:///`、不做認證,故不會寫 auth credential)不在「零寫入」字面內——`svn` client 改用 sandbox-local `--config-dir` 使其也不被污染(見 R4、AE5)。
- R2. 任何會進 PR 的檔案(script、test、docs、results、CI 設定)都不得含機器本機絕對路徑。
- R3. 移除先前 containment commit 留下的寫死 `C:\Turbo\test-turbo-plugin`,改用 R1 的 sandbox 機制(此項是改寫,不是新增另一條寫死路徑)。
- R4. 測試所需的 svn `file:///` URL、git worktree 路徑等,一律由 sandbox 根動態推導,不得硬編碼;此「動態推導 + path-free」**同樣適用 bash fixture helper**(`new_sb` / `new_sandbox` / `rm_sb` 等——目前 5 個 `.sh` 測試硬編 `/c/Turbo`),不是只有 `.ps1`。sandbox 根解析層**必須容忍含空格或 8.3 短檔名的 parent path**(例如 repo clone 在 `C:\Users\Mel Wu\…` 之下):以長形 `[System.IO.Path]::GetFullPath` 解析、對每個 `svnadmin` / `cmd` 重導 / `Push-Location` 傳長形 quoted LiteralPath,避免重現先前寫死 `C:\Turbo` 所迴避的 PS 5.1 8.3 短檔名 tilde-expansion bug。SVN 全域狀態隔離**只套用 `svn` client(checkout/info/copy/commit/update)的 `--config-dir`**;`svnadmin` / `svnlook` 無此選項、也不讀 `%APPDATA%`,只需給長形 quoted 路徑。
- R5. sandbox 在每次測試執行的開頭/結尾清理,確保可重複且不殘留。

### CI 自動化（主題 1）

- R6. 新增 GitHub Actions workflow 跑測試套件;與 v1.0.0 PR 一起上(在此之前不先獨立推上 GitHub)。
- R7. CI 以**慣例自動探索**每個 plugin 的測試:用 matrix 掃 `plugins/*/tests/`,對每個遵循標準佈局的 plugin 跑其標準測試入口。**新增一個照規格擺放測試的 plugin 不需新增或修改任何 `.github/workflows/*.yml`**;不得用「逐 plugin 手寫 workflow / 手動維護 plugin 清單」的作法。
- R8. `windows-latest` job 跑全部 `.ps1`(PS 5.1)+ 全部 `.sh`(git-bash)。
- R9. `ubuntu-latest` job 跑「SVN/git 橋接」那組真跨平台 `.sh`;.NET/IIS 組(`ps1-delegate.sh` 轉呼叫 PowerShell)在 Linux **於 fixture setup 之前**就偵測到缺 PowerShell/MSBuild/IIS 而 SKIP。R9 的「group」**不是 orchestrator 層的群組過濾**——discovery 仍按路徑扁平探索、不帶 group marker;ubuntu 上「哪些跑、哪些 SKIP」純粹由**每個測試依 R10 自我 SKIP** 決定(因此真跨平台測試的 fixture 不可順手依賴 powershell,見 R10(b))。
- R10. 測試能自我偵測所需能力(msbuild / IIS / svn / OS / 真正需要的 powershell)並乾淨 SKIP。**區分兩種 powershell 依賴**:(a) SUT 本身需要 PowerShell/MSBuild/IIS(如 .NET/IIS ps1-delegate 組)→ 缺工具時在任何 `powershell` 呼叫之前就 SKIP;(b) fixture 只是順手用 `powershell` 做 GUID/cleanup(如 `get-target-url.test.sh` 這種真跨平台 SVN-URL 測試)→ **改寫成 powershell-free(GUID 用 `uuidgen`、cleanup 用 `rm -rf`)讓它在 ubuntu 照常 RUN**,而非 SKIP。CI 將 SKIP 與 PASS/FAIL 區分,SKIP 不算失敗。

### 兩層常駐測試套件（主題 1 + 2）

- R11. script test 與 skill test 皆常駐於 `plugins/turbo-plugin/tests/`、版本控管、可重複、path-free,且擺在 R7 自動探索得到的慣例路徑與標準入口。
- R12. skill test 是 script test case 的人工版:每個 case 結構為「agent 依該 case 建好 fixture 檔案結構 → 給使用者該 case 的操作指示 → 使用者執行 → 記錄結果」。
- R13. 任何人都能照著 skill test 套件逐 case 重跑(如同本地跑 script test),以支援未來每次 plugin 變更的回歸驗證。
- R14. 改寫並取代現有 `plugins/turbo-plugin/tests/docs/skill-tests.md` 與 `skill-tests-session-plan.md`:去硬編碼 + 更新 case 反映新結構(`remote-svn/*` 分支、`.turbo-plugin/worktrees/`、release tag step、無 `.code-workspace`)。
- R15. skill 驗證結果以 placeholder 記錄並進 PR(`plugins/turbo-plugin/tests/runs/v1.0.0/skill-tests-results.md`),不得含本機路徑。

### marketplace 治理與 CLAUDE.md（主題 4）

- R16. `CLAUDE.md` 只保留整個 marketplace 通用的規約(版本號規則、標準 plugin 結構、skill/command/script 三層分工、跨平台 + PS 5.1 相容規則、設定檔分層、changelog 規約、marketplace manifest 規則);不提任何特定 plugin、不列 plugin 清單。
- R17. `CLAUDE.md` 明文表示「每個 plugin 的細節規範寫在各自的 `README.md`」。
- R18. `CLAUDE.md` 明訂:未來每個 plugin 都必須具備完整測試 + CI 自動化,遵循與 turbo-plugin 相同的兩層測試規格,並把測試擺在慣例路徑 + 標準入口(讓 R7 的自動探索能納入)。
- R19. 目前僅存在於 `CLAUDE.md` 的 plugin 專屬內容,在從 CLAUDE.md 移除前須先確認已落在對應 plugin 的 `README.md`(必要時搬移),避免遺失。

### 退役舊 plugin（主題 3）

- R20. 刪除 `plugins/turbo-dev-pack`、`plugins/turbo-dotnet-framework-commands`、`plugins/turbo-git-with-remote-svn`、`plugins/turbo-plugins-integration` 四個目錄。**此刪除受單一複合 gate 管制:必須同時滿足 (a) R31 parity 盤點完成且使用者逐項簽核、(b) owner 確認 dev marketplace `turbo-plugins-claude-dev` 無外部 clone/訂閱(見 Dependencies/Assumptions),兩者皆成立才執行**——在此之前四個舊目錄保留為 in-tree 的 source-of-truth 參考。
- R21. `.claude-plugin/marketplace.json` 只列 turbo-plugin,並在本 PR 中提交(先前「不提交 marketplace.json」的暫行約束解除)。

### worktree 結構與命名（主題 5 + 6）

- R22. remote worktree 一律建在 `<proj>/.turbo-plugin/worktrees/` 之下。
- R23. 不再建立/維護 `<proj>.code-workspace`;移除所有維護它的腳本與 skill 邏輯(含 `tp-create-remote-test` 的 completion check)。
- R24. `tp-setup` 將 `.turbo-plugin/worktrees/` 加入 `.gitignore`,且**此 ignore 規則必須在第一次 `git worktree add` 之前寫入**(否則主 worktree 的 `git status` 會把巢狀 worktree 視為未追蹤內容,導致 `tp-push-to-svn` 的 clean-check 拒跑);既有 setup 須 idempotent 補寫。
- R25. 分支命名 `remote-svn/main`、`remote-svn/test-<n>`;worktree 目錄 `remote-svn-main`、`remote-svn-test-<n>`。
- R26. turbo-plugin 只管理 `remote-svn-*` worktree,不再處理 `dev-<n>` 等其他 worktree。
- R27. 所有「定位主 worktree / 解析 remote worktree」的邏輯(`get_main_worktree` / `resolve_remote_worktree` 及 `.ps1` 對應)更新以符合新巢狀層級。
- R28. 不提供舊結構→新結構的遷移程式;新 setup 直接用新佈局。

### push-to-svn release tag（主題 7）

- R29. 只要 push 流程產出了 git merge commit(包含「檔案被 git 追蹤但被 svn:ignore,導致 svn commit 為空」的情況),就詢問 release tag;唯有 git、svn 皆無變更、根本無 merge commit 可產出時才跳過。
- R30. 把 tgs 漏搬的 release-tag 能力補進 turbo-plugin:`tp-push-to-svn` 的 Step 7(Yes/No 詢問)+ `tag-release.ps1` / `tag-release.sh`。移植時 ref 解析**必須改用 R25 的新命名**(`remote-svn/main`、`remote-svn/test-<n>`),不可沿用舊的 `remote/main`(否則 `git tag … remote/main` 會 unknown revision);需有 skill-test case 驗證 tag 指向 `remote-svn/test-<n>`。

### parity 盤點（主題 8，盤點動作在 plan 階段）

- R31. 在 plan 階段產出「舊 plugin(tdp/tnf/tgs/tpi)有、turbo-plugin 沒有」的能力對照清單(例如 `merge-main-into-all`、`init-from-existing` 等),逐項標記「補 / 不補 / 刻意不要」,由使用者決定;此盤點與簽核**先於** R20 刪除。退役舊 plugin 不得造成未盤點的靜默失能。標記為「補」但需非 trivial 實作的項目,移到 follow-up PR 追蹤為已知 gap,**不阻塞 v1.0.0 合併**(與 KD12 的張力以此化解:盤點與決策進此 PR,大型補實作可後續)。**trivial 判準**:只在現有 script/command 加少量條件邏輯 = trivial(進 v1.0.0);需新增任一獨立 `.ps1`/`.sh` 實作檔、或新增 skill/command 文件 = non-trivial(移 follow-up)。每個 non-trivial「補」項在 v1.0.0 PR 合併前須開出追蹤 issue(或在 PR body 以 task-list 連結),v1.0.0 merge checklist 含「所有 non-trivial 補項皆有追蹤」。

## Acceptance Examples

- AE1. **Covers R29, R30.** 工作分支有新 commit,但變更檔案全被 `svn:ignore`。跑 `/tp-push-to-svn`:merge 產出 git merge commit、`svn commit` 報無變更 → **仍然詢問 release tag**;選 Yes 則建出 `<branch>-release-*` git tag。
- AE2. **Covers R29.** 工作分支相對 `remote-svn/<branch>` 無任何新 commit(git、svn 皆無變更)→ 回報 nothing to push、不產 merge commit → **不詢問 release tag**。
- AE3. **Covers R9, R10.** 在 `ubuntu-latest` 跑 `build-web.test.sh`(ps1-delegate,需 PowerShell/MSBuild/IIS)→ 測試在 fixture setup **之前**偵測到缺 PowerShell → 標記 SKIP(不因 fixture 呼叫 `powershell` 而 fail)→ CI job 仍為綠燈。
- AE4. **Covers R7.** 假想新增一個遵循標準測試佈局的 plugin(`plugins/<new>/tests/` + 標準入口)→ 不改任何 `.github/workflows/*.yml`,CI 下次跑就把它的測試納入 matrix 執行。
- AE5. **Covers R1.** 完整跑一輪 script test 後,`C:\Turbo` 頂層與 `tests/.sandbox/` 以外位置零**測試導向**產物;工具全域狀態(SVN config skeleton)因 `svn` client 走 sandbox-local `--config-dir` 而不污染 `%APPDATA%`;sandbox 內產物在結尾被清掉。
- AE6. **Covers R2, R15.** 對整個會進 PR 的檔案樹搜尋本機絕對路徑樣式(`C:\Turbo`、`/c/Users` 等)→ 零命中;`skill-tests-results.md` 以 `<VALIDATION_ROOT>` 等 placeholder 記錄。
- AE7. **Covers R16, R17, R18.** 讀 `CLAUDE.md`:找不到任何特定 plugin 名稱或 plugin 清單;有一句指向各 plugin `README.md`;有一段明訂所有 plugin 必須具備兩層測試 + CI 且擺在慣例路徑。
- AE8. **Covers R4.** 把 repo clone 到含空格的 parent path(如 `C:\Users\Mel Wu\…`)再跑完整 script test → 全程不因 8.3 短檔名 tilde-expansion 而 fail;sandbox / svn repo / worktree 都正確解析,且 `Invoke-PsScript` 經 `cmd.exe /c` 重導的 stdout/stderr tempfile 也能在含空格路徑下寫入並讀回(至少一個經 `Invoke-PsScript` 的 `.test.ps1` 在含空格 clone 下綠燈)。
- AE9. **Covers R24.** `tp-setup` 後建立一個 remote worktree,立刻在主 worktree 跑 `git status --porcelain` → 輸出為空(`.turbo-plugin/worktrees/` 已被 ignore,巢狀 worktree 不顯示為未追蹤)。
- AE10. **Covers R31, R20.** 執行 R20 刪除前,PR 內可找到一份標記完整的能力對照清單(每個 gap 皆有「補 / 不補 / 刻意不要」決策 + 使用者簽核紀錄),刪除 commit 時序晚於簽核(或對照清單與刪除同 PR、簽核在 review thread);且每個 non-trivial「補」項皆有追蹤 issue/task。

## Scope Boundaries

- 舊結構(`<proj>.worktrees/remote-*`、`remote/*` 分支、`.code-workspace`)的自動遷移——不做,視為全新。
- `dev-<n>` 等非 `remote-svn-*` worktree 的管理——不在 turbo-plugin 範圍。
- v0.2.x 或任何向後相容/降版路徑——不做。
- 在獨立時間點先把測試推上 GitHub——不做;CI 設定與全部變更同進一個 v1.0.0 PR。
- 人工 skill 驗證的「實際執行」——本輪只**撰寫**常駐套件與計畫;執行是發 PR 前最後 gate,等其餘修正全部落地後才跑(因此這份需求的交付物是「修好的程式 + 可重複套件」,不含驗證執行結果本身)。

## Dependencies / Assumptions

- 假設 GitHub Actions runner 具備或可安裝 `git` 與 `svn`;`windows-latest` 映像內含 Windows PowerShell 5.1。
- **退役 + 不遷移的真正前提是:dev marketplace `turbo-plugins-claude-dev` 未被任何外部使用者 clone / 訂閱**(turbo-plugin 雖已是 1.0.0、marketplace 仍列舊 plugin,故「無外部使用者」不能當然成立)。R20 刪除前須由 owner 明確確認此前提成立,並以該確認為刪除的 gate。
- 假設使用者本機現有的 SVN 測試環境可接受手動重建或拋棄(KD7 不寫遷移的前提)。

## Outstanding Questions

### Deferred to Planning

- parity 盤點的實際結果——哪些漏搬能力要補回、哪些刻意不要(R31 的清單在 plan 階段產出後逐項決定)。
- 單一 v1.0.0 PR 內部的相依與階段切分(哪些先做、哪些可平行)。
- CI 自動探索的慣例細節:標準測試入口的命名/介面(`.ps1` orchestrator 與 skill-test 的標準進入點)、matrix 如何同時跨 plugin 與跨 OS(R7 與 R8/R9 的組合方式)。
- `CLAUDE.md` 內現有 plugin 專屬內容有多少已存在於 turbo-plugin `README.md`、多少需搬移(R19 的盤點)。
- 既有 36 個 script test case 去硬編碼後,是否有 case 因新 worktree 佈局/分支命名而需要改寫測試邏輯(非只改路徑)。
