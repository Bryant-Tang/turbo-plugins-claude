---
name: implement-task
description: 'Implement plan.md tasks in order by delegating coding and categorized AC review to subagents. Use when plan.md already exists and each task should loop implement -> parallel category review reports -> read review reports until COMPLETE, while the final build task starts from build review first, where n must be replaced with the actual task number, without running final test-plan verification.'
argument-hint: 'Optional: path/to/plan.md'
user-invocable: true
---

# Implement Task

## When to Use
- A requirement already has `plan.md`.
- The next step is to execute implementation tasks in order.
- Each task must be reviewed against its AC before moving on.
- Final verification from `test-plan.md` should not run yet.
- Skip this skill and use Claude Code's plan mode directly if you did not create `plan.md` or prefer a single-session implementation without subagent review loops.

## Outcome
- One target `plan.md` is identified.
- Each implementation task is executed in order through subagents.
- Each non-build task has one review report per AC category written or overwritten by the corresponding review subagent, with `n` replaced by the actual task number.
- The final build task has its own build review report written or overwritten by the build review subagent.
- The loop stops only when the current task review says `COMPLETE`.
- After all tasks for the current goal are `COMPLETE`, the user is asked whether to confirm the goal as done. If confirmed, the corresponding `- [ ]` line in `goal.md`'s `### 進度總覽` is changed to `- [x]`. If the user defers confirmation, or any task ended as `BLOCKED`, the checkbox is left unchanged.

## Core Rules
- First determine which `plan.md` to use. If more than one candidate fits, ask the user instead of guessing.
- Do not implement the task directly in the parent agent. Use the Agent tool for each implementation attempt.
- Do not review the task directly in the parent agent. Use the Agent tool for each review attempt.
- One implementation task per implementation subagent invocation.
- One implementation task per review cycle.
- If the current task changes C# code, the implementation subagent must follow the `csharp-comment` skill and add or update the required XML documentation comments plus any needed single-line or multi-line explanatory comments accordingly.
- For non-build tasks, run parallel review subagents by AC category after each implementation attempt.
- Review categories must follow the fixed AC category catalog from `write-plan`: Correctness, Security, and Integration; Maintainability, Testability, and Observability; Performance, Resource Usage, and User Experience.
- Each review subagent must write or overwrite its own review report file. The parent agent must not consolidate or rewrite those review reports.
- If any category review report is not `COMPLETE`, the current task is not `COMPLETE`.
- If any category review report is not `COMPLETE`, run another implementation subagent for that same task, then rerun the parallel category reviews, and let each review subagent overwrite its own report file.
- Limit the implement → review loop to a maximum of 2 additional attempts after the first review (3 total attempts per task). If the task is still not `COMPLETE` after 3 attempts, mark it as `BLOCKED` and stop. Report the blocking findings to the user before proceeding to the next task.
- The final build task is special: it must start with a build-focused review subagent, not with an implementation subagent.
- The build-focused review subagent for the final task must execute the repository-standard build, identify build errors, and write its own review report before any fix attempt starts.
- The parent agent only reads review report files to decide whether to continue, retry implementation, or move on.
- Do not run the final `test-plan.md` verification in this skill.

## Review Report Location Rule
- For non-build tasks, each category review subagent must write a separate file named `task-n-<category>-review.md`, replacing `n` with the actual task number and `<category>` with a stable lowercase kebab-case category name such as `correctness-security-integration`, `maintainability-testability-observability`, or `performance-resource-ux`.
- For the final build task, the build review subagent must write `task-n-build-review.md`, replacing `n` with the actual task number.
- If the spec folder already contains task review files at its root, keep that convention at the root.
- Otherwise default to the `reviews/` folder inside the same spec folder.

## Procedure
1. Identify the target `plan.md`. If ambiguous, ask the user.
2. Read `plan.md` and `goal.md`. If `plan.md` is inside a `goal-N/` subdirectory, `goal.md` is in the parent directory.
3. Determine the ordered implementation tasks, identify the final build task, and extract the categorized AC for each task.
4. For each non-build task, invoke an implementation subagent with the task scope, files, categorized AC, an explicit instruction not to touch later tasks, and an explicit instruction that any changed C# code must follow the `csharp-comment` skill.
5. After the implementation attempt completes, invoke parallel review subagents for the current non-build task, one subagent per AC category. Each review subagent must check only its assigned category against the current task scope and AC and must write or overwrite its own review report from the [task review template](./assets/task-review.template.md).
6. The parent agent reads the category review reports only. If every category review report verdict is `COMPLETE`, move to the next task.
7. If any category review report verdict is not `COMPLETE`, feed the blocking findings from those report files back into a new implementation subagent for the same non-build task, then rerun the parallel category review subagents and let them overwrite their own report files. Do not exceed 2 additional implementation attempts after the first review (3 total); if still not `COMPLETE`, record the task as `BLOCKED` and stop.
8. For the final build task, start by invoking a build-focused review subagent instead of an implementation subagent. That review subagent must run the repository-standard build and write or overwrite `task-n-build-review.md`.
9. The parent agent reads the build review report only. If the build review for the final task is not `COMPLETE`, invoke an implementation subagent limited to fixing the reported build failures, then rerun the build-focused review subagent and let it overwrite the same build review report.
10. Repeat until the current task review reports say `COMPLETE`, then continue.
11. Stop after the planned implementation tasks are complete. Do not execute `test-plan.md` here.
12. Once every planned implementation task for the current goal is `COMPLETE` (no `BLOCKED` task remaining), use `AskUserQuestion` to ask the user whether to confirm this goal as done. If the user confirms, read `goal.md`, locate the `- [ ] 目標 N：<標題>` line in `### 進度總覽` matching the goal that was just implemented, and use Edit to change `[ ]` to `[x]`. If the user defers confirmation, leave the checkbox unchanged and tell the user it stays unchecked until they confirm later. If any task ended as `BLOCKED`, skip the question entirely, leave the checkbox unchanged, and surface the blocking findings.

## Decision Rules
- If a task is too large for a single chat session, stop and revise `plan.md` first instead of silently doing a mega-task.
- Category reviewers must judge the task only against the current category AC and current scope, not against future tasks.
- Preserve existing user changes outside the current implementation scope.
- When C# files are in scope, treat `csharp-comment` as a required implementation rule rather than an optional polish item.
- If a previous category review file already exists but the code changed afterward, the same category review subagent must overwrite it with a fresh review instead of appending stale conclusions.
- The final build task review may execute build commands, but it must not drift into final `test-plan.md` verification.
- If any task in the current goal ended as `BLOCKED`, do not ask the user about the progress checkbox and do not modify `goal.md`'s `### 進度總覽`; report the blocking findings instead.
- Never silently flip a `### 進度總覽` checkbox to `[x]` without an explicit user confirmation in the same session.

## Completion Checks
- Every completed non-build task has a current category review report for each AC category, with `n` replaced by the actual task number in the file path and visible title.
- Every current category review report verdict is `COMPLETE`.
- The final build task has a current `task-n-build-review.md` report and its verdict is `COMPLETE`.
- The final build review report shows that the repository-standard build passed.
- No final verification tasks were executed in this skill.
- The user has been asked to confirm the current goal as done (unless any task ended as `BLOCKED`), and `goal.md`'s `### 進度總覽` checkbox for that goal has been updated to `[x]` when the user confirmed, or left unchanged when the user deferred or the goal was blocked.

## Handoff
After all tasks are marked `COMPLETE`, if end-to-end verification is needed, invoke `/tdp:testing-and-proof` next to execute `test-plan.md`.

## Template
- [task review template](./assets/task-review.template.md)