# Changelog

本檔記錄 turbo-plugin-feedback 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-08-14

### Added

- 初版:把 turbo-plugin 的問題回報成 GitHub issue 的 skill,獨立可安裝 plugin。
- `tp-report-issue`:主動觸發式 skill——遇到 bug、沉默失敗、或「plugin 有條件解決但目前沒做」的缺口時自動採用,不必等使用者開口。程序為「找 repo(讀 `plugin.json` 的 `repository`,不寫死位址)→ 查重複(含 closed)→ 蒐集事實 → 消毒 → 寫 → 確認後送出」。
- **消毒規則**:marketplace repo 是 public,內部 hostname / 內網位址、機器路徑、客戶與公司專案名、真實姓名一律換成 placeholder,憑證絕不出現;但版本、行號、程式碼片段、錯誤碼、重現步驟**照實保留**——判準是「拿掉之後維護者還修得動嗎」。
- **由 agent 送出,不產出報告檔請使用者自己轉貼**;但送出前要用 `AskUserQuestion` 把消毒後的完整內容給使用者過目(對外動作要先過人,而 public repo 貼出去就散出去了)。
- `plugin.json` 帶 `repository` 欄位,讓 skill 與人都查得到回報位址,而不是把位址寫死在 skill 文字裡。
- 純 skill plugin:無 script、不碰 `.turbo-plugin/` 狀態、無需 setup;測試套件探索到零個測試檔即通過(與 `turbo-plugin-code-comment` 相同)。
