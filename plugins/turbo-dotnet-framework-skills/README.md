# Turbo .NET Framework Skills for Claude

**t**urbo dot**n**et **f**ramework skills 簡稱 tnf

Skills and scripts for .NET Framework web project development, IIS Express startup, testing and proof, and team workflows.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugin` 指令
    - 或是手動編輯 `.claude/settings.json`
        ```json
            "extraKnownMarketplaces": {
                "turbo-plugins-claude": {
                    "source": {
                        
                    }
                }
            },
            "enabledPlugins": {
                "dotnet-framework-skills@turbo-plugins-claude": true
            }
        ```
1. 安裝完之後在 claude 聊天視窗使用 `/tb-dnf:setup` 設定環境變數與必要的設定檔案
