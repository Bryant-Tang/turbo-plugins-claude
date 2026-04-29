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
	- Correctness（正確性）: business logic, data consistency, edge cases, null handling, and deterministic behavior.
	- Security（安全性）: authentication, authorization, input validation, injection risk, data exposure, and permission boundaries.
	- Integration & Compatibility（整合性與相容性）: dependency wiring, contract compatibility, existing API behavior, database/schema/config integration, and downstream impact.
	- Maintainability & Code Quality（可維護性與程式碼品質）: naming, structure, separation of concerns, reuse of existing logic instead of duplicating similar code, code formatting and indentation consistency, `csharp-comment` compliance for C# code including XML documentation comments and needed inline/block explanations, and sufficiently clear Traditional Chinese comments where non-C# logic needs explanation.
	- Testability & Observability（可測試性與可觀測性）: deterministic verification points, logs, error messages, diagnosability, and whether the change can be statically or locally checked.
	- Performance & Resource Usage（效能與資源使用）: obvious inefficient loops, queries, repeated I/O, memory pressure, unnecessary remote calls, and CPU hotspots.
	- User Experience（使用者體驗）: UI wording, interaction flow, empty/error states, responsive behavior, and accessibility when the task is user-facing.

## Mandatory Static Review Baseline
- Every implementation task AC must explicitly include all of the following static checks inside the appropriate AC categories. These are **in addition to** the code formatting and indentation check required by Core Rules — both must appear in the AC.
- Integration & Compatibility must statically check whether the changed code may introduce compile errors, missing references, broken signatures, type mismatches, or obvious compatibility and integration regressions.
- Maintainability & Code Quality must statically check whether changed C# code follows the `csharp-comment` skill, including member XML documentation coverage, method `<param>` definitions, and needed single-line or multi-line explanatory comments for non-obvious logic.
- Maintainability & Code Quality must statically check whether changed non-C# logic has sufficiently detailed Traditional Chinese comments when comments are needed for understanding.
- Maintainability & Code Quality must statically check whether the same logic already exists and should be reused instead of creating duplicated code.
- Testability & Observability must statically check whether the planned verification points, logs, or error signals are specific enough to diagnose failures.
- These static checks are mandatory even when the task will later be validated through runtime verification.

## Core Rules
- First determine which `goal.md` to use. If more than one candidate fits, ask the user instead of guessing.
- Then determine which specific goal id within `goal.md` to plan for this session. Goal ids follow the `<number>[<letter>]` format (e.g. `1`, `2a`, `2b`, `3`). If `goal.md` contains more than one goal and the user did not specify a goal id, ask the user which goal to plan before proceeding. Plan only the tasks for that one goal — do not mix in other goals (including sibling lettered sub-goals under the same number).
- `plan.md` tasks must stay small enough that one implementation task can finish in a single chat session.
- Every implementation task must have explicit AC.
- Every implementation task AC must be grouped by the full AC category catalog in this skill.
- Every implementation task AC must include a code formatting and indentation requirement inside `Maintainability & Code Quality` so the finished code matches the repository's existing style and has no obvious formatting drift.
- Every implementation task that changes C# code must treat the `csharp-comment` skill as the required documentation comment standard.
- The final implementation task in `plan.md` must always be a dedicated build task.
- The final build task must require running the repository-standard build, capturing build failures, and fixing build errors until the build succeeds.
- Do not produce `test-plan.md`, `test-n.md`, or any final verification files in this skill. Final verification is planned separately via `write-test-plan` after every goal is implemented.
- The implementation plan for the selected goal must first be designed by invoking the Plan subagent (`Agent` tool with `subagent_type: "Plan"`); the parent agent only writes the resulting design into `goal-<id>/plan.md` using the plan template.

## Procedure
1. Identify the target `goal.md`. If the branch name and specs path clearly point to one file, use it. Otherwise ask the user.
2. Determine which specific goal id (e.g. `1`, `2a`, `2b`, `3`) to plan for this session. If the user passed a goal id as the skill argument, use it. If `goal.md` contains more than one goal and no goal id was given, ask the user which goal to plan before continuing.
3. Read `goal.md` and extract the scope, constraints, impact, and expected validation style for the selected goal only.
4. Create a `goal-<id>/` subdirectory beside `goal.md` (where `<id>` is the goal id determined in step 2, e.g. `goal-1/`, `goal-2a/`, `goal-2b/`).
5. Invoke the Plan subagent (`Agent` tool with `subagent_type: "Plan"`) to design the implementation plan for the selected goal. The Plan subagent prompt must include:
   - The full goal scope, constraints, impact, and expected validation style extracted from `goal.md`.
   - The full AC Category Catalog from this skill (verbatim list of seven categories).
   - The Mandatory Static Review Baseline from this skill (verbatim list of static checks).
   - The single-chat-session sizing constraint for each implementation task.
   - The requirement that the final task is a dedicated build task with the repository-standard build, build-failure capture, and fix loop.
   - An explicit instruction that the Plan subagent returns a structured task list (each task = goal + scope + AC by full category catalog + completion criteria) but does not write any files.
6. Read the Plan subagent's returned design. If it is missing any AC category, missing the static review baseline, or missing the final build task, re-invoke the Plan subagent with the gap explicitly called out instead of patching it silently.
7. Create `plan.md` inside `goal-<id>/` from the [plan template](./assets/plan.template.md) and fill in each task with the Plan subagent's design. Preserve the AC Category Catalog ordering and keep the final build task as the last entry.
8. Surface any ambiguous assumptions raised by the Plan subagent that still need user confirmation.

## Decision Rules
- Keep implementation tasks aligned with the selected goal scope and do not let them drift into final verification planning.
- Keep the build task separate from feature tasks so `implement-task` can treat it as the final gate.
- If the user asks for verification tasks here, redirect them to `write-test-plan` and complete only the implementation plan in this skill.
- If the selected goal cannot reasonably fit one chat session even after reasonable task splitting, stop and direct the user back to `write-goal` (or to edit `goal.md` directly) to split the goal into more lettered sub-goals under the same number (e.g. split `2a` into a new `2a` + `2b`, renaming the original `2b` to `2c`) and update `### 進度總覽` accordingly. Do not produce an oversized `plan.md`.

## Completion Checks
- `plan.md` exists inside `goal-<id>/` and all implementation tasks have AC.
- Every implementation task AC is grouped by the full AC category catalog in this skill (all seven categories present, with N/A where not applicable).
- Every implementation task AC explicitly includes: a compile-error risk check under `Integration & Compatibility`; `csharp-comment` compliance, Traditional Chinese comments, and duplicate-logic reuse checks under `Maintainability & Code Quality`; and a verification-signal adequacy check under `Testability & Observability`.
- Every implementation task AC explicitly requires code formatting and indentation to be checked under `Maintainability & Code Quality` and aligned with existing repository style.
- The final implementation task is a dedicated build task.
- No `test-plan.md` or `test-n.md` files were created in this skill.

## Templates
- [plan template](./assets/plan.template.md)
