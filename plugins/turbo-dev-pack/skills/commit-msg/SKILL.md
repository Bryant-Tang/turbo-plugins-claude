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
- The user asks for a git commit title after finishing a code change, spec update, SQL script change, doc update, or small refactor.
- The user does not want the agent to rediscover the format from recent git history every time.

## Portable Setup
- This skill is portable because it does not depend on git history discovery.
- When copying this skill to another project, update only the `Project Format Profile` section below.
- Keep the workflow and decision rules unless the target project needs different commit policy.

## Project Format Profile
- Primary format: `<type>: <摘要>`
- Optional scoped format: `<type>(<scope>): <摘要>`
- Preferred language: Traditional Chinese by default, but follow user or project preference when clearly specified
- Summary style: concise, action-oriented, and written as a completed change
- Default no-scope behavior: omit scope unless it adds real clarity
- Preferred default type for new features (code only): `feat`
- Preferred default type for bug fixes (code only): `fix`
- Preferred default type for behavior-preserving code cleanup: `refactor`
- Preferred default type for spec documents under `specs/<type>/<slug>/`: `spec`
- Preferred default type for SQL scripts under `sql files/<env>-db/<slug>/`: `db`
- Preferred default type for pure documentation (README, CHANGELOG, tutorial, comment-only commits): `doc`
- Preferred default type for non-implementation chores (config, dependency, plugin version bump, file moves): `chore`

## Active Format Rules
- Use Conventional Commit style with a lowercase type.
- Use the primary or optional scoped format from `Project Format Profile`.
- Summary should match the preferred language and summary style from `Project Format Profile`.
- Do not end the summary with a period.
- Keep the title to one line.

## Preferred Types
- `feat`: new feature, user-facing capability, or completed functional enhancement (**code changes only**)
- `fix`: bug fix, build blocker fix, regression fix, incorrect logic correction (**code changes only**)
- `refactor`: code cleanup that does not change behavior (covers test-only refactors and minor performance touch-ups that have no observable behavior change)
- `doc`: pure documentation changes — README, CHANGELOG, tutorial, comment-only commits
- `spec`: development spec documents under `specs/<type>/<slug>/` such as `goal.md`, `plan.md`, `test-plan.md`, `test-<n>.md`, `review-*.md`
- `db`: SQL scripts under `sql files/<env>-db/<slug>/`
- `chore`: non-implementation chores — tooling, config, dependency adjustments, plugin version bump, file relocation that does not change runtime behavior

## Project-Specific Defaults
- If the work adds new code-level functionality, prefer `feat`.
- If the work fixes a bug in code (eslint cleanup that fixes runtime correctness, regression fix, build-breaking frontend issue), prefer `fix`.
- If the work tidies code without changing behavior (renaming, extracting helper, restructuring tests), prefer `refactor`.
- If the work updates plan, goal, test-plan, review, or any other document under `specs/<type>/<slug>/`, prefer `spec`.
- If the work changes SQL files under `sql files/<env>-db/<slug>/`, prefer `db`.
- If the work updates README, CHANGELOG, tutorial, or only comments without changing logic, prefer `doc`.
- If the work is config alignment such as jsconfig, alias, build tooling, plugin version bump, or moving files around without runtime impact, prefer `chore` and add scope when useful, for example `chore(jsconfig): ...`.
- If there is no strong reason to add a scope, omit it.

## Mixed-Intent Commits
- If a single commit spans both code and spec (or code and SQL, etc.), choose the type that reflects the **dominant intent** of the commit.
- Strongly prefer splitting into separate commits when the change crosses categories — one commit per dominant intent makes the history easier to read and lets `push-to-svn` filter spec / db / doc / chore cleanly.

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
- If the change is a batch of related code-level lint fixes, use a summary like `fix: 修正 task 9 到 13 的 eslint 錯誤` or `fix: 修正 eslint 錯誤`. Pure-style lint cleanup that does not affect runtime is `refactor`.
- If the change is ambiguous, ask for a one-sentence summary of what changed before drafting the message.
- If this skill is copied to another project, update `Project Format Profile` first and keep the rest of the workflow unchanged unless the new project has a different policy.

## Examples
- `feat: 新增課程異動通知功能`
- `feat(report): 新增執行成果彙總匯出欄位`
- `fix: 修正 eslint 錯誤`
- `fix: 修正 task 9 到 13 的 eslint 錯誤`
- `refactor: 抽出共用 helper 統一 payload 組裝`
- `spec: 補充 plan 任務 9 之後 function 參數異動需追查 caller 的驗收條件`
- `spec(test-plan): 新增 test-2 對應驗收清單`
- `db: 新增 main-db 的 stored procedure`
- `doc: 補充 README 的 plugin 安裝順序`
- `doc(changelog): 補登 0.5.0 區段`
- `chore(jsconfig): 改用 paths 對齊 webpack alias，移除 baseUrl`
- `chore: 移除多餘的 BOM 編碼，確保檔案為 UTF-8 no BOM 格式`

## Completion Checks
- Type is lowercase and matches the new preferred types (`feat` / `fix` / `refactor` / `doc` / `spec` / `db` / `chore`).
- Message matches the active format declared in `Project Format Profile`.
- Summary is one line, concise, and matches the preferred language declared in `Project Format Profile` when applicable.
- The message reads like a finished change, not a plan or question.
- `feat` and `fix` are only used for code changes; spec / SQL / doc changes use the matching dedicated type.
