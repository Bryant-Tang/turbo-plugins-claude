---
name: db-management
description: 'Inspect project databases with DBHub read-only MCP tools, decide environment scope, and deliver standardized SQL scripts under sql files/local-db, sql files/test-db, and sql files/main-db. Use when feature work, bug fixing, schema investigation, data checking, seed data, migration prep, or deployment preparation depends on one or more databases exposed by the current workspace MCP tools.'
argument-hint: 'Optional: database name, work item id, or target environment'
user-invocable: true
---

# DB Management

## When to Use
- You need to inspect schema, data, procedures, functions, or indexes in one of this project's connected databases.
- A feature or bug fix depends on understanding production-like data structure before changing code.
- The requested database change would require `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, `DROP`, or other write operations.
- You need a repeatable SQL delivery artifact that the user can run in local, test, and production environments with clear separation.
- You want the generated SQL files to follow the same folder structure, file naming pattern, and script layout every time.

## Connected Databases
- Use the DBHub execute and object-search MCP tools that correspond to the target database in the current workspace.
- Database names and MCP tool suffixes may differ by repository, so resolve the correct pair before querying.

## Fixed Constraints
- All DBHub MCP database access in this repository is read-only.
- DBHub MCP access in this repository connects to the local databases only; it does not connect directly to test or production databases.
- You may query any connected database exposed by the workspace MCP tools, but you must not execute write SQL through MCP tools.
- If implementation requires data correction, schema change, seed data, backfill, migration, or any other write operation, create `.sql` files under the repository root `sql files/` environment folders instead of attempting the write directly.
- Do not assume local, test, and production databases are structurally identical. Column definitions, views, stored procedures, functions, triggers, and other objects may differ by environment.
- If a script depends on an object definition that is likely to differ outside local, ask the user to run a small verification query in the target test or production environment first and use that result before finalizing the corresponding SQL file.
- When test or production verification is needed, provide the user with a minimal read-only query, preferably a simple `SELECT`, and use the returned result instead of pretending DBHub can inspect that environment directly.
- Use the repository's environment split consistently:

| Folder | Purpose |
|---|---|
| `sql files/local-db/` | Local database verification, temporary test data, or scripts that will be rolled back after local validation |
| `sql files/test-db/` | Customer test environment deployment scripts |
| `sql files/main-db/` | Production deployment scripts |

- If `sql files/` or one of the required environment folders does not exist in the current writable worktree, create the needed folder before adding scripts.
- Existing repository convention may still use a work-item or topic subfolder under the environment folder, such as `sql files/local-db/115-A008/` or `sql files/local-db/account-sync/`.
- If a script is only for local verification and should be rolled back after testing, place it only under `sql files/local-db/`.
- If the final released version also requires the database change in production, prepare matching scripts in all 3 locations: `sql files/local-db/`, `sql files/test-db/`, and `sql files/main-db/`.

## Folder and File Naming Template
- Folder template: `sql files/<environment>/<work-item-or-topic>/`
- Valid environment values: `local-db`, `test-db`, `main-db`
- Work-item-or-topic naming rule:
	- If the user provides a work item id, use it directly, for example `115-A008`.
	- If there is no work item id, use a short kebab-case topic folder, for example `account-sync`.
	- Use the same folder name across `local-db`, `test-db`, and `main-db` for the same logical change.
- File template: `<order>-<database>-<purpose>.sql`
- File naming rule:
	- Use a 2-digit execution order such as `01`, `02`, `03`.
	- Use the actual target database name for the current repository.
	- Use a short descriptive purpose, preferably Traditional Chinese, such as `補資料`, `新增欄位`, `重建索引`, or `建立測試資料`.
	- Keep the same file name across environments when the files represent the same deployment step.
- Example folder and file combinations:
	- `sql files/local-db/115-A008/01-AppDb-建立測試資料.sql`
	- `sql files/test-db/115-A008/01-AppDb-新增欄位.sql`
	- `sql files/main-db/115-A008/01-AppDb-新增欄位.sql`
	- `sql files/local-db/account-sync/01-AuthDb-驗證登入資料.sql`

## SQL Template
- Use the shared script template at [assets/sql-script-template.sql](./assets/sql-script-template.sql).
- Copy the same layout into each environment-specific SQL file so local, test, and production scripts keep the same header, execution order, pre-check, main change, and post-check sections.
- For local-only verification scripts, keep the same template but place the file only under `sql files/local-db/` and fill in the rollback section.
- For production-bound changes, create the 3 files first, then keep comments and section ordering aligned across all of them.

## Procedure
1. If the task may depend on repository-specific database conventions, prior SQL delivery decisions, or previously confirmed environment constraints that are not already in chat, read the relevant repository memory first.
2. Identify which connected database is relevant to the task.
3. If table, column, procedure, function, or index names are uncertain, use the corresponding DBHub object-search MCP tool first.
4. Query only the minimum data needed with the corresponding DBHub execute MCP tool.
5. Translate the database findings into the required code change or implementation decision.
6. If the solution requires any write-side database action, decide the target environment scope before drafting SQL: local-only verification, test deployment, or full release including production.
7. If the SQL is only for local verification and will be rolled back after testing, create it only under `sql files/local-db/<work-item>/`.
8. If the SQL is part of the final released change and production must also be modified, create aligned scripts under `sql files/local-db/<work-item>/`, `sql files/test-db/<work-item>/`, and `sql files/main-db/<work-item>/`.
9. Before finalizing `test-db` or `main-db` scripts, check whether the relevant columns, views, procedures, functions, and triggers are known to be the same in that environment. If not, write a minimal verification query for the user to run there and wait for the result.
10. If the target environment scope is not obvious from the request, ask before creating the script.
11. Choose the work-item or topic folder name using the folder naming template in this skill.
12. Name each SQL file with the `<order>-<database>-<purpose>.sql` pattern.
13. Start from [assets/sql-script-template.sql](./assets/sql-script-template.sql) so the generated files share the same structure.
14. In each script, include the target database with `USE [DatabaseName]` when appropriate, keep statements in execution order, and add enough comments for operators to understand special steps, rollback expectations, or environment-specific differences.
15. If multiple logical changes are needed, prefer separate SQL files rather than one monolithic script unless the steps must be executed together.
16. Report both parts of the result: what was verified from read-only DB inspection, what the user still needed to verify in test or production if applicable, and what SQL script was prepared for manual execution.

## Decision Rules
- If the task is only investigation, do not create a SQL file.
- If relevant repository-specific database context may already exist in memory and is not present in chat, read memory before inspecting schemas or drafting SQL.
- If the task needs schema discovery, prefer the corresponding DBHub object-search MCP tool before writing broad `SELECT` queries.
- If the request implies a write but the exact target objects are still unclear, inspect first and then author the SQL script.
- If the user has not provided a work-item or folder name for `sql files/`, ask before creating the script so the output can follow the repo convention.
- If the change is only for local testing, validation, or temporary data setup that should be rolled back, create scripts only in `sql files/local-db/`.
- If the change must go live in production, create corresponding scripts in `sql files/local-db/`, `sql files/test-db/`, and `sql files/main-db/`.
- If the request is clearly not local-only but still does not say whether test-db only or test-db plus main-db is required, ask the user to confirm the intended environment matrix before drafting SQL.
- If local findings may not match test or production object definitions, stop assuming parity and ask the user for a minimal verification query result from that target environment before finalizing the script.
- If test or production verification is needed, do not say DBHub can inspect that environment. Instead, provide the exact simple read-only query for the user to run and use that returned result.
- If more than one database needs changes, separate the scripts by database or by clear execution step.
- If the script depends on manual post-processing, trigger recreation, or environment-specific review, state that explicitly inside the SQL file as comments.
- If the same logical change needs small environment-specific adjustments, keep the file names aligned across environment folders and explain the differences in comments.
- If multiple files are meant to be executed in sequence, keep the numeric prefix aligned across all environments.
- Never treat MCP read-only access as approval to bypass script delivery.
- When terminal commands are needed around this workflow, run each state-changing step separately. Do not use one multi-line shell block or `&&` to combine file creation, validation, cleanup, or other side-effect commands.

## SQL File Guidance
- Prefer descriptive file names such as `01-AppDb-新增條文版本表.sql` or `02-AuthDb-新增欄位.sql`.
- Keep one logical purpose per file when possible.
- Prefer the same relative file name across `local-db`, `test-db`, and `main-db` when they represent the same deployment step.
- Include `GO` separators where the SQL Server execution context requires them.
- Preserve object comments or extended properties when the change introduces new tables or columns and the surrounding schema follows that pattern.
- When the existing schema uses companion log tables or triggers, inspect and account for them in the script instead of changing only the base table.
- Apply the companion log-table and trigger rule per environment, not by assumption from another environment.
- When the script is local-only verification, add explicit rollback instructions or rollback SQL comments near the end of the file.

## Completion Checks
- Database inspection used only the read-only MCP tools.
- No write SQL was executed directly through DBHub.
- Any required write-side database work was captured in one or more `.sql` files under the correct environment folders in `sql files/`.
- Local-only validation scripts were kept only in `sql files/local-db/`.
- Any production-bound database change was prepared in all 3 locations: `sql files/local-db/`, `sql files/test-db/`, and `sql files/main-db/`.
- Any non-local environment differences that could affect correctness were explicitly verified or escalated back to the user for a target-environment check.
- Any needed test or production inspection was handled by asking the user to run a minimal read-only query, not by implying direct DBHub access to that environment.
- Folder names follow the work-item-or-topic template, and file names follow the `<order>-<database>-<purpose>.sql` pattern.
- The generated files follow the shared layout from [assets/sql-script-template.sql](./assets/sql-script-template.sql).
- The script location and naming are reproducible for local execution, test deployment, and production deployment.
- The final response clearly distinguishes verified database facts from proposed SQL changes.

## Notes
- This skill is workspace-scoped because the connected database names and DBHub tool names can vary by repository even when the MCP server and delivery convention stay the same.
- DBHub inspection in this workspace is limited to local databases; test and production checks must be performed by the user with agent-provided read-only SQL.
- Current repository evidence shows `sql files/` is environment-split with `local-db`, `test-db`, and `main-db`, and environment folders may contain work-item or topic subfolders under that folder.