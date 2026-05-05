---
name: implement-task-fast
description: 'Implement plan.md tasks faster by batching implementation (up to 3 tasks per subagent invocation) until all non-build tasks are done, then running a single review subagent covering all 7 AC categories at once. The final build task always starts from a build review first. Use when plan.md already exists and speed is preferred over per-task review loops, without running final test-plan verification.'
argument-hint: 'Optional: path/to/plan.md'
user-invocable: true
---

# Implement Task Fast

## When to Use
- A requirement already has `plan.md`.
- The next step is to execute implementation tasks with speed as priority.
- Per-task review loops are not needed; a single review pass at the end is acceptable.
- Final verification from `test-plan.md` should not run yet.
- Use `implement-task` instead if you need per-task review loops with retry logic.

## Outcome
- One target `plan.md` is identified.
- All non-build implementation tasks are executed in batches of up to 3 tasks per implementation subagent invocation.
- After all non-build tasks are implemented, one review subagent covers all implemented tasks against all 7 AC categories and writes a single combined review report.
- The final build task is handled separately: it starts with a build-focused review subagent (same as `implement-task`).
- After all tasks are complete, the user is asked whether to confirm the goal as done.

## Tool Preference
- For all file read, write, search, and edit operations, prefer the dedicated tools: Read, Write, Edit, Glob, Grep, and LSP diagnostics.
- Avoid using Bash, PowerShell, Python, or Node.js for file operations unless the task cannot be accomplished with the above tools.
- When instructing implementation and review subagents, include an explicit directive to use Read, Write, Edit, Glob, Grep, and LSP for file operations instead of Bash, PowerShell, Python, or Node.js.

## Core Rules
- First determine which `plan.md` to use. If more than one candidate fits, ask the user instead of guessing.
- Do not implement tasks directly in the parent agent. Use the Agent tool for each implementation subagent invocation.
- Do not review tasks directly in the parent agent. Use the Agent tool for the review subagent.
- Each implementation subagent handles up to 3 consecutive non-build tasks in one invocation. After one batch finishes, invoke the next batch subagent with the next up-to-3 tasks, and continue until all non-build tasks are done.
- After **all** non-build tasks are implemented, invoke one review subagent that covers **all** implemented non-build tasks against all 7 AC categories and writes a single combined review report file.
- If the current task changes C# code, the implementation subagent must invoke the `csharp-comment` skill via `/tdp:csharp-comment` after all C# code changes are complete. The review subagent must also verify `csharp-comment` compliance for any C# files in scope.
- If the current task changes JavaScript or TypeScript code (including `<script>` sections in `.vue`, `.cshtml`, or `.html` files), the implementation subagent must invoke the `js-comment` skill via `/tdp:js-comment` after all JS/TS code changes are complete. The review subagent must also verify `js-comment` compliance for any JS/TS files in scope.
- There is no per-task retry loop. If the combined review report is not `COMPLETE`, report the blocking findings to the user and stop. The user decides how to proceed (e.g. fix manually or re-invoke `implement-task` for specific tasks).
- The final build task is special: it must start with a build-focused review subagent, not with an implementation subagent. This matches `implement-task` behavior exactly.
- The build-focused review subagent for the final task must execute the repository-standard build, identify build errors, and write its own build review report before any fix attempt starts.
- The parent agent only reads review report files to decide whether to continue or stop.
- Do not run the final `test-plan.md` verification in this skill.

## AC-to-Reviewer Mapping

The AC Category Catalog (defined in `write-plan`) has K=7 categories numbered 1..7:

1. Correctness（正確性）
2. Security（安全性）
3. Integration & Compatibility（整合性與相容性）
4. Maintainability & Code Quality（可維護性與程式碼品質）
5. Testability & Observability（可測試性與可觀測性）
6. Performance & Resource Usage（效能與資源使用）
7. User Experience（使用者體驗）

The single combined review subagent covers all 7 categories (equivalent to N=1 in `implement-task`'s mapping table).

## Review Report Location Rule
- The combined review report for all non-build tasks must be written to `all-tasks-review.md` inside the same directory as `plan.md` (or in the `reviews/` subfolder if that convention already exists in the spec folder).
- For the final build task, the build review subagent must write `task-n-build-review.md`, replacing `n` with the actual task number.

## Procedure
1. Identify the target `plan.md`. If ambiguous, ask the user.
2. Read `plan.md` and `goal.md`. If `plan.md` is inside a `goal-<id>/` subdirectory (e.g. `goal-1/`, `goal-2a/`, `goal-2b/`), `goal.md` is in the parent directory.
3. Determine the ordered implementation tasks, identify the final build task, and extract the categorized AC for each task.
4. Before starting, count the number of AC categories present in `plan.md`. If the count is not 7, stop immediately and tell the user that `plan.md` uses the pre-v0.2.4 three-category format and must be regenerated with v0.2.4's `write-plan` before `implement-task-fast` can proceed.
5. **(Batch implementation)** Group the non-build tasks into batches of up to 3. For each batch, invoke one implementation subagent with:
   - The scope, files, and categorized AC for each task in the batch.
   - An explicit instruction to implement the tasks in order and not touch later tasks outside the batch.
   - An explicit instruction to invoke `/tdp:csharp-comment` after all C# code changes are complete.
   - An explicit instruction to invoke `/tdp:js-comment` after all JS/TS code changes are complete.
   - The tool preference directive (use Read, Write, Edit, Glob, Grep, LSP instead of Bash/PowerShell/Python/Node for file operations).
   - Continue invoking batch subagents (each up to 3 tasks) until all non-build tasks are implemented.
6. **(Single combined review)** After all non-build tasks are implemented, invoke one review subagent with:
   - All implemented non-build tasks' scope and categorized AC.
   - An instruction to review all tasks against all 7 AC categories.
   - An instruction to write the combined review report to `all-tasks-review.md`.
   - The tool preference directive.
7. The parent agent reads `all-tasks-review.md`. If the verdict is `COMPLETE`, proceed to the final build task. If not `COMPLETE`, report the blocking findings to the user and stop — do not auto-retry.
8. **(Final build task)** Start by invoking a build-focused review subagent instead of an implementation subagent. That review subagent must run the repository-standard build and write or overwrite `task-n-build-review.md`.
9. The parent agent reads the build review report only. If the build review for the final task is not `COMPLETE`, invoke an implementation subagent limited to fixing the reported build failures, then rerun the build-focused review subagent and let it overwrite the same build review report. Repeat until `COMPLETE` or the user decides to stop.
10. Stop after the planned implementation tasks are complete. Do not execute `test-plan.md` here.
11. Once every planned implementation task is `COMPLETE`, use `AskUserQuestion` to ask the user whether to confirm this goal as done. If the user confirms, read `goal.md`, locate the `- [ ] 目標 <編號>：<標題>` line in `### 進度總覽` matching the goal that was just implemented (the `<編號>` must match exactly, including any letter suffix such as `2a`), and use Edit to change `[ ]` to `[x]`. After the checkbox is updated, invoke the `/tdp:commit-msg` skill to recommend a commit message for the completed goal. If the user defers confirmation, leave the checkbox unchanged and tell the user it stays unchecked until they confirm later.

## Decision Rules
- If a batch contains fewer than 3 remaining non-build tasks, use whatever count remains (1 or 2) — do not pad with tasks from the next goal.
- If the combined review is not `COMPLETE`, do not auto-retry; surface the blocking findings and let the user decide. For targeted fixes, the user can invoke `implement-task` on specific tasks.
- Category reviewers in the combined review must judge each task only against that task's AC and scope, not against future tasks.
- Preserve existing user changes outside the current implementation scope.
- When C# files are in scope, the implementation subagent must invoke `/tdp:csharp-comment` rather than applying the rules manually.
- When JS/TS files (including `<script>` sections in `.vue`, `.cshtml`, or `.html` files) are in scope, the implementation subagent must invoke `/tdp:js-comment` rather than applying the rules manually.
- The final build task review may execute build commands, but it must not drift into final `test-plan.md` verification.
- Never silently flip a `### 進度總覽` checkbox to `[x]` without an explicit user confirmation in the same session.

## Completion Checks
- All non-build tasks have been implemented by batch subagents.
- `all-tasks-review.md` exists and its verdict is `COMPLETE`, covering all 7 AC categories for all non-build tasks.
- The final build task has a current `task-n-build-review.md` report and its verdict is `COMPLETE`.
- The final build review report shows that the repository-standard build passed.
- No final verification tasks were executed in this skill.
- The user has been asked to confirm the current goal as done (only when both `all-tasks-review.md` and the build review verdicts are `COMPLETE`), and `goal.md`'s `### 進度總覽` checkbox for that goal has been updated to `[x]` when the user confirmed, or left unchanged when the user deferred or the review was not `COMPLETE`.
- After the `goal.md` checkbox was updated to `[x]`, the `/tdp:commit-msg` skill was invoked and a commit message was recommended to the user.

## Handoff
After all tasks are marked `COMPLETE` for the current goal, continue with the next goal's plan mode → `/tdp:write-plan` → `/tdp:implement-task-fast` cycle. Once **every** goal in `goal.md` is implemented, end-to-end verification is optional: enter plan mode for the overall verification strategy, then call `/tdp:write-test-plan` to materialize `test-plan.md` and `test-n.md` at the spec folder root, and finally invoke `/tdp:testing-and-proof` to execute it. Skip these steps if the user prefers manual review.

## Template
- [task review template](../implement-task/assets/task-review.template.md)
