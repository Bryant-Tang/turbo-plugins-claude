# 這個指令要對哪個專案動手 —— 判準（給 agent 用）

> 這份檔案被 `tp-build-dotnet-framework`、`tp-run-dotnet-framework`、
> `tp-stop-dotnet-framework`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`
> 共用。**只有這一份**，改就改這裡。
>
> `turbo-plugin-git-svn` 有一份同名檔案，但**內容刻意不同**：那邊的目標是 git repo 的主
> worktree（有橋接守門、有 linked-worktree 硬拒）；這邊的目標是**專案根**，也就是放著
> `.turbo-plugin/` 的那個資料夾，跟 git 沒有必然關係（build / publish 在非 git 目錄也能跑）。
> 兩份不需要、也不應該保持一致。

## 預設：不傳，由當前目錄決定

每支腳本都收可選的 `-RepoRoot`（`.ps1`）／ `--repo-root`（`.sh`）。**不傳**時腳本就對當前目錄動手，
這是既有行為，也是單一專案 session 的正確答案——當前目錄就是那個專案。

## 什麼時候必須明確指定

**① session 開在「一個資料夾裡並排放著好幾個獨立專案」的根。** 這時當前目錄不是任何一個專案，
`.turbo-plugin/` 不在那裡，csproj 也不在那裡。**不要猜、也不要 `cd`。** 列出那些子專案、問使用者
要對哪一個動手，再用 `--repo-root` 指名。

> `cd "<專案>" && bash <腳本>` 雖然也能動，但它把「動了誰」藏在 shell 指令裡，使用者在
> 對話上看不到；指名則會出現在下面那行確認裡。

**② 使用者點名的專案不是當前目錄所在的那個。** 用 `--repo-root` 指名它。

**③ 要動的專案在另一個 git worktree 裡。** 例如 session 停在主 worktree，要建 / 發佈的卻是
`.claude/worktrees/<name>/` 底下那份（或反過來、或旁邊另一個 worktree）。這時**專案根就是那個
worktree**，用 `--repo-root "<那個 worktree 的根>"` 指名它，`--project` 寫相對於它的路徑。

> **build / publish 會直接拒跑**「`--project` 指到另一個 worktree、`--repo-root` 卻是這一個」的組合，
> 錯誤訊息會寫出該用的 worktree 根。原因：`.turbo-plugin/config.toml` 與 `[build."<路徑>"]` /
> `[publish."<路徑>"]` / `[frontend."<路徑>"]` 的分組鍵都從專案根讀、以專案根解析，目標在別的
> worktree 時分組**永遠對不到**，平台等設定會靜默落回共用值，讀到的還是另一條分支的 `config.toml`
> （issue #184：x64 專案因此用 AnyCPU 建，炸在很後面的 ASPNETCOMPILER，看起來像環境壞了）。
> 明確傳了 `--repo-root` 也一樣拒跑，不會被目標路徑靜默改寫。看到這個錯誤就照訊息改用
> `--repo-root` 重跑，並在確認行裡講出新的專案根。
>
> 只有 build / publish 有這道檢查。run / stop 本來就設計成能跨 worktree 找到同一個站台，不受影響。
>
> 目標**不在任何 git worktree 裡**、或和專案根在**同一個** worktree（專案根是 repo 裡的子資料夾）時
> 不拒跑；但若設定檔有分組而目標在專案根之外，結果模板的 `設定分組:` 行會變成**警告**——分組鍵
> 對不到那裡，多半是 `--repo-root` 指錯了。

## 會動到外部狀態的指令：動手前先把目標講出來

`run`（起 IIS Express）、`stop`、`publish`（產出可能被 CD 消費）、`cleanup-orphan-iis`（會砍程序）
在確認或回報裡加一行，用絕對路徑：

```
要動的專案：<解析出來的絕對路徑>
```

**為什麼這行是必要的**：當前目錄**是**一個合法專案、但使用者講的其實是隔壁那個專案時，什麼都不會
報錯——因為當前這個專案本身完全合法。只有「動手前把目標講出來給使用者看」能讓打錯的目標當場被看出來。

唯讀的 `Get-TargetUrl` / `Test-IisListening` 不需要這一行。

## 參數風格

`.sh` 收 `--kebab-case`（`--repo-root`、`--remove-all`），`.ps1` 收 `-PascalCase`
（`-RepoRoot`、`-RemoveAll`）。`.sh` 的 delegate 會自己轉譯，兩種風格各自在自己那邊都成立。

## 路徑格式

Windows 上使用者可能給 Git Bash 形式（`/c/Users/...`）——腳本會自己轉成 Windows 形式，不用預先處理。
路徑不存在或不是目錄時腳本直接報 `Repo root not found`，不會走到 MSBuild，也不會建立任何東西。
