# turbo-plugin

.NET Framework Web + git+SVN bridged 環境的本機開發雜務工具集。14 個 skill 涵蓋 setup / SVN bridge / build / run / publish / ignore / 註解,**env-free 設計**,集中設定於 `.turbo-plugin/`。

> v0.1.0 為與既有 `tdp` / `tnf` / `tgs` / `tpi` 四 plugin **並存的過渡版本**。description 寫成 conservative(明確要求才執行)避免過渡期重複觸發;cutover 後 0.2.0 會升級 description 啟用 agent-proactive。

## 安裝

1. 在 Claude Code 內執行 `/plugin`,從 marketplace `turbo-plugins-claude` 搜尋 `turbo-plugin` 並安裝
2. 安裝後在你的 .NET Framework Web + git+SVN 專案目錄啟動 Claude session,執行 `/tp-setup` 完成 bootstrap

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
├── config.toml                  # build / publish / frontend 偏好(進 git,跨同事共用)
├── applicationhost.config       # IIS Express 共享 source-of-truth(進 git)
├── dbhub.example.local.toml     # dbhub.local.toml 範本(進 git)
└── dbhub.local.toml             # gitignored,含 DB credentials,由使用者複製範本後填值
```

`tp-setup` 會建立此目錄並寫入 default-files template。

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

- **`PostToolUse EnterWorktree`**:每次 Claude 用 `EnterWorktree` 切到 peer 時觸發,自動改寫 peer 的 `applicationhost.config` 對應 site 的 `physicalPath`(atomic + idempotent)。
- **`SessionStart`**:每次 Claude session 啟動時觸發,依以下順序檢查:
  1. 非 git repo / submodule 內 → silent exit
  2. `.turbo-plugin/` marker 存在 + applicationhost.config 不對 → 提示「請執行 `/tp-setup`」
  3. marker 存在 + 在 peer worktree + 缺 `dbhub.local.toml` → Pattern B 警告
  4. marker 不存在 → 提示主 worktree 路徑(若在 peer)或「請執行 `/tp-setup`」(若在主 worktree)

兩個 hook 都是 advisory 不會 block session。

## 與既有 4 plugin 過渡期共存

v0.1.0 期間既有 `tdp` / `tnf` / `tgs` / `tpi` 仍可保留 enabled。為避免 auto-trigger 重複,description 寫成 conservative 風格,優先以 `/tp-<skill>` 手動觸發。

Cutover criteria:
- 13 個 skill 完整跑通
- F1 / F2 / F3 三 flow 各驗一輪
- 連續 5 工作日無 blocker

達標後可 disable / remove 既有 4 plugin(`.claude/settings.json` 的 `enabledPlugins`),0.2.0 將升級 description 啟用三層 trigger mode。

## License

MIT
