# `tools/` — repo 層級腳本

放**跨 plugin / repo 層級**的腳本。plugin 自己的腳本一律留在 `plugins/<name>/scripts/`，不要放這裡。

| 腳本 | 做什麼 | 誰在用 |
| --- | --- | --- |
| `affected-plugins.sh` | 依變更檔案清單判斷「哪些 plugin 的測試套件要跑」 | `.github/workflows/tests.yml` 的 `discover` job |
| `plugin-requires-tool.sh` | 讀 `plugins/<name>/tests/required-tools`,答「這個 plugin 需不需要某個外部工具」 | `tests.yml` 的 `Install Subversion` 步驟(兩個平台) |
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
- **orchestrator 探索到零個測試檔會 FAIL，不是 exit 0。** plugin 版允許「沒有測試檔就過」（有純
  skill plugin）；`tools/` 現在有測試，探索不到只代表被改名或刪掉了，那正是「安靜地變綠」。
- **邏輯是被呼叫、不是被複製。** `affected-plugins.sh` 從 `tests.yml` 的 `run:` 區塊裡抽出來，
  workflow 改成呼叫它。如果留兩份拷貝，測試會對著沒人跑的那份一直全綠。
- **stdout 是結果，診斷走 stderr。** 呼叫端把 stdout 直接寫進 `GITHUB_OUTPUT`，多一行就把 step
  output 弄壞了。所以 `affected-plugins.sh` 退回 `ALL` 時會在 **stderr** 說明是哪個路徑造成的——
  想知道「為什麼這次全部都跑了」，去 CI log 的 `Compute affected plugins` 那個 step 找那一行。
  反過來，答案是真子集時完全不出聲：每次都印會訓練人忽略它。

### 還沒被測到的

`verify-core-identical.sh`、`lint-ps-compat.ps1`、`verify-approved-verbs.ps1` 目前都沒有測試。
慣例已經在這裡了，補的時候直接往 `tools/tests/unit/` 加檔案即可。
