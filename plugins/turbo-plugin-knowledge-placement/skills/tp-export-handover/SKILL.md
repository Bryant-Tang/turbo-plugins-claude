---
name: tp-export-handover
description: 'Export the current-only project knowledge held in agent memory (open work, environment state, decisions not derivable from the code) into one readable handover document, so it survives a change of person or machine. Ask the user whether it should be a loose file or committed into docs/, and sanitise machine paths, internal hostnames and one-off identifiers only for the committed form. Run on request, or SUGGEST it when handover, offboarding or "someone else takes over" comes up; **never write or commit without explicit approval**.'
argument-hint: 'optional: --output <path>'
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# tp-export-handover

## Purpose

agent 記憶**不會跟著 repo 走**。換人、換機器,那些「只有現在成立、但接手的人需要知道」的事就消失了,
而且消失得毫無聲息——接手的人不會知道自己少了什麼。

這支 skill 把那一格倒出來,變成一份**人讀得懂的檔案**。

> 這條路徑必須真的被走過才算數。記憶從來沒有匯出過的專案,「接手的人需要知道」那一格就是空的。

## Tool Preference

涉及檔案 read / write / search / edit 的工作,優先使用 Read / Write / Edit / Glob / Grep,避開
Bash / PowerShell / Python / Node.js 做檔案操作。委派 subagent 時一併傳遞這條規則。

## Procedure

1. **找到記憶目錄**。就是你自己的持久記憶目錄(system prompt 裡有寫路徑),以及它底下的 `MEMORY.md`
   索引。**不要用猜的去組那個路徑**;找不到就直接說找不到,不要匯出一份空的。

2. **挑出要匯出的**。讀 `MEMORY.md` 索引,再讀它指到的檔案,依 frontmatter 的 `metadata.type` 分:

   | type | 匯不匯出 | 為什麼 |
   |---|---|---|
   | `project` | **要** | 這就是「接手的人需要知道」那一格 |
   | `reference` | **要** | 外部資源指標(儀表板、票務、文件連結)換人一樣要用 |
   | `feedback` / `user` | **不要** | 那是 agent 自己的工作方式與使用者偏好,不是專案交接內容 |

   同時**限定在這個專案**:記憶目錄是按專案路徑分的,但裡面仍可能有跨專案的條目。與當前 repo 無關的
   不要放進去。

3. **逐條查證再寫**。記憶反映的是**寫下當時**成立的事。條目若提到某個檔案、函式、旗標、分支或 issue
   編號,**先確認它現在還在**。已經不成立的:標成「已完成 / 已失效」並寫明,或整條拿掉——
   **不要原封不動抄過去**。一份把人帶錯路的交接文件比沒有交接文件更糟。

4. **問使用者要哪一種**(用 `AskUserQuestion`,**在寫任何檔案之前**):

   - **存成一個檔案** — 不進版控,內容照實保留(含機器路徑、內網位址等)。
   - **放進專案文件並提交** — 會進版控,所以會先把機器路徑、內網 hostname / URL、以及只在單次情境
     成立的代號換成佔位符。

   選項文字用白話寫,**不要出現 `type: project`、frontmatter、記憶檔名這類內部術語**——使用者要決定
   的是「這份東西給誰、會不會進版控」,不是你的儲存格式。

5. **依選擇產出**:

   - **檔案**:寫到 `--output` 指定的路徑,沒指定就問要放哪。**不要**自動 `git add`。
     產出後**告訴使用者哪幾段含有不能進版控的內容**,萬一日後想提交才知道要先改。
   - **提交**:先消毒(見下),寫進 `docs/`(檔名如 `docs/handover.md`),秀出完整內容請使用者確認,
     **得到明確同意後**才 commit。commit message 用 `docs:` 前綴。

## Decision Rules

- **消毒只在「進版控」那條路徑做**。這些內容當初就是**因為不進版控**才放記憶的;對一份交給接手者的
  私下檔案做消毒,只會把「fixture 在哪台機器的哪個路徑」這種真正有用的資訊洗掉。判準是**這份東西會不會
  被推出去**,不是「它從記憶來的」。
- **不要預設提交**。使用者可能根本不希望這些內容進版控。永遠問,不要替他決定。
- **一份檔案,不是一堆檔案**。接手的人要的是能一次讀完的東西,不是記憶目錄的鏡像。
- **不要把記憶刪掉**。匯出是複製,不是搬移;匯出後那些事在這台機器上仍然成立。
- **空的就說空的**。沒有 `project` 類記憶時,產出一份「目前沒有待交接事項」而不是硬湊,並提醒使用者
  這通常代表**進行中的事一直沒有被記下來**,而不是真的沒事。

## 消毒規則(只用於進版控的那份)

一律替換成固定佔位符,並保留技術細節:

| 原內容 | 換成 |
|---|---|
| 機器絕對路徑(`C:\Users\...`、`C:\Turbo\...`) | `<MACHINE-PATH>` |
| 內網 hostname / URL(SVN、DB、內部服務) | `<INTERNAL-SVN-URL>` / `<INTERNAL-HOST>` |
| 需求 / 計畫 / 任務代號,單一 session 的項目編號 | `<TICKET-ID>` / 直接拿掉 |
| 真實姓名、帳號、客戶名 | `<PERSON>` / `<CUSTOMER>` |
| 憑證、token、連線字串 | **整段拿掉**,不要留佔位符 |

**替換之後要重讀一次**:佔位符化之後句子可能變得沒有意義(「把它放在 `<MACHINE-PATH>` 底下」),
那種句子要改寫成仍然可執行的說法,而不是留一個讀不懂的洞。

## Completion Checks

- 產出**恰好一個**檔案,而且使用者事先同意過它的形式與位置。
- 每一條都經過第 3 步的查證;已失效的有標註或已移除。
- 走「提交」那條路徑時:全文沒有機器路徑、內網位址、真實姓名或憑證;而且是在使用者看過內容並明確
  同意之後才 commit。
- 走「檔案」那條路徑時:**沒有** `git add`,而且已經告訴使用者哪些內容不適合進版控。
- 記憶本身沒有被修改或刪除。
