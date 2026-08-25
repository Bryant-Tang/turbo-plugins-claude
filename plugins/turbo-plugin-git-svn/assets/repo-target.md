# 這個指令要對哪個 repo 動手 —— 判準（給 agent 用）

> 這份檔案被 `tp-setup`、`tp-push-to-svn`、`tp-pull-from-svn`、`tp-checkout-svn-branch`、
> `tp-merge-main-into-branches`、`tp-request-merge`、`tp-suggest-ignore`、`tp-svn-log` 共用。
> **只有這一份**，改就改這裡。

## 預設：不傳，由當前目錄決定

每支腳本都收可選的 `-RepoRoot`（`.ps1`）／ `--repo-root`（`.sh`）。**不傳**時腳本從當前目錄往上找
repo，再定位到它的主 worktree。這是絕大多數情況的正確行為，也是既有行為——單一專案的 session 裡
當前目錄就是答案，多傳一步只會多一個算錯的機會。

## 什麼時候必須明確指定

**① 當前目錄自己不是 repo、但底下有多個 repo。** 這是「一個資料夾裡並排放著好幾個獨立專案」的形狀。
**不要猜。** 列出那些子目錄、問使用者要對哪一個動手，再用 `--repo-root` 指名。不指名的話每支指令都會
倒在 `not inside a git repository`——不會做錯事，但一支都不能用。

> 這個情境跟 `tp-setup` 建立橋接時的第三道守門偵測的是同一件事（見 `tp-setup` 對
> `TP_TOKEN:NESTED_GIT_REPOS` 的處理）。差別只在守門是硬擋，這裡是「先問清楚再指名」。

**② 使用者點名的專案不是當前目錄所在的那個。** 用 `--repo-root` 指名它，不要靠 `cd`。

## 限制是對「目標」的，不是對「呼叫者」的

`--repo-root` 不會放寬任何守門，只是把「要動誰」講清楚：

- 指到 linked worktree → 建立橋接時一樣被拒（守門判的是**指名的那個路徑**，不是你站在哪）。
- pull / push / svn-log 這類 → 自動落到該 repo 的主 worktree，跟不傳時從那個目錄呼叫的結果一致。

所以各 SKILL 裡「作用對象是主 worktree」講的是目標，不是要求使用者先切到某個目錄。

## 會寫入的指令：動手前先把目標講出來

`tp-setup`、`tp-push-to-svn`、`tp-pull-from-svn`、`tp-request-merge`、`tp-suggest-ignore` 的
「從 SVN 移除」本來就有確認步驟。在那個確認裡加一行，用絕對路徑：

```
要動的專案：<解析出來的絕對路徑>
```

**為什麼這行是必要的**：當前目錄**是**一個合法 repo、但使用者講的其實是隔壁那個 repo 時，三道守門
一個都不會響——因為當前這個 repo 本身完全合法。`--repo-root` 本身也救不了（沒人指名它就不會傳）。
只有「動手前把目標講出來給使用者看」能讓打錯的目標當場被看出來。

唯讀的 `tp-svn-log` 不需要這一行：誤打的代價是印錯一份 log。

## 路徑格式

Windows 上使用者可能給 Git Bash 形式（`/c/Users/...`）——腳本會自己轉成 Windows 形式，不用預先處理。
路徑不存在或不是目錄時腳本直接報 `repo root not found`，不會走到 git，也不會建立任何東西。
