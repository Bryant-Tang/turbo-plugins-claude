---
date: 2026-06-19
topic: turbo-plugin-split
---

# 把 turbo-plugin 拆成四個獨立 plugin（需求）

## Summary

把單一的 `turbo-plugin` 拆成四個可獨立安裝的 plugin——`turbo-plugin-git-svn`、`turbo-plugin-dotnet-framework-web`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment`——全部維持 `tp-*` skill 前綴、共用同一個專案根 `.turbo-plugin/`。git-svn 另外得到一個確定性、由腳本組合的 SVN push 訊息,以及一支「把既有 SVN 分支匯入成本機 bridge」的新 skill；dotnet-framework-web 得到固定、終端可點擊的發佈路徑輸出。

---

## Problem Frame

現況 `turbo-plugin` 是單體,把三種彼此無關的關注點綁在一起:git↔SVN bridge、.NET Framework Web 建置/發佈、三環境 DB。但不是每個專案都用三環境 DB、也不是每個專案都是 .NET Framework Web。即將開工的 .NET Core + DbUp 專案只需要 git↔SVN 那塊,卻得連帶安裝整包,並在專案根產生用不到的設定與狀態。

兩個既有行為痛點也一併處理:

- **SVN push 訊息每次都不一樣**。目前 push 的 commit 訊息有很大一部分由 agent 當下摘要/改寫,導致每次推送產出的訊息結構與內容不穩定。
- **發佈路徑無法點擊**。發佈腳本其實已確定性印出完整路徑,但 agent 常把它包進散文、結尾加上「。」、或沒貼完整,導致 VS Code 終端無法連結,必須手動複製貼到檔案總管。

---

## Key Decisions

KD1. **共用核心採「各 plugin 自帶複本 + CI 一致性測試」,不採執行期共用 lib。** Claude Code 的 `${CLAUDE_PLUGIN_ROOT}` 是各 plugin 各自的版本化 cache,無法可靠 source 其它 plugin 的 script；把共用 code 放進專案根又會讓它變成可變的專案狀態(版本取決於誰最後跑 setup、且污染使用者產品 repo)。各自帶複本讓 plugin 版本鎖死行為、彼此零執行期依賴。

KD2. **每個 plugin 各自 standalone setup,互不宣告 dependency。** 任一 plugin 的 setup 都能 idempotent 建出 concern-neutral 的 base `.turbo-plugin/` 骨架,再加自己那塊。這樣才真正做到「只裝你要的」——.NET Core 專案只裝 git-svn 即可。

KD3. **舊單體 `turbo-plugin` 由四個取代,不並存。** 單一維護者情境下,並存只會造成 skill 兩套、維護加倍、使用者混淆。

KD4. **新開第四個 `turbo-plugin-code-comment` 收 C#/JS 註解慣例;`tp-commit-msg` 歸 git-svn。** 撰寫慣例與三個 concern 正交,自成一類；`tp-commit-msg` 是 git 相鄰的品質建議,放 git-svn 合理。

KD5. **SVN push 訊息改為「腳本組合 body + agent 寫 title」,並移除 type 過濾。** 腳本確定性列出所有非-merge commit 的 subject(解決「每次都不一樣」);commit 格式交回使用者自理。

KD6. **發佈路徑改用固定模板、兩種形式逐字呈現。** 同時印 raw Windows 絕對路徑與 `file:///` URL,把 agent 從格式裡拿掉,根除結尾標點/不完整的問題。

KD7. **checkout 既有 SVN 分支遇同名碰撞時「拒絕並告知」。** fail-safe,絕不覆蓋本機既有工作。

---

## Requirements

**Packaging and split**

R1. `turbo-plugin` 拆成四個各自獨立安裝的 plugin:`turbo-plugin-git-svn`、`turbo-plugin-dotnet-framework-web`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment`;各自為 `.claude-plugin/marketplace.json` 中一筆 entry,目錄為 `plugins/<plugin-name>/`。

R2. 所有 skill 跨四個 plugin 一律維持 `tp-*` 前綴。

R3. skill → plugin 對應如下:
  - git-svn:`tp-pull-from-svn`、`tp-push-to-svn`、`tp-svn-log`、`tp-reset-branch-to-main`、`tp-merge-main-into-branches`、`tp-suggest-ignore`、`tp-commit-msg`,以及新增的 checkout skill(見 R17）。
  - dotnet-framework-web:`tp-build-dotnet-framework-web`、`tp-run-dotnet-framework-web`、`tp-stop-dotnet-framework-web`、`tp-publish-dotnet-framework-web`、`tp-cleanup-orphan-iis`。
  - three-environment-db:`tp-db-management`(含 `.mcp.json` 的 `tp-dbhub` 宣告)。
  - code-comment:`tp-csharp-comment`、`tp-js-comment`。

R4. 舊的單體 `turbo-plugin` entry 與目錄移除,由四個新 plugin 取代(git 歷史留存)。

R5. 四個新 plugin 各自從 `0.1.0` 起、各自維護 CHANGELOG。

**Shared infrastructure and setup**

R6. universal core helper(讀 config、路徑正規化、worktree 解析、git 版本探測)複製進每個需要它的 plugin;新增一條 CI 檢查斷言各 plugin 的 core 複本逐字一致。

R7. concern 專屬 helper 只存在於其所屬 plugin:SVN trust/worktree 解析在 git-svn、IIS/MSBuild 在 dotnet、dbhub 在 db。

R8. 每個 plugin 的 setup 為 standalone:若 base `.turbo-plugin/` 骨架不存在則 idempotent 建立(concern-neutral),再加自己 concern 的 config/bootstrap;不宣告、也不要求其它 plugin。

R9. 四個 plugin 持續共用同一個專案根 `.turbo-plugin/` 與 `.claude/settings.local.json`;各自只寫自己的 key/section,且設定讀取器須容忍未知 section。

R10. code-comment 為純 skill plugin:無 script、不碰 `.turbo-plugin/` 狀態、無需 setup。

**git-svn: push message**

R11. SVN push 訊息的 body 由腳本確定性組合:列出 push 區間內**所有非-merge commit** 的 subject;不做 conventional-commit type 過濾,也不再對未知 type 逐筆詢問。

R12. 訊息 title(首行)由 agent 於 push 當下撰寫;body 由腳本鎖定、agent 不可改;body 以固定 header 下的 `- ` 條列呈現,預設不附短 hash。

R13. git-svn 不再強制 commit 格式;commit 風格交回使用者。`tp-commit-msg` 仍獨立對使用者自己的 `.commitlintrc.json` 檢查 commit 語意(品質建議,與 push 流程的 type 過濾是不同層,後者移除)。

R14. push 流程中對使用者的確認/詢問點一律使用固定措辭模板;最後確認提供「確認送出 / 自己改標題 / 取消」,移除會引入 agent 變異的自由「編輯訊息」迴圈。

**dotnet-framework-web: publish path**

R15. 發佈完成後以固定模板呈現路徑:同時輸出 raw Windows 絕對路徑與 `file:///` URL,各自單獨一行、結尾無標點、前後不接散文;agent 逐字轉述腳本印出的路徑行。

**git-svn: checkout an existing SVN branch**

R16. 新增 git-svn skill(暫名 `tp-checkout-svn-branch`),把只存在於 SVN 的既有分支,一步匯入成本機 `remote-svn/<branch>` bridge 加上一條已填內容的本機工作分支。

R17. 本機工作分支名預設 = SVN 分支葉名消毒後;SVN 內容於 bridge 建立時(`svn checkout`)一併抓下,不另設 sync 步驟;日後更新走既有 `tp-pull-from-svn`。

R18. 操作前以 `Assert-TrustedSvnUrl` 對目標 SVN URL 驗證,錨點為 `remote-svn-main` 的 repos-root-url。

R19. worktree 命名/消毒/碰撞沿用 `Resolve-RemoteWorktree`(`remote-svn-<branch-dash>` + allowlist + normalize-then-compare）。

R20. 若本機已有同名分支但內容不同,skill 拒絕並告知使用者,不建立任何東西(不覆蓋、不自動換名)。

**Contributor workflow (tests, docs, CI)**

R21. 每個新 plugin 各自附帶 CLAUDE.md 規定的兩層測試套件(`tests/` 慣例佈局),CI 自動探索無需改 `.yml`;repo 根 README 安裝章節與各 plugin README 同步更新為四個 plugin。

---

## Key Flows

F1. tp-checkout-svn-branch 匯入
  - **Trigger:** 使用者要為「只存在於 SVN」的既有分支建立本機 bridge + 工作分支。
  - **Steps:** 驗證目標 SVN URL 在受信任根下 → 解析 worktree 名 → 若本機同名分支內容不同則拒絕並告知 → 建 `remote-svn/<branch>` bridge 並 `svn checkout` 內容 → 建出已填內容的本機工作分支(預設名 = 消毒後 SVN 葉名)。
  - **Outcome:** 本機 bridge 與工作分支帶著 SVN 內容;後續更新走 `tp-pull-from-svn`。
  - **Covered by:** R16, R17, R18, R19, R20

F2. push 訊息組合
  - **Trigger:** `tp-push-to-svn` 準備一次推送。
  - **Steps:** 腳本列舉 push 區間 commit、排除 merge commit、把 subject 組成 `- ` 條列 body → agent 寫一行 title → 固定措辭最後確認(確認送出 / 改標題 / 取消)。
  - **Outcome:** body 確定性、title 由 agent;無 type 過濾、無逐筆詢問。
  - **Covered by:** R11, R12, R14

---

## Acceptance Examples

AE1. **Covers R11, R12.** Given 本次推送含 `feat:`、`fix:`、`refactor:` 三個 commit 與一個自動產生的 merge commit;When 組合 push 訊息;Then body 以條列列出那三個非-merge subject、merge commit 被略過,title 為 agent 寫的一行。

AE2. **Covers R11, R13.** Given 本次推送含 `docs:`、`test:`、`chore:`(舊行為會被過濾掉);When push;Then 三者全部出現在 body(不再依 type 過濾)。

AE3. **Covers R20.** Given 本機已有與目標 SVN 分支同名、但內容不同的分支;When 執行 `tp-checkout-svn-branch`;Then 拒絕並告知使用者,不建立 bridge 或工作分支。

AE4. **Covers R15.** Given 一次成功發佈;When agent 回報;Then 輸出為兩行(raw `C:\...` 路徑一行、`file:///...` URL 一行),各自單獨一行、結尾無標點、無散文包裹。

---

## Scope Boundaries

**Deferred for later**

- 新 checkout skill 的 **bridge base-ref 模型**(branch 起於 repo init commit 後 merge,或直接以 SVN HEAD 為起點)——留待 plan 期,以「與既有 bridge 一致、讓 `tp-pull-from-svn` 行為統一」為原則決定。
- 新 skill 的**最終命名**(`tp-checkout-svn-branch` vs `tp-clone-svn-branch`)。
- 另一份暫存 seed:`docs/brainstorms/2026-06-06-turbo-plugin-dotnet-csproj-vs2022-SEED.md`(.NET Core csproj / VS2022),屬獨立 brainstorm。

**Not a goal**

- 讓 dotnet-framework-web 在「完全無 git/SVN」的專案運作雖因 standalone setup 在技術上可行,但非本次目標,不為此額外設計。

---

## Dependencies / Assumptions

- 專案根 `.turbo-plugin/` 為 cwd 相對、可被多個 plugin 可靠共用(已驗證,且為現行 tgs/worktree 既有協調模式)。
- 單一 marketplace 可內含多個各自獨立安裝的 plugin(已驗證,即現行 `plugins` 陣列再加筆)。
- `${CLAUDE_PLUGIN_ROOT}` 為各 plugin 各自的版本化 cache,故不依賴跨 plugin 直接呼叫對方 script(已驗證)——這正是 KD1 採「各自帶複本」的根據。
- **不依賴** Claude Code 的 plugin-dependency 機制(四個 plugin 皆 standalone);若日後想用它做「共同安裝」便利,需先實證該機制與其版本前提(grounding 階段某 agent 給的版本號為幻覺,已排除)。

---

## Outstanding Questions

**Deferred to Planning**

- bridge base-ref 模型(見 Scope Boundaries)。
- `Common.ps1` / `common.sh` 中哪些函式屬「universal core」(複製)、哪些屬 concern 專屬(留在所屬 plugin)——需逐函式劃線。
- core 一致性 CI 檢查的實作方式(逐字比對的範圍與失敗呈現)。
- 取代舊單體時,git 歷史/blame 的保留方式(`git mv` 既有目錄成 git-svn 再抽出其餘,或全新目錄)。

---

## Sources / Research

- Seed:`docs/brainstorms/2026-06-07-turbo-plugin-checkout-existing-svn-branch-SEED.md`(本次 checkout skill 的來源,6 個待解題已在本文 R16–R20 與 Outstanding Questions 收斂)。
- 現行 push 行為(已驗證):`plugins/turbo-plugin/skills/tp-push-to-svn/SKILL.md` —— type 過濾與 5 類保留子集(113–119)、merge commit 略過(124)、未知 type 逐筆詢問(133–142）、agent 組 title(147–148);**type 過濾是 agent 在 SKILL.md 做的**,腳本只負責 git merge staging。
- 現行發佈輸出(已驗證):`plugins/turbo-plugin/scripts/Publish-Web.ps1:124-125` 已印 `Published to: <path>`(`$displayPath` 為 `file:///` 形式)與 `PUBLISH_OUTPUT_PATH=<raw absolute>`(`$resolved`);問題在 agent 散文呈現,非腳本。
- 共用 helper(已驗證存在):`scripts/lib/Common.ps1` 的 `Resolve-RemoteWorktree`(191)、`Assert-TrustedSvnUrl`(270);`common.sh` 的 `resolve_remote_worktree`(201)、`assert_trusted_svn_url`(264);`scripts/New-RemoteBridge.ps1`(獨立 script);`scripts/lib/IisHelpers.ps1`、`scripts/lib/ApplicationHostHelpers.ps1`。
- `tp-commit-msg`(已驗證):讀 repo root `.commitlintrc.json` 的 `rules.type-enum` 取有效 type,不 hard-code 清單。
- `.turbo-plugin/`(已驗證):由 `tp-setup` 在專案根建立/擁有,非 plugin cache 內;worktrees 置於 `.turbo-plugin/worktrees/`。
- marketplace 現況(已驗證):`.claude-plugin/marketplace.json` 目前恰一筆 plugin `turbo-plugin`。
