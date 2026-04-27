# Turbo Plugins for Claude

Some claude plugins that handle dev process.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugin` 指令
    - 或是手動編輯 `.claude/settings.json`
    ```json
    "extraKnownMarketplaces": {
      "turbo-plugins-claude": {
        "source": {
              "source": "git",
              "url": "https://github.com/Bryant-Tang/turbo-plugins-claude.git"
        }
      }
    },
    "enabledPlugins": {
      "turbo-dev-pack@turbo-plugins-claude": true,
      "turbo-dotnet-framework-commands@turbo-plugins-claude": true
    }
    ```
1. 安裝完之後在 claude 聊天視窗使用 `/tdp:setup` 、 `/tnf:setup` 設定環境變數與必要的設定檔案