# Changelog

本檔記錄 turbo-plugin-code-comment 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [0.1.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-code-comment--v0.1.0...turbo-plugin-code-comment--v0.1.1) (2026-08-17)


### Fixed

* **code-comment:** 讓既有安裝也收得到 turbo-plugin-feedback 相依 ([bc22b51](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/bc22b51610f1cee45658c60cd307565954675d69))


### Documentation

* 其餘四個 plugin 的 README 也寫上 turbo-plugin-feedback 相依,並清掉指向已刪除文件的註解 ([d9a3728](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/d9a3728be8e0270c9170039bcc7b774489ae0e8a))

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 初版:C# 與 JavaScript / TypeScript 註解撰寫慣例 skill 集,獨立可安裝 plugin。
- `tp-csharp-comment`:C# 註解撰寫慣例 skill(含 `assets/example-with-comments.cs` 範例)。
- `tp-js-comment`:JavaScript / TypeScript 註解撰寫慣例 skill(含 `assets/example-with-comments.ts` 範例)。
- 純 skill plugin:無 script、不碰 `.turbo-plugin/` 狀態、無需 setup。
- 兩個 skill 的 `description` 寫成**主動觸發**式(「撰寫 / 修改對應程式碼時主動套用,不需使用者另外明講」),讓 agent 動到 `.cs` / `.js` / `.ts` 時自動採用;**刻意不**寫進 `.turbo-plugin/conventions.md`(便於觀察 description 本身是否足以驅動自動使用)。
- 兩層測試套件入口(`tests/Invoke-ScriptTests.ps1` / `tests/invoke-script-tests.sh`);本 plugin 無 script,orchestrator 在無 `scripts/` 時跳過 lint pre-flight 與 Pester framework gate,於 windows 與 ubuntu 皆回 exit 0(綠)。
