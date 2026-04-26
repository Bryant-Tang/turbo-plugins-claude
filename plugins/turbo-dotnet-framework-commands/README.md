# Turbo .NET Framework Commands for Claude

**t**urbo dot**n**et **f**ramework commands 簡稱 tnf

Commands and scripts for .NET Framework web project build with MSBuild and IIS Express startup.

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
                "turbo-dotnet-framework-commands@turbo-plugins-claude": true
            }
        ```
1. 安裝完之後在 claude 聊天視窗使用 `/tnf:setup` 設定 MSBuild 與 IIS Express 相關環境變數

## 提供的命令

- **`build-project`** — 使用 MSBuild 建置 ASP.NET web 專案，可選打包前端資產
- **`run-project`** — 在背景啟動 IIS Express，驗證埠監聽狀態
