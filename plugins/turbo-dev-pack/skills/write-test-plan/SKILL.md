---
name: write-test-plan
description: 'Write the final overall test-plan.md and decomposed test-n.md files for an entire goal.md (covering all goals) into the spec folder root. Use when every goal has been implemented and the user wants final end-to-end verification planning. Replace the n in every test-n file name with the actual task number.'
argument-hint: 'Optional: path/to/goal.md'
user-invocable: true
---

# Write Test Plan

## When to Use
- Every goal in `goal.md` has been implemented (進度總覽 中對應的 `- [ ]` 應已勾選為 `- [x]`，包含所有帶字母字尾的子目標如 `2a`、`2b`).
- The next step is to plan the final end-to-end verification that covers the whole `goal.md`, not a single goal.
- The work needs explicit verification tasks with evidence rules before `testing-and-proof` runs.
- It is recommended to enter Claude Code's plan mode first to align on the overall verification strategy, then call this skill to materialize the strategy into files.
- Skip this skill if the user prefers to validate everything through manual review without writing a structured test plan.

## Outcome
- One target `goal.md` is identified.
- One `test-plan.md` is created at the spec folder root (the same directory as `goal.md`).
- One `test-n.md` file is created at the spec folder root for each verification task listed in `test-plan.md`, and `n` must be replaced with the actual task number.
- A `screenshots/` directory is prepared at the spec folder root if any verification task requires browser screenshots.

## Placeholder Rule
- Replace every `test-n` placeholder with the actual verification task number in file names and visible document text.

## Verification Mode Rules
- Default to browser-backed verification when the requirement affects a user-facing flow that can be reproduced locally through build, debug, and browser interaction.
- Use non-browser verification when the requirement is backend-only, static-audit oriented, environment-limited, or otherwise cannot be safely and reliably proven through the browser.
- Mixed mode is allowed. A single `test-plan.md` may contain both browser tasks and non-browser tasks.

## Core Rules
- First determine which `goal.md` to use. If more than one candidate fits, ask the user instead of guessing.
- The verification scope must cover all goals in the chosen `goal.md`, not just one goal.
- `test-plan.md` and every `test-n.md` must be written at the spec folder root, alongside `goal.md`. Do not place them inside any `goal-<id>/` subdirectory.
- Every verification task must stay small enough that one verification task can finish in a single chat session.
- Every verification task must define evidence.
- Browser-verifiable tasks must use actual system screenshots embedded directly in `test-n.md` with Markdown image syntax.
- Screenshot evidence must show the real system page only. Do not use annotated, synthetic, or manually edited images.
- Non-browser tasks must use file plus line links as evidence.

## Procedure
1. Identify the target `goal.md`. If the branch name and specs path clearly point to one file, use it. Otherwise ask the user.
2. Read `goal.md` (and any related `goal-<id>/plan.md` files for context) to understand the full delivered scope across all goals.
3. Create `test-plan.md` at the spec folder root from the [test-plan template](./assets/test-plan.template.md). The plan must cover all goals.
4. Split the final verification into ordered `test-n.md` tasks, replacing `n` with the actual verification task number. Do not collapse everything into one large final verification document.
5. Create one `test-n.md` file per verification task at the spec folder root from the [test-n template](./assets/test-n.template.md), and replace `n` with the actual verification task number.
6. If any verification task needs browser screenshots, ensure `screenshots/` is ready at the spec folder root to hold screenshot files when `testing-and-proof` runs.
7. Surface any ambiguous assumptions that still need user confirmation.

## Decision Rules
- If nearby spec folders already show an accepted browser-backed verification style for the same repository workflow, reuse that style instead of inventing a new one.
- If nearby spec folders already show an accepted non-browser evidence style for the same repository workflow, reuse that style when browser proof is not a realistic or meaningful success signal.
- Keep verification tasks aligned with the delivered behavior in `goal.md`, but do not force a one-to-one mapping with implementation tasks across `goal-<id>/plan.md` files.
- If a verification task would require too many manual steps, split it further into additional `test-n.md` files, replacing `n` with the actual verification task number in each file.

## Completion Checks
- `test-plan.md` exists at the spec folder root and lists the verification tasks in order.
- All referenced `test-n.md` files exist at the spec folder root, with `n` replaced by the actual verification task number.
- Each `test-n.md` defines evidence that matches its verification mode.
- If any task requires browser screenshots, `screenshots/` is ready at the spec folder root.

## Templates
- [test-plan template](./assets/test-plan.template.md)
- [test-n template](./assets/test-n.template.md)
