---
date: 2026-06-19
topic: drop-svn-ignore
---

# 拿掉 svn:ignore,讓 git↔SVN bridge 只靠 .gitignore（需求）

## Summary

把 svn:ignore 從 turbo-plugin 的 git↔SVN bridge 整個拿掉,只靠 `.gitignore` 決定什麼進 SVN——bridge 本來就純看 git 決定送什麼,svn:ignore 是死資料。作為一個小的獨立 PR 在現行單體 turbo-plugin 上落地,排在「四拆計畫」之前。

---

## Problem Frame

bridge 目前同時維護 `.gitignore`(git 側)與 `svn:ignore`(SVN 側),後者還會被 propset 並 commit 到 SVN。但經 code 掃描確認:bridge 決定 `svn add`/`commit` 哪些檔案,是完全由 git 驅動(用 `git check-ignore` 過濾),svn:ignore 對 bridge 自己的 commit 零作用;`.git` 不進 SVN 是靠 `svn rm --keep-local .git`,不是 svn:ignore。svn:ignore 唯一的服務對象是「直接用純 SVN 的非-bridge 客戶端」——而使用者確認**只有 bridge 在用、沒有純 SVN 使用者**。因此 svn:ignore 是純多餘累贅,維護它(Set-SvnIgnore、tp-suggest-ignore 的 SVN 半邊、bootstrap 的 propset/commit、setup 的 svn:ignore 步驟)只是徒增複雜與「偷寫 SVN」的風險。拿掉它即達成「remote-svn 用起來跟 remote git 一樣」。

---

## Key Decisions

KD1. **svn:ignore 在此情境是死資料,移除安全。** 已驗證:bridge 的送交集合純由 `git check-ignore` 計算;`.git` 靠 `svn rm --keep-local` 排除;svn:ignore 的唯一消費者(純 SVN 客戶端)不存在(使用者確認)。

KD2. **既有 svn:ignore 屬性留著不管,不主動清。** 改完後沒有任何東西會再讀 svn:ignore,清掉只是多對 SVN 寫一筆、零效益。

KD3. **tp-suggest-ignore 保留 svn-untrack、捨棄 svn:ignore 設定半邊。** 一個剛被 `.gitignore`、但「之前已進 SVN」的檔,bridge 不會自動從 SVN 刪它,仍需明確 `svn delete --keep-local`;這個能力與 svn:ignore 無關、要留。

KD4. **先 drop、再四拆。** 先簡化再搬家:四拆要搬的 code 變少,且四拆 doc-review 的「import 偷寫 SVN」finding 從根本消失。四拆計畫隨後小幅修訂以反映簡化後的 code。

---

## Requirements

**行為**
- R1. bridge 僅靠 `.gitignore` 決定什麼進 SVN;svn:ignore 從 bridge 完全移除。送交行為本身不變(bridge 本來就 git-driven)。
- R2. bridge bootstrap 的 `svn rm --keep-local .git` 保留——是它(非 svn:ignore)把 `.git` 擋在 SVN 之外。

**移除的機制**
- R3. `Set-SvnIgnore.ps1` / `set-svn-ignore.sh` 移除,連同其測試。
- R4. `New-RemoteBridge` 移除 `svn propset svn:ignore` + `svn commit` 區塊(保留 `svn rm --keep-local .git`)。
- R5. `tp-setup` 移除 case (a) 的 svn:ignore 子步驟,以及 phase summary 中「推送 svn:ignore 到 SVN」那行。

**tp-suggest-ignore 重塑**
- R6. `tp-suggest-ignore` 保留 `.gitignore` 管理與「把已 gitignore、但仍存於 SVN 的檔以 `svn delete --keep-local` 從 SVN 移除」的能力;移除 svn:ignore 設定模式(`--add-svn`/`--remove-svn`)、「SVN Ignore」分類、以及「git/svn ignore 不一致」分類。

**不變 / 遷移**
- R7. `Build-SvnCommit` / `Submit-SvnCommit` 不變(已是 git-driven、用 `git check-ignore`)。
- R8. 既有已 bridge 的 SVN repo 裡的 svn:ignore 屬性留著 inert;無清除、無遷移步驟。

**排序**
- R9. 作為現行單體 turbo-plugin 上的小型獨立 PR 落地,排在四拆之前;四拆計畫隨後修訂以反映簡化後的 code。

---

## Scope Boundaries

**不在範圍內**
- 四拆計畫本身(獨立計畫 `docs/plans/2026-06-19-001-refactor-turbo-plugin-four-way-split-plan.md`);本案只是先落地並讓它變簡單。

**Not a goal**
- 主動清除既有 svn:ignore 屬性(KD2 已決定留著 inert)。

---

## Dependencies / Assumptions

- **載重假設**:只有 bridge 在用該 SVN repo、沒有直接用純 SVN(TortoiseSVN / svn CLI)的客戶端(使用者已確認)。若日後新增純 SVN 消費者,svn:ignore 的缺席會讓他們在 `svn status` / `svn add .` 看到 `.git`、`.turbo-plugin/worktrees/`、build 產物——屆時需重新評估。
- **已驗證事實**(code 掃描):bridge 的 `svn add`/`commit` 集合 = `svn status '?'` 減去 `git check-ignore` 命中者;`.git` 由 `svn rm --keep-local` 排除;Build/Submit-SvnCommit 全程不讀 svn:ignore。

---

## Outstanding Questions

**Deferred to Planning**
- `New-RemoteBridge` 原本「把 main 的 `.gitignore` 複製進 bridge worktree」那步,在 svn:ignore 移除後是否仍需要(它原是 svn:ignore 樣式推導的一環;bridge worktree 本就帶該分支自己的 `.gitignore`)。
- `tp-suggest-ignore` 的「Inconsistency / Un-track」分類確切重塑——哪些以 svn-untrack 形式存活、措辭與流程如何調整。

---

## Sources / Research

- code 掃描(本 session)確認的關鍵 file:line:
  - bridge 送交純 git-driven:`plugins/turbo-plugin/scripts/Submit-SvnCommit.ps1`(`git check-ignore` 過濾,git-ignored 直接 skip,約 118–145)/ `submit-svn-commit.sh`(約 121–145);`Build-SvnCommit.ps1` 約 119–154 / `build-svn-commit.sh` 約 95–108 同樣以 `git check-ignore` 分類。
  - svn:ignore 設定點:`New-RemoteBridge.ps1` 約 118–163(propset+commit;`svn rm --keep-local .git` 在 124)/ `new-remote-bridge.sh` 約 127–148;`tp-setup` SKILL.md case (a) 子步驟(svn:ignore propset);`Set-SvnIgnore.ps1` / `set-svn-ignore.sh`(整支專責 svn:ignore CRUD);`tp-suggest-ignore` SKILL.md 的 `--add-svn`/`--remove-svn` 與「SVN Ignore」分類。
  - 無證據顯示有非-bridge SVN 客戶端(README 描述為個人 bridge 工具);此為組織事實,使用者確認「只有 bridge 在用」。
- 關聯:四拆計畫 `docs/plans/2026-06-19-001-refactor-turbo-plugin-four-way-split-plan.md`(本案落地後其 import-svn:ignore finding 消失,並需小幅修訂)。
