---
name: start-dev
description: 'Start a new bugfix or feature workflow for this repo. Use when a new requirement needs its own bugfix/ or feature/ branch, matching specs folder, and an initial goal.md created through user discussion before planning or coding.'
argument-hint: 'Optional: bugfix/<slug> | feature/<slug>'
user-invocable: true
---

# Start Dev

## When to Use
- A new bug fix starts and it should live on its own `bugfix/<slug>` branch.
- A new feature starts and it should live on its own `feature/<slug>` branch.
- The work does not yet have a `specs/.../goal.md`.
- The user still needs to discuss and refine the requirement before planning.

## Outcome
- One dedicated branch name is confirmed.
- One matching specs folder exists under `specs/bugfix/` or `specs/feature/`.
- A `goal.md` exists and reflects the currently agreed requirement.
- The work is ready for the next phase.
- Each goal in **修正或開發目標** is independently deliverable without depending on any other incomplete goal.
- Each goal is scoped small enough to plan and implement in a single chat session using plan mode.

## Naming And Path Rules
- Every requirement gets exactly one dedicated branch.
- Branch names must start with `bugfix/` or `feature/`.
- The slug after the prefix may contain English letters (upper and lower case), digits, and hyphens only. Spaces and other special characters are not allowed. Examples: `feature/add-payment-flow`, `bugfix/fix-login-error`.
- `bugfix/<slug>` maps to `specs/bugfix/<slug>/`.
- `feature/<slug>` maps to `specs/feature/<slug>/`.
- SQL work-item folders for this branch must use the same `<slug>`: `sql files/local-db/<slug>/`, `sql files/test-db/<slug>/`, and `sql files/main-db/<slug>/`. This allows `finish-dev` to detect and archive them automatically when the work is complete.
- Do not mix unrelated requirements in one branch or one specs folder.

## Procedure
1. Determine whether the requirement is a bug fix or a feature.
2. Determine the branch slug. If the slug is ambiguous, ask the user before creating or reusing any branch or specs path.
3. Confirm the intended branch name. If the user asked to start the work and the working tree is safe, create or switch to that branch. If the working tree is not safe, stop and explain the blocker instead of forcing a branch change.
4. Create the matching specs folder if it does not exist.
5. Create `goal.md` from the [goal template](./assets/goal.template.md).
6. Discuss the requirement with the user and keep editing `goal.md` until scope, expected behavior, constraints, impact, and validation direction are clear enough for planning. While defining goals in **修正或開發目標**, validate each one:
   - **Independently deliverable**: the goal can be merged or demonstrated on its own without relying on other incomplete goals.
   - **Session-scoped**: small enough to plan and fully implement in a single chat session using plan mode; if not, split it further.
   If a goal is too broad, break it into smaller goals. If goals must run in sequence, record the dependency in each goal's 依賴關係 field. Whenever goals are added, removed, renamed, or reordered, immediately update the `### 進度總覽` checklist at the top of **修正或開發目標** so that each `- [ ] 目標 N：<標題>` line matches a `### 目標 N：<簡短標題>` heading exactly. Initial checkbox state is `- [ ]`; do not pre-mark goals as completed in this skill.
7. Stop after `goal.md` is ready. Do not create `plan.md`, `test-plan.md`, `test-n.md`, or review reports in this skill. Do not hand off to any specific next skill. When `test-n.md` is created later, replace `n` with the actual verification task number.

## Decision Rules
- If the user bundled more than one independent requirement together, split them into separate branches and separate specs folders instead of sharing one `goal.md`.
- If an existing branch name or specs path does not match the requirement, ask whether to create a new one instead of silently reusing the wrong location.
- If the user is still changing scope, keep refining `goal.md`; do not jump ahead to implementation planning.
- Record confirmed facts, confirmed expectations, and open questions that materially affect implementation or verification.
- If a goal in **修正或開發目標** spans more than one major subsystem or involves unrelated changes, split it into two or more smaller goals.
- If goals have ordering dependencies, state them explicitly so that the user knows which goal to implement first.

## Completion Checks
- Branch name follows the prefix rule.
- Specs folder matches the branch slug.
- `goal.md` exists in that specs folder.
- `goal.md` is ready for the next phase.
- Each goal in **修正或開發目標** is independently deliverable.
- Each goal is scoped for one plan mode session.
- The `### 進度總覽` checklist exists at the top of **修正或開發目標**, has exactly one `- [ ] 目標 N：<標題>` entry per goal, and every entry's title text matches its corresponding `### 目標 N：<簡短標題>` heading exactly.

## Handoff

After `goal.md` is confirmed, tell the user:

> `goal.md` 已完成。接下來按目標逐一執行，完成一個目標後再進行下一個（建議從沒有依賴關係的目標開始）：
>
> **每個目標重複以下步驟：**
> 1. 開新的 chat session，使用 **plan mode** 規劃該目標的實作方式
> 2. `/tdp:write-plan` — 將計畫寫入 `plan.md`、`test-plan.md`、`test-n.md`
> 3. `/tdp:implement-task` — 透過 subagent 逐步實作並評審；所有 task 完成後會詢問你是否確認該目標完成，若是則自動把 `goal.md` 進度總覽中對應的 `- [ ]` 改為 `- [x]`
> 4. `/tdp:testing-and-proof`（可選）— 執行驗證並產出截圖或非 browser 證據，或改以人工 review 代替
>
> **所有目標完成後：**
> `/tdp:finish-dev` — 歸檔規格資料夾，完成開發
>
> 如果目標範圍或細節還需要調整，繼續在這裡討論並修正 `goal.md`，再進入下一步。

## Template
- [goal template](./assets/goal.template.md)