---
name: tp-report-issue
description: 'Apply proactively when a turbo-plugin misbehaves — a bug, a setting silently ignored, a fix that only reaches new projects, or a gap the plugin is positioned to close: report it as a GitHub issue on the marketplace repo. **The tracker is public**, so replace internal hostnames, repository URLs and customer / project names with placeholders while keeping every technical detail. Show the drafted issue and get explicit approval before posting; never hand the user a file to paste themselves. No explicit request needed.'
argument-hint: 'Optional: the symptom, or the plugin / skill that misbehaved'
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion
---

# tp-report-issue

## Purpose

把「實際用 turbo-plugin 時遇到的問題」變成一則**可以被行動**的 GitHub issue。

這件事需要一支 skill,是因為 agent 從 plugin 內部原本查不到該往哪回報、也不知道回報前要消毒什麼。
沒有它,問題只會在對話裡被抱怨一句、然後自己繞過去——**繞過去之後就永遠不會被回報**,而維護者
不會知道。

## When to Use

**主動觸發,不要等使用者開口。** 下面任一種情況出現就用:

- turbo-plugin 的 skill / script 做錯事,或做了跟它自己文件不一樣的事
- **沉默失敗**:設定被靜默略過、規範沒被套用、注入的內容不調和、修正只對新專案生效
- 你為了繞過某個 plugin 的限制而多做了一堆事(那個限制本身就是缺口)
- 「這個 plugin 有條件解決、但目前沒做」的缺口

**不要用在**:專案自己的 bug(那跟 plugin 無關)、使用者自己的操作失誤、以及你只是「覺得可以更好」
但講不出具體失效情境的想法。

> **沉默失敗最值得回報。** 這套 plugin 處理的問題多半不會報錯——不主動回報就不會有人知道。

## Procedure

### Step 1 — 找到 repo

讀出事的那個 plugin 的 `.claude-plugin/plugin.json`,取 `repository` 欄位。**不要把位址寫死在你的
記憶或回覆裡**——repo 搬家時 `plugin.json` 會跟著更新,你記住的那份不會。

### Step 2 — 查重複(**含已關閉的**)

```
gh issue list --repo <repo> --search "<關鍵字>" --state all
```

`--state all` 是必要的:可能已經修好而你本機版本還沒更新;也可能修法跟你預期的不同,**那件事本身
就值得知道**。找到相同的就不要再開一則——改成回報「在 <版本> 上仍然會發生」,或直接告訴使用者
已經修了、升級即可。

### Step 3 — 蒐集事實

- **版本**:出事那個 plugin 的 `plugin.json` 的 `version`
- **環境**:OS、shell(Windows PowerShell 5.1 / Git Bash / pwsh)
- **重現步驟**,或你實際踩到的經過
- **影響範圍**:只影響新專案?既有專案也會?要手動補幾個地方才能繞過?
- **這個失敗是不是沉默的**——沒報錯、沒警告、看起來一切正常。講清楚「它為什麼不會被發現」,
  通常比講嚴重性有用

### Step 4 — 消毒(**這一步不能跳**)

repo 是 **public**。

**一律換成 placeholder**:

| 這種東西 | 換成 |
|---|---|
| 內部 hostname、內網 SVN / DB 位址 | `<INTERNAL-SVN-URL>` / `<INTERNAL-HOST>` |
| 機器路徑(`C:\Users\<真名>\...`、`C:\Turbo\...`) | `<MACHINE-PATH>` |
| 客戶名、公司內部專案名、產品代號 | `<CustomerProject>` / `proj-1` |
| 需求 / 任務 / 計畫代號、單一 session 的項目編號 | 直接拿掉 |
| 真實姓名、email | 拿掉,或換成 `<author>` |

**憑證絕對不出現**——連「長得像被遮蔽過的」也不要貼。

**但技術細節要照實保留**:版本號、行號、程式碼片段、錯誤訊息與錯誤碼、實際跑的指令、重現步驟。
**消毒過頭會讓 issue 變成無法行動的抱怨**——那比不回報好不了多少。分辨方式很簡單:
**拿掉之後維護者還修得動嗎?**修不動就是消過頭了。

> 檔名與路徑常常同時含兩種資訊。`C:\Turbo\<客戶名>\src\Foo\Bar.cs:42` → `<MACHINE-PATH>/src/Foo/Bar.cs:42`
> ——**行號與相對路徑要留著**,那是維護者真正要用的部分。

### Step 5 — 寫

**標題**:一句話講清楚「什麼東西在什麼情況下會怎樣」,不要只寫「X 壞了」。

**內容**至少涵蓋:現象 / 這個失敗是不是沉默的 / 重現或經過 / 影響範圍 / 環境與版本。
如果是**建議**而不是 bug,再加:提案 + **你認為還沒想清楚的設計問題**——只丟一句「希望支援 X」
的建議,維護者沒辦法從那裡開始。

有把握的話可以附上你認為的根因或修法,但**要標明那是推測**。

### Step 6 — 確認後才送出

用 `AskUserQuestion` 把**消毒後的完整標題與內容**給使用者看,問「要送出這則 issue 嗎」。
選項:送出 / 修改後送出 / 不要送。

同意後用 `gh issue create --repo <repo> --title ... --body-file <暫存檔>` 送出,並把回傳的 issue 網址
告訴使用者。

## Decision Rules

- **不要寫一份報告檔請使用者自己去貼。** 那是把工作推回去給他,而且多數時候就沒有下文了。
  由你送出;使用者只負責點頭。
- **要確認再送出,但確認的是內容、不是「要不要回報」。** 回報這件事你主動判斷;送出這個
  對外動作要先過使用者——public repo 一旦貼出去就散出去了,事後刪掉也不保證沒被索引。
- **一則 issue 講一件事。** 同時遇到三個問題就開三則。混在一起的那則會有一半永遠不會被處理。
- **不確定是不是 plugin 的問題**:先講給使用者聽、問他,不要猜著開。
- **消毒有疑慮就問。** 「這個字串是不是內部資訊」你判斷不了時,直接問使用者,不要賭。

## Completion Checks

- issue 已建立,而且你把網址告訴使用者了。
- 送出的內容裡**沒有**:內部 hostname / 內網位址、機器絕對路徑、客戶或公司專案名、真實姓名、
  任何憑證。
- 送出的內容裡**有**:plugin 名稱與版本、環境、重現或經過、影響範圍。
- 送出前查過重複(含 closed)。
- 使用者明確同意過。
