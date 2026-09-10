---
name: tp-init-svn-eol-style
description: 'One-time migration that puts svn:eol-style=native on the text files already in SVN, so the repository stores LF and every working copy gets its platform line endings. Writes to SVN and is not reversible, so run ONLY on explicit request; you may SUGGEST it, but do NOT auto-trigger. Always show the --preview output and get confirmation before applying.'
argument-hint: 'optional: --branch <name> | --preview | --batch-size <n> | --cleanup-locks'
user-invocable: true
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# tp-init-svn-eol-style

## Purpose

把 **`svn:eol-style=native`** 補到 SVN 上**已經存在**的文字檔上，讓行尾的分工變成跟
git + GitHub 一樣：**SVN 儲存 LF，而每一份工作副本拿自己平台的行尾**。

沒有這個屬性時，SVN 是原樣存、原樣取——推什麼位元組進去就存什麼。這就是同一個 repo 裡會
同時存在 LF 版和 CRLF 版檔案的原因（issue #164、#167）。

> **這支是那個「開關」**：整個 repo 只會處於兩種模式之一，而這支 skill 是唯一把它從
> 「SVN 原樣存、bridge 釘 LF」移到「SVN 正規化、每份工作副本依平台」的動作。跑過之後，
> `/tp-push-to-svn` 會自動替新檔案補屬性；**在那之前它什麼都不會標記**——只標記一部分檔案
> 會讓 bridge 的兩側對不上而永久顯示為已修改。

## 這支會寫入 SVN

它會做**一次 SVN commit**（內容只有屬性變更）。SVN 的歷史不可逆，所以：

- **一定要先跑 `--preview` 給使用者看**，取得明確同意之後才實際執行。
- 預覽裡最需要人看的是**行尾混雜的檔案清單**（見下方 Decision Rules）。

## Procedure

1. **先確定要對哪個 repo 動手**——讀 `${CLAUDE_PLUGIN_ROOT}/assets/repo-target.md`，依它的
   判準決定要不要帶 `-RepoRoot` / `--repo-root`。當前目錄自己不是 repo、底下卻並排著多個
   repo 時**必須先問使用者是哪一個**再指名。跑之前**用白話講出要動的專案絕對路徑**。

2. **先跑預覽**（不會改動任何東西）：

   Windows：
   ```
   powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/Initialize-SvnEolStyle.ps1" -Preview [-Branch <name>] [-RepoRoot <path>]
   ```

   其他平台：
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/initialize-svn-eol-style.sh" --preview [--branch <name>] [--repo-root <path>]
   ```

   **預覽被工作副本鎖擋下時**（訊息會說 `stale working-copy lock(s)`）：那是上一次提交被中斷
   留下的,而在清掉之前**任何 svn 操作都會被拒絕**。用 `AskUserQuestion` 問使用者要**由指令
   自己清**（重跑時加 `--cleanup-locks` / `-CleanupLocks`）**還是他自己在 bridge 跑
   `svn cleanup`**。兩者都只動本機、不碰 SVN，但那仍然是他沒明講的狀態變更,所以要問過。

3. **把預覽結果原樣講給使用者聽**：會標記幾個檔、跳過幾個二進位檔、跳過幾個行尾混雜的檔，
   以及**混雜檔案的完整清單**。然後在**同一次** `AskUserQuestion` 裡問完三件事：

   - **要不要執行**（這是寫入 SVN、且不可逆的那一步，必須明確同意）。
   - **分批大小**。預設每批 1000 個檔，會切成多筆修訂送出。講白話說明為什麼要分批：整棵樹
     一次送出時，伺服器端會在「正在提交」那一步逾時，而**逾時的意思是「沒有回應」、不是
     「沒有提交」**，事後很難判斷到底成功了沒。切小之後每批很快就做完，中途失敗也只影響那一批，
     已經送出去的不會白做。要調整就把數字帶進 `--batch-size` / `-BatchSize`。
   - **行尾混雜的檔案要不要統一**（只在預覽有列出來時問）。**答「要」也不要自己改內容**——
     這件事做不到「在這一輪裡走完」，而且在主 worktree 上根本產不出可以 commit 的變更
     （git 的 blob 本來就已經是純 LF，混雜只存在於工作副本的位元組裡）。告訴使用者：這需要在
     bridge 上動內容、再經由正常的推送流程送出，目前是獨立的一項待處理工作。答「不要」就照舊
     把它們排除、維持現有行尾。

4. 同意之後，拿掉 `--preview` / `-Preview` 再跑一次，並帶上第 3 步談定的 `--batch-size`
   （沒特別談就不帶，用預設值）。

5. 回報實際標記了幾個檔、送出了幾批、以及有沒有檔案被留在外面。

## Decision Rules

- **行尾混雜的檔案會被永久排除，而且要講清楚。** 設了 `svn:eol-style` 之後，SVN 會**拒絕
  commit** 行尾混雜的檔案（錯誤碼 `E135000`）。而 SVN 的 commit 是不可分割的——漏掉一個就
  整批失敗。這些檔案因此被排除、維持它們現有的行尾。要讓它們也被涵蓋，得**先在 git 這側把
  行尾正規化**再重跑這支。這件事事後在任何地方都看不出來，所以預覽階段一定要講。

- **二進位檔絕不會被標記。** 掛了這個屬性，SVN 會去 translate 不是換行的位元組，檔案會損毀。
  判準用 git 自己的（`git ls-files --eol`），因為在這個流程裡 git 本來就是內容的源頭。

- **bridge 兩側都必須乾淨**才會執行。這顆 commit 應該只含屬性變更；待處理的工作會被掃進去，
  而純屬性的修訂正是拉取路徑會跳過的那種——搭便車進去的東西會到達 SVN 而**永遠回不到 git**。
  遇到這個錯誤時，先請使用者處理掉待處理的變更，**不要**自己去 revert 或 commit。

- **重複執行是安全的。** 把屬性設成它已經有的值對 SVN 而言不算變更，所以第二次跑會回報
  「沒有東西要做」。

- **兩種失敗要用不同的話講，因為本機狀態相反。**
  - **屬性設不上去**（常見成因：某個檔案被 SVN 標成 `svn:mime-type=application/octet-stream`，
    那種檔案設不了 `svn:eol-style`；`svn` 的錯誤訊息會指出是哪一支）：腳本會**自己還原**已經
    暫存的屬性變更，bridge 回到執行前的樣子。轉述時就照這樣講——**不要**叫使用者去 revert。
    要繼續的話，得先處理那支檔案（例如在 bridge 對它 `svn propdel svn:mime-type`），再重跑。
  - **commit 失敗**：屬性變更**刻意留著**，因為重跑只需要重送 commit、不必重設上萬個屬性。
    分批之後訊息會講明失敗在第幾批，**在那之前的批次都已經送出去了、不受影響**。

    如果是逾時（`E175012`），**這是「不確定」的狀態,不是「失敗」的狀態**,而且**當下查不出來**:
    大筆 transaction 可能在伺服器停止回應之後才做完。實際發生過——腳本回報失敗、立刻查發現
    路徑沒動、兩小時後那條路徑上出現的正是腳本自己寫的那則提交訊息。所以轉述時要照這個順序:

    1. **先不要下結論,等幾分鐘。**
    2. 再去看**這條分支路徑**最新的一筆 log（不要看版本庫 HEAD——修訂號是整個版本庫共享的，
       別人提交不相干的路徑一樣會讓 HEAD 前進）。**認的是提交訊息**:開頭是
       `Set svn:eol-style=native` 就是這支指令寫的。
    3. **在確定之前絕對不要叫使用者 `svn revert`**——那會丟掉一份可能還需要的 pending，
       重做要把上萬個屬性再設一次。

    腳本的訊息裡已經帶了正確的指令與順序，照著轉述即可。

- **不要自動觸發。** 可以在使用者提到行尾不一致、或 push 出現大量純行尾差異時**建議**它，
  但實際執行一律要使用者明講。

- **全新的 repo 用不到這支。** `/tp-setup` 接上一個**全新**的 SVN 樹時就已經把 `svn:eol-style`
  宣告下去了，所以那種 repo 從第一筆提交起就是對的。跑這支只會回報「沒有東西要做」。
  這支是給**接管既有 SVN 樹**的情況——那裡才有一堆既存檔案的行尾要決定。

## Completion Checks

- 預覽的輸出**完整轉述**給使用者了，包含混雜檔案的清單。
- 使用者對「要寫入 SVN」這件事給了明確同意。
- 實際執行後回報了標記的檔案數，以及被留在外面的檔案數。
- 若腳本因為 bridge 不乾淨而中止，**沒有**自行嘗試繞過那道守門。
