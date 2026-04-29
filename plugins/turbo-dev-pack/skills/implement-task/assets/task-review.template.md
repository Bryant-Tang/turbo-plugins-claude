# Task N Category Review

> 將標題中的 `Task N`、檔名與本文所有的 `task-n` 都替換成實際任務編號。檔名依 Review Report Location Rule 決定，例如 `task-1-review-correctness+security+integration-compatibility.md`（N=3 reviewer 1）或 `task-1-review-1-of-3.md`（fallback）或 `task-3-build-review.md`（建置任務）。

> 本文件只記錄單一 review subAgent 負責的指派分類（一或多個）的結果；父 agent 只讀取各份 review 報告，不負責彙整改寫。

## 範圍

- 任務：<plan.md 中的任務名稱>
- 分類：<逗號分隔的指派分類 slug 清單，例如 correctness, security, integration-compatibility；建置任務固定為 build>
- 檢查依據：<相對路徑到 plan.md>、<相對路徑到 goal.md>、本批 AC
- 檢查檔案：
  - <檔案 1>
  - <檔案 2>
- 不執行最後總驗證。
- 不修改 `test-plan.md` 與其他 `test-n.md`，並將 `n` 視為實際驗證任務編號。

## 檢查方法

1. <如何依照目前這一個分類的 AC 進行檢查，或如何對 build 分類執行建置 review>
2. <如何確認範圍沒有漏掉>
3. <如何判定 COMPLETE / INCOMPLETE / BLOCKED>

## Findings

- <這個分類的觀察結果>
- <是否符合 AC>

## 建置結果

- <若本報告是 build review，記錄建置命令、成功或失敗摘要、主要錯誤；否則寫 N/A>

## AC 檢查結果

| 分類 | AC | 結果 | 說明 |
| - | - | - | - |
| <該 AC 所屬分類 slug> | <AC 1> | PASS / FAIL | <說明> |
| <該 AC 所屬分類 slug> | <AC 2> | PASS / FAIL | <說明> |

## Blocking Findings

- 無。

## 是否需要下一個實作 subAgent

- 不需要 / 需要。
- 若需要，列出下一輪要修正的具體項目。

## 結論

COMPLETE / INCOMPLETE / BLOCKED

<用一小段文字總結本輪 review 的結論與原因。>