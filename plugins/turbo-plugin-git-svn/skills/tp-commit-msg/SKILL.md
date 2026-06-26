---
name: tp-commit-msg
description: '撰寫或檢查 git commit message 時主動使用:依本專案語意規範產出 / 檢查訊息(祈使句、what + why、語言一致;不得引用 git SHA 或僅本地識別碼)。**本 skill 不驗證、不限制 commit type**(type 沿用該 repo 既有慣例即可)。準備 commit 一段改動時就套用,不需使用者另外明講「幫我寫 commit message」。'
argument-hint: 'Optional: draft commit message or the change to summarize'
user-invocable: true
allowed-tools: Read, Bash, Grep, Glob
---

# tp-commit-msg

## When to Use

- 使用者要求「寫 commit message」「幫我寫提交訊息」或在 commit 前要求檢查訊息。
- agent 完成一段改動、準備 `git commit` 時,需要一條符合本專案語意規範的訊息。
- 既有 draft commit message 需要檢查 / 改寫成符合規範。

## Primary Goal

- 寫出讓**未來不在現場的讀者**(其他同事、半年後的自己)看得懂「改了什麼、為什麼改」的 commit message。
- 訊息本身要能獨立成立——不依賴當前對話、ticket、或暫時情境就能理解。
- 本 skill **只**負責訊息的**語意品質**;**不驗證、不限制、不列舉 commit type**——type 前綴沿用該 repo 既有 commit 慣例即可。

## Core Rules

### Type(不驗證、不限制)

- commit type 前綴(`feat` / `fix` / `refactor` / `docs` / ...)**沿用該 repo 既有 commit 慣例**即可;本 skill **不**強制固定 type 清單、**不**驗證 type、**不**讀任何 commitlint 設定檔。turbo-plugin-git-svn 整體不管 commit type。
- type 的「哪些會進 SVN history」是 `tp-push-to-svn` 的範圍(它同樣不依 type 過濾、全收非-merge subject),不在本 skill 範圍。

### 不得引用「換個環境就對不上」的識別碼

- **不得引用特定 git SHA / commit hash**:本專案遠端是 SVN,不同 clone 的 git SHA 不一致;訊息裡寫死某個 SHA 在別人的 clone 或 SVN 端沒有意義。要指涉相關變更時用「行為描述」而非 SHA(例如「沿用前一版的 trust 檢查」而非「見 commit a1b2c3d」)。
- **不得引用僅本地 / 單次情境才有意義的識別碼**:需求編號、計畫編號、任務代號(如 `U7` / `R12a` / `KD4`)、單一 session 的項目編號等,對 repo 的長期讀者沒有指涉對象,不要寫進 commit message。要說明動機就用白話描述那個動機本身。
  - (註:plan / brainstorm 等**文件**內部使用這些 ID 做追溯是另一回事;此規則只約束 **commit message**。)

### 一般語意規則

- **祈使句**:subject 用祈使語氣描述這個 commit「做了什麼」(例如「修正…」「新增…」「移除…」),而非過去式或進行式。
- **what + why**:subject 講「做了什麼」;若改動的**原因 / 動機**不顯而易見,在 body 補「為什麼」(尤其 bug 修正要講清楚原本錯在哪、為何這樣修)。
- **語言一致**:整條訊息(subject + body)語言一致;本專案文件以繁體中文為主,除非該 repo 既有 commit 慣例明顯使用英文。
- **subject 精簡聚焦**:一條 commit 一個主題;subject 不要塞多個不相關變更。若一次提交橫跨多個不相關主題,建議拆成多個 commit。
- **可讀性**:subject 後接 type 前綴格式(`<type>: <祈使描述>`);body 與 subject 間空一行;body 用條列或段落說明細節。

## Procedure

1. 釐清這個 commit 實際改了什麼(讀 diff / `git status` / `git diff --staged`,必要時)。
2. 選 type:依改動性質挑一個貼切的 conventional 前綴(程式行為變更→`feat`/`fix`、純文件→`docs`、重構→`refactor`、雜務→`chore` 等),沿用該 repo 既有慣例;本 skill 不驗證、不限制 type。
3. 寫 subject:`<type>: <祈使描述做了什麼>`,精簡且聚焦單一主題。
4. 視需要寫 body:改動原因不顯而易見、或 bug 修正時,補「為什麼 / 原本錯在哪」。
5. 自我檢查(見 Completion Checks):掃過訊息,移除任何 git SHA、本地識別碼、依賴當前對話情境的措辭。
6. 若是檢查既有 draft:指出違規處 + 提供改寫版本。

## Completion Checks

- commit type 沿用該 repo 既有 / conventional 慣例;本 skill 未驗證、未限制 type,也未讀任何 commitlint 設定。
- 訊息中**沒有**特定 git SHA / commit hash。
- 訊息中**沒有**需求 / 計畫 / 任務代號或單一 session 項目編號等僅本地識別碼。
- subject 為祈使句、聚焦單一主題;動機不顯而易見時 body 有交代「為什麼」。
- 整條訊息語言一致。
- 一位不在現場的讀者,只看這條訊息就能理解改了什麼、為什麼改。
