---
name: tp-svn-log
description: '在指定 remote-<branch> worktree 跑 svn log,顯示 SVN history。使用者明確要求查 SVN history 時執行;agent 在需要對齊 SVN revision / 確認新 SVN commit 時也可建議執行(read-only,可安全 auto-trigger)。'
argument-hint: '[--branch <main|test-<n>>] [--limit <n>] [-r/--revision <spec>] [--verbose]'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-svn-log

## Purpose

對指定 `remote-<branch>` worktree 跑 `svn log --xml`,腳本自己解析 XML 再格式化為純文字輸出。`--xml` 確保 svn 永遠以 UTF-8 emit 輸出(不看 console codepage),避免中文 commit message 在 zh-TW Windows 變 `?` 亂碼。

## Procedure

1. 跑 script,參數依平台:

   ```powershell
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.ps1" [-Branch <main|test-<n>>] [-Limit <n>] [-Revision <spec>] [-VerboseOutput]
   ```
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/svn-log.sh" [--branch <main|test-<n>>] [--limit <n>] [--revision <spec>] [--verbose]
   ```

   可選參數(logical 名稱與行為):
   - branch(default `main`)
   - limit(default **5**,正整數)
   - revision(svn 修訂號規格,直接透傳給 svn,可用格式如 `5` / `r5` / `3:10` / `HEAD` / `BASE` / `{2026-01-01}:{2026-05-26}` 等)
   - verbose(顯示變更檔案清單)

2. **必須**把 script stdout 完整 echo 到對話訊息中,用 markdown code block 包起來,讓使用者直接讀到 log 內容:

   ```
   r5 | bryant | 2026-05-26T12:34:56.000Z | 修正中文檔名
   r4 | alice  | 2026-05-25T...           | another commit
   ...
   # LAST_SHOWN_REV=1
   ```

   **不要** 只依賴 tool result UI(可能被折疊或截斷);使用者必須能直接從對話訊息讀到 log。`# LAST_SHOWN_REV=<n>` trailer 行也一起 echo,讓使用者也看到分頁狀態 — U11 pagination loop 也讀此 trailer 行決定下一頁起點。

3. **Emit 下一步選項(分頁互動)**

   執行 script 並 echo log 到對話訊息之後,在**同一則訊息結尾**附加固定 template 的選項清單(plain text,**不**用 AskUserQuestion — modal UI 對輕量分頁互動太重):

   ```
   ──
   接下來想看什麼?
   1. 下 5 筆(更舊的 5 個 commit)
   2. 指定修訂(直接打 r5、3:10、{2026-01-01}:{2026-05-26} 等)
   3. 其他(換話題)

   回 1 / 2 / 3 或直接打你要的修訂號即可。
   ```

   Emit 完選項清單後**結束本輪 SKILL turn**,等待使用者下一輪訊息。**不要** 在同一輪繼續呼叫 script 或追問 — 分頁狀態完全靠下一輪訊息驅動。

4. **解析使用者下一輪訊息(分頁迴圈)**

   下一輪使用者訊息進來時,依下列優先序判斷意圖並動作。**只有「下 5 筆」與「指定修訂」兩條路徑會再次呼叫 script + 回到 step 2 重新 echo + emit 選項清單**;其餘路徑都退出分頁迴圈。

   1. **下 5 筆**(訊息 trim 後正規化匹配下列任一):「1」/「next」/「下5筆」/「下一頁」
      - 從**前一次 script stdout 的 `# LAST_SHOWN_REV=<n>` trailer** 讀最舊的 revision `n`(主要路徑;script 端 U10 已 emit trailer)。
      - 若 trailer 不可得(例如 conversation compaction 讓 stdout 不在 context 內),fallback 解析已 emit 給使用者的 chat 內容中所有 `r<n>` headers 取最小值。
      - 計算下一頁 revision spec:
        - 若 `n > 1`:spec 為 `<n-1>:1`,呼叫 svn-log `--revision <n-1>:1 --limit 5`(svn 預設由新到舊列出,所以 5 筆會是 `r(n-1)` 到 `r(max(1, n-5))`)。
        - 若 `n <= 1`:已到歷史最舊,**不**呼叫 script;直接 emit「已到歷史最舊(r1 是最早的 commit)」訊息 + 重新 emit step 3 的選項清單,讓使用者跳 revision 或退出。
      - 若 trailer 與 chat history 都拿不到 `LAST_SHOWN_REV`:emit「找不到分頁起點,請手動指定修訂號(例如 r5、3:10)」+ 重新 emit 選項清單。
      - 呼叫 script 完後回到 step 2 重新 echo log + 回到 step 3 emit 選項。

   2. **指定修訂**(訊息符合下列任一 pattern):
      - `^r?\d+$`(單一 revision,如 `5` / `r5`)
      - `^r?\d+:r?\d+$`(範圍,如 `3:10` / `r3:r10`)
      - `^\{[\d-]+\}:\{[\d-]+\}$`(日期範圍,如 `{2026-01-01}:{2026-05-26}`)
      - `^HEAD$` / `^BASE$`
      - 以「2 」前綴帶上述任一 spec(如 `2 r5` / `2 3:10` — 對應選項清單的「2.」)
      - 動作:若有「2 」前綴先剝掉,取 spec 值;呼叫 svn-log `--revision <spec>`(透傳給 svn,**separate arg invariant** per F10 與 U10 一致 — Bash tool call svn-log script 時 spec 必須當**獨立 argument** 傳,不字串拼接)。
      - 呼叫完回到 step 2 重新 echo log + 回到 step 3 emit 選項。

   3. **退出**(訊息明顯不屬於分頁互動):
      - 訊息為「3」/「其他」/「取消」/「不要」/「換話題」/「離開」之一,**或**
      - 訊息完全不相關(例如「幫我看 build.ps1」、「commit 一下」、「跑 build」等與 SVN log 無關的話題)。
      - **不**再呼叫 script,**不**再 emit 選項清單,**不**追問。
      - 讓對話自然進行下一個話題 — agent 退出分頁迴圈,依使用者新訊息一般處理。

## Decision Rules

- 必須在 main worktree 跑;script 內部自動定位 main + 對應 remote worktree。
- `--limit` 必須是正整數,非法值 → script 拋錯。
- `--revision` 的值不經 script validate,直接透傳給 svn — 由 svn 自己決定接受與否。**禁止** 在組指令時把多個 args 拼成單一字串(security invariant per F10);PS / bash script 內部都以 array splatting 傳值。
- read-only 操作,**不會修改任何檔案 / branch / SVN state**,可安全在 agent 想對齊版本時自動執行。
- 分頁迴圈狀態 **不**寫檔、**不**靠 global var、**不**靠 AskUserQuestion modal — 完全從 script stdout 的 `# LAST_SHOWN_REV=<n>` trailer(主要路徑)與 chat history 的 `r<n>` headers(fallback)推算。
- 一旦使用者退出分頁(回「3」/「其他」/「不要」/「換話題」/ 無關話題),SKILL **不**重啟分頁迴圈,除非使用者**再次明確**呼叫 `/tp-svn-log` 或請求 SVN log。
- 「2 」前綴是 optional disambiguation — 使用者也可以直接打 spec(`r5` / `3:10` / `{2026-01-01}:{2026-05-26}`)不加前綴,只要符合 revision pattern 就視為「指定修訂」。
- 解析下一輪訊息時 **revision spec pattern 優先於 escape 文字** — 若使用者回「2」(剛好對應選項清單的「2.」但沒附 spec),視為**模糊**,降階為退出(由使用者下一輪再明確指定);**不**追問。

## Completion Checks

- 輸出符合 `r<rev> | <author> | <date> | <msg>` 格式(每筆一行;`--verbose` 多印變更檔案清單)。
- 中文 commit message 顯示為正確 UTF-8,**不變 `?`**。
- 至少有一筆 entry 時 stdout 末尾出現 `# LAST_SHOWN_REV=<最小 revision>` trailer。
- script stdout 已被完整 echo 到對話訊息(markdown code block)。
- echo log 之後在**同一則訊息結尾**附加 step 3 的三選一選項清單(plain text,**不**用 AskUserQuestion)。
- 結束本輪 turn 等使用者下一輪訊息;**不**在本輪追問或自動續呼叫 script。

## Test Scenarios

- **Default limit**: 不傳 limit → 顯示**最近 5 筆**(不是 50)的 SVN log。
- **Custom limit**: PowerShell `-Limit 3` / bash `--limit 3` → 顯示最近 3 筆 SVN revision。
- **Revision single**: `--revision r5` → 只顯示 r5 一筆。
- **Revision range**: `--revision 3:7` → 顯示 r3 到 r7。
- **Revision + Limit**: `--revision 1:100 --limit 3` → svn 在範圍內取前 3 筆。
- **Revision date range**: `--revision {2026-01-01}:{2026-05-26}` → svn 接受日期範圍格式。
- **Invalid limit**: PowerShell `-Limit 'abc'` → PS param binding 直接拒;`-Limit -5` 或 bash `--limit -5` → script 拋 `Limit must be a positive integer`。
- **Encoding (zh-TW)**: SVN repo 有 commit message「修正中文檔名」→ 顯示為正確 UTF-8 中文,**不變 `?`**(此為 XML 解析的主要驗證)。
- **Multi-line commit message**: SVN 有一筆 commit message 含換行 → PS [xml] / bash xmllint 路徑正確 preserve 換行;bash grep+awk fallback 對多行 msg 可能截斷至第一行(已知 limitation,建議裝 xmllint)。
- **Trailer emission**: 顯示完所有 entry 後 stdout 末尾出現 `# LAST_SHOWN_REV=<最小 revision>` 行。
- **Empty result**: `--revision 999999` 等指向不存在的 revision → stdout 空(無 trailer)、exit 0。
- **bash xmllint fallback**: Git Bash 未裝 xmllint → 走 grep+awk fallback,輸出格式與 xmllint 路徑相同。

### 分頁迴圈(AE8 / AE9 / AE10)

- **AE8 pagination forward**: SVN repo 有 r1-r20,跑 `/tp-svn-log`(顯示 r20-r16) → echo log + trailer `# LAST_SHOWN_REV=16` + emit 選項清單 → 使用者回「1」 → SKILL 從 trailer 讀 16,呼叫 svn-log `--revision 15:1 --limit 5` → 顯示 r15-r11 + trailer `# LAST_SHOWN_REV=11` + emit 選項;再回「1」 → `--revision 10:1 --limit 5` → 顯示 r10-r6。
- **AE9 jump to revision (with r prefix)**: 使用者回「r5」 → SKILL 呼叫 `--revision r5` → 顯示單筆 r5 + emit 選項。
- **AE9 jump to revision (numeric without prefix)**: 使用者回「5」 → 因匹配 `^r?\d+$` → 呼叫 `--revision 5` → 顯示單筆 r5。
- **AE9 range**: 使用者回「3:10」 → 呼叫 `--revision 3:10` → 顯示 r3-r10 + emit 選項。
- **AE9 with "2 " prefix**: 使用者回「2 r5」 → SKILL 剝掉「2 」前綴 → 呼叫 `--revision r5` → 顯示單筆 r5 + emit 選項。
- **AE9 date range**: 使用者回「{2026-01-01}:{2026-05-26}」 → 呼叫 `--revision {2026-01-01}:{2026-05-26}` → 顯示該日期區間內的 commits + emit 選項。
- **AE10 escape via「其他」**: 使用者回「其他」 → SKILL 退出分頁迴圈,**不**再 emit 選項清單。
- **AE10 escape via「3」**: 使用者回「3」 → 視為「其他」,退出。
- **AE10 escape via unrelated**: 使用者回「換個話題,幫我看 build.ps1」 → SKILL 退出,讓 agent 一般對話接手處理 build.ps1。
- **AE10 escape via「不要 / 取消」**: 使用者回「不要」或「取消」 → 退出。
- **Trailer missing fallback**: 前一輪 script 因某種原因未 emit trailer(例如 empty result 或 conversation compaction 後 stdout 不在 context)→ SKILL 從 chat history 中前一輪 echo 出的 `r<n>` headers 找最小值;若 chat history 也找不到,emit「找不到分頁起點,請手動指定修訂號(例如 r5、3:10)」+ 重新 emit 選項清單。
- **Reach SVN history boundary**: 顯示到 r5-r1 後使用者回「1」想看更舊 → SKILL 偵測 `LAST_SHOWN_REV=1`(n <= 1)→ **不**呼叫 script,直接 emit「已到歷史最舊(r1 是最早的 commit)」+ 重新 emit 選項清單(讓使用者跳 revision 或退出)。
- **Ambiguous「2」alone**: 使用者只回「2」沒帶 spec → 視為模糊,降階為退出;不追問(讓使用者下一輪自己明確指定 spec 或重新呼叫)。
