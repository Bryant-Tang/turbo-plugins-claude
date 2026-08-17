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

另外相依 **`turbo-plugin-feedback`**：它只有一個 skill `/tp-report-issue`，用途是把你遇到的 turbo-plugin
bug 或沉默失敗整理成 issue 送出，含**送進 public repo 前的消毒規則**。這條相依不帶版本約束，理由見
`turbo-plugin-feedback/README.md`。

安裝本 plugin 時 Claude Code 會自動解析並安裝這兩個相依。

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

## Hooks：讓隔離工作副本在工作區根也能用

工作區根**本身不是 repo**，所以 Claude Code 內建的隔離在那裡直接失敗；先 `cd` 進某個子專案再開，
session 就被釘在那一個專案上——「站在根目錄一次管全部」這件事就沒了。

`WorktreeCreate` / `WorktreeRemove` hook 解掉這個兩難：它交還一份**工作區的鏡像**，

```
<工作區根>/.worktrees/<session名>/
    ├─ proj-1/     ← proj-1 真正的 git worktree
    └─ proj-2/     ← proj-2 真正的 git worktree
```

session 就站在那個鏡像目錄裡，於是 `git -C <專案>` 照樣打得到每一個專案，而所有編輯都落在各自的隔離
worktree、**沒有任何東西動到主 checkout**。離開時一次收掉整組；有未提交變更的那個**會被留下來**
（`git worktree remove` 不加 `--force`，所以這裡不可能弄丟你的修改）。移除時也會把它建立的分支一起
收乾淨——但**只在該分支沒有自己的 commit**（或它的 tip 已經被別的 ref 涵蓋）時才刪，否則保留並說明
原因。

### 工作區根自己的檔案**不會**被複製進鏡像（issue #86）

Claude Code 是**從 session 的工作目錄往上走**去找 `CLAUDE.md` 的，而鏡像位在
`<工作區根>/.worktrees/<name>`，所以 `<工作區根>/CLAUDE.md` 是它的祖先目錄、**本來就會被載入**。
複製一份進鏡像反而會讓同一段內容在 context 裡出現兩次；而只要有人改了副本，就變成**兩個版本同時載入**，
Claude 會在互相矛盾的指示之間任意挑一個。

代價要講明白:**背景隔離 session 改不了工作區根的檔案**（隔離守衛擋下 `Edit` / `Write`，而且它是純
路徑判斷、不看那個檔有沒有進版控）。那類編輯請在**沒有被隔離的 session** 進行。

> **也不要靠腳本繞過去。** 守衛只攔 `Edit` / `Write` / `NotebookEdit` 與命令的**工作目錄**，
> 所以一支 shell script 目前確實寫得進去——但那是守衛的縫，不是官方通道，而 Claude Code 正在收緊
> 這一塊（「command shape」那道檢查已經在擋無法靜態驗證的命令）。把行為建在那上面,補起來就會壞。

### 工作區的形狀是「宣告」的，不是猜的

hook 判斷「這是不是多專案工作區」是看 `<工作區根>/CLAUDE.md` 裡有沒有 `tp-multi-repo-workspace-setup`
寫下的標記，**不是**看「根目錄是不是 git repo」。後者是原本的做法，而它的失效方式是靜默的：只要有人
在工作區根 `git init`（正是 setup skill 一再警告、而且「事後沒有東西能還原」的那個誤操作），之後每一
次隔離都只會拿到外層 repo 的一份 worktree、裡面一個專案都沒有，而且不會有任何錯誤。現在那種情況會照舊
隔離外層 repo（猜另一邊可能動到錯的樹），但會**明確告訴你專案為什麼不在裡面**。

> **⚠ 這組 hook 會接管你「所有」repo 的隔離工作副本建立，不只多專案工作區。**
> Claude Code 的規則是「只要宣告了 `WorktreeCreate`，它就取代內建行為」——實測確認在普通 git repo 裡
> 也會被呼叫。所以腳本自己處理了一般 repo 那條路徑：worktree 一樣落在 `<repo>/.claude/worktrees/<name>`、
> 一樣開新分支。**不想要這個行為的話就不要裝這個 plugin**，因為 hook 是 plugin 層級的、沒辦法只對某些
> 資料夾生效。
>
> **已知落差 ①:`.worktreeinclude` 會失效,對你的每一個 repo。** Claude Code 用它把 gitignored 的
> 檔案（`.env` 之類）自動帶進每個新 worktree,但官方文件明講:「Because the hook replaces the default
> git behavior, `.worktreeinclude` is not processed」。所以裝上這個 plugin 之後,原本靠它帶進去的檔案
> **不會再出現在 worktree 裡**,而且沒有任何提示。目前的替代方式是進 worktree 之後自己複製;讓 hook
> 自己實作 `.worktreeinclude` 已列入後續工作。
>
> **已知落差 ②**：分支基準點固定採 Claude Code 的預設語意 `fresh`（從 `origin/<主分支>` 長；沒有 origin
> 時退回 HEAD），**不讀 `worktree.baseRef` 設定**。要正確讀它得在這裡解析並合併 Claude Code 的多層
> settings，而在沒有保證存在的 JSON parser 的情況下那麼做，弄壞 hook 的機率高過幫上忙——hook 壞掉的
> 後果是「開不了隔離 session」。把 `baseRef` 設成 `head` 的人，在這裡會拿到 `fresh` 的行為。

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
