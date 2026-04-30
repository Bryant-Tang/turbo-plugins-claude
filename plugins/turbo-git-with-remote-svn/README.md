# Turbo Git with Remote SVN for Claude

**t**urbo **g**it with remote **s**vn 簡稱 tgs

Commands and skills for git project workflows bridging a remote SVN repository.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugins` 指令
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 選擇 `Marketplaces`
      1. 選擇 `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
      1. 選擇 `tgs`
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
      "tgs@turbo-plugins-claude": true
    }
    ```

## 更新

1. 在 claude 聊天視窗使用 `/plugins`
1. 選擇 `Marketplaces`
1. 選擇 `turbo-plugins-claude`
1. 選擇 `Update marketplace`
1. 選擇 `Installed`
1. 選擇 `tgs`
1. 選擇 `Update now`

## 提供的命令

- **`create-project`** — 在指定位置建立 git + SVN 混合專案初始結構
- **`create-remote-test`** — 建立測試分支與對應的 SVN 同步 worktree
- **`create-dev-worktree`** — 建立個人開發隔離 worktree
- **`pull-from-svn`** — 從 SVN 拉取最新內容並 merge 進 git 工作分支
- **`push-to-svn`** — 將 git 工作分支的變更送交到 SVN
- **`svn-log`** — 顯示指定 branch 對應 remote worktree 的 SVN 歷史紀錄

## 設定

安裝後在每個 worktree 的 Claude Code session 中執行 `/tgs:setup` 可以互動式設定環境變數，讓常用參數不需要每次手動輸入：

| 環境變數 | 說明 | 預設值 |
|---|---|---|
| `TGS_SVN_LOG_DEFAULT_BRANCH` | `svn-log` 的 `--branch` 預設值 | `main` |
| `TGS_SVN_LOG_DEFAULT_LIMIT` | `svn-log` 的 `--limit` 預設值 | `50` |
| `TGS_SVN_LOG_DEFAULT_VERBOSE` | `svn-log` 的 `--verbose` 預設值（設為 `1` 或 `true` 開啟） | 關閉 |
| `TGS_DEFAULT_WORKING_BRANCH` | `pull-from-svn` / `push-to-svn` 的 `--branch` 預設值（空白時每次詢問） | （空白） |

這些變數設定在 `.claude/settings.local.json` 的 `env` block 中。每個 worktree 是獨立的工作目錄，設定檔不共享——在 main worktree 與每個 dev-\<n\> worktree 中分別執行 `/tgs:setup`。
