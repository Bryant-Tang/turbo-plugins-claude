---
name: tp-multi-repo-workspace-setup
description: 'Set up a workspace holding several independent git repos side by side: inject a root CLAUDE.md (each subfolder is its own repo, read its CLAUDE.md first, never commit across projects), then optionally run each subproject''s git<->SVN setup. Run on request; you may SUGGEST it when the current directory is not a repo but subdirectories are, but **do NOT auto-trigger** -- it writes CLAUDE.md.'
argument-hint: 'optional: --workspace-root <path>'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-multi-repo-workspace-setup

## Purpose

使用者的工作區長這樣:

```
proj-root/            ← 本身不是 git repo;session 開在這裡
├─ proj-1/            ← 獨立 git repo（自己的 CLAUDE.md / SVN 路徑 / 資料庫）
├─ proj-2/            ← 獨立 git repo
└─ …
```

在這裡開 session 的好處是能同時看多個專案(跨專案讀取今天就能做,Read / Grep 不看 repo 邊界);
代價是 agent **推導不出**兩件事,而使用者也無從得知該怎麼告訴它:

1. 子資料夾的 `CLAUDE.md` 雖然會被自動發現,但是**延遲載入**——只在讀到該目錄底下的檔案時才進
   context,而且 **`/compact` 之後不會自動回來**(根目錄的會)。所以「還沒讀檔就開始規劃」時,
   那個專案的規範根本不在手上。
2. 這些子資料夾**各自是獨立 repo**。這件事沒寫下來就推導不出來,後果是跨專案一起 commit,
   或更糟——在工作區根 `git init`,把所有專案包成一個 repo(事後沒有東西能還原)。

本 skill 把這些寫進工作區根的 `CLAUDE.md`,並可逐一(**一次一個、各自確認**)帶著明確的專案路徑
去跑各子專案的 git↔SVN setup。

> **工作區根的 `CLAUDE.md` 不在任何 repo 裡**,所以它不進版控、不會跟著傳給同事。每個人在自己的
> 工作區各跑一次本 skill 即可。

## Procedure

### Step 0 — 執行路由

依環境選工具(**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**):
- Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
- Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`(**單破折號參數 `-WorkspaceRoot`**;GNU 風格
  `--workspace-root` 在 `powershell -File` 下不可靠)。
- Linux / macOS → 用 **Bash 工具**跑 `.sh`。

Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;
都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL)。

### Step 1 — 探測工作區

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-WorkspaceProjects.ps1" [-WorkspaceRoot <path>]
```
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-workspace-projects.sh" [--workspace-root <path>]
```

腳本唯讀,輸出零到多行 `PROJECT ...` 資料行,最後一行是**唯一**的 `TP_TOKEN:` 終結 token。
**只認以 `TP_TOKEN:` 開頭的行**(子資料夾名稱內嵌的假 token 已被腳本消毒),且**不要自己跑 git 判斷**:

- `TP_TOKEN:PROJECTS count=<N>` → 找到 `<N>` 個專案,進 Step 2。資料行格式
  `PROJECT setup=<yes|no> main=<yes|no> path=<絕對路徑>`;**`path=` 一定是最後一個欄位**,所以
  「`path=` 之後到行尾」就是完整路徑(含空白),不需要再拆。
- `TP_TOKEN:WORKSPACE_IS_REPO path=<p>` → 這個資料夾**本身就是**一個 git repo(或位在某個 repo 底下),
  不是多專案工作區。用白話說明,並建議直接用 `turbo-plugin-git-svn` 的 setup;**結束 skill,什麼都不寫**。
- `TP_TOKEN:NO_PROJECTS path=<p>` → 這裡沒有含 `.git` 的子資料夾。用白話回報並問使用者是不是想指定
  別的資料夾(可用 `--workspace-root`);**結束 skill,什麼都不寫**。
- `TP_TOKEN:ERROR reason=<訊息>` → 把 `reason` 原文顯示給使用者並**結束 skill,什麼都不寫**。
- (防呆)非零 exit 且完全沒有 `TP_TOKEN:` 行 → 顯示 stderr 並結束,不要臆測路由。

### Step 2 — 用白話呈現探測結果並確認

先用純文字列出要動的工作區與找到的專案,再 `AskUserQuestion`:

```
工作區:<絕對路徑>
找到 3 個專案:
  proj-1  （尚未設定）
  proj-2  （已設定過）
  proj-3  （這是別的 repo 的附屬工作目錄，會跳過）
```

對照關係(**不要**把 `setup=` / `main=` / token 名這些內部字眼丟給使用者):

| 資料行 | 白話 |
|---|---|
| `setup=no main=yes` | 尚未設定 |
| `setup=yes main=yes` | 已設定過 |
| `main=no` | 這是別的 repo 的附屬工作目錄,會跳過 |

`AskUserQuestion` 二選一:**「為這個工作區做設定」** / **「取消」**。取消 → 結束,什麼都不寫。

> `main=no` 的項目是某個 repo 的 linked worktree,不是獨立專案。git↔SVN 的 setup 會拒絕在那裡建立
> 橋接,所以本 skill **不對它提供設定選項**,只在清單裡說明會跳過。

### Step 3 — 注入工作區根的 `CLAUDE.md`（idempotent）

讀 `${CLAUDE_PLUGIN_ROOT}/skills/tp-multi-repo-workspace-setup/assets/claudemd-workspace-snippet.md`,
用標記包夾後寫進 `<工作區根>/CLAUDE.md`:

```
<!-- turbo-plugin:begin multi-repo-workspace -->
（snippet 內容）
<!-- turbo-plugin:end multi-repo-workspace -->
```

程序(與其它 turbo-plugin 的標記慣例一致):

- 檔案不存在 → 用 Write 建立一個只含這組標記與內容的 `CLAUDE.md`。
- 檔案存在且**已含**這對標記 → 用 Edit 把**兩個標記之間**的內容取代成新的 snippet(標記本身保留)。
- 檔案存在但**沒有**這對標記 → 用 Edit 在**檔尾追加**一組標記 + 內容。

**絕不**改動標記以外的內容,也**絕不**動別的 `turbo-plugin:*` 標記區塊。用 Read / Write / Edit 做,
不要用 shell 重導向拼檔。

**不要在 snippet 裡加上子專案清單**,也不要加各專案的資料庫 / SVN 路徑 / 專屬規範——snippet 自己就寫了
為什麼不能加(過期的清單比沒有清單更糟)。要照抄 snippet,不要「順手補上」。

### Step 4 — 逐一詢問要不要跑各子專案的 setup（一次一個）

只對 Step 1 回報 `main=yes` 的專案提供;**一個專案一個 `AskUserQuestion`,答完一個才問下一個**。

每一輪:

1. `AskUserQuestion`,白話說明這會對**哪一個**專案做什麼——第一行是**要動的專案絕對路徑**:

   ```
   要動的專案：<絕對路徑>
   ```

   `setup=no` → 「這個專案還沒接上 SVN,要現在設定嗎?」;`setup=yes` → 「這個專案已經設定過了,
   要再檢查 / 補齊設定嗎?」。選項:**設定這個專案** / **跳過這個** / **這裡就停下**。
2. 選「設定這個專案」→ **委派給 `turbo-plugin-git-svn` 的 setup skill**(`/turbo-plugin-git-svn:tp-setup`
   ——**必須帶 plugin 前綴**,因為 `tp-setup` 這個名字有多個 plugin 都有),並明確告訴它**目標專案的
   絕對路徑**,由它自己走 `--repo-root`。**不要**自己去呼叫 `Initialize-GitSvnBridge` 或自己下 git / svn
   指令:SVN URL、git 身分、匯入粒度、base 骨架、編碼偵測全都由那支 skill 負責,自己複製一份必然會漂移。
3. 那支 skill 結束後回來問下一個專案。中途失敗 → 回報它的訊息,問使用者要不要繼續問下一個專案還是停下。
4. 選「跳過這個」→ 直接問下一個;選「這裡就停下」→ 結束 skill(`CLAUDE.md` 已寫入的部分保留,
   那是 idempotent 的)。

### Step 5 — 收尾回報

用白話講三件事:工作區根的 `CLAUDE.md` 已寫入哪一段、哪些專案做了設定 / 跳過、以及**這個 `CLAUDE.md`
不在任何 repo 裡所以不會傳給同事,每個人要在自己的工作區各跑一次**。

## Decision Rules

- **絕不對工作區根 `git init`**,也不要建議使用者這麼做。這是本 skill 存在的原因之一。
- **一次一個專案、各自確認**。不要「一鍵全部設定」——setup 是破壞性最高的操作(會建 repo、會寫 SVN),
  批次化會讓使用者失去逐個核對目標的機會。`--repo-root` 讓「在對哪個 repo 動手」變明確,但它是
  **前提**、不是批次化的許可。
- **子專案的 setup 一律委派給 `/turbo-plugin-git-svn:tp-setup`**,並帶 plugin 前綴(`tp-setup` 這個
  skill 名有多個 plugin 都有,不帶前綴會呼叫到別的 plugin)。
- **`main=no` 的項目不提供設定**(是別的 repo 的 linked worktree,git↔SVN 的 setup 會拒絕)。
- **注入的 snippet 照抄,不加專案清單**。清單會過期,而過期的清單比沒有清單更糟。
- **只動自己的標記區塊**(`multi-repo-workspace`)。標記外的內容與其它 `turbo-plugin:*` 區塊一律不碰。
- **檔案操作用 Read / Write / Edit**,不要用 Bash / PowerShell 重導向去拼 `CLAUDE.md`。
- 探測腳本是唯讀的,可以安全重跑;整個 Step 1 + Step 3 都 idempotent。
- **不自動觸發**:偵測到這種資料夾形狀時可以**建議**,但寫 `CLAUDE.md` 前必須有使用者明確同意。

## Completion Checks

- `<工作區根>/CLAUDE.md` 含且只含**一組** `<!-- turbo-plugin:begin multi-repo-workspace -->` /
  `<!-- turbo-plugin:end multi-repo-workspace -->`,內容與 asset 的 snippet 一致;標記外的原有內容未被改動。
- 重跑本 skill 不會產生第二組標記、也不會重複內容(idempotent)。
- 工作區根**沒有** `.git`(本 skill 不建立 repo)。
- 每個做了設定的子專案,是由 `/turbo-plugin-git-svn:tp-setup` 完成的(不是本 skill 自己下的 git / svn 指令)。
- 每一輪詢問都只涉及**一個**專案,且該輪的第一行寫出了那個專案的絕對路徑。
