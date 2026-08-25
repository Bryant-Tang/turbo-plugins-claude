# Turbo Plugins for Claude

Some Claude plugins that handle a .NET Framework Web + git↔SVN bridged dev process.

turbo-plugins-claude 收納六個正交、各自獨立安裝的 plugin。只裝你需要的那塊：
（第七個 `turbo-plugin-feedback` 是共用件，下面每一個都相依它，會自動一起裝上。）

| Plugin | 用途 | 需要 setup? |
|---|---|---|
| **`turbo-plugin-git-svn`** | git↔SVN bridge + 設定入口（setup / pull / push / checkout-svn-branch / svn-log / merge / request-merge / suggest-ignore / commit-msg） | 是（`/tp-setup`） |
| **`turbo-plugin-dotnet-framework`** | .NET Framework Web 本機開發（build / run / stop / publish / cleanup-orphan-iis，IIS Express + MSBuild） | 否（設定用到才建，可自我修復） |
| **`turbo-plugin-three-environment-db`** | 三環境 DB 輔助（`tp-db-management` skill + `tp-dbhub` MCP server） | 複製 `dbhub.example.toml` → `dbhub.local.toml` 填值 |
| **`turbo-plugin-code-comment`** | C# / JS / TS 註解撰寫慣例（`tp-csharp-comment` / `tp-js-comment`） | 否（純 skill） |
| **`turbo-plugin-multi-repo-workspace`** | 「一個資料夾底下並排放著多個獨立 git repo」的工作區設定（`tp-multi-repo-workspace-setup`） | 是（`/tp-multi-repo-workspace-setup`，每個工作區一次） |
| **`turbo-plugin-knowledge-placement`** | 「這件事該寫在哪」的判準 + 把 agent 記憶匯出成交接文件（`tp-knowledge-placement-setup` / `tp-export-handover`） | 是（`/tp-knowledge-placement-setup`，每個專案一次） |
| `turbo-plugin-feedback` | 把 turbo-plugin 的問題回報成 issue（`tp-report-issue`，含 public repo 消毒規則）。**不必自己裝**——上面每一個都相依它 | 否（純 skill） |

### 怎麼選

- 只要 git↔SVN 橋接工作流 → 裝 **`turbo-plugin-git-svn`**。
- 還要在本機跑 .NET Framework Web（IIS Express）→ 加裝 **`turbo-plugin-dotnet-framework`**。
- 要用 DBHub 唯讀檢視三環境 DB + SQL 標準化 → 加裝 **`turbo-plugin-three-environment-db`**。
- 只想要程式碼註解慣例（不碰 SVN / IIS / DB）→ 單裝 **`turbo-plugin-code-comment`** 即可，無需 setup。
- session 開在「並排放著多個獨立 repo」的資料夾（`proj-root/proj-1` + `proj-root/proj-2` + …）→ 加裝 **`turbo-plugin-multi-repo-workspace`**；它相依 `turbo-plugin-git-svn`，安裝時會自動一起裝上。
- 常搞不清楚「這條規範該寫進 `CLAUDE.md`、`docs/`、還是讓 agent 記著」，或者**換人接手時那些只有現在成立的事會整批消失** → 加裝 **`turbo-plugin-knowledge-placement`**。它**刻意不被任何 plugin 相依**：用了 SVN 橋接不代表就得接受這套文件方法。
- **遇到 plugin 本身的問題** → 不必做任何事：每個 plugin 都相依 `turbo-plugin-feedback`，它的 `tp-report-issue` 會主動把問題整理成 issue（送出前會先讓你過目）。

> `.turbo-plugin/` 設定目錄由各 plugin 共用。`turbo-plugin-git-svn` 的 `/tp-setup` 會建立它；只裝 dotnet plugin 時不必先做任何事——需要寫設定的一方會自己把目錄、檔案與自己的區塊建起來。

### 這個 marketplace 不做什麼

這裡收的都是「**被綁在特定環境裡**」才會遇到的具體問題：只能用 SVN、只能用 .NET Framework、多個獨立 repo 並排在同一個資料夾。這些東西換個團隊就未必用得上，但在用得上的地方，細節（PowerShell 5.1 相容、CP950 中文檔名、IIS Express 的設定檔）沒人幫你處理。

**通用的開發流程不在範圍內**，例如：

- 需求討論、逐條轉成 spec、蒐集佐證
- 規劃與實作的流程編排（plan / implement 類的 skill）
- 程式碼審查、commit 訊息以外的一般性工作流

理由是這些跟技術棧無關，而且已經有成熟的開源 plugin 在做。**在這裡重做一份，只會做出一個比較差的版本，還要自己維護。** 需要的話另外裝一個就好——各 plugin 之間不會互相干擾。

> 這條界線先前只存在於口頭，結果同樣的提案被重新提出過兩次（issue #22、#23，均以 `not planned` 關閉）。寫在這裡是為了讓期待一開始就對齊。

## 安裝

1. 加入 marketplace
    - 在 Claude Code 聊天視窗使用 `/plugin`
      1. 選擇 `Marketplaces` → `+ Add Marketplace`
      1. 輸入 `https://github.com/Bryant-Tang/turbo-plugins-claude.git`
    - 或手動編輯 `.claude/settings.json`
      ```json
      "extraKnownMarketplaces": {
        "turbo-plugins-claude": {
          "source": {
            "source": "git",
            "url": "https://github.com/Bryant-Tang/turbo-plugins-claude.git"
          }
        }
      }
      ```
2. 安裝需要的 plugin（在 `/plugin` 內搜尋下列名稱，選擇 scope 後安裝；或在 `enabledPlugins` 加對應條目）
      ```json
      "enabledPlugins": {
        "turbo-plugin-git-svn@turbo-plugins-claude": true,
        "turbo-plugin-dotnet-framework@turbo-plugins-claude": true,
        "turbo-plugin-three-environment-db@turbo-plugins-claude": true,
        "turbo-plugin-code-comment@turbo-plugins-claude": true,
        "turbo-plugin-multi-repo-workspace@turbo-plugins-claude": true,
        "turbo-plugin-knowledge-placement@turbo-plugins-claude": true
      }
      ```
      `turbo-plugin-feedback` **不用列**——上面每一個都相依它，安裝時會自動帶上並一起啟用。
      `turbo-plugin-knowledge-placement` 則相反：**沒有任何 plugin 相依它**，要用就得自己列上去。
3. 若裝了 `turbo-plugin-git-svn`，在專案目錄啟動 Claude session 後執行 `/tp-setup` 完成 bootstrap。
4. 若裝了 `turbo-plugin-multi-repo-workspace`，在**並排放著多個專案的那個資料夾**啟動 session 後執行 `/tp-multi-repo-workspace-setup`；它會注入該資料夾的 `CLAUDE.md`，並可逐一帶你完成各子專案的 `/tp-setup`。
5. 若裝了 `turbo-plugin-knowledge-placement`，在每個專案執行一次 `/tp-knowledge-placement-setup`，把判準寫進該專案的 `CLAUDE.md`。

## 更新

1. 在 Claude Code 聊天視窗使用 `/plugin`
1. 選擇 `Marketplaces` → `turbo-plugins-claude` → `Update marketplace`
1. 選擇 `Installed`，對要更新的 plugin 選 `Update now`

> plugin 更新依**版本號**（非 git commit）。每個 plugin 各自獨立版本化。

## 發版（維護者）

版本由 [release-please](https://github.com/googleapis/release-please) 依 conventional commit 自動管理，**不要手改 `plugin.json` 的 `version`，也不要手寫 CHANGELOG 的發版區段**。

- merge 進 `main` 後，所有「有可發版變更」的 plugin 會被收進**一個** Release PR（各 plugin 版本仍獨立計算，只是共用一條 release 分支——分開開的話 `.release-please-manifest.json` 那幾行相鄰的版本號會讓任兩個 PR 互相衝突）
- 因此 **merge 進 `main` 就等於打算發版**；想壓著某個變更先不發，就先不要 merge 它的 feature PR
- merge 那個 Release PR 才發版：自動打 tag（`<plugin>--v<version>`，**兩個減號**）並建立 GitHub Release
- **merge 功能 PR 時不要 squash**：CHANGELOG 的每一條來自個別 commit 的標題，squash 會把它們壓成一條

> **PR 標題不要用 `fix:` / `feat:` 前綴**，用 `chore:` 或不加。GitHub 會把 PR 標題放進 merge commit 的
> body，release-please 讀到後會多生一條沒有 scope 的假條目，且**每個該次 merge 動到的 plugin 都會收到
> 一份**。這件事沒有設定層的解（GitHub 的三種 merge commit 組合都會被解析到，release-please 也沒有排除
> merge commit 的選項）——原委與已查證過的死路寫在 `CLAUDE.md` 的 Versioning Rules。
