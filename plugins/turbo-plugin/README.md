# turbo-plugin

.NET Framework Web + git+SVN bridged 環境的本機開發雜務工具集。14 個 skill 涵蓋 setup / SVN bridge / build / run / publish / ignore / 註解,**env-free 設計**,集中設定於 `.turbo-plugin/`。

> v1.0.0 為第一次 marketplace release,整合既有 `tdp` / `tnf` / `tgs` / `tpi` 四 plugin 的 dev 流程進單一 plugin。

## 安裝

1. 在 Claude Code 內執行 `/plugin`,從 marketplace `turbo-plugins-claude` 搜尋 `turbo-plugin` 並安裝
2. 安裝後在你的 .NET Framework Web + git+SVN 專案目錄啟動 Claude session,執行 `/tp-setup` 完成 bootstrap

### 推薦設定(`tp-setup` Phase 3 會引導)

跑 `/tp-setup` 時,Phase 3 會偵測你目前的 Claude Code 環境並 per-item 詢問是否啟用以下功能(可選 user-level / project-level / local-level scope,或跳過)。每一項都有 preview 列出副作用,選了才會動。

- **C# LSP**(`csharp-lsp@claude-plugins-official`):啟用後 tp-setup 會跑 `dotnet tool install -g csharp-ls` 自動裝 language server;需 .NET SDK 已裝
- **TS/JS LSP**(`typescript-lsp@claude-plugins-official`):啟用後 tp-setup 會跑 `npm install -g typescript-language-server typescript`;需 Node.js / npm 已裝
- **compound-engineering plugin**(`compound-engineering@compound-engineering-plugin`,第三方 marketplace):3-選項(跳過 / 安裝(自動更新)/ 安裝(不自動更新));自動更新會在啟動時 fetch 最新版,留意 GitHub repo 被 hijack 風險
- **Agent teams**(experimental):寫 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"` 啟用
- **TUI fullscreen**:寫 top-level `tui = "fullscreen"` 讓 Claude Code 進全螢幕 TUI 模式

任何 user-level settings.json 變更**重啟 Claude Code 後才會生效**;Phase 4 完成報告會列出 `~/.claude/settings.json` 寫入位置與重啟提示。LSP server binary 安裝失敗(runtime 缺 dotnet / npm 等)會記入 Phase 4 補裝清單,附手動 retry 指令與官方下載連結。

## 主要 skill

| Skill | 用途 |
|---|---|
| `/tp-setup` | 唯一設定入口(四 case:新建 / 接管現有 git+SVN / 主 worktree 補設定 / peer-mode) |
| `/tp-pull-from-svn` | 從 SVN 拉更新到 `remote/main` 並 merge 進工作分支 |
| `/tp-push-to-svn` | 將工作分支推送上 SVN(自 parse subject 篩選 conventional commit type) |
| `/tp-svn-log` | 在 `remote-*` worktree 跑 SVN log |
| `/tp-create-remote-test` | 建立 `remote/test-<n>` 分支與對應 worktree |
| `/tp-reset-remote-test` | 從 main 重設 test-<n> 分支 |
| `/tp-build-dotnet-framework-web` | MSBuild build .NET Framework Web 專案 |
| `/tp-run-dotnet-framework-web` | 啟動 IIS Express 跑專案,內含 listening 健康檢查 + 跨 worktree self-heal |
| `/tp-stop-dotnet-framework-web` | 停止對應 project identity 的 IIS Express instance(跨 worktree 識別) |
| `/tp-publish-dotnet-framework-web` | MSBuild publish + pack-content 整套發佈 |
| `/tp-suggest-ignore` | 偵測 untracked 檔案,建議加入 `.gitignore` + `svn:ignore` |
| `/tp-csharp-comment` | 對 C# 程式碼套用本專案註解 convention |
| `/tp-js-comment` | 對 JS / TS(含 `.vue` / `.cshtml` `<script>`)套用本專案註解 convention |

## 集中設定目錄 `.turbo-plugin/`

```
.turbo-plugin/
├── config.toml                  # build / publish / frontend / [iis] 偏好(進 git,跨同事共用)
├── config.local.toml            # gitignored,machine-specific tool paths([tools] msbuild_path / iis_express_path 等)
├── applicationhost.config       # IIS Express canonical(進 git;physicalPath 為佔位符)
├── dbhub.example.local.toml     # dbhub.local.toml 範本(進 git)
└── dbhub.local.toml             # gitignored,含 DB credentials,由使用者複製範本後填值
```

`tp-setup` 會建立此目錄並寫入 default-files template;Phase 3 詢問互動填入 `config.local.toml [tools]` 的 tool paths。

### `[iis] enabled` opt-out 機制

沒有 .NET Framework Web 開發需求時(例如純 SVN-bridge 工作流、純前端專案),可在 `.turbo-plugin/config.toml` 設:

```toml
[iis]
enabled = false
```

所有 IIS 相關 SKILL(`tp-run-dotnet-framework-web` / `tp-stop-dotnet-framework-web` / `tp-build-dotnet-framework-web` / `tp-publish-dotnet-framework-web` / `tp-cleanup-orphan-iis`)會 emit 統一友善訊息引導重新啟用,不會嘗試啟動 IIS Express 或寫 applicationhost.config。預設為 `true`(不設視為啟用)。

### `applicationhost.config` runtime(v1.0 起 VS 與 turbo-plugin 分頭管理)

從 v1.0.0 起,turbo-plugin 與 Visual Studio 對 `applicationhost.config` 完全分離:

- **`.turbo-plugin/applicationhost.config`(canonical)**:turbo-plugin 自管,進 git。所有 `<site>` 的 `physicalPath` 屬性值為佔位符 `__TURBO_PLUGIN_PHYSICAL_PATH__`,跨機器 / 跨同事 portable。**canonical 永遠不被 physicalPath 改寫污染**。
- **`%TEMP%\turbo-plugin-iis-<identity-hash>.config`(transient)**:每次 `tp-run` 啟動時由 `Start-Iis.ps1` 從 canonical 複製一份到 temp 並把佔位符替換為當前 worktree 的 csproj 所在目錄,以 `iisexpress -config:<temp>` 啟動。`tp-stop` 停掉 process 後刪除對應 temp file;`tp-cleanup-orphan-iis` 順手清掉孤兒 temp file。
- **`.vs/<sln>/config/applicationhost.config`(VS 自管)**:VS UI 自己維護的 IIS 設定,turbo-plugin 從本版起**完全不讀不寫**(`Invoke-PostToolUseEnterWorktree.ps1` / `Invoke-SessionStart.ps1` / `Remove-OrphanIis.ps1` 對該檔的處理皆已移除)。VS 內改了 IIS port / binding 不會自動回流到 `.turbo-plugin/applicationhost.config`,需要手動 copy(future brainstorm 議題)。

同一專案在所有 worktree 之間仍只能啟動一個 IIS Express instance(port / site 從專案檔產生,跨 worktree 算出相同值,物理上不可能並發);切換 worktree 跑 `tp-run` 走「同 site 已存在則先 stop 再用新 physicalPath 重啟」邏輯。

## Pattern A vs Pattern B

`turbo-plugin` 支援兩種 Claude session 啟動方式:

### Pattern A — 在主 worktree 啟動(推薦)

1. `cd <proj>` 進主 worktree
2. 啟動 Claude Code session
3. 用 Claude 內建 `EnterWorktree` tool 切換到 peer worktree

優點:`tp-dbhub` MCP server 讀主 worktree 的 `dbhub.local.toml`,peer worktree 不需各自準備檔案;`PostToolUse EnterWorktree` 自動補 peer 的 applicationhost.config。

### Pattern B — 直接在 peer worktree 啟動

1. `cd <proj>.worktrees/dev-x` 進 peer worktree
2. 啟動 Claude Code session

優點:適合長時間在同一 peer worktree 工作。

缺點:`tp-dbhub` MCP server 鎖定 session 啟動位置,**該 peer worktree 必須有自己的 `dbhub.local.toml`**;`SessionStart` hook 偵測到缺檔會 prompt 警告。

> ⚠️ **Hybrid 警告**:Pattern B 啟動後再用 `EnterWorktree` 進別的 peer 不會切換 MCP server 連線(MCP server 已鎖定原 peer 的 `dbhub.local.toml`)。如需切換,結束 session 重新在目標 peer 啟動 Claude。

## Hooks

`turbo-plugin` 自帶兩個 hook,安裝即生效:

- **`PostToolUse EnterWorktree`**:v1.0 起改為 **no-op**(僅 emit `{}` + exit 0)。先前版本會把 canonical 複製進 `.vs/<sln>/config/applicationhost.config` 並 patch physicalPath;v1.0 把 runtime 改為 temp file 渲染後,EnterWorktree 已無需做任何寫入(canonical 不被改、`.vs/` 由 VS 自管、temp file 在 `tp-run` 啟動時才產生)。
- **`SessionStart`**:每次 Claude session 啟動時觸發,依以下順序檢查:
  1. 非 git repo / submodule 內 → silent exit
  2. `.turbo-plugin/` marker 存在 + 在 peer worktree + 缺 `dbhub.local.toml` → Pattern B 警告
  3. marker 不存在 → 提示主 worktree 路徑(若在 peer)或「請執行 `/tp-setup`」(若在主 worktree)

兩個 hook 都是 advisory 不會 block session。

## 與既有 4 plugin 共存

v1.0.0 將既有 `tdp` / `tnf` / `tgs` / `tpi` 四 plugin 的 dev 流程整合進單一 `turbo-plugin`。若你仍在用舊 4 plugin,可在 `~/.claude/settings.json` 或 project-level `.claude/settings.json` 的 `enabledPlugins` 移除對應條目,改用 `/tp-<skill>` 觸發新 plugin 的 14 個 skill。

## License

MIT
