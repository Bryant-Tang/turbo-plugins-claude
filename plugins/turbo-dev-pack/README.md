# Turbo Dev Pack for Claude

**t**urbo **d**ev **p**ack 簡稱 tdp

Skills and scripts for web project development workflows, testing and proof, and team collaboration.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugins` 指令
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 選擇 `Marketplaces`
      1. 選擇 `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
      1. 選擇 `tdp`
      1. 選擇你想要的 scope (user / project / local) 並安裝
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
        "tdp@turbo-plugins-claude": true
      }
      ```
1. 安裝完之後在 claude 聊天視窗使用 `/tdp:setup` 設定環境變數與必要的設定檔案

## 更新

1. 在 claude 聊天視窗使用 `/plugins`
1. 選擇 `Marketplaces`
1. 選擇 `turbo-plugins-claude`
1. 選擇 `Update marketplace`
1. 選擇 `Installed`
1. 選擇 `tdp`
1. 選擇 `Update now`