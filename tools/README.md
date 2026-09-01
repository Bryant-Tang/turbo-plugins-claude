# `tools/` — repo 層級腳本

放**跨 plugin / repo 層級**的腳本。plugin 自己的腳本一律留在 `plugins/<name>/scripts/`，不要放這裡。

| 腳本 | 做什麼 | 誰在用 |
| --- | --- | --- |
| `affected-plugins.sh` | 依變更檔案清單判斷「哪些 plugin 的測試套件要跑」 | `.github/workflows/tests.yml` 的 `discover` job |
| `plugin-requires-tool.sh` | 讀 `plugins/<name>/tests/required-tools`,答「這個 plugin 需不需要某個外部工具」 | `tests.yml` 的 `Install Subversion` 步驟(兩個平台) |
| `install-svn.sh` | 裝 Subversion,並依平台用對的重試形狀(apt 要先有逾時才重試得動,choco 直接重試) | `tests.yml` 的 `Install Subversion` 步驟(兩個平台) |
| `verify-inert-files.sh` | 把惰性檔案的**內容**換成垃圾再跑全部套件,用實驗證明「沒有東西讀它們」 | `tests.yml` 的 `inert-files-are-inert` job |
<!-- ⚠️ 本機跑它之前先把惰性檔案的修改 commit 掉:它會換掉內容再「還原」,而還原的來源是 git,
     所以**未 commit 的惰性檔修改會被消滅**。CI 的工作目錄永遠是乾淨的,只有本機會踩到。
     實際發生過:一次在 CLAUDE.md 加規則、還沒 commit 就跑了 tools 套件,那段字直接沒了。 -->
| `check-commit-parseable.{sh,js}` | 用 release-please 自己那支嚴格解析器判斷 commit 會不會被靜默丟掉(issue #141) | `tests.yml` 的 `commit-messages-parseable` job |
| `verify-core-identical.{ps1,sh}` | 跨 plugin 逐位元組一致性 + marketplace 可安裝性 | `verify-core-identical` job；本機手動 |
| `lint-ps-compat.{ps1,sh}` | PS 5.1 相容性 lint | 各 plugin orchestrator 的 pre-flight |
| `verify-approved-verbs.ps1` | PowerShell approved verb 檢查 | 本機手動 |

## 測試慣例

`tools/tests/` **沿用 plugin 的 `tests/` 佈局**，只有一套慣例要記：

```
tools/tests/
├── invoke-script-tests.sh   # orchestrator（0/1 exit contract，同 plugin 版）
├── lib/shunit2              # vendored,與 plugins/*/tests/lib/shunit2 同一份
└── unit/*.test.sh           # 測試檔,orchestrator 自動探索
```

本機執行：

```bash
bash tools/tests/invoke-script-tests.sh
```

CI 由 `tests.yml` 的 **`tools-tests`** job 跑，而該 job **在 `tests-passed` 的 `needs` 裡**。
新增測試檔不必改 workflow——orchestrator 自己找 `unit/*.test.sh`。

`tools/tests/lib/shunit2` 與五個 plugin 的 vendored 副本**逐位元組一致**，由
`verify-core-identical.{ps1,sh}` 守著（六份都釘在裡面）。要換 shUnit2 版本就六份一起換，
不然 CI 會紅。

### 幾條刻意的決定

- **沒有 `.ps1` 孿生也沒有 Pester 半邊。** 「每支 script 都要 `.ps1` + `.sh` 兩版」是**plugin 腳本**
  的規範（使用者會在兩個平台上跑）。`tools/` 的消費者是 CI 與本機開發者，各腳本用最合適的單一語言即可
  ——`verify-approved-verbs.ps1` 本來就沒有 `.sh`，`affected-plugins.sh` 也只有 GitHub Actions 的
  `shell: bash` 在呼叫。多一份沒人呼叫的拷貝＝多一個會漂移的地方，那正是這些測試要防的事。
  日後真的有 `.ps1` 需要 Pester，再補 `Invoke-ScriptTests.ps1` 與對應的 CI job。
- **`check-commit-parseable` 拆成 `.sh` + `.js`,不要把 `.js` 那半改寫成 bash。** 它的工作是問
  **release-please 自己那支解析器**（`@conventional-commits/parser`,嚴格 PEG 文法）答不答得出來,
  而那是一個 npm 套件、只有 node 叫得動。用 bash 重寫等於改成「猜同一個文法」的近似規則——而近似規則
  漏掉的構造會**靜默通過**,正是這支腳本存在要防的失效。`.sh` 那半只做選件與回報,判準完全外包。
- **orchestrator 探索到零個測試檔會 FAIL，不是 exit 0。** plugin 版允許「沒有測試檔就過」（有純
  skill plugin）；`tools/` 現在有測試，探索不到只代表被改名或刪掉了，那正是「安靜地變綠」。
- **邏輯是被呼叫、不是被複製。** `affected-plugins.sh` 從 `tests.yml` 的 `run:` 區塊裡抽出來，
  workflow 改成呼叫它。如果留兩份拷貝，測試會對著沒人跑的那份一直全綠。
- **stdout 是結果，診斷走 stderr。** 呼叫端把 stdout 直接寫進 `GITHUB_OUTPUT`，多一行就把 step
  output 弄壞了。所以 `affected-plugins.sh` 退回 `ALL` 時會在 **stderr** 說明是哪個路徑造成的——
  想知道「為什麼這次全部都跑了」，去 CI log 的 `Compute affected plugins` 那個 step 找那一行。
  反過來，答案是真子集時完全不出聲：每次都印會訓練人忽略它。

### `NONE` 與惰性清單

`affected-plugins.sh` 的答案有三種:`ALL`、`NONE`、真子集。`NONE` 意思是「這次變更**全部**落在惰性
清單上,沒有任何 plugin 套件會被影響」——目前的惰性清單是 repo 根的 `CLAUDE.md` / `README.md` /
`LICENSE`、`.release-please-manifest.json`,以及各 plugin 由 release-please 維護的 `CHANGELOG.md`
與 `.claude-plugin/plugin.json`。這是為了 Release PR:它的 diff 恰好就是那三種形狀、一行程式碼都
沒有,卻曾經連續三次各付掉 26 / 27 / 26 分鐘。

三件事讓這個「唯一會縮到零」的答案不至於變成安靜的綠燈:

1. **`NONE` 是一個字,不是空輸出。** 空輸出對呼叫端來說已經是「腳本沒跑起來」,而那必須 fail-open
   成 `ALL`。兩者若共用同一種表示法,「壞掉」跟「真的沒影響」就分不出來,而其中一邊的安全解讀正好是
   另一邊的錯誤解讀。
2. **要有正面證據。** 至少要有一個路徑被看到**且**被判為惰性;沒有路徑、或路徑一個都歸不了屬,仍然
   是 `ALL`。而任何一個會擴大的路徑都直接壓過惰性路徑(擴大是立即 exit)。
3. **`verify-core-identical` 與 `tools-tests` 沒有 `needs: discover`**,不管答案是什麼都會跑。所以
   `NONE` 從來不等於「這顆 commit 沒被測」。

惰性清單成立的前提是一句關於**這個 repo** 的斷言:沒有任何東西會去讀那些檔案的**內容**。腳本自己
驗證不了這件事,所以有**兩道**守門,角色不同,兩道都要留:

| | 是什麼 | 成本 | 弱點 |
| --- | --- | --- | --- |
| `test_no_test_reads_an_inert_file`(在 `affected-plugins.test.sh`) | grep 測試**原始碼**,找「同一行既提到惰性檔名、又像是離開自己目錄」 | 本機七秒 | 在**猜人怎麼寫**。算路徑與開檔分兩行就抓不到;掃描範圍也只有 `plugins/*/tests/` 與 `tools/tests/` |
| `inert-files-are-inert` job(跑 `verify-inert-files.sh`) | 不讀程式碼:把那些檔案的**內容**換成垃圾,跑全部套件,看有沒有東西出聲 | CI 約數分鐘 | 只跑 ubuntu。在那裡自我 SKIP 的案例(缺 .NET / IIS)根本沒執行,就沒機會讀到 |

前者是快速訊號,後者才是**證據**——它不問任何人宣告了什麼,直接看有沒有差,所以不管那個讀取是用什麼
語言、什麼寫法。**加惰性項目之前先確認這兩道都還在。**

`verify-inert-files.sh` 有兩個刻意的設計,改它的時候不要拆掉:

- **惰性清單是推導的,不是寫死的。** 它把每個追蹤檔逐一丟進 `affected-plugins.sh`,答 `NONE` 的就是
  惰性檔。抄第二份清單的話,漂開的方向是無聲的:有人新增惰性項目、實驗卻沒涵蓋到它,而那看起來就
  像通過。
- **套件清單是 glob 出來的**(`plugins/*/tests/invoke-script-tests.sh`),理由和 `tests.yml` 的矩陣
  一樣:加一個 plugin 不必改任何設定,也就不會有 plugin 悄悄掉出這個實驗。

它在跑之前會**拒絕**動一個有未提交修改的惰性檔案——還原用的是 `git checkout --`,那會直接丟掉你本機
的編輯。

### 還沒被測到的

`verify-core-identical.sh`、`lint-ps-compat.ps1`、`verify-approved-verbs.ps1` 目前都沒有測試。
慣例已經在這裡了，補的時候直接往 `tools/tests/unit/` 加檔案即可。
