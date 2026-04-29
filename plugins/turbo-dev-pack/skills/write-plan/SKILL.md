---
name: write-plan
description: 'Write plan.md from an approved goal.md into a goal-<id>/ subdirectory (where <id> is the goal id, e.g. 1, 2a, 2b, 3). Use when a requirement already has goal.md and now needs single-session implementation tasks with categorized AC, mandatory static checks, and a final build task. This skill only plans implementation; it does not produce any test-plan or test-n files — call write-test-plan separately for final verification planning after all goals are implemented.'
argument-hint: 'Optional: goal id (e.g. 1, 2a, 2b, 3) or path/to/goal.md'
user-invocable: true
---

# Write Plan

## When to Use
- A requirement already has `goal.md`.
- The next step is to create `plan.md` for one specific goal.
- The work needs explicit AC before implementation starts.
- Call this skill once per goal. Each call creates a `goal-<id>/` subdirectory (where `<id>` is the goal id from `goal.md`'s `### 進度總覽`, e.g. `goal-1/`, `goal-2a/`, `goal-2b/`, `goal-3/`) inside the spec folder and places `plan.md` there. Previous goals' subdirectories are not modified.
- Final verification planning is out of scope here — use `write-test-plan` after every goal is implemented.

## Outcome
- One target `goal.md` is identified.
- A `goal-<id>/` subdirectory is created beside `goal.md` (where `<id>` is the goal id, e.g. `1`, `2a`, `2b`, `3`).
- One `plan.md` is created inside `goal-<id>/`.

## AC Category Catalog
- Every implementation task must write AC under the full category set below, in this order.
- If a category does not apply to the current task, keep the category heading and write `N/A` plus a short reason instead of deleting the category.
- The category set is fixed so later `implement-task` review can dispatch parallel category reviewers consistently.
- Categories:
	- Correctness, Security, and Integration: business logic, data consistency, edge cases, null handling, dependency wiring, static inspection for possible compile errors, authentication, authorization, input validation, injection risk, data exposure, permission boundaries, contract compatibility, existing API behavior, database/schema/config integration, and downstream impact.
	- Maintainability, Testability, and Observability: naming, structure, separation of concerns, comment quality that follows `csharp-comment` for C# code including XML documentation comments and needed inline/block explanations, sufficiently clear Traditional Chinese comments where non-C# logic needs explanation, reuse of existing logic instead of duplicating similar code, code formatting and indentation consistency, deterministic verification points, logs, error messages, diagnosability, and whether the change can be statically or locally checked.
	- Performance, Resource Usage, and User Experience: obvious inefficient loops, queries, repeated I/O, memory pressure, unnecessary remote calls, UI wording, interaction flow, empty/error states, responsive behavior, and accessibility when the task is user-facing.

## Mandatory Static Review Baseline
- Every implementation task AC must explicitly include all of the following static checks inside the appropriate AC categories. These are **in addition to** the code formatting and indentation check required by Core Rules — both must appear in the AC.
- Correctness, Security, and Integration must statically check whether the changed code may introduce compile errors, missing references, broken signatures, type mismatches, or obvious compatibility and integration regressions.
- Maintainability, Testability, and Observability must statically check whether changed C# code follows the `csharp-comment` skill, including member XML documentation coverage, method `<param>` definitions, and needed single-line or multi-line explanatory comments for non-obvious logic.
- Maintainability, Testability, and Observability must statically check whether changed non-C# logic has sufficiently detailed Traditional Chinese comments when comments are needed for understanding.
- Maintainability, Testability, and Observability must statically check whether the same logic already exists and should be reused instead of creating duplicated code.
- Maintainability, Testability, and Observability must statically check whether the planned verification points, logs, or error signals are specific enough to diagnose failures.
- These static checks are mandatory even when the task will later be validated through runtime verification.

## Core Rules
- First determine which `goal.md` to use. If more than one candidate fits, ask the user instead of guessing.
- Then determine which specific goal id within `goal.md` to plan for this session. Goal ids follow the `<number>[<letter>]` format (e.g. `1`, `2a`, `2b`, `3`). If `goal.md` contains more than one goal and the user did not specify a goal id, ask the user which goal to plan before proceeding. Plan only the tasks for that one goal — do not mix in other goals (including sibling lettered sub-goals under the same number).
- `plan.md` tasks must stay small enough that one implementation task can finish in a single chat session.
- Every implementation task must have explicit AC.
- Every implementation task AC must be grouped by the full AC category catalog in this skill.
- Every implementation task AC must include a code formatting and indentation requirement inside `Maintainability, Testability, and Observability` so the finished code matches the repository's existing style and has no obvious formatting drift.
- Every implementation task that changes C# code must treat the `csharp-comment` skill as the required documentation comment standard.
- The final implementation task in `plan.md` must always be a dedicated build task.
- The final build task must require running the repository-standard build, capturing build failures, and fixing build errors until the build succeeds.
- Do not produce `test-plan.md`, `test-n.md`, or any final verification files in this skill. Final verification is planned separately via `write-test-plan` after every goal is implemented.

## Procedure
1. Identify the target `goal.md`. If the branch name and specs path clearly point to one file, use it. Otherwise ask the user.
2. Determine which specific goal id (e.g. `1`, `2a`, `2b`, `3`) to plan for this session. If the user passed a goal id as the skill argument, use it. If `goal.md` contains more than one goal and no goal id was given, ask the user which goal to plan before continuing.
3. Read `goal.md` and extract the scope, constraints, impact, and expected validation style for the selected goal only.
4. Create a `goal-<id>/` subdirectory beside `goal.md` (where `<id>` is the goal id determined in step 2, e.g. `goal-1/`, `goal-2a/`, `goal-2b/`). Create `plan.md` inside `goal-<id>/` from the [plan template](./assets/plan.template.md).
5. Split the implementation into ordered tasks. Keep each task narrow enough for a single chat session.
6. For each non-build implementation task, write goal, scope, AC grouped by the full AC category catalog, and completion criteria.
7. In every implementation task AC section, include an explicit acceptance criterion under `Maintainability, Testability, and Observability` that code formatting and indentation must be checked and must match the repository's existing style.
8. In every implementation task AC section, explicitly include the mandatory static review baseline so the task later checks possible compile errors, `csharp-comment` compliance for C# changes, necessary Traditional Chinese comments for non-C# logic, and duplicate-logic reuse.
9. Append one final implementation task dedicated to build execution. This task must be the last task in `plan.md` and must define the repository-standard build scope, expected success condition, and how build failures are to be fixed.
10. Surface any ambiguous assumptions that still need user confirmation.

## Decision Rules
- Keep implementation tasks aligned with the selected goal scope and do not let them drift into final verification planning.
- Keep the build task separate from feature tasks so `implement-task` can treat it as the final gate.
- If the user asks for verification tasks here, redirect them to `write-test-plan` and complete only the implementation plan in this skill.
- If the selected goal cannot reasonably fit one chat session even after reasonable task splitting, stop and direct the user back to `start-dev` (or to edit `goal.md` directly) to split the goal into more lettered sub-goals under the same number (e.g. split `2a` into a new `2a` + `2b`, renaming the original `2b` to `2c`) and update `### 進度總覽` accordingly. Do not produce an oversized `plan.md`.

## Completion Checks
- `plan.md` exists inside `goal-<id>/` and all implementation tasks have AC.
- Every implementation task AC is grouped by the full AC category catalog in this skill.
- Every implementation task AC explicitly includes static checks for possible compile errors, `csharp-comment` compliance for C# changes, necessary Traditional Chinese comments for non-C# logic, and duplicate-logic reuse.
- Every implementation task AC explicitly requires code formatting and indentation to be checked under `Maintainability, Testability, and Observability` and aligned with existing repository style.
- The final implementation task is a dedicated build task.
- No `test-plan.md` or `test-n.md` files were created in this skill.

## Templates
- [plan template](./assets/plan.template.md)
