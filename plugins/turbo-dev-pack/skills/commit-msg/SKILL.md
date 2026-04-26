---
name: commit-msg
description: 'Generate a commit message from the fixed format declared inside this skill. Use when the user asks for commit message, git commit title, 提交訊息, commit 訊息, or wants a project-specific message style without re-checking git history.'
argument-hint: 'Optional: changed files or a short summary of the change'
user-invocable: true
---

# Commit Message

## When to Use
- The user asks for a commit message for the current project.
- The user wants a message that matches the project style declared in this skill.
- The user asks for a git commit title after finishing a bug fix, lint cleanup, spec update, build fix, or small refactor.
- The user does not want the agent to rediscover the format from recent git history every time.

## Portable Setup
- This skill is portable because it does not depend on git history discovery.
- When copying this skill to another project, update only the `Project Format Profile` section below.
- Keep the workflow and decision rules unless the target project needs different commit policy.

## Project Format Profile
- Project label: Wda.Restart
- Primary format: `<type>: <摘要>`
- Optional scoped format: `<type>(<scope>): <摘要>`
- Preferred language: Traditional Chinese by default, but follow user or project preference when clearly specified
- Summary style: concise, action-oriented, and written as a completed change
- Default no-scope behavior: omit scope unless it adds real clarity
- Preferred default type for new features: `feat`
- Preferred default type for bug fixes and lint cleanup: `fix`
- Preferred default type for tooling and config alignment: `chore`
- Preferred default type for performance optimization: `perf`

## Active Format Rules
- Use Conventional Commit style with a lowercase type.
- Use the primary or optional scoped format from `Project Format Profile`.
- Summary should match the preferred language and summary style from `Project Format Profile`.
- Do not end the summary with a period.
- Keep the title to one line.

## Preferred Types
- `feat`: new feature, new user-facing capability, or completed functional enhancement
- `fix`: bug fix, lint cleanup, build blocker fix, regression fix, incorrect logic correction
- `chore`: tooling, config, dependency, non-feature maintenance, script adjustment
- `perf`: performance optimization without intended feature change
- `docs`: documentation-only changes
- `refactor`: code cleanup that does not change behavior
- `test`: test-only changes

## Project-Specific Defaults
- If the work adds a new feature or expands existing functionality, prefer `feat`.
- If the work mainly clears eslint or build-breaking frontend issues, prefer `fix`.
- If the work updates plan, goal, test-plan, or review documents for a bugfix workflow, prefer `fix` unless the user clearly wants `docs`.
- If the change is about config alignment such as jsconfig, alias, or build tooling, prefer `chore` and add scope when useful, for example `chore(jsconfig): ...`.
- If the work mainly improves runtime speed, rendering speed, query speed, or resource usage without changing intended behavior, prefer `perf`.
- If there is no strong reason to add a scope, omit it.

## Procedure
1. Identify the primary outcome of the change, not the file list.
2. Choose the smallest correct type from the preferred types.
3. Decide whether scope adds clarity. If not, omit it.
4. Write one concise summary that reflects the completed change.
5. Return only one primary commit message unless the user explicitly asks for alternatives.

## Decision Rules
- Do not inspect recent git history just to infer format; use the format declared in `Project Format Profile`.
- Do not include issue numbers, branch names, or long file lists unless the user explicitly asks for them.
- If the change spans multiple sub-tasks but one outcome dominates, summarize that dominant outcome.
- If the change is a batch of related lint fixes, use a summary like `修正 task 9 到 13 的 eslint 錯誤` or `修正 eslint 錯誤` depending on the requested specificity.
- If the change is ambiguous, ask for a one-sentence summary of what changed before drafting the message.
- If this skill is copied to another project, update `Project Format Profile` first and keep the rest of the workflow unchanged unless the new project has a different policy.

## Examples
- `feat: 新增課程異動通知功能`
- `feat(report): 新增執行成果彙總匯出欄位`
- `fix: 修正 eslint 錯誤`
- `fix: 修正 task 9 到 13 的 eslint 錯誤`
- `perf: 優化報表查詢效能`
- `fix: 補充 plan 任務 9 之後 function 參數異動需追查 caller 的驗收條件`
- `chore(jsconfig): 改用 paths 對齊 webpack alias，移除 baseUrl`
- `fix: 移除多餘的 BOM 編碼，確保檔案為 UTF-8 no BOM 格式`

## Completion Checks
- Type is lowercase and appropriate.
- Message matches the active format declared in `Project Format Profile`.
- Summary is one line, concise, and matches the preferred language declared in `Project Format Profile` when applicable.
- The message reads like a finished change, not a plan or question.