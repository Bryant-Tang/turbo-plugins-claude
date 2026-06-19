# Changelog

本檔記錄 turbo-plugin-code-comment 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 自單體 `turbo-plugin` v0.6.0 拆出,成為獨立可安裝 plugin。
- `tp-csharp-comment`:C# 註解撰寫慣例 skill(含 `assets/example-with-comments.cs` 範例)。
- `tp-js-comment`:JavaScript / TypeScript 註解撰寫慣例 skill(含 `assets/example-with-comments.ts` 範例)。
- 純 skill plugin:無 script、不碰 `.turbo-plugin/` 狀態、無需 setup。
- 兩層測試套件入口(`tests/Invoke-ScriptTests.ps1` / `tests/invoke-script-tests.sh`);本 plugin 無 script,orchestrator 在無 `scripts/` 時跳過 lint pre-flight 與 Pester framework gate,於 windows 與 ubuntu 皆回 exit 0(綠)。

### 遷移說明

- 舊安裝 `turbo-plugin@turbo-plugins-claude` 已由四個獨立 plugin 取代。若只需 C# / JS 註解慣例,改裝 `turbo-plugin-code-comment@turbo-plugins-claude`。
