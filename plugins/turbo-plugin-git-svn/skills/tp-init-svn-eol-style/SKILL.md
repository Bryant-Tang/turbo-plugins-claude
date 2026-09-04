---
name: tp-init-svn-eol-style
description: 'One-time migration that puts svn:eol-style=native on the text files already in SVN, so the repository stores LF and every working copy gets its platform line endings. Writes to SVN and is not reversible, so run ONLY on explicit request; you may SUGGEST it, but do NOT auto-trigger. Always show the --preview output and get confirmation before applying.'
argument-hint: 'optional: --branch <name> | --preview'
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

3. **把預覽結果原樣講給使用者聽**：會標記幾個檔、跳過幾個二進位檔、跳過幾個行尾混雜的檔，
   以及**混雜檔案的完整清單**。用 `AskUserQuestion` 取得明確同意。

4. 同意之後，拿掉 `--preview` / `-Preview` 再跑一次。

5. 回報實際標記了幾個檔，以及有沒有檔案被留在外面。

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

- **不要自動觸發。** 可以在使用者提到行尾不一致、或 push 出現大量純行尾差異時**建議**它，
  但實際執行一律要使用者明講。

## Completion Checks

- 預覽的輸出**完整轉述**給使用者了，包含混雜檔案的清單。
- 使用者對「要寫入 SVN」這件事給了明確同意。
- 實際執行後回報了標記的檔案數，以及被留在外面的檔案數。
- 若腳本因為 bridge 不乾淨而中止，**沒有**自行嘗試繞過那道守門。
