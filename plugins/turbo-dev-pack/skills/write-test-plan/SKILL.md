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
- The overall verification strategy must first be designed by invoking the Plan subagent (`Agent` tool with `subagent_type: "Plan"`); the parent agent only writes the resulting design into `test-plan.md` and each `test-n.md` using the templates.

## Procedure
1. Identify the target `goal.md`. If the branch name and specs path clearly point to one file, use it. Otherwise ask the user.
2. Read `goal.md` (and any related `goal-<id>/plan.md` files for context) to understand the full delivered scope across all goals.
3. Invoke the Plan subagent (`Agent` tool with `subagent_type: "Plan"`) to design the overall final verification strategy. The Plan subagent prompt must include:
   - The full delivered scope summarized from `goal.md` and all `goal-<id>/plan.md` files.
   - The Verification Mode Rules from this skill (browser default, non-browser conditions, mixed mode allowed).
   - The Core Rules constraints (verification scope must cover all goals; files written at spec folder root; each task fits one chat session; every task defines evidence; browser tasks use real screenshots; non-browser tasks use file plus line links).
   - An explicit instruction that the Plan subagent returns: (a) the test-plan structure (purpose, mode split, shared prerequisites, task list, recommended order, completion criteria) and (b) for each verification task, the fields needed by the test-n template (task name, evidence type, scope, prerequisites, steps, expected result, blockers).
   - An explicit instruction that the Plan subagent does not write any files.
4. Read the Plan subagent's returned design. If it leaves any goal uncovered, mixes browser and non-browser evidence inappropriately, or skips evidence rules, re-invoke the Plan subagent with the gap explicitly called out.
5. Create `test-plan.md` at the spec folder root from the [test-plan template](./assets/test-plan.template.md) and fill it in using the Plan subagent's strategy. Replace every `test-n` placeholder with the actual verification task number.
6. For each verification task in the design, create one `test-n.md` at the spec folder root from the [test-n template](./assets/test-n.template.md), replacing `n` with the actual verification task number, and fill in the fields the Plan subagent provided.
7. If any verification task needs browser screenshots, ensure `screenshots/` is ready at the spec folder root to hold screenshot files when `testing-and-proof` runs.
8. Surface any ambiguous assumptions raised by the Plan subagent that still need user confirmation.

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
