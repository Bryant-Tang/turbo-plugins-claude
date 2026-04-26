---
name: write-plan
description: 'Write plan.md, test-plan.md, and decomposed test-n.md files from an approved goal.md. Use when a requirement already has goal.md and now needs single-session implementation tasks with categorized AC, mandatory static checks, a final build task, and final verification tasks with evidence rules. Replace the n in every test-n file name with the actual task number.'
argument-hint: 'Optional: path/to/goal.md'
user-invocable: true
---

# Write Plan

## When to Use
- A requirement already has `goal.md`.
- The next step is to create `plan.md`.
- Final verification needs to be split into `test-plan.md` plus multiple `test-n.md` files.
- The work needs explicit AC and evidence rules before implementation starts.

## Outcome
- One target `goal.md` is identified.
- One `plan.md` is created beside it.
- One `test-plan.md` is created beside it.
- One `test-n.md` file is created for each verification task listed in `test-plan.md`, and `n` must be replaced with the actual task number.

## Placeholder Rule
- Replace every `test-n` placeholder with the actual verification task number in file names and visible document text.

## AC Category Catalog
- Every implementation task must write AC under the full category set below, in this order.
- If a category does not apply to the current task, keep the category heading and write `N/A` plus a short reason instead of deleting the category.
- The category set is fixed so later `implement-task` review can dispatch parallel category reviewers consistently.
- Categories:
	- Correctness, Security, and Integration: business logic, data consistency, edge cases, null handling, dependency wiring, static inspection for possible compile errors, authentication, authorization, input validation, injection risk, data exposure, permission boundaries, contract compatibility, existing API behavior, database/schema/config integration, and downstream impact.
	- Maintainability, Testability, and Observability: naming, structure, separation of concerns, comment quality that follows `csharp-comment` for C# code including XML documentation comments and needed inline/block explanations, sufficiently clear Traditional Chinese comments where non-C# logic needs explanation, reuse of existing logic instead of duplicating similar code, code formatting and indentation consistency, deterministic verification points, logs, error messages, diagnosability, and whether the change can be statically or locally checked.
	- Performance, Resource Usage, and User Experience: obvious inefficient loops, queries, repeated I/O, memory pressure, unnecessary remote calls, UI wording, interaction flow, empty/error states, responsive behavior, and accessibility when the task is user-facing.

## Mandatory Static Review Baseline
- Every implementation task AC must explicitly include all of the following static checks inside the appropriate AC categories.
- Correctness, Security, and Integration must statically check whether the changed code may introduce compile errors, missing references, broken signatures, type mismatches, or obvious compatibility and integration regressions.
- Maintainability, Testability, and Observability must statically check whether changed C# code follows the `csharp-comment` skill, including member XML documentation coverage, method `<param>` definitions, and needed single-line or multi-line explanatory comments for non-obvious logic.
- Maintainability, Testability, and Observability must statically check whether changed non-C# logic has sufficiently detailed Traditional Chinese comments when comments are needed for understanding.
- Maintainability, Testability, and Observability must statically check whether the same logic already exists and should be reused instead of creating duplicated code.
- Maintainability, Testability, and Observability must statically check whether the planned verification points, logs, or error signals are specific enough to diagnose failures.
- These static checks are mandatory even when the task will later be validated through runtime verification.

## Core Rules
- First determine which `goal.md` to use. If more than one candidate fits, ask the user instead of guessing.
- `plan.md` tasks must stay small enough that one implementation task can finish in a single chat session.
- Every implementation task must have explicit AC.
- Every implementation task AC must be grouped by the full AC category catalog in this skill.
- Every implementation task AC must include a code formatting and indentation requirement inside `Maintainability, Testability, and Observability` so the finished code matches the repository's existing style and has no obvious formatting drift.
- Every implementation task that changes C# code must treat the `csharp-comment` skill as the required documentation comment standard.
- The final implementation task in `plan.md` must always be a dedicated build task.
- The final build task must require running the repository-standard build, capturing build failures, and fixing build errors until the build succeeds.
- Every verification task must stay small enough that one verification task can finish in a single chat session.
- Every verification task must define evidence.
- Browser-verifiable tasks must use actual system screenshots embedded directly in `test-n.md` with Markdown image syntax.
- Screenshot evidence must show the real system page only. Do not use annotated, synthetic, or manually edited images.
- Non-browser tasks must use file plus line links as evidence.

## Verification Mode Rules
- Default to browser-backed verification when the requirement affects a user-facing flow that can be reproduced locally through build, debug, and browser interaction.
- Use non-browser verification when the requirement is backend-only, static-audit oriented, environment-limited, or otherwise cannot be safely and reliably proven through the browser.
- Mixed mode is allowed. A single `test-plan.md` may contain both browser tasks and non-browser tasks.

## Procedure
1. Identify the target `goal.md`. If the branch name and specs path clearly point to one file, use it. Otherwise ask the user.
2. Read `goal.md` and extract the requirement scope, constraints, impact, and expected validation style.
3. Create `plan.md` from the [plan template](./assets/plan.template.md).
4. Split the implementation into ordered tasks. Keep each task narrow enough for a single chat session.
5. For each non-build implementation task, write goal, scope, AC grouped by the full AC category catalog, and completion criteria.
6. In every implementation task AC section, include an explicit acceptance criterion under `Maintainability, Testability, and Observability` that code formatting and indentation must be checked and must match the repository's existing style.
7. In every implementation task AC section, explicitly include the mandatory static review baseline so the task later checks possible compile errors, `csharp-comment` compliance for C# changes, necessary Traditional Chinese comments for non-C# logic, and duplicate-logic reuse.
8. Append one final implementation task dedicated to build execution. This task must be the last task in `plan.md` and must define the repository-standard build scope, expected success condition, and how build failures are to be fixed.
9. Create `test-plan.md` from the [test-plan template](./assets/test-plan.template.md).
10. Split final verification into ordered `test-n.md` tasks, replacing `n` with the actual verification task number. Do not collapse everything into one large final verification document.
11. Create one `test-n.md` file per verification task from the [test-n template](./assets/test-n.template.md), and replace `n` with the actual verification task number.
12. If any verification task needs browser screenshots, ensure the spec folder is ready to hold screenshot files under `screenshots/` when `testing-and-proof` runs.
13. Surface any ambiguous assumptions that still need user confirmation.

## Decision Rules
- If nearby spec folders already show an accepted browser-backed verification style for the same repository workflow, reuse that style instead of inventing a new one.
- If nearby spec folders already show an accepted non-browser evidence style for the same repository workflow, reuse that style when browser proof is not a realistic or meaningful success signal.
- Keep implementation tasks and verification tasks aligned, but do not force a one-to-one mapping when the final proof needs a different grouping.
- Keep the build task separate from feature tasks so `implement-task` can treat it as the final gate.
- If a verification task would require too many manual steps, split it further into additional `test-n.md` files, replacing `n` with the actual verification task number in each file.

## Completion Checks
- `plan.md` exists and all implementation tasks have AC.
- Every implementation task AC is grouped by the full AC category catalog in this skill.
- Every implementation task AC explicitly includes static checks for possible compile errors, `csharp-comment` compliance for C# changes, necessary Traditional Chinese comments for non-C# logic, and duplicate-logic reuse.
- Every implementation task AC explicitly requires code formatting and indentation to be checked under `Maintainability, Testability, and Observability` and aligned with existing repository style.
- The final implementation task is a dedicated build task.
- `test-plan.md` exists and lists the verification tasks in order.
- All referenced `test-n.md` files exist, with `n` replaced by the actual verification task number.
- Each `test-n.md` defines evidence that matches its verification mode.

## Templates
- [plan template](./assets/plan.template.md)
- [test-plan template](./assets/test-plan.template.md)
- [test-n template](./assets/test-n.template.md)