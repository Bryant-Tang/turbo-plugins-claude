# Turbo Dev Pack for Claude

**t**urbo **d**ev **p**ack 簡稱 tdp

Skills and scripts for web project development workflows, testing and proof, and team collaboration.

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
      "turbo-dev-pack@turbo-plugins-claude": true
    }
    ```
1. 安裝完之後在 claude 聊天視窗使用 `/tdp:setup` 設定環境變數與必要的設定檔案
