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

> **重要**：把開發分支 merge 進 `test-<n>` 時請固定使用 `--no-ff`（VS Code Git extension 與 IntelliJ 都可設定預設 `--no-ff`；命令列加上 `--no-ff` 旗標）。`/tgs:release` 偵測 release 候選時依賴 merge commit 的 parent[1]，fast-forward merge 不留 merge commit 會被偵測漏抓。

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

### 結束一輪測試 / 退役 test 槽

| 動作 | 指令 |
|---|---|
| 把 `test-<n>` 對齊回 main、丟棄 test-only commit、推上 SVN（保留槽位繼續用） | `/tgs:reset-remote-test --n <n>` |
| 永久退役一個 `test-<n>` 槽（刪本地 branch / worktree / workspace 條目；SVN URL 保留） | `/tgs:cleanup-remote-test --n <n>` |

- **reset** 是常用動作：每輪測試結束、要把測試環境拉回 main 起點時用。SVN 上的 `branches/test-<n>` URL 不變，部署到該 URL 的測試伺服器自動拿到 main 內容
- **cleanup** 是少用動作：當你確定該 `test-<n>` 槽不會再用時。SVN 路徑保留作為歷史，`/tgs:create-remote-test` 下次自動取新編號

### 發布到正式環境

| 模式 | 指令 |
|---|---|
| A. 互動完整 / 部分發布 | `/tgs:release --n <n>` |
| B. 顯式指定子集 | `/tgs:release --n <n> --branch <name> [--branch <name> ...]` |
| C. Hotfix（不經 test-<n>） | `/tgs:release --branch <name> [--branch <name> ...]` |

- **模式 A**：偵測 `main..test-<n>` 中所有 dev merge commit 為候選，互動勾選；全選自動 reset `test-<n>`，部分選則保留未發布的 merge
- **模式 B**：跳過互動，嚴格只發布指定的分支；分支名稱必須對應到 test-<n> 內某筆 merge commit
- **模式 C**：直接從分支當前 HEAD 發布到 main 與 SVN trunk，不碰任何 test-<n>
- 每個模式都會：merge 進 main → `/tgs:push-to-svn --branch main`（含可選 release tag 互動）→ 視情況 `/tgs:reset-remote-test --n <n>` → 互動式清理 dev worktree
- 失敗即停（不自動 rollback），錯誤訊息會明確指出停在哪一步、後續如何手動接續

## 提供的命令與 skill

從 0.7.0 起，原本以 SKILL 形式存在的多步互動指令都改為 command（使用者體驗不變，仍以 `/tgs:<name>` 觸發）。`suggest-ignore` 維持 SKILL，因為 agent 看到新 untracked 檔案時主動建議它仍有真實價值。

| 名稱 | 類型 | 用途 |
|---|---|---|
| `create-project` | command | 建立 tgs 專案初始結構 |
| `create-remote-test` | command | 新增 `test-<n>` 環境（git + SVN） |
| `create-dev-worktree` | command | 新增 `dev-<n>` 個人開發 worktree |
| `create-branch` | command | 在 main worktree 建立指定名稱的 branch（無語意 primitive，給 tdp 等高層工作流委派用） |
| `archive` | command | 原子改名 branch + 搬移多個資料夾（無語意 primitive，給 tdp 的 `finish-dev` 委派用） |
| `pull-from-svn` | command | SVN → git（透過 `remote-*` worktree） |
| `push-to-svn` | command | git → SVN（透過 `remote-*` worktree）；單一確認頁顯示完整訊息預覽，自動過濾 Merge / doc / spec / db / chore commit |
| `reset-remote-test` | command | 把 `test-<n>` 對齊回 main、推上 SVN（槽位保留；release tag 指到的歷史仍可找回） |
| `cleanup-remote-test` | command | 永久退役 `test-<n>` 槽（刪本地 branch / worktree / workspace 條目；SVN 不動） |
| `release` | command | 發布到正式環境：merge dev 進 main → push SVN trunk → 視情況 reset test-<n> → 清理 dev worktree |
| `svn-log` | command | 唯讀查看 SVN 歷史 |
| `merge-main-into-all` | command | 把 main merge 進所有非 `remote/*` 與 `archives/*` 的 branch |
| `init-from-existing` | command | 把既有 git 專案遷移成 tgs 結構（idempotent） |
| `suggest-ignore` | skill | 管理 git/SVN ignore：直接新增或移除 `.gitignore` / `svn:ignore` pattern，或互動式分析並修正 git/SVN 不一致 |
| `setup` | command | 互動式設定 tgs 環境變數 |

## Primitive 委派（給其它 plugin 使用）

`create-branch` 與 `archive` 是設計成可被其它 plugin 委派呼叫的無語意 primitive：tgs 不假設 branch 命名 convention（`feature/`、`bugfix/`、`archives/` 等），由呼叫者組成完整名稱與路徑後傳入。`turbo-dev-pack` (tdp) 從 0.5.0 起就是透過這條路徑來建立 dev branch 與歸檔。

設計原則：

- tgs 提供 git / 結構操作的機械性原子保證（pre-flight、原子改名、失敗 rollback）
- tdp 等高層 plugin 維持自家 convention（`<type>/<slug>` namespace、`specs/<type>/<slug>/` 資料夾、archives 命名等）
- 兩端透過 `/tgs:<command>` slash command 介面溝通，不直接呼叫對方的 script

## 設定

安裝後在每個 worktree 的 Claude Code session 中執行 `/tgs:setup` 可以互動式設定環境變數，讓常用參數不需要每次手動輸入：

| 環境變數 | 說明 | 預設值 |
|---|---|---|
| `TGS_SVN_LOG_DEFAULT_BRANCH` | `svn-log` 的 `--branch` 預設值 | `main` |
| `TGS_SVN_LOG_DEFAULT_LIMIT` | `svn-log` 的 `--limit` 預設值 | `50` |
| `TGS_SVN_LOG_DEFAULT_VERBOSE` | `svn-log` 的 `--verbose` 預設值（設為 `1` 或 `true` 開啟） | 關閉 |
| `TGS_DEFAULT_WORKING_BRANCH` | `pull-from-svn` / `push-to-svn` 的 `--branch` 預設值（空白時每次詢問） | （空白） |

這些變數設定在 `.claude/settings.local.json` 的 `env` block 中。每個 worktree 是獨立的工作目錄，設定檔不共享——在 main worktree 與每個 dev-\<n\> worktree 中分別執行 `/tgs:setup`。
