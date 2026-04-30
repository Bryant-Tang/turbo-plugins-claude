# Turbo Plugins Integration for Claude

**t**urbo **p**lugins **i**ntegration 簡稱 tpi

Cross-plugin orchestration skills for turbo-plugins-claude: set up all installed plugins in one go, or generate an integrated tutorial covering every installed plugin.

## 安裝

1. 安裝 plugin
    - 在 claude 聊天視窗使用 `/plugins` 指令
      1. 在 claude 聊天視窗使用 `/plugins`
      1. 選擇 `Marketplaces`
      1. 選擇 `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
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
      "tpi@turbo-plugins-claude": true
    }
    ```

## 更新

1. 在 claude 聊天視窗使用 `/plugins`
1. 選擇 `Marketplaces`
1. 選擇 `turbo-plugins-claude`
1. 選擇 `Update marketplace`
1. 選擇 `Installed`
1. 選擇 `tpi`
1. 選擇 `Update now`

## 用法

### setup-all

第一次安裝多個 turbo-plugins-claude plugin 後，或更新 plugin 之後，一次跑完所有 setup：

```
/tpi:setup-all
```

執行後 tpi 會：
1. 讀取已安裝的 turbo-plugins-claude plugin 清單
2. 讓使用者勾選要執行 setup 的 plugin（預設全選）
3. 偵測同一專案底下的其他 worktree，讓使用者勾選要一起套用 env 設定的 peer worktree（預設全選）
4. 在當下 worktree 依固定順序（tdp → tnf → tgs → 其他）依序呼叫每個 plugin 的 setup skill
5. 把 setup 產生的 env 設定複製到步驟 3 選取的 peer worktree；可針對特定 worktree 的特定 env 指定不同值
6. 顯示彙總結果（plugin setup 段 + propagation 段），失敗的項目提供重試指令

#### 多 worktree 行為

- 呼叫 setup-all 的 worktree 即為 **primary**；互動問答（env var 設定）只在 primary 跑一次。
- Peer worktree 只接收結果：env 區塊被合併更新，companion 目錄（`specs/` 等）補建。
- 若要讓某個 peer 的特定 env 值與 primary 不同（例如 dev-1 的 `TGS_DEFAULT_WORKING_BRANCH` 用 `test-3` 而非 `main`），在 Stage A 勾選該 peer 並在後續步驟指定。
- 單 worktree 專案（或非 git 目錄）偵測不到多個 worktree 時，行為與 v0.1.0 相同。

也可以傳入 alias 清單，只跑指定的 plugin：

```
/tpi:setup-all tdp,tnf
```

### teach-me

根據已安裝的 plugin 動態產生整合教學，並進入互動問答模式：

```
/tpi:teach-me
```

執行後 tpi 會讀取每個已安裝 plugin 的 README、skills 與 commands，產生包含以下三段的教學：
- **Overview** — 所有已安裝 plugin 的快速參考表
- **Per-plugin 章節** — 每個 plugin 的 skills、commands 與設定變數
- **Cross-plugin 工作流** — 跨 plugin 的端到端流程（依實際安裝組合產生）

教學結束後進入 Q&A 迴圈，可以繼續追問；最後可選擇是否將教學存成 `.md` 檔。

只看特定 plugin 的章節：

```
/tpi:teach-me tdp
```

直接跳到某個跨 plugin 工作流：

```
/tpi:teach-me workflow:svn-sync
```

## 提供的 skill

| 名稱 | 類型 | 用途 |
|---|---|---|
| `setup-all` | skill | 一次執行所有已安裝 plugin 的 setup |
| `teach-me` | skill | 根據已安裝 plugin 動態產生整合教學並問答 |
