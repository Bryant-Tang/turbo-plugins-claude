---
name: write-goal
description: 'Create or refine goal.md inside an existing spec folder through user discussion. Use when a branch and specs folder already exist (typically right after start-dev) and the requirement still needs scope, expected behavior, constraints, impact, validation direction, and goal numbering (with optional letter suffix for sub-goals) discussed and recorded before write-plan can run. Also use when write-plan reports a goal is still too large for one chat session and same-number sub-goals need to be re-split.'
argument-hint: 'Optional: path/to/goal.md'
user-invocable: true
---

# Write Goal

## When to Use
- Branch and specs folder already exist (typically right after `start-dev`).
- The specs folder does not yet have a `goal.md`, or the existing `goal.md` is still being discussed and revised.
- `write-plan` reports a goal is still too large for one chat session and same-number sub-goals need to be re-split.
- The user still needs to discuss and refine the requirement before `write-plan`.

## Outcome
- One target spec folder is identified.
- A `goal.md` exists at the spec folder root and reflects the currently agreed requirement.
- Goal numbering follows the `<number>[<letter>]` format (e.g. `1`, `2a`, `2b`, `2c`, `3`). The letter suffix is optional and only used when goals share the same number.
- Goals that share the same number form a delivery group: the group as a whole is independently deliverable without depending on any other incomplete number group; individual sub-goals within the group do not need to be independently deliverable on their own.
- Each individual goal (including each lettered sub-goal) is scoped small enough to plan and implement in a single chat session using plan mode.
- The `### 進度總覽` checklist exists and matches the goal headings exactly.

## Path Rules
- `goal.md` must live at the spec folder root: `specs/bugfix/<slug>/goal.md` or `specs/feature/<slug>/goal.md`.
- If more than one spec folder is a candidate, ask the user instead of guessing.
- Do not create `goal.md` inside any `goal-<id>/` subdirectory.

## Procedure
1. Identify the target spec folder. If the current branch and specs path clearly point to one folder, use it. Otherwise ask the user.
2. If `goal.md` does not yet exist, create it from the [goal template](./assets/goal.template.md). If it already exists, read the current content before continuing the discussion.
3. Discuss the requirement with the user and keep editing `goal.md` until scope, expected behavior, constraints, impact, and validation direction are clear enough for planning.
4. While defining goals in **修正或開發目標**, validate each one:
   - **Group-level deliverability**: each number group (e.g. all goals numbered `2`, including `2a`, `2b`, `2c`) is independently deliverable as a whole without relying on other incomplete number groups.
   - **Session-scoped per individual goal**: each individual goal — `1`, `2a`, `2b`, `2c`, `3`, etc. — is small enough to plan and fully implement in a single chat session using plan mode; if any single goal is too large, split it.
   - **Numbering format**: use `<number>[<letter>]` such as `1`, `2a`, `2b`, `3`. Omit the letter suffix when there is no sibling sub-goal under the same number; introduce letters only when the number is split.
5. If a single goal is too broad to fit one session, split it into more sub-goals **under the same number**, re-lettering as needed. Example: an original `目標 2a` + `目標 2b`; if `2a` is found too large, split it into a new `2a` + `2b` and rename the original `2b` as `2c`. If goals must run in sequence, record the dependency in each goal's 依賴關係 field; sub-goals within the same number group should also state same-group dependencies (e.g. `同群組 2b` or `無`). Whenever goals are added, removed, renamed, re-lettered, or reordered, immediately update the `### 進度總覽` checklist at the top of **修正或開發目標** so that each `- [ ] 目標 <編號>：<標題>` line matches a `### 目標 <編號>：<簡短標題>` heading exactly. Initial checkbox state is `- [ ]`; do not pre-mark goals as completed in this skill.
6. Stop after `goal.md` is ready. Do not create `plan.md`, `test-plan.md`, `test-n.md`, or review reports in this skill.

## Decision Rules
- If the user bundled more than one independent requirement together, do not split them inside this skill — direct the user back to `start-dev` to open separate branches and specs folders.
- If the user is still changing scope, keep refining `goal.md`; do not jump ahead to implementation planning.
- Record confirmed facts, confirmed expectations, and open questions that materially affect implementation or verification.
- If a goal in **修正或開發目標** spans more than one major subsystem or involves unrelated changes that cannot be one delivery, split it into separate **number groups** (e.g. `1` and `2`).
- If a single goal is too large for one chat session but its concern still belongs to the same delivery, split it into **lettered sub-goals under the same number** (e.g. `2a`, `2b`, `2c`).
- When `write-plan` (or plan mode) reports that a goal is still too large to fit one chat session, re-split that goal in this skill into more sub-goals under the same number, re-lettering subsequent sub-goals as needed, and refresh the `### 進度總覽` checklist accordingly.
- If goals have ordering dependencies, state them explicitly so that the user knows which goal to implement first. For sub-goals within the same number group, state same-group dependencies in 依賴關係.

## Completion Checks
- `goal.md` exists at the spec folder root.
- Goal numbering follows `<number>[<letter>]`; the letter suffix is only used when sub-goals share the same number.
- Each number group of goals (all goals sharing the same number, including any lettered sub-goals) is independently deliverable as a whole.
- Each individual goal — including each lettered sub-goal — is scoped for one plan mode session.
- The `### 進度總覽` checklist exists at the top of **修正或開發目標**, has exactly one `- [ ] 目標 <編號>：<標題>` entry per goal (with letter suffix where applicable), and every entry's title text matches its corresponding `### 目標 <編號>：<簡短標題>` heading exactly.

## Handoff

After `goal.md` is confirmed, tell the user:

> `goal.md` 已完成。接下來按目標逐一執行，完成一個目標後再進行下一個（建議從沒有依賴關係的目標開始）：
>
> **每個目標（含字母字尾的子目標）重複以下步驟：**
> 1. 開新的 chat session，使用 **plan mode** 規劃該目標的實作方式
> 2. 若 plan mode 發現該目標仍太大、無法在單一 session 內完成，回到 `/tdp:write-goal`（或直接編輯 `goal.md`）將其拆分為更多同數字子目標（例如 `2a` 拆成新的 `2a` + `2b`，原 `2b` 重新編號為 `2c`），並更新 `### 進度總覽` checklist
> 3. `/tdp:write-plan` — 將計畫寫入 `goal-<編號>/plan.md`（僅實作計畫，不含驗證）
> 4. `/tdp:implement-task` — 透過 subagent 逐步實作並評審；所有 task 完成後會詢問你是否確認該目標完成，若是則自動把 `goal.md` 進度總覽中對應的 `- [ ]` 改為 `- [x]`
>
> **所有目標完成後（可選的整體驗證流程）：**
> 5. 開新的 chat session，使用 **plan mode** 規劃整體驗證策略（涵蓋 `goal.md` 中所有目標）
> 6. `/tdp:write-test-plan` — 將測試計畫寫入 spec 根目錄的 `test-plan.md` 與 `test-n.md`
> 7. `/tdp:testing-and-proof` — 執行驗證並產出截圖或非 browser 證據；若改以人工 review 代替，可跳過 6、7 兩步
>
> **最後：**
> `/tdp:finish-dev` — 歸檔規格資料夾，完成開發
>
> 如果目標範圍或細節還需要調整，繼續在這裡討論並修正 `goal.md`，再進入下一步。

## Template
- [goal template](./assets/goal.template.md)
