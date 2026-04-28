# Turbo .NET Framework Commands for Claude

**t**urbo dot**n**et **f**ramework commands 簡稱 tnf

Commands and scripts for .NET Framework web project build with MSBuild and IIS Express startup.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugins` 指令
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 選擇 `Marketplaces`
      1. 選擇 `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
      1. 選擇 `tnf`
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
      "tnf@turbo-plugins-claude": true
    }
    ```
1. 安裝完之後在 claude 聊天視窗使用 `/tnf:setup` 設定 MSBuild 與 IIS Express 相關環境變數

## 更新

1. 在 claude 聊天視窗使用 `/plugins`
1. 選擇 `Marketplaces`
1. 選擇 `turbo-plugins-claude`
1. 選擇 `Update marketplace`
1. 選擇 `Installed`
1. 選擇 `tnf`
1. 選擇 `Update now`

## 提供的命令

- **`build-web`** — 使用 MSBuild 建置 ASP.NET web 專案，可選打包前端資產
- **`run-web`** — 在背景啟動 IIS Express，驗證埠監聽狀態
