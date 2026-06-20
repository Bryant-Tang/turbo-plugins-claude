# tp-setup 共用 base 段（concern-neutral）

> 這份檔案是 **turbo-plugin 系列共用的 setup base 段**,被 git-svn / dotnet / db 三個 plugin 的
> `tp-setup` SKILL 引用。各 plugin 的 SKILL 會「先跑本 base 段,再跑自己的 concern 段」。
> 三個 plugin 各帶一份**內容相同**的本檔(像 `Core.{ps1,sh}` 一樣 byte-identical);修改時三份要同步。
>
> base 段**只**處理 concern-neutral 的共用檔骨架,**不**碰任何單一 concern 的設定
> (git bridge / IIS apphost / dbhub 等一律由各 plugin 的 concern 段處理)。

## Pre-check（任一失敗就停下回報,不繼續）

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/lib/Core.ps1`(PowerShell)或 `core.sh`(Bash)的
   `Probe-GitVersion` / `probe_git_version`。Git < 2.31 → fail loudly 帶升級提示。
   - 若某 plugin 該語言的 Core 不存在(例如 dotnet 只有 `Core.ps1`、無 `core.sh`,其 `.sh` 走 ps1-delegate;
     dotnet 為 Windows-only,實務上 setup 走 PowerShell 用 `Core.ps1`),退化為跑 `git --version` 自行比對 ≥ 2.31。
2. 跑 `git rev-parse --show-superproject-working-tree`。非空 → 拒跑,提示「submodule 不在
   turbo-plugin 管理範圍內,請在 superproject root 設定」。

## Marker 慣例（各 plugin 只寫自己的標記區塊,彼此不覆蓋）

共用檔用標記區塊隔開各 concern 的內容。setup 寫入時**只**動自己 concern 的區塊:

| 檔案 | 標記語法 | concern 值 |
|---|---|---|
| `.turbo-plugin/config.toml` | `# >>> turbo-plugin:<concern> >>>` … `# <<< turbo-plugin:<concern> <<<`(TOML 註解,reader 會略過) | `git-svn` / `dotnet` |
| `.turbo-plugin/conventions.md` | `<!-- turbo-plugin:begin <concern> -->` … `<!-- turbo-plugin:end <concern> -->` | `git-svn` |
| 專案根 `CLAUDE.md` | `<!-- turbo-plugin:begin base -->` … `<!-- turbo-plugin:end base -->`(只有單一 base 區塊) | `base` |

**更新自己區塊的通用程序**(idempotent):讀檔 → 若找到自己 concern 的 begin/end 標記 → 用新內容
**取代**該對標記之間的內容(標記本身保留);若找不到 → 在檔尾**追加**一組自己的 begin/end 標記
+ 內容。**絕不**動別的 concern 的標記區塊或標記外的內容。

> **併發範圍**:標記合併只保證**循序** setup 不互相覆蓋(單一維護者假設)。兩個 session 同時對同一
> 專案根跑 setup 的 read-modify-write 競態屬 out of scope。

## Base 檔骨架（idempotent,以「個別檔案是否存在」判斷,不是只看目錄）

依序確保下列 concern-neutral 共用檔存在;**每一項都先查該檔/該區塊是否已就緒,已就緒就跳過**
(故 base 段二度執行不會重寫)。各 plugin 的 concern 段稍後在自己的標記區塊內填內容。

1. **`.turbo-plugin/` 目錄** — 不存在則建立。
2. **`.turbo-plugin/config.toml`** — 不存在則複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/config.toml`
   (concern-neutral 殼:header 註解 + 空的 `git-svn` / `dotnet` 標記區塊);**已存在則不覆寫整檔**
   (concern 段稍後只更新自己的標記區塊)。
   - db plugin **不碰** config.toml(db 在 config.toml 沒有設定);db 的 base 段跳過此項。
3. **`.turbo-plugin/conventions.md`** — 不存在則複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/conventions.md`
   (base:intro + 空的 `git-svn` 標記區塊);**已存在則不覆寫整檔**。
4. **專案根 `.gitignore`** — 確保含 base 區塊(idempotent,缺則追加,不重複):
   ```
   # turbo-plugin
   .claude/**/*.local.*
   .turbo-plugin/**/*.local.*
   ```
   - git bridge 與 .NET 產物等 concern-specific 的 ignore 規則(`.turbo-plugin/worktrees/`、`.svn/`、
     `.vs/`、`bin/`、`obj/` 等)由各 plugin 的 concern 段追加,不在 base。
5. **專案根 `CLAUDE.md`** — 確保含「先讀 conventions.md」的指向區塊。注入內容(複製
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/claudemd-base-snippet.md`)用 `<!-- turbo-plugin:begin base -->`
   / `<!-- turbo-plugin:end base -->` 標記包夾:不存在則建立含該 snippet 的檔;已存在則用標記
   idempotent 取代/追加,不影響其它段落。

## Base 段不做的事（交給各 plugin 的 concern 段）

- **git init / 預設分支 / 初始 commit / `remote-svn/main` bridge / 連接歷史 / `[svn]` 設定 /
  `.commitlintrc.json` / `.svn/` ignore** → **git-svn** concern。
- **`[iis]/[build]/[publish]/[frontend]/[run]` 設定 / `applicationhost.config` / `.vs//bin//obj/` ignore /
  MSBuild / IIS Express 路徑偵測** → **dotnet** concern。
- **`dbhub.example.local.toml` / `dbhub.local.toml` / `.mcp.json`(tp-dbhub)** → **db** concern。

## Case 偵測（供各 plugin concern 段使用,固定優先序）

```
if not exist .git:                → case (a) 新建（只有 git-svn 會 git init;dotnet/db 見各自 fail-loud 規則）
elif not Test-IsMainWorktree:     → case (d) peer-mode
elif not exist .turbo-plugin:     → case (b) init-from-existing
else:                             → case (c) 補設定
```

- **Phase summary + override**:進 case 前先平實白話報告「偵測為 case (X),即將 <高階步驟>」,
  並用 `AskUserQuestion` 讓使用者「執行偵測到的 case / 改執行其他 case / 取消」。**只列「會動到外部」**
  的 unconditional 動作(如 `svn checkout` 從伺服器抓內容);純 repo-only 的本地檔寫入 / git 本地 op 不列。
