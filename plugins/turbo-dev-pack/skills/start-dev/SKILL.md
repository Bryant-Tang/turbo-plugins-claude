---
name: start-dev
description: 'Start a new bugfix or feature workflow by creating or switching to a dedicated branch and matching specs folder. Use when a new requirement needs its own bugfix/<slug> or feature/<slug> branch and corresponding specs/bugfix/<slug>/ or specs/feature/<slug>/ folder. Goal definition is handled separately by write-goal — this skill stops once the branch and specs folder are ready.'
argument-hint: 'Optional: bugfix/<slug> | feature/<slug>'
user-invocable: true
---

# Start Dev

## When to Use
- A new bug fix starts and it should live on its own `bugfix/<slug>` branch.
- A new feature starts and it should live on its own `feature/<slug>` branch.

## Outcome
- One dedicated branch name is confirmed.
- One matching specs folder exists under `specs/bugfix/` or `specs/feature/`.
- The work is ready for `write-goal` to define the requirement.

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

## Decision Rules
- If the user bundled more than one independent requirement together, split them into separate branches and separate specs folders instead of sharing one workflow.
- If an existing branch name or specs path does not match the requirement, ask whether to create a new one instead of silently reusing the wrong location.

## Completion Checks
- Branch name follows the prefix rule.
- Specs folder matches the branch slug.
- Specs folder exists at the expected path.

## Handoff

After the branch and specs folder are ready, tell the user:

> 分支與 specs 資料夾準備好了。接下來請執行 `/tdp:write-goal` 建立並討論 `goal.md`，把需求範圍、預期結果、限制、影響與驗證方向釐清到可進入規劃的程度。
