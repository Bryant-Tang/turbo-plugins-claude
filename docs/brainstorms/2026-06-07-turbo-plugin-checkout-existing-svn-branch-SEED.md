---
title: turbo-plugin — 把 SVN 上既有分支抓下來建本機 bridge（SEED，待正式 brainstorm）
status: parked-seed
created: 2026-06-07
type: requirements-seed
target_version: 未定（v0.6.0+）
parked_from: docs/plans/2026-06-07-001-feat-turbo-plugin-v0.5.0-plan.md（F2 討論衍生）
---

# 把 SVN 既有分支抓下來建本機 bridge（SEED）

> **這不是完成的需求文件**,是 v0.5.0 plan 審查（F2）時衍生的新工作流種子,用來保存背景與待解問題,避免遺失。下次正式做這塊時,用 `/ce-brainstorm` 把本檔當輸入,先把「無中生有建 bridge」的語意談清楚再產正式 requirements。

## 為什麼抽出

v0.5.0 plan 的 F2 審查在處理「首推自動建 bridge 不該再建工作分支」時,使用者點出另一個情境:**SVN 上已有一條分支,但本機沒有對應 bridge,想把它抓下來變成本機 bridge + 工作分支**。這跟 v0.5.0 已規劃的兩個工作流都不同,是個真正的缺口,但屬全新 skill / 工作流,塞進已 18-unit 的 v0.5.0 會撐大且跳過需求審查,故抽出另談（比照 `.NET csproj` 種子的處理）。

## 三個工作流的定位（釐清缺口）

| 情境 | 現況 |
|---|---|
| 本機有分支、SVN 還沒有 → 建 SVN 端 + 推 | v0.5.0 `tp-push-to-svn` 首推 bootstrap（已規劃） |
| 已有 bridge → 把 SVN 最新內容同步下來 | 現有 `tp-pull-from-svn`（已存在） |
| **SVN 上已有分支、本機沒 bridge → 抓下來建本機 bridge + 工作分支** | ❌ 無（本種子的目標） |

現有 `tp-pull-from-svn` 只能對「已存在的 bridge」做同步,無法「無中生有」把只存在於 SVN 的分支拉下來建 bridge。

## 與 v0.5.0 push-bootstrap 的關鍵差異

- push-bootstrap（F2 修法後）:**本機分支已存在**,所以**不建**工作分支,只建 SVN 端 + bridge worktree。
- 本種子情境正好相反:**本機分支不存在**,要**從 SVN 內容反過來建出**工作分支與 bridge。

兩者方向相反,不能共用同一段邏輯,因此傾向獨立 skill（暫稱 `tp-checkout-svn-branch` / `tp-clone-svn-branch`,正式命名待定）。

## 核心待解問題（正式 brainstorm 要先回答）

1. **本機工作分支怎麼來?** 從 SVN 內容建一條同名本機工作分支?分支名如何由 SVN 路徑/`remote-svn/<branch>` 反推?
2. **若本機已有同名分支但內容不同**怎麼辦?拒絕?提示改名?還是只建 bridge 不碰工作分支?
3. **trust 檢查**:拉下來的 SVN URL 要不要過 `Assert-TrustedSvnUrl`(KTD-8)?錨點仍是 `remote-svn-main` 的 repos-root-url?
4. **要不要順便 checkout / 首次 sync?** 抓下 bridge 後是否自動接 `tp-pull-from-svn` 的 sync,還是分兩步?
5. **與 v0.5.0 `Resolve-RemoteWorktree` 一般化的關係**:bridge worktree 目錄命名、消毒、碰撞規則沿用 v0.5.0 的(`remote-svn-<branch-dash>` + allowlist + normalize-then-compare)。
6. **bridge base ref 模型**:沿用「bridge branch 起於 repo init commit、svn checkout 後再 merge」還是改直接以 SVN HEAD 為起點?

## 影響範圍（現況事實,供日後 plan 參考）

- 新 skill + 配對 `.ps1`/`.sh` script + 兩層測試（CLAUDE.md 要求）。
- 沿用 v0.5.0 完成後的 `New-RemoteBridge`(內部 helper)、`Resolve-RemoteWorktree`(一般化 + 消毒/碰撞)、`Assert-TrustedSvnUrl`。
- README skill 表格 + marketplace/plugin.json skill 數 + 人工 skill-test 套件同步。

## 下一步

v0.5.0 做完後,用 `/ce-brainstorm` 開正式討論,以本檔為輸入；先把上述待解問題談清楚再產正式 requirements。
