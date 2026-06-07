---
title: turbo-plugin — .NET 技能 csproj 化 / VS 2022 自動分析（SEED，待正式 brainstorm）
status: parked-seed
created: 2026-06-06
type: requirements-seed
target_version: 0.6.0
parked_from: docs/brainstorms/2026-06-06-turbo-plugin-v0.5.0-requirements.md
---

# .NET 技能 csproj 化 / VS 2022 自動分析（SEED）

> **這不是完成的需求文件**,是從 v0.5.0 brainstorm **抽出**的種子,用來保存背景與已知決策,避免多次 compact 後遺失。下次要正式做這塊時,用 `/ce-brainstorm` 把本檔當輸入,先把「自動分析到什麼程度算完成」談清楚再產正式 requirements。

## 為什麼抽出

原本是 v0.5.0 的 item 17。在 2026-06-06 的 v0.5.0 brainstorm + doc-review 過程中,scope-guardian / feasibility 指出「體驗對齊 VS 2022」野心太大、缺驗收準則(VS 真實行為涉及 MSBuild 屬性求值 + Import 鏈 + Directory.Build.props,自己重做是無底洞)。使用者決定:**想做大範圍版本,但太大,整個抽出另開 brainstorm 細談範圍**;v0.5.0 完全不動 .NET 技能。

## 原始需求(item 17,逐字保留意圖)

> dot-net-framework 相關 skill,應該改成 script 接收一個 `*.csproj` 就好,然後 script 自動分析應該要分析的,就像是用 VS 2022 一樣的體驗。每次 skill 呼叫 scripts 由 agent 自行判斷要傳入的 `*.csproj`,而不是寫死專案的 csproj 檔在 turbo-plugin 的那些參數裡面,這樣才可以適用「有多個 csproj 而且多個可能都需要 build / run / publish」的專案。

## 已知決策 / 傾向(brainstorm 中曾確認,供後續沿用或重新檢視)

- 使用者傾向「**大範圍**」版本(真的做到接近 VS 2022 的自動分析),而非只移除寫死設定的最小版。
- 早先曾傾向 KD4:「**純 agent 傳入 csproj、移除寫死專案的 config 預設**(`[build].project`、`[publish]` 的 project 路徑等)」;`configuration` / `platform` / pubxml 等非專案路徑設定可保留或由 csproj 推導。此傾向在抽出時**未定案**,正式 brainstorm 時重新確認。

## 影響範圍(現況事實,供 plan 參考)

- 相關 skill:`tp-build-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-cleanup-orphan-iis`。
- 現有 lib 已有 `Find-SingleCsproj`(`Common.ps1`),3-tier:CLI arg → `config.toml [build].project` → 自動偵測單一 csproj;`Build-Web.ps1` / `Publish-Web.ps1` / `Get-ProjectIdentity.ps1` / `IisHelpers.ps1` 已呼叫。所以「最小版」其實只是移除 `[build].project` 寫死、改 agent 每次傳。
- run/stop 的 IIS Express identity 目前綁 `(port + project identity)`;多 csproj 同時 run 時的 identity / port 配置需要設計。

## 核心待解問題(正式 brainstorm 要先回答)

1. **「自動分析」的邊界到哪算完成?** 只讀 csproj 直接屬性?還是要做 MSBuild 屬性求值 + Import 鏈 + `Directory.Build.props`?驗收準則是什麼?
2. **要自動推導哪些項目?** configuration / platform / pubxml / 輸出路徑 / target framework / 相依?各自從哪取(csproj XML vs MSBuild evaluation vs 既有 config)?
3. **多 csproj 同時 build/run/publish** 的工作流:agent 如何選 csproj?同時 run 多個的 IIS identity / port 衝突如何處理?
4. **與 v0.5.0 的關係**:v0.5.0 完成後,config 的 `[build]` / `[publish]` 結構長怎樣?哪些保留、哪些移除?
5. **PS 5.1 可行性**:在 Windows PowerShell 5.1 下做 MSBuild 屬性求值有無現成可靠手段(例如呼叫 `msbuild -pp` / `-getProperty`),還是要 parse XML?

## 下一步

v0.5.0 全部做完後,用 `/ce-brainstorm` 開正式討論,以本檔為輸入。
