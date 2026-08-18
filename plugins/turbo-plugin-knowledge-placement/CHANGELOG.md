# Changelog

本檔記錄 turbo-plugin-knowledge-placement 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-08-18

### Added

- 初版:「這件事該寫在哪」的判準與交接機制,獨立可安裝 plugin。純 skill,無 script、不碰 `.turbo-plugin/` 狀態。
- `tp-knowledge-placement-setup`:把四格判準注入專案 `CLAUDE.md` 的 `turbo-plugin:begin knowledge-placement` 標記區塊(只取代標記之間,標記外的內容逐字保留)。
- `tp-export-handover`:把 agent 記憶裡「接手的人需要知道」那一格匯出成一份可讀的檔案。**先問使用者**要「存成一個檔案」還是「放進 `docs/` 並提交」,而且**消毒只發生在進版控那條路徑**——那些內容當初就是因為不進版控才放記憶的,對一份私下交給接手者的檔案消毒只會洗掉真正有用的資訊。
- 判準把待辦從「專案根 `TODO.md`」改落到 **agent 記憶**(`type: project`)。理由:「不進版控、但屬於交接內容」這個格子沒有任何工具支援——git 不管它、隔離工作副本只帶進去不搬回、兩個副本各加一條沒有東西能合併;想補機制就是在重造 merge。
- 明文寫下**被 git 忽略的檔案的三個不變式**(不是用來編輯的 / 可以重新產生 / 可以接受手動編輯),同時作為 `turbo-plugin-multi-repo-workspace` 實作 `.worktreeinclude` 時「什麼該放進去」的判準。
- 資產一致性測試(shUnit2 + Pester 兩套):標記恰好一組且順序正確、不佔用別的 plugin 的標記名、每支 skill 的 frontmatter 完整且 `name` 與目錄相符、`description` 必須是英文(description 會被前載,body 不會)。
- **刻意不被任何 plugin 相依**:用了 git↔SVN 橋接或多專案工作區,不代表就得接受這套文件方法。`turbo-plugin-code-comment` 同樣維持獨立,只交叉引用。
