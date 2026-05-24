---
name: tp-publish-dotnet-framework-web
description: '對 .NET Framework Web 專案跑 MSBuild publish(含 frontend pack 步驟)。**publish 產出可能被 CD pipeline 消費,影響部署環境;必須使用者明確要求才執行**;agent 偵測到「完成一輪改動準備部署」時可建議,但需明確確認。'
argument-hint: '[--pubxml <path>] [--configuration <name>] [--platform <name>] [--project <path>]'
user-invocable: true
---

# tp-publish-dotnet-framework-web

## Purpose

對 .NET Framework Web 專案跑 MSBuild publish:先跑 frontend pack(若 `[frontend]` 設定齊備),再用 `.pubxml` profile 跑 `msbuild /p:DeployOnBuild=true`,落地產出到 `<PublishUrl>`。

## Procedure

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/publish-web.{ps1,sh}` 帶 optional 參數。Script 會:
   - 偵測 `.csproj`(同 `tp-build`)
   - 偵測 MSBuild(同 `tp-build`)
   - 偵測 `.pubxml`(CLI arg → `config.toml [publish].default_pubxml` → 自動找 `<project>/Properties/PublishProfiles/` 單一 `.pubxml`)
   - 跑 `pack-content.ps1`(若 `[frontend]` 設定齊備)
   - 跑 `msbuild /p:DeployOnBuild=true /p:PublishProfile=<name> /p:PublishProfileRootFolder=<dir> /p:Configuration=<cfg> /p:Platform=<plat>`
   - 後處理:parse `.pubxml` 取 `<PublishUrl>` + `<WebPublishMethod>`,回報實際產出位置(`FileSystem` 落地路徑 / FTP URL 等)
2. 解讀輸出,把 `Published to: <path>` / `PUBLISH_OUTPUT_PATH=<path>` 直接呈現給使用者。

## Decision Rules

- 多個 `.pubxml` 又沒指定 → fail loudly 列出候選 + 建議設 `[publish].default_pubxml`。
- 內建 default:`Configuration = Release`,`Platform = Any CPU`(刻意不同於 `tp-build` 的 Debug default)。
- Frontend pack 是 publish 鏈的一部份(brainstorm R17:pack-content 邏輯併入 publish);**不要在 SKILL 內額外呼叫** `pack-content`,script 已包含。
- Publish 影響外部 artifact(可能被 CD pipeline 消費),屬 **proactive suggestion only** 類別 — agent 偵測到「使用者完成準備部署」時可建議,但需明確同意。

## Completion Checks

- `msbuild` 結束 exit code 為 0。
- `<PublishUrl>` 路徑含新 artifact。
- 若 frontend 設定齊備:`<PublishUrl>/<frontend-output-dir>/` 含 frontend build 結果。

## Tool Preference

shell 操作限 `msbuild` / 跑 plugin script;檔案讀寫用 Read / Edit / Write。

## Test Scenarios

- **No .pubxml found**: 在無 .pubxml 的 csproj 跑 /tp-publish → fail loudly 訊息含「No .pubxml found in .Properties\PublishProfiles\」並建議使用 VS 先建 publish profile。
- **Multiple .pubxml**: 有多個 .pubxml → fail loudly 列出所有 .pubxml path,要求加 `--profile <name>`。
- **PUBLISH_OUTPUT_PATH stdout token**: publish 成功後 stdout 含 `PUBLISH_OUTPUT_PATH=<absolute-path-to-output>` 一行供 agent parse。
- **TURBO_PLUGIN_MSBUILD_PATH invalid**: env 設不存在路徑 → fail loudly 訊息含該路徑。
