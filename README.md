# Turbo Plugins for Claude

Some claude plugins that handle dev process.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugins` 指令
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 選擇 `Marketplaces`
      1. 選擇 `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
      1. 選擇 `tdp`
      1. 選擇你想要的 scope (user / project / local) 並安裝
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 輸入 `tnf` 以搜尋
      1. 選擇 `tnf`
      1. 選擇你想要的 scope (user / project / local) 並安裝
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 輸入 `tgs` 以搜尋
      1. 選擇 `tgs`
      1. 選擇你想要的 scope (user / project / local) 並安裝
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 輸入 `tpi` 以搜尋
      1. 選擇 `tpi`
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
        "tdp@turbo-plugins-claude": true,
        "tnf@turbo-plugins-claude": true,
        "tgs@turbo-plugins-claude": true,
        "tpi@turbo-plugins-claude": true
      }
      ```
1. 安裝完之後在 claude 聊天視窗使用 `/tdp:setup` 、 `/tnf:setup` 設定環境變數與必要的設定檔案，或是安裝 `tpi` 後執行 `/tpi:setup-all`，可一次完成所有已安裝 plugin 的 setup

## 更新

1. 在 claude 聊天視窗使用 `/plugins`
1. 選擇 `Marketplaces`
1. 選擇 `turbo-plugins-claude`
1. 選擇 `Update marketplace`
1. 選擇 `Installed`
1. 選擇 `tdp`
1. 選擇 `Update now`
1. 選擇 `tnf`
1. 選擇 `Update now`
1. 選擇 `tgs`
1. 選擇 `Update now`
1. 選擇 `tpi`
1. 選擇 `Update now`
