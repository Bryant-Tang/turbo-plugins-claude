---
name: tp-build-dotnet-framework-web
description: '對 .NET Framework Web 專案跑 MSBuild build。使用者明確要求 build 時執行;agent 偵測到「程式碼變更後驗證可建置」需求時也可建議執行(build 失敗可重跑,可逆操作)。'
argument-hint: '[--configuration <name>] [--platform <name>] [--project <path>]'
user-invocable: true
allowed-tools: Bash, Read
---

# tp-build-dotnet-framework-web

## Purpose

對 .NET Framework Web 專案跑 MSBuild build,自動偵測 `.csproj`、走 R9 4 層 lookup chain 取設定(skill arg → `config.toml [build]` → 內建 default → fail loudly)。

## Procedure

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

### Step 1 — 執行 build

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Build-Web.ps1` (或 `${CLAUDE_PLUGIN_ROOT}/scripts/build-web.sh`)帶 optional `-Configuration <name>` / `-Platform <name>` / `-Project <path>`(`.sh` 為 thin wrapper 轉呼叫 `.ps1`)。
2. Script 會:
   - 偵測 `.csproj`(CLI arg → `config.toml [build].project` → 自動找單一 .csproj)
   - 偵測 MSBuild(user-level env `TURBO_PLUGIN_MSBUILD_PATH` → 標準 VS 安裝路徑)
   - 跑 `msbuild /restore /t:Build /p:SolutionDir=<repo>\` 帶 configuration + platform
   - build 成功後跑 `Compress-Content.ps1`(自動偵測 `[frontend]` 設定;省略則 skip)
3. 解讀輸出,將 build error 直接回傳給使用者。

## Decision Rules

- **TRUST_REQUIRED 處理**: 若 script stdout 含 `TRUST_REQUIRED hash=<h> install_command=<cmd> build_command=<cmd>`,用 `AskUserQuestion` 顯示實際指令並詢問:「即將執行以下 frontend 指令,確認允許?`install: <cmd>` / `build: <cmd>`」。使用者選 Yes → 寫入 `.turbo-plugin/pack-content-trust.local.toml`(格式:`approved_hash = "<h>"`)並重新呼叫 script。使用者選 No → 終止 skill。
- Build 失敗可逆(重跑即可),屬於 agent-proactive 觸發類別 — 偵測「剛改完程式碼」可建議跑。
- 多個 `.csproj` 又沒指定 → fail loudly 列出候選 + 建議設 `[build].project`。
- MSBuild 找不到 → fail loudly 提示設 `TURBO_PLUGIN_MSBUILD_PATH`。
- 內建 default:`Configuration = Debug`,`Platform = Any CPU`(注意 platform 字串含空格,符合 `.csproj` 慣用)。

## Completion Checks

- `msbuild` 結束 exit code 為 0。
- `<project>\bin\<Configuration>\` 含新 build 產出檔案。
- 若 `[frontend]` 設定齊備:`<frontend.dir>/` 內 build 輸出齊備。

## Test Scenarios

- **[frontend] config absent**: 沒設 `[frontend]` 段 → /tp-build 略過 frontend 步驟、直接 MSBuild、Build succeeded 訊息出現。
- **[frontend] config present**: 設 `[frontend] path = "src/web/frontend"; install_command = "npm install"; build_command = "npm run build"` → /tp-build 先 cd 進 frontend 跑兩個 command,再 MSBuild。Build succeeded 出現。
- **Multiple .csproj without -Project**: repo 有 2 個 csproj → /tp-build fail loudly 列出兩個 csproj path 並要求加 `-Project`。
- **TURBO_PLUGIN_MSBUILD_PATH invalid**: env 設不存在路徑 → fail loudly 訊息含 env key 與該路徑。

## Tool Preference

shell 操作限 `msbuild` / 跑 plugin script;檔案讀寫用 Read / Edit / Write。
