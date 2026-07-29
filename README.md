# Turbo Plugins for Claude

Some Claude plugins that handle a .NET Framework Web + git↔SVN bridged dev process.

turbo-plugins-claude 收納四個正交、各自獨立安裝的 plugin。只裝你需要的那塊：

| Plugin | 用途 | 需要 setup? |
|---|---|---|
| **`turbo-plugin-git-svn`** | git↔SVN bridge + 設定入口（setup / pull / push / svn-log / reset / merge / suggest-ignore / commit-msg） | 是（`/tp-setup`） |
| **`turbo-plugin-dotnet-framework-web`** | .NET Framework Web 本機開發（build / run / stop / publish / cleanup-orphan-iis，IIS Express + MSBuild） | 否（設定用到才建，可自我修復） |
| **`turbo-plugin-three-environment-db`** | 三環境 DB 輔助（`tp-db-management` skill + `tp-dbhub` MCP server） | 複製 `dbhub.example.local.toml` → `dbhub.local.toml` 填值 |
| **`turbo-plugin-code-comment`** | C# / JS / TS 註解撰寫慣例（`tp-csharp-comment` / `tp-js-comment`） | 否（純 skill） |

### 怎麼選

- 只要 git↔SVN 橋接工作流 → 裝 **`turbo-plugin-git-svn`**。
- 還要在本機跑 .NET Framework Web（IIS Express）→ 加裝 **`turbo-plugin-dotnet-framework-web`**。
- 要用 DBHub 唯讀檢視三環境 DB + SQL 標準化 → 加裝 **`turbo-plugin-three-environment-db`**。
- 只想要程式碼註解慣例（不碰 SVN / IIS / DB）→ 單裝 **`turbo-plugin-code-comment`** 即可，無需 setup。

> `.turbo-plugin/` 設定目錄由各 plugin 共用。`turbo-plugin-git-svn` 的 `/tp-setup` 會建立它；只裝 dotnet plugin 時不必先做任何事——需要寫設定的一方會自己把目錄、檔案與自己的區塊建起來。

## 安裝

1. 加入 marketplace
    - 在 Claude Code 聊天視窗使用 `/plugin`
      1. 選擇 `Marketplaces` → `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
    - 或手動編輯 `.claude/settings.json`
      ```json
      "extraKnownMarketplaces": {
        "turbo-plugins-claude": {
          "source": {
            "source": "git",
            "url": "https://github.com/Bryant-Tang/turbo-plugins-claude.git"
          }
        }
      }
      ```
2. 安裝需要的 plugin（在 `/plugin` 內搜尋下列名稱，選擇 scope 後安裝；或在 `enabledPlugins` 加對應條目）
      ```json
      "enabledPlugins": {
        "turbo-plugin-git-svn@turbo-plugins-claude": true,
        "turbo-plugin-dotnet-framework-web@turbo-plugins-claude": true,
        "turbo-plugin-three-environment-db@turbo-plugins-claude": true,
        "turbo-plugin-code-comment@turbo-plugins-claude": true
      }
      ```
3. 若裝了 `turbo-plugin-git-svn`，在專案目錄啟動 Claude session 後執行 `/tp-setup` 完成 bootstrap。

## 更新

1. 在 Claude Code 聊天視窗使用 `/plugin`
1. 選擇 `Marketplaces` → `turbo-plugins-claude` → `Update marketplace`
1. 選擇 `Installed`，對要更新的 plugin 選 `Update now`

> plugin 更新依**版本號**（非 git commit）。每個 plugin 各自獨立版本化。
