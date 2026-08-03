---
name: tp-run-dotnet-framework-web
description: 'Run a .NET Framework project locally. You pick the csproj, then dispatch on `<OutputType>`: web starts under IIS Express (health check + cross-worktree self-heal), console runs its built exe with remembered arguments. Run on request, or suggest when something needs checking by hand.'
argument-hint: '[--project <path-to-csproj>] [--timeout <seconds>] [--arguments <args>] [--working-directory <path>] [--repo-root <path>]'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-run-dotnet-framework-web

## Purpose

給 agent 用的 VS 2022「Run」。你(agent)判斷要跑哪個 `.csproj`,把明確 target 傳給變薄的 `Start-Iis`
執行器;它啟動 IIS Express 服務該專案上次的 build 產物,並處理跨 worktree project identity matching 與
listening 健康檢查。run **不涉 configuration**(服務的是已建好的產物)。

## Procedure

> **先決定要對哪個專案動手。** 讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`。
> 摘要:單一專案的 session 不必傳 `--repo-root`(維持既有行為,當前目錄就是那個專案);
> session 開在「並排放著多個獨立專案」的資料夾時,**問使用者要動哪一個、用 `--repo-root`
> 指名**,不要用 `cd` 切過去——`cd` 會把「動了誰」藏在 shell 指令裡。下面每一步的
> `.turbo-plugin/` 與 csproj 解析都以這個目標為準。

### Step 0 — 前置檢查 ([iis] enabled)

從 `.turbo-plugin/config.toml` 讀 `[iis] enabled`(預設 `true`,未設定 / 無 `[iis]` section 視為 `true`)。若為 `false` → 直接回報下方訊息給使用者並結束 SKILL 流程,**不**呼叫任何 script:

```
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
```

否則進入下方步驟。

> **這道閘只管 IIS。** `[iis] enabled = false` 的意思是「這台機器不跑 IIS Express」,與 console 專案無關——console 不碰 IIS。所以若 Step 1.5 判定是 console 專案,**忽略這道閘**繼續往下。

### Step 1 — 判斷要跑哪個 csproj

你是這個專案的 VS,由你決定 run 的對象,**不靠 script 自動偵測**。

- run 一律是**單一 csproj**(IIS Express 跑一個 web 專案),**不接受 `.sln`**。
- 先查記憶 `[run].project`(無值時 fallback 讀 `[build].project`)。有值、檔在、**且是 csproj** → 用它。
- **fallback 撈到的 `[build].project` 可能是 `.sln`(整個方案)**——run 跑的是單一 web 專案、不能跑方案。這時**別把 `.sln` 當 target**,改走下面的探索(跟「沒記憶」一樣),由你自己判斷出該跑的 web csproj。
- 沒記憶(或 fallback 撈到 `.sln`)時用 Glob 找 `*.csproj`(跳過 `bin/`、`obj/`、`node_modules/`、`.vs/`、`.git/`),判斷哪個是要在本機跑起來的 web 專案;多個合理且無從判斷 → `AskUserQuestion` 請使用者選。
- run **不要**傳 configuration——它服務的是上次 build 的產物。

### Step 1.5 — 這是 web 專案還是 console 專案?

**先分流,再往下走。** 這個 plugin 服務兩種 .NET Framework 專案,兩種的「跑起來」是完全不同的事。

判準:讀那個 csproj 的 `<OutputType>`。

| `<OutputType>` | 是什麼 | 走哪條 |
|---|---|---|
| `Exe` / `WinExe` | console 專案 | **console 路徑**(執行建置出來的 exe) |
| `Library` | 類別庫或 web 專案 | web 專案 → **IIS Express 路徑**;純類別庫 → 跑不起來,直說 |

`Library` 還要再分:web 專案的 csproj 會有 web 專案型別 GUID(`<ProjectTypeGuids>` 含
`349C5851-65DF-11DA-9384-00065B846F21`)或 `<IISUrl>` / `<DevelopmentServerPort>` 這類設定;
兩者都沒有的 `Library` 就是純類別庫,沒有東西可以跑。

**判不出來就問使用者,不要猜。** 猜錯的兩個方向都很糟:對 console 專案起 IIS 會拿到看不懂的錯誤,
對 web 專案找 exe 則永遠找不到。

### Step 2 — 啟動 IIS Express(web 專案)

跑 `${CLAUDE_PLUGIN_ROOT}/scripts/Start-Iis.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/start-iis.sh`)帶 `-Project <csproj>`、(可選)`-Timeout <seconds>`。Script 流程:

- 解析 target(CLI → `[run].project` → fallback `[build].project` → 清楚報錯;**收到 `.sln` 報錯**)
- parse `<IISUrl>` 取 port / scheme;算出**兩個**站台名——**canonical 名**(就是專案名 `<csproj-stem>`,也就是
  Visual Studio 寫進 `applicationhost.config` 的名字)與**執行期名**(`<csproj-stem>-<sha256前8字元>`,帶 project
  identity hash)。canonical 檔只用前者(可進版控、換機器不會對不上);hash 只出現在 per-launch temp 檔與
  iisexpress 命令列上,供 stop / orphan 清理辨識是哪個專案
- **`.turbo-plugin/applicationhost.config` 缺這個專案的站台就當場補上**(檔案不存在就產生一份):站台需要的
  資訊全都在 csproj 裡,不必先跑任何設定指令(Visual Studio 也是第一次執行專案時才生出這個檔)。同一份檔案
  可以放多個專案的站台,補的時候不會動到別的站台。既有內容若是 IIS Express 載不進去的形狀,會自動重建並
  保留原有站台。補完會多印一行說明,照樣轉述給使用者
  - 產生的檔以 **IIS Express 自帶的範本**為底,所以會有一千行左右——那是它真的需要的內容,不是冗餘
- 找已執行的 iisexpress.exe instance:
  - **同 port + site name 也 match(同 project,可能在別 worktree 啟)** → 自動 `Stop-Process` 舊 instance,繼續啟新
  - **同 port + site name 不 match(別 project 撞 port)** → fail loudly,提示停掉別 project 的 instance 或改 port
  - **無佔用** → 直接啟
- 渲染 per-launch temp applicationhost.config(canonical 不變,替換 physicalPath 為當前 worktree,並把站台改名成
  帶 hash 的執行期名)、以 **`-NoNewWindow`** 啟動 `iisexpress.exe`(**不可用 `-WindowStyle`**——不管 Hidden 或
  Minimized,IIS Express 都會在綁 port 前就以 exit code 0 結束;`-NoNewWindow` 既不開視窗又跑得起來)、
  polling `netstat` 直到 port LISTENING 或超時(`-Timeout` → `[run].listening_timeout_seconds` → default 30)
- 啟動失敗時會把 IIS Express **自己的訊息**一起印出來(它的 stdout/stderr 導到 per-launch log),那通常直接
  就是原因;照樣逐字轉述給使用者

### Step 2b — console 專案:執行 exe

console 走這裡,**不要**碰 IIS。跑
`${CLAUDE_PLUGIN_ROOT}/scripts/Start-Console.ps1`(或 `${CLAUDE_PLUGIN_ROOT}/scripts/start-console.sh`):
`-Project <csproj>`、(可選)`-Arguments <引數字串>`、(可選)`-WorkingDirectory <路徑>`、
(可選)`-Timeout <秒>`、(可選)`-RepoRoot <路徑>`。

- **引數與工作目錄比照 VS 存在本機**:VS 存在 `<專案>.csproj.user`(不進版控,因為那是某一個開發者的),
  我們存在 `.turbo-plugin/config.local.toml` 的 `[run]` 區塊(`arguments` / `working_directory`),
  同樣不進版控。使用者這次給的值優先。
- **多數 console 專案是一次性的**(報表、轉檔),所以腳本會等它跑完,把 stdout / stderr 與離開碼一起回報。
  超過等待時間還在跑,就回報「還在跑」與 PID,並把它記下來給 stop 用。
- **離開碼要原樣轉述**,不要看到非零就自己判斷成「壞掉了」——console 工具用離開碼表達結果是常態。

### Step 3 — 回報結果模板

腳本結尾印 `Listening on <url>` 與一行 `RUN_OUTPUT (...)` marker + 數行:**解析後的實際 target** 與 web URL(run 不涉 configuration)。把這些**逐字轉述**給使用者;URL 那行保持原樣(不接散文/句號)讓它可點擊。「解析後 target」是糾錯閘——確認跑的是不是對的專案。

### Step 4 — 記憶存回(save-back)

run 成功後,讀並遵循 `${CLAUDE_PLUGIN_ROOT}/assets/memory-save-back.md`:比對這次選定的 target 與已存記憶,有差異就問使用者要不要存。**run 存回寫 `[run].project`**(不寫 `[build]`)。run 不涉 configuration,故 save-back 只比對 target。

## Decision Rules

- **執行路由(挑 `.ps1` 還是 `.sh`)**:依環境選工具,**不要用 Bash 工具去呼叫 `pwsh` / `powershell`**——
  - Windows + 有 Git Bash → 用 **Bash 工具**跑 `.sh`。
  - Windows + 無 Git Bash → 用 **PowerShell 工具**跑 `.ps1`。
  - Linux / macOS → 用 **Bash 工具**跑 `.sh`。
  Git Bash 偵測:依序檢查 `C:\Program Files\Git\bin\bash.exe`、`C:\Program Files (x86)\Git\bin\bash.exe`;都不存在再用 `where.exe bash`,但**排除** `System32\bash.exe`(那是 WSL,不是 Git Bash)。
- **target 由你判斷、不靠 script 偵測**:要跑哪個 csproj 由你看 context / 記憶 / 必要時 `AskUserQuestion`;收到 `.sln` 報錯。
- **設定檔缺就當場補,不要叫使用者先去跑設定指令**:`applicationhost.config` 的內容完全由 csproj 推導得出,
  沒有任何要問使用者的東西。要求先跑別的指令只會變成死路(舊版錯誤訊息叫人「開 Visual Studio 複製設定檔」,
  而這個 plugin 存在的目的就是不必開 VS)。
- **跨 worktree self-heal**:同 project 在別 worktree 已啟 → 自動停舊 instance,**不**詢問使用者(這是 brainstorm 動機 bug fix)。
- **別 project 撞 port**:fail loudly,**不**自動停別 project 的 instance。
- **listening 健康檢查 incorporated 進 run**:啟完一定要驗 port 真的 LISTENING,不寫「Started PID xxx」就結束。
- **timeout 預設 30s**,可調(冷啟 + first-request JIT 場景使用者可在 `[run].listening_timeout_seconds` 設 90s)。
- run **不涉 configuration**:服務上次 build 的產物,save-back 也只記 target。

## Completion Checks

- `Started IIS Express (site: <name>, PID: <pid>)`、`Listening on <url>`、`RUN_OUTPUT` 模板都出現,且解析後 target 是預期專案。
- `netstat -ano | findstr :<port>` 顯示 `LISTENING` 狀態。
- 如果有跨 worktree self-heal 觸發,輸出含 `Stopping previous instance(s)`。
- save-back:若 target 與記憶不同,已問過使用者並寫對 `[run].project`。
- Manual: 主 worktree 跑 `Get-ProjectIdentity.ps1` 記下 IDENTITY_HASH → 切到 peer worktree 跑同一個 → 兩值完全相同。

## Test Scenarios

- **console 一次性**:對 `<OutputType>Exe` 的專案跑 run → 執行 exe、stdout 完整轉述、離開碼原樣傳回(**非零也照實講**,不要自行改判成失敗或成功)。
- **console 的引數與工作目錄**:`.turbo-plugin/config.local.toml` 的 `[run] arguments` / `working_directory` 有值時生效;使用者這次給的值優先。
- **console 常駐**:超過等待時間仍在跑 → 回報「還在跑」與 PID;接著 stop 停掉它。
- **型別判不出來**:`<OutputType>` 缺、或 `Library` 但看不出是不是 web → 問使用者,**不猜**。
- **web 專案回歸**:web 專案的 run 行為完全不變(仍走 IIS Express)。

- **Cross-worktree self-heal**: 主 worktree 跑 /tp-run 啟 iisexpress → 切到 peer worktree 跑 /tp-run,確認 (a) 舊 instance 被 Stop-Process、(b) 新 instance 啟在 peer worktree path、(c) `Started IIS Express` + `Listening on` + `RUN_OUTPUT` 都出現。
- **Port collision different project**: 啟 project A → 另開 project B 設同 port `<IISUrl>` → /tp-run project B fail loudly,不殺 A 的 instance、netstat A's port 仍 LISTENING。
- **`.sln` 被拒**: 傳 `-Project <.sln>` → script 報錯(run 需 csproj)。
- **多個 csproj、無記憶**: worktree 多個 csproj 又沒 `[run].project`/`[build].project` → 你用 `AskUserQuestion` 列候選請使用者選。
- **Listening timeout**: 設 `[run] listening_timeout_seconds = 1` → /tp-run 對啟動較慢 project 在 1s 退並提示調 timeout(.ps1 + .sh 兩條都驗)。
- **併發 run 各自站台**: 兩個不同 csproj 各自 /tp-run → 兩站台共存、各自 LISTENING。

## Tool Preference

所有檔案 read / write / search / edit(含 save-back)優先用 Read / Edit / Write / Glob / Grep;shell 操作限 `iisexpress.exe` / `netstat` / 跑 plugin script。
