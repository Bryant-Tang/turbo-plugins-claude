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
- The work is ready for `write-plan`.

## Naming And Path Rules
- Every requirement gets exactly one dedicated branch.
- Branch names must start with `bugfix/` or `feature/`.
- The slug after the prefix may contain English letters (upper and lower case), digits, and hyphens only. Spaces and other special characters are not allowed. Examples: `feature/ElderDisplayFix`, `bugfix/fix-login-error`.
- `bugfix/<slug>` maps to `specs/bugfix/<slug>/`.
- `feature/<slug>` maps to `specs/feature/<slug>/`.
- Do not mix unrelated requirements in one branch or one specs folder.

## Procedure
1. Determine whether the requirement is a bug fix or a feature.
2. Determine the branch slug. If the slug is ambiguous, ask the user before creating or reusing any branch or specs path.
3. Confirm the intended branch name. If the user asked to start the work and the working tree is safe, create or switch to that branch. If the working tree is not safe, stop and explain the blocker instead of forcing a branch change.
4. Create the matching specs folder if it does not exist.
5. Create `goal.md` from the [goal template](./assets/goal.template.md).
6. Discuss the requirement with the user and keep editing `goal.md` until scope, expected behavior, constraints, impact, and validation direction are clear enough for planning.
7. Stop after `goal.md` is ready. Do not create `plan.md`, `test-plan.md`, `test-n.md`, or review reports in this skill; hand off to `write-plan`. When `test-n.md` is created later, replace `n` with the actual verification task number.

## Decision Rules
- If the user bundled more than one independent requirement together, split them into separate branches and separate specs folders instead of sharing one `goal.md`.
- If an existing branch name or specs path does not match the requirement, ask whether to create a new one instead of silently reusing the wrong location.
- If the user is still changing scope, keep refining `goal.md`; do not jump ahead to implementation planning.
- Record confirmed facts, confirmed expectations, and open questions that materially affect implementation or verification.

## Completion Checks
- Branch name follows the prefix rule.
- Specs folder matches the branch slug.
- `goal.md` exists in that specs folder.
- `goal.md` is ready to drive `write-plan`.

## Template
- [goal template](./assets/goal.template.md)