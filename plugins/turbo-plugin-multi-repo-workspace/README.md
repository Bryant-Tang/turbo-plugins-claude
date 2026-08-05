# turbo-plugin-multi-repo-workspace

把「一個資料夾底下並排放著多個獨立 git repo」的工作區教會 agent。

```
proj-root/            ← 本身不是 git repo；session 開在這裡
├─ proj-1/            ← 獨立 git repo（自己的 CLAUDE.md / SVN 路徑 / 資料庫）
├─ proj-2/            ← 獨立 git repo
└─ …
```

## Skills

| Skill | 用途 |
|---|---|
| `tp-multi-repo-workspace-setup` | 探測工作區 → 注入工作區根 `CLAUDE.md` 標記區塊 → 逐一（一次一個、各自確認）委派各子專案的 git↔SVN setup |

## 為什麼需要這個 plugin

在 `proj-root` 開 session 能同時看多個專案（跨專案讀取本來就能做，Read / Grep 不看 repo 邊界）。代價是 agent
**推導不出**兩件事，而使用者也無從得知該怎麼告訴它：

1. 子資料夾的 `CLAUDE.md` **會**被自動發現，但是**延遲載入**——只在讀到該目錄底下的檔案時才進 context，而且
   **`/compact` 之後不會自動回來**（根目錄的會）。所以「還沒讀檔就開始規劃」時，那個專案的規範不在手上。
2. 這些子資料夾**各自是獨立 repo**。沒寫下來就推導不出來，後果是跨專案一起 commit，或更糟——在工作區根
   `git init`，把所有專案包成一個 repo，而且事後沒有東西能還原。

注入的區塊就是在寫這幾件事。**它刻意不列出有哪些子專案**，也不列各專案的資料庫 / SVN 路徑 / 專屬規範：新增專案
或改動其中任何一項時很容易忘記回來更新，而過期的清單比沒有清單更糟。要知道有哪些專案就看資料夾，要知道某個專案
的規範就讀它自己的 `CLAUDE.md`。

> **工作區根的 `CLAUDE.md` 不在任何 repo 裡**，所以不進版控、不會跟著傳給同事。每個人在自己的工作區各跑一次
> `tp-multi-repo-workspace-setup` 即可。

## 相依

`turbo-plugin-git-svn`。子專案的 git↔SVN setup 一律委派給它的 `tp-setup`（SVN URL、git 身分、匯入粒度、base
骨架、編碼偵測全由那支負責），本 plugin 不自行複製那套互動。

安裝本 plugin 時 Claude Code 會自動解析並安裝相依。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-multi-repo-workspace@turbo-plugins-claude
```

## 探測腳本的輸出契約

`scripts/Get-WorkspaceProjects.ps1` / `get-workspace-projects.sh`（唯讀，可安全重跑）輸出零到多行資料行，
最後是**唯一**的終結 token：

```
PROJECT setup=<yes|no> main=<yes|no> path=<絕對路徑>
TP_TOKEN:PROJECTS count=<N>
```

| 終結 token | 意思 |
|---|---|
| `TP_TOKEN:PROJECTS count=<N>` | 找到 N 個並排專案（資料行在前） |
| `TP_TOKEN:WORKSPACE_IS_REPO path=<p>` | 這個資料夾本身就是 repo（或位在某個 repo 底下）→ 不是多專案工作區，直接用 git-svn 的 setup |
| `TP_TOKEN:NO_PROJECTS path=<p>` | 不是 repo，直屬子目錄也沒有一個是 |
| `TP_TOKEN:ERROR reason=<訊息>` | 其它失敗（例如指定的路徑不存在） |

- **`path=` 固定是行上最後一個欄位**，所以「`path=` 之後到行尾」就是完整路徑，含空白也不需引號或轉義。
- `setup=` = 該專案是否已有 `.turbo-plugin/` 標記。`main=` = 該目錄是否為自己 repo 的主 worktree；某個 repo 的
  linked worktree 回 `no`，git↔SVN 的 setup 會拒絕在那裡建橋，所以 skill **不對它提供設定選項**。
- 目錄名內嵌的 `TP_TOKEN:` 前綴會被改寫成 `TP_TOKEN_`，所以一個叫得像 token 的資料夾無法左右 skill 的路由。
- **只掃直屬子目錄**，這是刻意的：git-svn 的橋接 worktree 在 `<專案>/.turbo-plugin/worktrees/remote-svn-*`，
  各自帶一個 `.git` **檔**；那是孫層，掃一層深就永遠不會把橋接誤認成並排的專案。

## 注入的 `CLAUDE.md` 標記

```
<!-- turbo-plugin:begin multi-repo-workspace -->
…
<!-- turbo-plugin:end multi-repo-workspace -->
```

與其它 turbo-plugin 的標記慣例一致（`<!-- turbo-plugin:begin <concern> -->`）：只動自己的區塊，不碰標記外的內容
或別的 concern 的區塊。重跑不會產生第二組標記。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -File tests/Invoke-ScriptTests.ps1
```
```bash
bash tests/invoke-script-tests.sh
```

這個套件的工作根走**系統 temp**而非 repo 相對的 `tests/.sandbox/`，因為受測腳本問的正是「這個資料夾在不在 git
repo 裡」——沙箱放在 `plugins/` 底下答案會是「在」（就是這個 repo），每個情境都會塌成 `WORKSPACE_IS_REPO`。
仍是 path-free（位置在執行時取得、不寫死），且測試結束會清掉。temp 若剛好位在某個 repo 內，相關 case
**明顯 SKIP** 而不是假綠。

## License

MIT
