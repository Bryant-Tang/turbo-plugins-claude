---
name: write-plan-fast
description: 'Write plan.md from an approved goal.md into a goal-<id>/ subdirectory using a two-pass approach: first draft all task titles in one pass, then write all AC conditions for every task in a second pass. Use when a requirement already has goal.md and speed is preferred over iterative per-task planning. This skill only plans implementation; it does not produce any test-plan or test-n files — call write-test-plan separately for final verification planning after all goals are implemented.'
argument-hint: 'Optional: goal id (e.g. 1, 2a, 2b, 3) or path/to/goal.md'
user-invocable: true
---

# Write Plan Fast

## When to Use
- A requirement already has `goal.md`.
- The next step is to create `plan.md` for one specific goal.
- Speed is preferred: all task titles are drafted first, then all AC conditions are written in a single pass.
- Call this skill once per goal. Each call creates a `goal-<id>/` subdirectory (where `<id>` is the goal id from `goal.md`'s `### 進度總覽`, e.g. `goal-1/`, `goal-2a/`, `goal-2b/`, `goal-3/`) inside the spec folder and places `plan.md` there.
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
	- Maintainability & Code Quality（可維護性與程式碼品質）: naming, structure, separation of concerns, reuse of existing logic instead of duplicating similar code, code formatting and indentation consistency, `csharp-comment` compliance for C# code including XML documentation comments and needed inline/block explanations, `js-comment` compliance for JS/TS code (including `<script>` sections in `.vue`, `.cshtml`, and `.html` files) including JSDoc coverage and needed inline explanations, and sufficiently clear Traditional Chinese comments where neither C# nor JS/TS logic needs explanation.
	- Testability & Observability（可測試性與可觀測性）: deterministic verification points, logs, error messages, diagnosability, and whether the change can be statically or locally checked.
	- Performance & Resource Usage（效能與資源使用）: obvious inefficient loops, queries, repeated I/O, memory pressure, unnecessary remote calls, and CPU hotspots.
	- User Experience（使用者體驗）: UI wording, interaction flow, empty/error states, responsive behavior, and accessibility when the task is user-facing.

## Mandatory Static Review Baseline
- Every implementation task AC must explicitly include all of the following static checks inside the appropriate AC categories. These are **in addition to** the code formatting and indentation check required by Core Rules — both must appear in the AC.
- Integration & Compatibility must statically check whether the changed code may introduce compile errors, missing references, broken signatures, type mismatches, or obvious compatibility and integration regressions.
- Maintainability & Code Quality must statically check whether changed C# code follows the `csharp-comment` skill, including member XML documentation coverage, method `<param>` definitions, and needed single-line or multi-line explanatory comments for non-obvious logic.
- Maintainability & Code Quality must statically check whether changed JS/TS code (including `<script>` sections in `.vue`, `.cshtml`, and `.html` files) follows the `js-comment` skill, including JSDoc coverage for exported symbols and needed single-line or multi-line explanatory comments for non-obvious logic.
- Maintainability & Code Quality must statically check whether changed non-C#/non-JS/TS logic has sufficiently detailed Traditional Chinese comments when comments are needed for understanding.
- Maintainability & Code Quality must statically check whether the same logic already exists and should be reused instead of creating duplicated code.
- Testability & Observability must statically check whether the planned verification points, logs, or error signals are specific enough to diagnose failures.
- These static checks are mandatory even when the task will later be validated through runtime verification.

## Tool Preference
- For all file read, write, search, and edit operations, prefer the dedicated tools: Read, Write, Edit, Glob, Grep, and LSP diagnostics.
- Avoid using Bash, PowerShell, Python, or Node.js for file operations unless the task cannot be accomplished with the above tools.
- When invoking subagents, include an explicit instruction to follow the same tool preference rule.

## Core Rules
- If this skill is invoked outside of plan mode, call `EnterPlanMode` immediately before proceeding to any steps.
- The total number of implementation tasks in `plan.md` (excluding the final build task) must not exceed 9. Together with the mandatory final build task, the plan must have at most 10 tasks total.
- If the selected goal cannot be covered within 9 implementation tasks + 1 build task, stop immediately and ask the user to use `/tdp:write-goal` to split the goal into smaller sub-goals before proceeding.
- First determine which `goal.md` to use. If more than one candidate fits, ask the user instead of guessing.
- Then determine which specific goal id within `goal.md` to plan for this session. Goal ids follow the `<number>[<letter>]` format (e.g. `1`, `2a`, `2b`, `3`). If `goal.md` contains more than one goal and the user did not specify a goal id, ask the user which goal to plan before proceeding. Plan only the tasks for that one goal — do not mix in other goals (including sibling lettered sub-goals under the same number).
- `plan.md` tasks must stay small enough that one implementation task can finish in a single chat session.
- Every implementation task must have explicit AC.
- Every implementation task AC must be grouped by the full AC category catalog in this skill.
- Every implementation task AC must include a code formatting and indentation requirement inside `Maintainability & Code Quality` so the finished code matches the repository's existing style and has no obvious formatting drift.
- Every implementation task that changes C# code must treat the `csharp-comment` skill as the required documentation comment standard.
- Every implementation task that changes JavaScript or TypeScript code (including `<script>` sections in `.vue`, `.cshtml`, or `.html` files) must treat the `js-comment` skill as the required documentation comment standard.
- The final implementation task in `plan.md` must always be a dedicated build task.
- The final build task must require running the repository-standard build, capturing build failures, and fixing build errors until the build succeeds.
- Do not produce `test-plan.md`, `test-n.md`, or any final verification files in this skill. Final verification is planned separately via `write-test-plan` after every goal is implemented.
- The implementation plan uses a **two-pass** approach via the Plan subagent: Pass 1 produces the task title list; Pass 2 fills in all AC conditions at once. The parent agent only writes the resulting design into `goal-<id>/plan.md` using the plan template.
- Every task in `plan.md` must be an implementation task. Exploratory actions — surveying existing code, searching for relevant files, investigating the current state — are planning work and must be completed during the planning phase (before `plan.md` is written). They must not appear as tasks in `plan.md`.

## Procedure
1. Identify the target `goal.md`. If the branch name and specs path clearly point to one file, use it. Otherwise ask the user.
2. Determine which specific goal id (e.g. `1`, `2a`, `2b`, `3`) to plan for this session. If the user passed a goal id as the skill argument, use it. If `goal.md` contains more than one goal and no goal id was given, ask the user which goal to plan before continuing.
3. Read `goal.md` and extract the scope, constraints, impact, and expected validation style for the selected goal only.
4. Create a `goal-<id>/` subdirectory beside `goal.md` (where `<id>` is the goal id determined in step 2, e.g. `goal-1/`, `goal-2a/`, `goal-2b/`).
5. **(Pass 1 — Task List)** Invoke the Plan subagent (`Agent` tool with `subagent_type: "Plan"`) to draft **only the ordered task title list** (no AC conditions yet). The Pass 1 prompt must include:
   - The full goal scope, constraints, impact, and expected validation style extracted from `goal.md`.
   - The single-chat-session sizing constraint for each implementation task.
   - The requirement that the final task is a dedicated build task.
   - The task count constraint: at most 9 implementation tasks + 1 build task (10 total).
   - An explicit instruction to return **only** a numbered list of task titles — no AC, no details yet.
6. Review the Pass 1 task list. If it exceeds 9 implementation tasks (excluding the build task), re-invoke Pass 1 with the excess called out and ask the Plan subagent to consolidate or flag that the goal must be split. If the build task is missing, re-invoke Pass 1 with the gap called out.
7. **(Pass 2 — All AC Conditions)** Invoke the Plan subagent again with the confirmed task list from Pass 6 and request the **full AC conditions for every task in one pass**. The Pass 2 prompt must include:
   - The confirmed task title list from Pass 6.
   - The full AC Category Catalog from this skill (verbatim list of seven categories).
   - The Mandatory Static Review Baseline from this skill (verbatim list of static checks).
   - An explicit instruction to write all AC conditions for all tasks in one response, in order, grouped by the full AC category catalog for each task.
   - An explicit instruction that the Plan subagent returns the full structured task list (each task = title + scope + AC by full category catalog + completion criteria) but does not write any files.
8. Read the Pass 2 output. If any task is missing an AC category or missing the static review baseline items, re-invoke Pass 2 with the gaps explicitly called out instead of patching them silently.
9. Create `plan.md` inside `goal-<id>/` from the [plan template](../write-plan/assets/plan.template.md) and fill in each task with the Pass 2 design. Preserve the AC Category Catalog ordering and keep the final build task as the last entry.
10. Surface any ambiguous assumptions raised by the Plan subagent that still need user confirmation.
11. **(Plan-mode handoff)** Steps 1–10 above constitute the planning phase (always run in plan mode; if not already in plan mode, `EnterPlanMode` was called at the start). After `ExitPlanMode` grants approval:
    - Write the finalized design into `goal-<id>/plan.md` using the plan template (this is the implementation step).
    - Then **stop**. Tell the user: "`plan.md` 已寫入。建議先執行 `/compact` 清理對話脈絡，然後再執行 `/tdp:implement-task-fast` 開始實作。"

## Decision Rules
- Keep implementation tasks aligned with the selected goal scope and do not let them drift into final verification planning.
- Keep the build task separate from feature tasks so `implement-task` can treat it as the final gate.
- If the user asks for verification tasks here, redirect them to `write-test-plan` and complete only the implementation plan in this skill.
- If the confirmed task list still exceeds the 9+1 limit after consolidation attempts, stop and ask the user to use `/tdp:write-goal` to split the goal into smaller sub-goals.

## Completion Checks
- `plan.md` exists inside `goal-<id>/` and all implementation tasks have AC.
- Every implementation task AC is grouped by the full AC category catalog in this skill (all seven categories present, with N/A where not applicable).
- Every implementation task AC explicitly includes: a compile-error risk check under `Integration & Compatibility`; `csharp-comment` compliance, `js-comment` compliance, Traditional Chinese comments, and duplicate-logic reuse checks under `Maintainability & Code Quality`; and a verification-signal adequacy check under `Testability & Observability`.
- Every implementation task AC explicitly requires code formatting and indentation to be checked under `Maintainability & Code Quality` and aligned with existing repository style.
- The total task count is at most 10 (at most 9 implementation tasks + 1 build task).
- The final implementation task is a dedicated build task.
- No `test-plan.md` or `test-n.md` files were created in this skill.

## Templates
- [plan template](../write-plan/assets/plan.template.md)
