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

## 用法

### Worktree 結構

tgs 用多個 git worktree 分隔職責，讓 SVN 同步與個人開發互不干擾：

```
<proj>/                              ← main worktree（main / test-<n> 分支切換）
<proj>.worktrees/
  ├─ remote-main/                    ← SVN trunk 同步，branch: remote/main
  ├─ remote-test-<n>/                ← SVN test 分支同步，branch: remote/test-<n>
  └─ dev-<n>/                        ← 個人開發隔離 worktree
<proj>.code-workspace                ← VS Code workspace（自動維護）
```

- `remote-*` worktree 是 git/SVN 的橋樑，通常不直接在裡面編輯檔案
- `main` 與 `test-<n>` 共用 main worktree（切 branch），不另開目錄
- 任一 worktree 開 Claude Code 都能呼叫 tgs 指令（自動定位主目錄）

### 建立新專案

第一次建立專案時依序執行：

1. `/tgs:create-project --svn-url <SVN trunk URL>` — 建立目錄結構、初始化 git、checkout SVN
2. `/tgs:pull-from-svn --branch main` — 把 SVN 內容 commit 進 `remote/main` 並 merge 到 `main`
3. 在新專案目錄開啟 Claude Code，執行 `/tgs:setup` 設定環境變數預設值

### 建立測試分支環境

需要測試環境（test-`<n>`）時：

- `/tgs:create-remote-test --svn-url <SVN test branch URL>` — 自動取下個編號，建立 git 端分支並連結 SVN 測試分支（URL 不存在時會以 `svn copy` 從 main 建立）；完成後執行 `/tgs:pull-from-svn --branch test-<n>` 完成首次同步

### 開始個人開發

1. `/tgs:create-dev-worktree --branch <branch>` — 建立 `dev-<n>` 隔離 worktree，避免影響 main worktree 的 branch 狀態
2. 在 `dev-<n>` 目錄開啟 Claude Code，執行 `/tgs:setup`（每個 worktree 設定各自獨立）
3. 開發完成後，在 main worktree 把分支 merge 進 `main` 或 `test-<n>`，再用以下 push 流程送上 SVN

### 日常 SVN 同步

| 動作 | 指令 |
|---|---|
| 拉 SVN 最新內容進 git | `/tgs:pull-from-svn --branch <main\|test-<n>>` |
| 把 git 變更送上 SVN | `/tgs:push-to-svn --branch <main\|test-<n>>` |
| 查看 SVN 歷史紀錄 | `/tgs:svn-log --branch <main\|test-<n>> [--limit N] [--verbose]` |
| 管理 git/SVN ignore 設定 | `/tgs:suggest-ignore [--add-git\|--add-svn\|--remove-git\|--remove-svn <pattern>]` |
| 互動式分析並修正 git/SVN ignore 不一致 | `/tgs:suggest-ignore [--branch <branch>]` |

- 設定 `TGS_DEFAULT_WORKING_BRANCH` 後可省略 `--branch`（透過 `/tgs:setup` 設定）
- **pull** 流程：自動把 main worktree 切到目標 branch、merge、再切回原 branch；發生衝突時停在目標 branch 等使用者解決
- **push** 流程：列出待送 commit，AI 建議 SVN commit message 標題，確認後送出

## 提供的命令與 skill

| 名稱 | 類型 | 用途 |
|---|---|---|
| `create-project` | command | 建立 tgs 專案初始結構 |
| `create-remote-test` | command | 新增 `test-<n>` 環境（git + SVN） |
| `create-dev-worktree` | command | 新增 `dev-<n>` 個人開發 worktree |
| `pull-from-svn` | skill | SVN → git（透過 `remote-*` worktree） |
| `push-to-svn` | skill | git → SVN（透過 `remote-*` worktree） |
| `svn-log` | command | 唯讀查看 SVN 歷史 |
| `suggest-ignore` | skill | 管理 git/SVN ignore：直接新增或移除 `.gitignore` / `svn:ignore` pattern，或互動式分析並修正 git/SVN 不一致 |
| `setup` | skill | 互動式設定 tgs 環境變數 |

## 設定

安裝後在每個 worktree 的 Claude Code session 中執行 `/tgs:setup` 可以互動式設定環境變數，讓常用參數不需要每次手動輸入：

| 環境變數 | 說明 | 預設值 |
|---|---|---|
| `TGS_SVN_LOG_DEFAULT_BRANCH` | `svn-log` 的 `--branch` 預設值 | `main` |
| `TGS_SVN_LOG_DEFAULT_LIMIT` | `svn-log` 的 `--limit` 預設值 | `50` |
| `TGS_SVN_LOG_DEFAULT_VERBOSE` | `svn-log` 的 `--verbose` 預設值（設為 `1` 或 `true` 開啟） | 關閉 |
| `TGS_DEFAULT_WORKING_BRANCH` | `pull-from-svn` / `push-to-svn` 的 `--branch` 預設值（空白時每次詢問） | （空白） |

這些變數設定在 `.claude/settings.local.json` 的 `env` block 中。每個 worktree 是獨立的工作目錄，設定檔不共享——在 main worktree 與每個 dev-\<n\> worktree 中分別執行 `/tgs:setup`。
