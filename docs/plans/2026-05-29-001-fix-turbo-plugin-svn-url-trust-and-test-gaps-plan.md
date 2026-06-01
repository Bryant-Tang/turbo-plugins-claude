---
title: "fix: turbo-plugin SVN URL 信任驗證 + script-level 測試補缺"
type: fix
status: completed
date: 2026-05-29
---

# fix: turbo-plugin SVN URL 信任驗證 + script-level 測試補缺

## Summary

修補一個 production 安全洞(`New-RemoteTest` 把未驗證的外部 SVN URL 直接餵給 `svn copy` / `svn checkout` / `svn info`),並回補 script-level 測試套件 `2026-05-25-002` 廣度達成、深度縮水所遺留的覆蓋缺口——指令信任把關、regex 誤殺防護、中文訊息檔的 no-BOM 編碼、lib helper 單元測試,以及一個 rollback regression。順帶把該舊 plan 兩條已過時的 sub-test 標 N/A。

---

## Problem Frame

`2026-05-25-002-feat-turbo-plugin-script-level-test-plan.md` 的廣度目標已達成:22 個 script 各有 `.ps1` + `.sh` 配對測試、orchestrator(`plugins/turbo-plugin/tests/Invoke-ScriptTests.ps1`)可跑、最近一次 run 36/36 PASS。但逐行核對發現深度 sub-test 在 v1.0 重寫時被縮水,且其中一條「應驗未驗」的安全項其實對應一個**真實的 production 功能缺**,不只是測試缺:

- `plugins/turbo-plugin/scripts/New-RemoteTest.ps1` 是唯一接受呼叫端傳入 SVN URL(`-SvnUrl`)的 script。它在三處把這個未經驗證的 URL 拿去做副作用操作:`svn info`(存在性探測)、`svn copy`(在任意目的地建 branch)、`svn checkout --force`(把任意 URL 簽出到本地 worktree)。攻擊面包含 path traversal 與 scheme switch(例如 `file:///C:/Windows/...`、`http://attacker/...`)。`new-remote-test.sh` 是原生 bash 實作(非 ps1-delegate),帶有同樣三處邏輯,必須同步修補。

其餘缺口屬「測試覆蓋不足」而非功能錯誤:shell 注入 canary(`Compress-Content`)、csproj-stem regex 誤殺防護(`Remove-OrphanIis`)完全 0 覆蓋;CJK argv→svn 的編碼往返只有診斷 token、沒有真正往返驗證;`lib/Common.ps1` 16 個目標 function 只有 2 個被直接測到(含一個 v0.2.1 修過的 P0 bug `Get-RelativePathSafe` 沒有 regression test);`New-RemoteTest` 的 trap 位置修正已落地但缺「git mutation 失敗也會 rollback」的 regression case。

兩條舊 sub-test 已因架構演進失效,應在舊 plan 標記而非假裝補測:`U3.9` PS↔bash hash bit-for-bit parity(bash `get_project_identity_hash()` 已在 v0.2.7+ 刻意刪除,見 `plugins/turbo-plugin/scripts/lib/common.sh` 的移除註解)、`U2.12` `Find-MSBuild` 的 env 情境(v1.0 已改 strict-cut,env 一律不讀)。

本 plan 全程在 `feat/turbo-plugin-v1.0` 分支、屬 v1.0.0 範圍,不 bump 版本、不動 `.claude-plugin/marketplace.json`。

---

## Requirements

### 安全(production 行為修正)

- R1. `New-RemoteTest`(`.ps1` 與 `.sh` 兩端)在**產生任何 git / svn 副作用之前**(即在建立 branch / worktree、以及任何 `svn` 操作之前)先驗證呼叫端傳入的 SVN URL 落在信任根目錄底下;不符則明確 throw / 非零退出,且**不**建立任何 branch / worktree、不觸發 rollback。驗證涵蓋全部三個 URL sink:`svn info` 探測、`svn copy`、`svn checkout --force`。
- R2. URL 信任驗證集中在一個共用 lib helper(`lib/Common.ps1` + `lib/common.sh`),`.ps1` 與 `.sh` 使用同一套比對邏輯,避免兩端發散。
- R3. 信任基準取自 `remote-main` worktree 的 `repos-root-url`(非 trunk `url`),使合法的 sibling branch URL 不被誤拒。
- R10. 比對採「邊界安全」前綴比對:以 `base + '/'` 為前綴或與 `base` 完全相等才算通過,避免 `svn://host/repos` 誤通過 `svn://host/repos-evil/...`(prefix-confusion 繞過)。
- R11. 比對前先正規化大小寫:lowercase URL 的 scheme 與 host(`file://` 另 lowercase 磁碟機代號),再做 ordinal 比對;`.ps1` 與 `.sh` 演算法一致(PowerShell 5.1 `StartsWith` 預設 case-sensitive,不正規化會產生繞過)。

### 測試覆蓋補缺

- R4. `Compress-Content`(pack-content)的「信任把關」有效:trust hash 不符或未核准的 install/build 指令會被**拒絕執行**(throw / 非零 / 不產生指令副作用)而非靜默放行。canonical 斷言放 `.ps1`;`.sh` 為 delegate-smoke(`compress-content.sh` 是 ps1-delegate、無獨立邏輯,只驗 dispatch + 錯誤往上冒)。(原 002 U8.3 的 shell-metachar canary 已查明對現行 tokenized invocation 無效——該 script 不經 shell 解析,metachar 結構上無法注入,canary 為空測試;改測真正存在的信任把關。)
- R5. `Remove-OrphanIis` 比對 running `iisexpress.exe` 的 `/site:` 名稱時,把 csproj stem 當 literal(regex-escape)而非 regex,不誤殺 stem 含 regex metacharacter 的站台。canonical 斷言放 `.ps1`;`.sh` 為 delegate-smoke(`remove-orphan-iis.sh` 是 ps1-delegate)。(v1.0 已移除 applicationhost.config 的 XML 掃描,保護點在 process 命令列比對。)
- R6. 中文寫入 SVN commit 訊息檔的編碼正確:`Write-Utf8NoBom`(ps1)/ `write_utf8_no_bom`(sh)把 CJK 內容寫成**不帶 BOM 的 UTF-8**、byte 正確。這是 `Submit-SvnCommit` 透過 `svn commit --file <tmp> --encoding UTF-8` 送出中文訊息時真正依賴的編碼關卡(訊息是寫進 UTF-8 暫存檔再交給 svn,**不是**用 argv 直接傳)。在 U7 / U8 的 lib helper 測試中涵蓋。
- R7. `lib/Common.ps1` / `lib/common.sh` 的未測 helper 取得直接單元覆蓋,優先 `Get-RelativePathSafe`(P0 regression)與 `Get-ProjectIdentityHash` 的 cross-repo isolation。
- R8. `New-RemoteTest` 在 git mutation(branch 建立)失敗時也會完整 rollback,有對應 regression case(現有測試只涵蓋 `svn copy` 失敗那條路徑)。

### 舊 plan 對帳

- R9. `2026-05-25-002` 的 `U3.9`(hash parity)與 `U2.12`(`Find-MSBuild` env 情境)在該 plan 內標為 N/A 並寫明失效原因,保留審計軌跡而非刪除。

---

## Key Technical Decisions

- KTD1 — URL 信任驗證集中為共用 lib helper(`Assert-TrustedSvnUrl` in `lib/Common.ps1`、`assert_trusted_svn_url` in `lib/common.sh`),不在 script 內 inline。**唯一理由是避免 `.ps1` / `.sh` 兩端比對邏輯發散**(這正是 `U3.9` hash function 當初發散後被刪的教訓);目前只有 `New-RemoteTest` 一個 consumer,不為「未來可能的重用」過度泛化 helper 介面(其餘 SVN script 的 URL 皆從信任本地 WC 衍生,本 plan 的 Scope Boundaries 已確認無第二個 consumer)。
- KTD2 — 信任基準用 `svn info --show-item repos-root-url`(query `remote-main` worktree),不是 trunk 的 `url`(用 repos-root 才不會把合法 sibling branch `branches/test-<n>` 誤判為越界)。**注意現況:** `New-RemoteTest.ps1` 取 `remote-main` URL 的查詢目前在 `if (-not $svnExists)` 分支內(約 L70-72),位置在第一個 sink `svn info $SvnUrl`(約 L66)**之後**;因此實作時必須**把 `remote-main` 的 `repos-root-url` 查詢往前提到所有 sink 與所有 git mutation 之前**——這是一個新的前置步驟,不是「現成可得」。
- KTD3 — 驗證涵蓋全部三個 URL sink。`svn checkout --force` 把任意 URL 簽出到本地 worktree 比 `svn copy` 更危險,只擋 `svn copy` 不足;`svn info` 探測雖唯讀也會連到攻擊者 URL,故驗證必須在它之前。
- KTD4 — 比對採「邊界安全」前綴:正規化兩端(去信任 base 尾斜線、lowercase scheme/host、`file://` lowercase 磁碟機代號)後,以 `candidate == base` 或 `candidate.StartsWith(base + '/')` 判定通過。單純 `StartsWith(base)` 會被 `repos` vs `repos-evil` 這類 prefix-confusion 繞過(見 R10);PowerShell 5.1 `StartsWith` 預設 case-sensitive,不正規化大小寫會被 `FILE://` vs `file://` 繞過(見 R11)。
- KTD5 — 舊 plan 過時項用「就地標 N/A + 原因」對帳,不刪 sub-test。理由:`002` 是歷史決策文件,保留條目與失效原因比抹除更有審計價值。
- KTD6 — 所有 CJK 測試資料一律取自 `plugins/turbo-plugin/tests/docs/script-tests-schema.md` 的 25 條字典(單一真實來源);任何含非 ASCII 的新 `.ps1` 存成 UTF-8 with BOM(PS 5.1 中文 Windows 相容,見 CLAUDE.md)。CJK 往返判定重用既有的 F-3 容忍 helper `Assert-SvnLogTextRoundTrip`,不另造判定邏輯。
- KTD7 — 不新增 orchestrator 程式碼。測試靠 `*.test.{ps1,sh}` 命名 + `tests/unit/` 位置自動被 discover；本 plan 涉及的 script(`New-RemoteTest` / `Compress-Content` / `Remove-OrphanIis` / `Common`)其 `### <Section>` heading 在 results doc(`Write-TrackingRow.ps1` 實際寫入處)應已存在,實作前驗證存在即可,僅在缺漏時補建。

---

## Implementation Units

單元依四個 phase 排序;Phase A(安全)為 production 行為修正,優先且先行。除標注依賴外,Phase B/C/D 各單元彼此獨立。所有測試遵守既有 pattern:`.ps1` prod test dot-source `tests/lib/AssertHelpers.ps1` 並用 `Assert-*` + `Reset-Counters`,結尾 `exit ($Failed -gt 0)`;`.sh` test 自帶 inline `assert_eq`/`assert_match`,最後一行輸出 `OK: ...`(成功)或 `FAIL: ...`(失敗)並對應 exit code。

### Phase A — Production 安全修正

> Phase A(U1 + U2)是這份 plan 唯一改動 production 行為的部分,**可獨立 review / merge,不需等待 Phase C / D 的補測單元完成**。實作上建議讓 U1 + U2 構成可獨立交付的提交序列。

#### U1. 共用 SVN URL 信任 helper（lib + 單元測試）

- **Goal:** 在 lib 新增 `Assert-TrustedSvnUrl`(ps1)/ `assert_trusted_svn_url`(sh),驗證傳入 URL 落在指定 working copy 的 `repos-root-url` 底下,否則 throw / 非零退出;並補對應 lib 單元測試。
- **Requirements:** R2, R3, R10, R11
- **Dependencies:** 無(但 **blocks U7、U8**——三者共用 `Common.test.ps1` / `common.test.sh`,序列執行需 U1 先落地;若平行實作需 worktree 隔離)
- **Files:**
  - `plugins/turbo-plugin/scripts/lib/Common.ps1`(新增 function)
  - `plugins/turbo-plugin/scripts/lib/common.sh`(新增 function)
  - `plugins/turbo-plugin/tests/unit/scripts/lib/Common.test.ps1`(新增 case;與 U7 共用此檔)
  - `plugins/turbo-plugin/tests/unit/scripts/lib/common.test.sh`(新增 case;與 U8 共用此檔)
- **Approach:** helper 接「信任參考 working copy 路徑」+「待驗 URL」,內部跑 `svn info --show-item repos-root-url <wc>` 取信任 base(**注意:必須用 `repos-root-url`,不是 `url`/trunk;sh 端不可沿用 `new-remote-test.sh` 既有的 `--show-item url`**)。比對採**邊界安全 + 大小寫正規化 + 兩端尾斜線**(見 KTD4):去 base **與 candidate** 尾斜線、lowercase 兩端的 scheme/host(`file://` 另 lowercase 磁碟機代號)、percent-decode 兩端後,以 `candidate == base` 或 `candidate.StartsWith(base + '/')` 判定;**不可**用裸 `StartsWith(base)`(prefix-confusion)或 case-sensitive 比對;含 `..` traversal 的 candidate 一律 reject。ps1 版不符時 `throw`;sh 版回非零並寫 stderr。`svn info` 取不到 base 時(WC 不存在 / 非 WC / server 連不到)一律 **fail closed**(視為不通過,不可讓呼叫端 catch 後繞過)。lib test 以 dot-source 方式直接呼叫 helper(mirror `Common.test.ps1` 既有的「向上四層定位 + 直接 source」pattern),用 seed svn 固件提供真實 working copy 當信任參考;**fail-closed 案例用「空的非-WC 暫存目錄」當參考路徑**,讓 `svn info` 穩定失敗(不需斷網)。
- **Patterns to follow:** `plugins/turbo-plugin/scripts/lib/Common.ps1` 既有 helper(`Get-NormalizedAbsolutePath` 已 lowercase 磁碟機代號可參考、`Resolve-RemoteWorktree`)的參數/錯誤風格;lib test import pattern 見 `plugins/turbo-plugin/tests/unit/scripts/lib/Common.test.ps1` 開頭(向上四層 dot-source)。
- **Test scenarios:**
  - 同 repo trunk URL(`<root>/trunk`)→ 通過。
  - 合法 sibling branch URL(`<root>/branches/test-1`)→ 通過(證明用 repos-root 而非 trunk url;需確認 seed 固件 repo 根目錄下確實有 `branches/`,否則此 case 無法真正驗到)。
  - `<root>-evil/trunk`(同 host、root 為前綴延伸)→ **reject**(守 R10 prefix-confusion 邊界)。
  - 大小寫變體 `FILE:///C:/...`(scheme 大寫)→ 正規化後仍正確判定(守 R11)。
  - candidate 尾斜線變體(`<root>/branches/test-1/`)→ 與無尾斜線同結果(不因尾斜線誤判)。
  - `file:///C:/Windows/...` 越界 URL → throw / 非零。
  - `http://attacker/...` 不同 host/scheme → throw / 非零。
  - 信任參考用「空的非-WC 暫存目錄」→ `svn info` 失敗 → fail closed(不通過)。
  - sh 端對上述同組輸入行為一致(`assert_eq` 比對退出碼 + stderr 片段)。
- **Verification:** lib test 全綠;helper 在 ps1 與 sh 對同組輸入給出一致 accept/reject;`<root>-evil`、大寫 scheme、fail-closed 三個案例皆被擋;**sh helper 確認呼叫 `repos-root-url`(非 `url`),合法 sibling branch 通過、`<root>-evil` 不通過**。

#### U2. 在 New-RemoteTest 強制 URL 信任驗證 + reject/rollback 測試

- **Goal:** 讓 `New-RemoteTest.ps1` 與 `new-remote-test.sh` 在**任何 git mutation 與任何 svn 操作之前**先呼叫 U1 helper 驗證 `$SvnUrl`;補惡意 URL reject 案例,並補 git-mutation 失敗的 rollback regression。
- **Requirements:** R1, R8
- **Dependencies:** U1
- **Files:**
  - `plugins/turbo-plugin/scripts/New-RemoteTest.ps1`(把 `remote-main` 的 `repos-root-url` 查詢往前提到 git mutation〔約 L55-62〕之前;在所有副作用之前插入驗證)
  - `plugins/turbo-plugin/scripts/new-remote-test.sh`(對應:在 git mutation〔約 L87-89〕與 trap 註冊之前查信任 base 並驗證)
  - `plugins/turbo-plugin/tests/unit/scripts/New-RemoteTest.test.ps1`
  - `plugins/turbo-plugin/tests/unit/scripts/new-remote-test.test.sh`
- **Approach:** **關鍵 — 驗證點要在 outer rollback `try` 之前**(`New-RemoteTest.ps1` 約 L54 的 try 之前;不可放 try 內,否則 reject 也會觸發 rollback、且測試會兩種放法都過而看不出差異)。現況 `svn info $SvnUrl`(第一個 sink)在 L66、git mutation 在 L55-62,而取信任 base 的 `remote-main` 查詢卻在更後面的 `if (-not $svnExists)` 分支(約 L70-72)。實作要把 `remote-main` 的 `repos-root-url` 查詢**提前**到 try 之前,先 `Assert-TrustedSvnUrl` 通過,才進入既有的 branch 建立 / worktree / 三個 sink。**hoist 後每次呼叫都會依賴 remote-main 存在**——若 remote-main 不存在 / 非 WC,要在任何副作用前 fail-closed(明確訊息、提示跑 `/tp-setup`),不可變成既有 svn-path-exists 路徑的靜默回歸。`.sh` 同理:在 L87-89 git mutation 與 ERR trap 註冊之前驗證,且取 base 用 `repos-root-url`(非既有 L95 的 `url`)。rollback regression 不能用「invalid init commit」觸發(`rev-list` 在 try 外〔約 L48〕會先失敗、走 outer catch 而不觸發 rollback),也**不能**碰撞 `test-<n>`(L42-43 有 try 外 pre-check 會先擋);要碰撞 **`remote/test-<n>`**(try 內第一個 git mutation,L55),預先建立它造成 `git branch` 失敗,確認 trap 真的回滾。另:既有測試的 Case 3(bogus `file://` URL)修完後會被新驗證**提前 reject**(不再觸發 rollback),需 **retarget**(改用「信任根內、但 svn copy/checkout 會失敗」的 URL 才真正走 rollback)或交由本單元新增的碰撞案例承擔 rollback 覆蓋——擇一並註明,避免「rejection 假扮 rollback」。
- **Patterns to follow:** 既有 `New-RemoteTest.test.ps1` 的 case 結構(missing-arg / worktrees-missing / bogus-URL-rollback);sandbox 與 svn 固件取得方式 mirror `Get-ProjectIdentity.test.ps1`。
- **Test scenarios:**
  - `Covers 002:U17.4b.` 餵 `file:///C:/Windows/System32/` → reject、非零退出、**無 branch 被建立、無 worktree 被簽出、未進 rollback**。
  - `Covers 002:U17.4b.` 餵 `http://attacker.example/repo` → reject、無副作用。
  - `Covers R10.` 餵 `<repos-root>-evil/branches/test-1`(prefix-confusion)→ reject。
  - 合法 sibling branch URL → 通過,行為與修前一致(不回歸)。
  - remote-main 不存在 / 非 WC → 在任何副作用前 fail-closed(非零、無 branch/worktree、清楚訊息)。
  - `Covers 002:U17.5.` 預置 **`remote/test-<n>`** 製造碰撞使 try 內 `git branch` 失敗 → 觸發 rollback;斷言 rollback **確實執行**(部分建立的 branch/worktree 被清掉),而非只看退出碼。
  - sh 端對 reject 與 rollback 案例行為一致(退出碼 + stderr 片段)。
- **Verification:** New-RemoteTest 兩端測試全綠;惡意 URL 在任何副作用前即被擋(reject 案例不留任何 branch/worktree、不觸發 rollback);rollback 案例確實觀察到回滾動作(非 rejection 假扮);remote-main 缺席 fail-closed;既有合法路徑不回歸。

---

### Phase B — 舊 plan 對帳

#### U3. 在 002 plan 標記兩條過時 sub-test 為 N/A

- **Goal:** 在 `2026-05-25-002` plan 內把 `U3.9` 與 `U2.12` 標為 N/A 並寫明失效原因。
- **Requirements:** R9
- **Dependencies:** 無
- **Files:** `docs/plans/2026-05-25-002-feat-turbo-plugin-script-level-test-plan.md`
- **Approach:** 在 `U3.9` 條目註明:bash `get_project_identity_hash()` 已於 v0.2.7+ 刻意移除(IIS/build script 皆 ps1-delegate,hash 一律在 PS 端算;bash 版因斜線正規化差異本就算不出一致 hash),故 PS↔bash parity 無對照對象,標 N/A。在 `U2.12` 條目註明:`Find-MSBuild` v1.0 改 strict-cut,env `TURBO_PLUGIN_MSBUILD_PATH` 一律不讀(見 `plugins/turbo-plugin/scripts/lib/Common.ps1` 對應註解),原 env 情境作廢。不刪除原條目。
- **Patterns to follow:** 該 plan 既有條目格式。
- **Test scenarios:** Test expectation: none — 純文件對帳,無行為變更。
- **Verification:** 該 plan 兩條目可見 N/A 標記與原因,其餘內容不動。

---

### Phase C — security / encoding 測試補缺

#### U4. Compress-Content 信任把關測試

- **Goal:** 驗證 `Compress-Content`(pack-content)在執行 install/build 指令前的信任把關有效:未核准 / trust hash 不符的指令被拒絕,而非靜默執行。
- **Requirements:** R4
- **Dependencies:** 無
- **Files:**
  - `plugins/turbo-plugin/tests/unit/scripts/Compress-Content.test.ps1`
  - `plugins/turbo-plugin/tests/unit/scripts/compress-content.test.sh`
- **Approach:** 為什麼不測 metachar 注入 — `Compress-Content` 用 tokenized invocation(`& $tokens[0] @tokenArgs`,不經 shell),metachar 結構上無法注入,canary 是空測試。真正的安全屬性是「指令在執行前要先通過 trust hash 把關」。構造 config 帶 install/build command 但**未核准 / hash 不符**,執行後斷言該指令被拒(throw / 非零 / 無指令副作用);對照組:已核准的指令正常通過。指令用「會留下可觀察痕跡(touch 一個 sentinel 檔)」的安全指令,以區分「被擋」vs「有跑」。
- **Patterns to follow:** 既有 `Compress-Content.test.ps1` 的 frontend/trust case 結構(`Compress-Content.ps1` 內 `if (-not $trustApproved) { throw ... }` 把關);sandbox 取得方式同其他 unit test;`.sh` 的 delegate-smoke 寫法見既有 `compress-content.test.sh`(明文不重跑 heavy 流程)。
- **Test scenarios — canonical 斷言放 `.ps1`:**
  - 未核准指令 → 被拒(sentinel 檔未生成、非零退出)。
  - trust hash 與 config 不符 → 被拒。
  - 已核准指令(hash 相符)→ 正常執行(sentinel 檔生成,對照組)。
- **Test scenarios — `.sh`(delegate-smoke only):** `compress-content.sh` 是 ps1-delegate,只驗 dispatch 可執行 + 錯誤往上冒,不重複 trust 斷言(沿用既有 delegate-smoke 慣例)。
- **Verification:** `.ps1` 測試全綠且未核准指令確實被擋(對照組證明不誤擋);`.sh` delegate-smoke 通過。

#### U5. Remove-OrphanIis regex 誤殺防護

- **Goal:** 證明 `Remove-OrphanIis` 比對 running `iisexpress.exe` 的 `/site:` 名稱時把 csproj stem 當 literal(regex-escape),不誤殺 stem 含 regex metacharacter 的站台。
- **Requirements:** R5
- **Dependencies:** 無
- **Files:**
  - `plugins/turbo-plugin/tests/unit/scripts/Remove-OrphanIis.test.ps1`
  - `plugins/turbo-plugin/tests/unit/scripts/remove-orphan-iis.test.sh`
- **Approach:** 為什麼不用 applicationhost.config 固件 — v1.0 的 `Remove-OrphanIis` **已移除 XML 站台掃描**,改為比對 running `iisexpress.exe` 的 `/site:` 命令列(`$candidateSite -match $stemPattern`)。保護點是「stem 在組成 `$stemPattern` 時要 regex-escape」,所以要驅動「`/site:` 名稱 → stem 比對」這段,而非建假 XML。以含 metachar 的 stem(如 `My.Test`)對上一個 near-miss 站台名(如 `MyXTest-deadbeef`)斷言**不** match(stem 被當 literal)。process 列舉來源需可注入——**implementation-time 決定**:把 pattern 建構/比對抽成可測 helper,或 mock process 來源(`Get-Process` / `Get-CimInstance` CommandLine);若都不可行,退而直接單元測試 stem→pattern 的 escape 行為。
- **Patterns to follow:** `Remove-OrphanIis.ps1` 的 `/site:([^\s"]+)` 擷取與 `$stemPattern` 比對段;既有 `Remove-OrphanIis.test.ps1` 的 no-orphan happy path case。
- **Test scenarios — canonical 斷言放 `.ps1`:**
  - 10 種 metacharacter stem(`.` `+` `[` `]` `(` `)` `{` `}` `^` `$`)各一案:該 stem 對 near-miss 站台名不誤 match(不被當 orphan)。
  - 對照組:真正的 orphan(stem 完全不對應任何專案)仍被正確清除(不因 escape 而漏清)。
- **Test scenarios — `.sh`(delegate-smoke only):** `remove-orphan-iis.sh` 是 ps1-delegate,只驗 dispatch 可執行,不重複 regex-escape 斷言。
- **Verification:** `.ps1` 測試全綠(metacharacter stem 不誤殺 near-miss 站台、真 orphan 仍清除);`.sh` delegate-smoke 通過。
- **Execution note:** process 列舉的注入 seam 是 implementation-time unknown,實作前先決定用 helper 抽取、mock、還是直接測 escape 行為。

> 原規劃的 U6(CJK 訊息經 `Submit-SvnCommit` → svn 往返)已移除:複查發現 `Submit-SvnCommit` 有沉重的前置條件(需先有 pending merge + 兩個 pin 檔)才肯跑,且它送中文是「寫 UTF-8 暫存檔 + `--file --encoding UTF-8`」而非 argv。真正的編碼關卡是「寫檔不帶 BOM」,已下沉到 U7 / U8 的 `Write-Utf8NoBom` / `write_utf8_no_bom` lib 測試(R6)。中文 commit 訊息的端到端往返歸 deferred skill-level 測試(與中文檔名 push 同)。

---

### Phase D — lib helper 深度補缺

#### U7. Common.ps1 helper 單元測試補缺

- **Goal:** 替 `lib/Common.ps1` 未測 helper 補直接單元測試,優先 `Get-RelativePathSafe`(P0 regression)與 `Get-ProjectIdentityHash` cross-repo isolation;並含 `Write-Utf8NoBom` 的 CJK 無-BOM byte 驗證(R6 的編碼關卡)。
- **Requirements:** R6, R7
- **Dependencies:** U1（共用 `Common.test.ps1` 檔)
- **Files:** `plugins/turbo-plugin/tests/unit/scripts/lib/Common.test.ps1`
- **Approach:** dot-source `Common.ps1` 後直接呼叫各 helper(mirror 既有 import pattern)。`Get-ProjectIdentityHash` isolation 案例用兩個不同 repo path 驗證 hash 不相撞;`Get-RelativePathSafe` 的 P0 regression 用**原始 v0.2.1 bug 的確切輸入**(從 git log / CHANGELOG v0.2.1 條目定位;若不可復原則記錄最接近的近似輸入與理由)。`Write-Utf8NoBom` 寫 CJK 後讀回 byte:前 3 byte **不是** `EF BB BF`、且內容 byte 等於 canonical UTF-8(用 `Assert-FileBytes`)。
- **Patterns to follow:** `plugins/turbo-plugin/tests/unit/scripts/lib/Common.test.ps1` 既有 `Resolve-ConfigValue` / `Find-MSBuild` case 結構與向上四層 dot-source;`Assert-FileBytes`(`tests/lib/AssertHelpers.ps1`)。
- **Test scenarios:**
  - `Get-RelativePathSafe`:3 種路徑輸入 + v0.2.1 P0 bug regression(用原始觸發輸入,命名標記 regression)。
  - `Get-ProjectIdentityHash`:determinism(同輸入同 hash)、case-normalization、cross-repo isolation(不同 repo 不撞)。
  - `Get-NormalizedAbsolutePath`:多種輸入正規化 + 空字串 throw。
  - `Resolve-RemoteWorktree`:main / test-<n> / 不支援分支 throw。
  - `Format-IisExpressSiteName`:ASCII 與中文 csproj stem。
  - `Find-SingleCsproj`:single / 0(throw)/ multiple(throw)。
  - `schema_version` warning:=1 無警告、=2 有警告。
  - `Write-Utf8NoBom`:寫 CJK(取自 schema 25 字典)→ 無 BOM(前 3 byte ≠ `EF BB BF`)+ byte 等於 canonical UTF-8。
- **Verification:** `Common.test.ps1` 全綠且覆蓋上述 helper;P0 regression 用原始輸入、`Write-Utf8NoBom` CJK 無-BOM 有明確 byte 斷言。

#### U8. common.sh helper 單元測試補缺

- **Goal:** 替 `lib/common.sh` 未測 helper 補 bash 單元測試(排除已移除的 hash function);含 `write_utf8_no_bom` 的 CJK 無-BOM byte 驗證(R6)。
- **Requirements:** R6, R7
- **Dependencies:** U1（共用 `common.test.sh` 檔)
- **Files:** `plugins/turbo-plugin/tests/unit/scripts/lib/common.test.sh`
- **Approach:** source `common.sh` 後直接呼叫各 function,用 inline `assert_eq`/`assert_match`。涵蓋 PS 端 U7 的 bash 對應項,但**不**含 `get_project_identity_hash`(已於 v0.2.7+ 移除,見 U3)。`write_utf8_no_bom` 寫 CJK 後用 `od`/`xxd` 檢前 3 byte ≠ `ef bb bf`、內容 byte 等於 canonical UTF-8。
- **Patterns to follow:** `plugins/turbo-plugin/tests/unit/scripts/lib/common.test.sh` 既有 4 個 case 的結構。
- **Test scenarios:**
  - `get_main_worktree`:peer/linked worktree 取得同一 main path。
  - `resolve_repo_path`:relative / absolute / Git-Bash 風格路徑。
  - `resolve_remote_worktree`:main / test-<n> / 不支援分支非零。
  - `write_utf8_no_bom`:寫 CJK(取自 schema 25 字典)→ 無 BOM(前 3 byte ≠ `ef bb bf`)+ byte 等於 canonical UTF-8。
  - `format_iis_express_site_name`:`<stem>-<hash>` 格式。
  - `read_turbo_plugin_config`:flat 模式與 section+key sentinel(`__TP_FOUND__:` 前綴)。
  - `get_normalized_absolute_path`:forward-slash / backslash / 空輸入多種情境。
- **Verification:** `common.test.sh` 全綠且覆蓋上述 function;不含已移除的 hash function;`write_utf8_no_bom` CJK 無-BOM 有明確 byte 斷言。

---

## Scope Boundaries

### 本 plan 不做

- 不 bump 任何 plugin 版本號(整個分支屬 v1.0.0 範圍,無既有使用者、無 migration 需求)。
- 不修改 `.claude-plugin/marketplace.json`(使用者手動管理)。
- 不修改 orchestrator(`Invoke-ScriptTests.ps1` / `invoke-script-tests.sh`)——測試靠命名與位置自動 discover。
- 不對 `Build-SvnCommit` / `Submit-SvnCommit` / `Sync-FromSvn` / `Get-SvnLog` / `Set-SvnIgnore` / `Reset-RemoteTest` 加 URL 驗證——研究確認它們的 SVN URL 皆從信任的本地 working copy 衍生,不吃外部 URL,無同類缺口。

### Deferred to Follow-Up Work

- **中文檔名 push 的 server-byte 驗證(舊 plan `U16.9` / `U16.10`)**:這是「`svn add` 中文檔名 → commit → 驗 server byte」的情境,屬 `/tp-push-to-svn` 的 **skill-level / 手動** 測試(schema doc 已將字典 3.4 / 3.5 標為 reserved for `/tp-push-to-svn` case),不在 script-level 範圍。歸 `2026-05-27-001-feat-turbo-plugin-v1.0-manual-test-plan.md` 的 Phase 2(skill-level)承接。
- U5 的 regex-metachar 集若實作中發現需要更完整的矩陣,以本 plan 列出的核心集(`.` `+` `[` `]` `(` `)` `{` `}` `^` `$`)為準,額外擴充列為後續。

---

## Risks & Dependencies

- R6 的編碼驗證已從「跑 svn 往返」下沉為 `Write-Utf8NoBom` / `write_utf8_no_bom` 的 hermetic byte 測試(不需 svn.exe、不依賴 F-3 codepage),脆弱度大幅降低;原本最高風險的 svn 往返不再在 script 層做。
- **信任基準竄改(已知殘留風險,接受):** `Assert-TrustedSvnUrl` 每次動態問 `remote-main` WC 的 `repos-root-url`。若攻擊者能寫入該 WC 的 `.svn` 內部檔,可污染信任 base。此威脅需要本機 WC 寫入權(門檻高),本 plan 採動態問 + 接受此殘留風險,不在 setup 持久化信任 root(該強化跨出本 plan 範圍,如未來需要再另開)。
- U2 把 `remote-main` 的 `repos-root-url` 查詢 hoist 到所有副作用之前後,**每次呼叫都依賴 remote-main 存在**;remote-main 缺席要 fail-closed(見 U2 測試案例),不可變成既有 svn-path-exists 路徑的靜默回歸。
- U2 誤拒風險:把合法 sibling branch URL 誤拒;KTD2/KTD4 用 `repos-root-url` + 邊界安全比對正是為此,且 U1/U2 都有合法 sibling branch 通過的測試案例守住。
- U1 ↔ U7、U1 ↔ U8 共用同一測試檔(`Common.test.ps1` / `common.test.sh`)。序列執行(U1 先)即可避免衝突;若平行則需 worktree 隔離。
- `### <Section>` heading:`Write-TrackingRow.ps1` 寫的是 **results doc**(`tests/runs/v1.0.0/script-tests-results.md`),其 PascalCase heading 應已存在(這些 script 已有通過的測試);schema doc 用的是舊 command-style heading 且**不被 orchestrator append**。實作前驗證 results doc 的 heading,缺漏才補建,否則 `Write-TrackingRow.ps1` 會 throw。

---

## Sources / Research

- 安全缺口逐行核對:`plugins/turbo-plugin/scripts/New-RemoteTest.ps1` 三個 sink — L66(`svn info`)、L75(`svn copy`)、L84(`svn checkout --force`);git mutation 在 L55-62(早於三個 sink);`new-remote-test.sh` 對應 git mutation L87-89、sink L91 / L97 / L104(原生 bash,非 delegate);L51-62 既有 rollback trap。其餘 SVN script 的 URL 皆由 `svn info --show-item url <wc>` 從信任本地 WC 衍生(`Build-SvnCommit` L50 / `Submit-SvnCommit` L36 / `Sync-FromSvn` 等),不吃外部 URL。
- `repos-root-url` 可行性與**插入點修正**:`New-RemoteTest.ps1` 取 `remote-main` URL 的查詢在 `if (-not $svnExists)` 分支內(約 L70-72),位置**晚於**第一個 sink(L66)與 git mutation(L55-62)。`remote-main` 是合法 SVN WC、`repos-root-url` 可取,但必須把該查詢**往前提到所有副作用之前**——故 KTD2 修正為「需新增前置查詢」,非「現成可得」。
- U-ID 引用慣例:plan 內 `Covers 002:U17.4b` 之類標記引用的是**上游 002 plan 的 sub-test ID**(非本 plan 的 U1-U8)。`New-RemoteTest` 是 v1.0 對舊 `create-remote-test` 的 rename,002 的 U17 即對應現在的 `New-RemoteTest`。
- 測試 infra 慣例:orchestrator discovery/routing/PASS-FAIL 見 `plugins/turbo-plugin/tests/Invoke-ScriptTests.ps1`(discovery L296-305、routing L315-361、infra gate L219-294、prod case L427-570);範例配對 `tests/unit/scripts/Get-ProjectIdentity.test.ps1` + `get-project-identity.test.sh`;assert API 見 `tests/lib/AssertHelpers.ps1`(含 `Assert-SvnLogTextRoundTrip` L276-368 的 F-3 容忍)。
- 固件:`tests/fixtures/base/.turbo-plugin/applicationhost.config`(fake IIS site `HelloApp-deadbeef`)、`tests/fixtures/seed/`(svn dump r1-r20,CJK 在 r5/r10/r15)、`tests/fixtures/reset/Reset-Fixture.ps1`。
- CJK 字典與 reserved 條目:`tests/docs/script-tests-schema.md`(25 條字典;3.4 / 3.5 標 reserved for `/tp-push-to-svn`)。
- 結果記錄格式:`tests/runs/v1.0.0/script-tests-results.md`(每 script 兩列:`.ps1` 與 `.sh`;`Write-TrackingRow.ps1` 需既存 `### <Section>` heading)。
- 失效項依據:`plugins/turbo-plugin/scripts/lib/common.sh` 的 `get_project_identity_hash` 移除註解(v0.2.7+);`plugins/turbo-plugin/scripts/lib/Common.ps1` `Find-MSBuild` strict-cut 註解(env 不讀)。
- `Submit-SvnCommit` 送中文訊息的機制:寫進 UTF-8 暫存檔再 `svn commit --file <tmp> --encoding UTF-8`(**非 argv**),且有 MERGE_HEAD + `MERGE_HEAD.tp_branch_sha` + `MERGE_HEAD.tp_svn_status` 三道前置 gate(`Submit-SvnCommit.ps1` L32-68 / `submit-svn-commit.sh` L38/L53/L71)。故 R6 的編碼關卡定位在 `Write-Utf8NoBom`(寫檔不帶 BOM),中文訊息端到端往返因前置 gate 太重而歸 skill-level。
- `compress-content.sh` / `remove-orphan-iis.sh` 為 ps1-delegate(一行轉呼叫 `lib/ps1-delegate.sh` → .ps1),無獨立邏輯;故 U4 / U5 的 .sh 採 delegate-smoke 慣例(canonical 斷言在 .ps1)。
- 上游 plan:`docs/plans/2026-05-25-002-feat-turbo-plugin-script-level-test-plan.md`(本 plan 的補缺對象)。
