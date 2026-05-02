---
name: implement-task
description: 'Implement plan.md tasks in order by delegating coding and categorized AC review to subagents. Use when plan.md already exists and each task should loop implement -> parallel category review reports -> read review reports until COMPLETE, while the final build task starts from build review first, where n must be replaced with the actual task number, without running final test-plan verification.'
argument-hint: 'Optional: path/to/plan.md, --reviewers=N (1..7)'
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
- Each non-build task has N reviewer reports (one per reviewer subagent) written or overwritten, with `n` replaced by the actual task number. Each reviewer covers the AC categories assigned by the AC-to-Reviewer Mapping.
- The final build task has its own build review report written or overwritten by the build review subagent.
- The loop stops only when the current task review says `COMPLETE`.
- After all tasks for the current goal are `COMPLETE`, the user is asked whether to confirm the goal as done. If confirmed, the corresponding `- [ ] 目標 <編號>：<標題>` line in `goal.md`'s `### 進度總覽` is changed to `- [x]` (where `<編號>` may include a letter suffix such as `2a`). After the checkbox is updated, the parent agent invokes `/tdp:commit-msg` to recommend a commit message to the user. If the user defers confirmation, or any task ended as `BLOCKED`, the checkbox is left unchanged.

## Core Rules
- First determine which `plan.md` to use. If more than one candidate fits, ask the user instead of guessing.
- Do not implement the task directly in the parent agent. Use the Agent tool for each implementation attempt.
- Do not review the task directly in the parent agent. Use the Agent tool for each review attempt.
- One implementation task per implementation subagent invocation.
- One implementation task per review cycle.
- If the current task changes C# code, the implementation subagent must invoke the `csharp-comment` skill via `/tdp:csharp-comment` after all C# code changes are complete. Each reviewer subagent must also verify `csharp-comment` compliance for any C# files in scope and include the findings in its review report.
- For non-build tasks, run N parallel reviewer subagents after each implementation attempt, where N is resolved by the Reviewer Count Resolution rule.
- The AC categories assigned to each reviewer follow the AC-to-Reviewer Mapping table. The parent agent must use the mapping verbatim and must not improvise the grouping.
- Each review subagent must write or overwrite its own review report file. The parent agent must not consolidate or rewrite those review reports.
- If any category review report is not `COMPLETE`, the current task is not `COMPLETE`.
- If any category review report is not `COMPLETE`, run another implementation subagent for that same task, then rerun the parallel category reviews, and let each review subagent overwrite its own report file.
- Limit the implement → review loop to a maximum of 2 additional attempts after the first review (3 total attempts per task). If the task is still not `COMPLETE` after 3 attempts, mark it as `BLOCKED` and stop. Report the blocking findings to the user before proceeding to the next task.
- The final build task is special: it must start with a build-focused review subagent, not with an implementation subagent.
- The build-focused review subagent for the final task must execute the repository-standard build, identify build errors, and write its own review report before any fix attempt starts.
- The parent agent only reads review report files to decide whether to continue, retry implementation, or move on.
- Do not run the final `test-plan.md` verification in this skill.

## Reviewer Count Resolution

Resolve the parallel reviewer count `N` for non-build tasks using this priority order:

1. Skill argument `--reviewers=N` parsed from the user's invocation (e.g. `/tdp:implement-task --reviewers=4 path/to/plan.md`). `N` must be an integer in 1..7.
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/get-default-reviewer-count.sh` (or `${CLAUDE_PLUGIN_ROOT}/scripts/get-default-reviewer-count.ps1` on Windows) from the repository root. The script reads `TDP_IMPLEMENT_TASK_REVIEWERS` and outputs `3` when the variable is not set.

If a resolved value is outside 1..7 or is not an integer, stop and ask the user for a valid value before proceeding.

The final build task is not affected by `N`; it always uses exactly one build review subagent.

## AC-to-Reviewer Mapping

The AC Category Catalog (defined in `write-plan`) has K=7 categories numbered 1..7:

1. Correctness（正確性）
2. Security（安全性）
3. Integration & Compatibility（整合性與相容性）
4. Maintainability & Code Quality（可維護性與程式碼品質）
5. Testability & Observability（可測試性與可觀測性）
6. Performance & Resource Usage（效能與資源使用）
7. User Experience（使用者體驗）

Assign categories to N reviewer buckets using this fixed mapping. The parent agent must follow this table verbatim and must not improvise the grouping.

| N | Reviewer buckets (category numbers) |
|---|---|
| 1 | {1,2,3,4,5,6,7} |
| 2 | {1,2,3,4} · {5,6,7} |
| 3 | {1,2,3} · {4,5} · {6,7} |
| 4 | {1,2} · {3,4} · {5} · {6,7} |
| 5 | {1,2} · {3} · {4} · {5} · {6,7} |
| 6 | {1,2} · {3} · {4} · {5} · {6} · {7} |
| 7 | {1} · {2} · {3} · {4} · {5} · {6} · {7} |

Each reviewer subagent must check only the AC items belonging to its assigned categories, and must not drift into other categories.

## Review Report Location Rule
- For non-build tasks, each reviewer subagent writes a separate file named `task-<n>-review-<slugs>.md`, where `<slugs>` is the `+`-joined list of assigned AC category slugs in catalog order (e.g., `task-1-review-correctness+security+integration-compatibility.md` for N=3 reviewer 1). If the joined slug string exceeds 60 characters, fall back to `task-<n>-review-<i>-of-<N>.md` where `<i>` is the 1-based reviewer index and `<N>` is the resolved reviewer count.
- Before invoking a new round of reviewer subagents for the same task (e.g., after a retry implementation attempt), the parent agent must delete all existing `task-<n>-review-*.md` files for that task number to prevent stale reports from a previous round from persisting.
- For the final build task, the build review subagent must write `task-n-build-review.md`, replacing `n` with the actual task number.
- If the spec folder already contains task review files at its root, keep that convention at the root.
- Otherwise default to the `reviews/` folder inside the same spec folder.

## Procedure
1. Identify the target `plan.md`. If ambiguous, ask the user.
2. Read `plan.md` and `goal.md`. If `plan.md` is inside a `goal-<id>/` subdirectory (e.g. `goal-1/`, `goal-2a/`, `goal-2b/`), `goal.md` is in the parent directory.
3. Determine the ordered implementation tasks, identify the final build task, and extract the categorized AC for each task.
4. For each non-build task, invoke an implementation subagent with the task scope, files, categorized AC, an explicit instruction not to touch later tasks, and an explicit instruction to invoke `/tdp:csharp-comment` after all C# code changes are complete.
5. After the implementation attempt completes, invoke N parallel reviewer subagents for the current non-build task (where N is the resolved reviewer count from Reviewer Count Resolution). Assign each reviewer its bucket of AC categories from the AC-to-Reviewer Mapping table. Each reviewer must check only the AC items belonging to its assigned categories against the current task scope and AC, and must write its own review report using the file naming rule from Review Report Location Rule, from the [task review template](./assets/task-review.template.md).
6. The parent agent reads the category review reports only. If every category review report verdict is `COMPLETE`, move to the next task.
7. If any category review report verdict is not `COMPLETE`, feed the blocking findings from those report files back into a new implementation subagent for the same non-build task, then rerun the parallel category review subagents and let them overwrite their own report files. Do not exceed 2 additional implementation attempts after the first review (3 total); if still not `COMPLETE`, record the task as `BLOCKED` and stop.
8. For the final build task, start by invoking a build-focused review subagent instead of an implementation subagent. That review subagent must run the repository-standard build and write or overwrite `task-n-build-review.md`.
9. The parent agent reads the build review report only. If the build review for the final task is not `COMPLETE`, invoke an implementation subagent limited to fixing the reported build failures, then rerun the build-focused review subagent and let it overwrite the same build review report.
10. Repeat until the current task review reports say `COMPLETE`, then continue.
11. Stop after the planned implementation tasks are complete. Do not execute `test-plan.md` here.
12. Once every planned implementation task for the current goal is `COMPLETE` (no `BLOCKED` task remaining), use `AskUserQuestion` to ask the user whether to confirm this goal as done. If the user confirms, read `goal.md`, locate the `- [ ] 目標 <編號>：<標題>` line in `### 進度總覽` matching the goal that was just implemented (the `<編號>` must match exactly, including any letter suffix such as `2a`), and use Edit to change `[ ]` to `[x]`. After the checkbox is updated, invoke the `/tdp:commit-msg` skill to recommend a commit message for the completed goal. If the user defers confirmation, leave the checkbox unchanged and tell the user it stays unchecked until they confirm later. If any task ended as `BLOCKED`, skip the question entirely, leave the checkbox unchanged, and surface the blocking findings.

## Decision Rules
- Before starting the implement → review loop, count the number of AC categories present in `plan.md`. If the count is not 7, stop immediately and tell the user that `plan.md` uses the pre-v0.2.4 three-category format and must be regenerated with v0.2.4's `write-plan` before `implement-task` can proceed.
- If a task is too large for a single chat session, stop and revise `plan.md` first instead of silently doing a mega-task.
- Category reviewers must judge the task only against the current category AC and current scope, not against future tasks.
- Preserve existing user changes outside the current implementation scope.
- When C# files are in scope, the implementation subagent must invoke `/tdp:csharp-comment` rather than applying the rules manually. The reviewer subagent covering Maintainability & Code Quality (category 4) must verify `csharp-comment` compliance as part of its review.
- If a previous category review file already exists but the code changed afterward, the same category review subagent must overwrite it with a fresh review instead of appending stale conclusions.
- The final build task review may execute build commands, but it must not drift into final `test-plan.md` verification.
- If any task in the current goal ended as `BLOCKED`, do not ask the user about the progress checkbox and do not modify `goal.md`'s `### 進度總覽`; report the blocking findings instead.
- Never silently flip a `### 進度總覽` checkbox to `[x]` without an explicit user confirmation in the same session.

## Completion Checks
- Every completed non-build task has N current reviewer reports (matching the resolved N) covering all 7 AC categories, with `n` replaced by the actual task number in the file path and visible title.
- Every current reviewer report verdict is `COMPLETE`.
- The final build task has a current `task-n-build-review.md` report and its verdict is `COMPLETE`.
- The final build review report shows that the repository-standard build passed.
- No final verification tasks were executed in this skill.
- The user has been asked to confirm the current goal as done (unless any task ended as `BLOCKED`), and `goal.md`'s `### 進度總覽` checkbox for that goal has been updated to `[x]` when the user confirmed, or left unchanged when the user deferred or the goal was blocked.
- After the `goal.md` checkbox was updated to `[x]`, the `/tdp:commit-msg` skill was invoked and a commit message was recommended to the user.

## Handoff
After all tasks are marked `COMPLETE` for the current goal, continue with the next goal's plan mode → `/tdp:write-plan` → `/tdp:implement-task` cycle. Once **every** goal in `goal.md` is implemented, end-to-end verification is optional: enter plan mode for the overall verification strategy, then call `/tdp:write-test-plan` to materialize `test-plan.md` and `test-n.md` at the spec folder root, and finally invoke `/tdp:testing-and-proof` to execute it. Skip these steps if the user prefers manual review.

## Template
- [task review template](./assets/task-review.template.md)