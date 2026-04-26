---
name: testing-and-proof
description: 'Execute a requirement test-plan.md and write proof back into each test-n.md. Use when a bugfix or feature already has test-plan.md and the user wants ordered verification, browser screenshots, or non-browser evidence. This skill must reuse build-project and run-project, apply and restore the local test stash around each IIS-backed verification task, and delegate each verification task to a subagent that writes the corresponding test-n.md. Replace the n in every test-n file name with the actual task number.'
argument-hint: 'Optional: path/to/test-plan.md'
user-invocable: true
---

# Testing and Proof

## When to Use
- A requirement already has `test-plan.md` and `test-n.md` files, with `n` replaced by the actual verification task number.
- The user asks for ordered verification instead of only build or startup logs.
- The user asks for screenshots, browser proof, or non-browser evidence to be written back into the spec folder.
- The user wants cleanup after each IIS-backed verification task.

## Prerequisites
- The `/setup` skill must have been completed and the `build-project` and `run-project` commands must be configured and working before running this skill.
- If `build-project` or `run-project` are not yet configured, run `/setup build` or `/setup run` first.

## Required Dependencies
- Reuse the exact build method already defined by the `build-project` command whenever IIS-backed verification may need fresh binaries.
- Reuse the exact IIS startup and shutdown method already defined by the `run-project` command.
- Do not substitute different build commands, different ports, or foreground IIS Express startup.
- Resolve the browser target URL with `${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.ps1`, which reuses the `run-project` IISUrl parsing logic.
- If `.claude/scripts.local.psd1` key `TEST_LOCAL_STASH_SHA` is configured, apply that local-only git stash before each IIS-backed verification task.
- If `TEST_LOCAL_STASH_SHA` is configured, stop IIS Express and revert those local-only changes after each IIS-backed verification task so the repository returns to its prior state.
- If `TEST_LOCAL_STASH_SHA` is not configured, skip the local-test stash apply and revert steps.
- If a verification task depends on any SQL script that would write to a database, the agent must not execute that SQL. The agent must ask the user to run the script manually and wait for confirmation before continuing.

## Outcome
Produce a proof package driven by `test-plan.md`, including:
- The resolved `test-plan.md` path.
- One updated `test-n.md` file per executed verification task, with `n` replaced by the actual verification task number.
- Screenshot files saved under the spec folder for browser-backed tasks.
- File plus line evidence for non-browser tasks.
- Cleanup confirmation for every IIS-backed verification task.

## Placeholder Rule
- Replace every `test-n` placeholder with the actual verification task number in file names and visible document text.

## Exact Procedure
1. Determine which `test-plan.md` to use. If the target is not clear from the current branch or the user request, ask the user.
2. Read `test-plan.md` and enumerate the referenced `test-n.md` files in order, with `n` replaced by the actual verification task number.
3. For each verification task, read the corresponding `test-n.md` and decide whether it is IIS-backed browser verification or non-browser verification.
4. Check whether the task requires any prerequisite SQL that would write to a database, such as local test-data setup, rollback, or data correction scripts.
5. If write SQL is required, do not execute it. Instead:
   - Identify the exact script path that the user needs to run.
   - Tell the user why that script is required for the verification.
   - Wait for the user's confirmation that the script has been executed.
   - If the user does not execute it, treat the task as blocked and write that status into the corresponding `test-n.md`.
6. For each IIS-backed browser task whose prerequisites are already satisfied, run this sequence as separate steps:
   - If `TEST_LOCAL_STASH_SHA` is configured, verify the git working tree is safe for local test stash apply.
   - If `TEST_LOCAL_STASH_SHA` is configured, apply the named local-test stash with `${CLAUDE_PLUGIN_ROOT}/scripts/apply-local-test-stash.ps1`.
   - Run the `build-project` workflow if fresh binaries may be needed.
   - Run the `run-project` workflow to start IIS Express on the port parsed from the target web csproj `IISUrl`.
   - Resolve the exact browser target URL with `${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.ps1`.
   - Invoke the Agent tool for that one verification task only. The subagent must execute the verification, save screenshot files under `screenshots/`, and write or overwrite the corresponding `test-n.md`.
   - Stop IIS Express using the `run-project` workflow resources.
   - If `TEST_LOCAL_STASH_SHA` is configured, revert the local-test stash changes with `${CLAUDE_PLUGIN_ROOT}/scripts/revert-local-test-stash.ps1`.
7. For each non-browser task whose prerequisites are already satisfied, invoke the Agent tool for that one verification task only. The subagent must write or overwrite the corresponding `test-n.md` with file plus line evidence.
8. Continue in order until all requested verification tasks are complete or blocked.
9. Summarize which `test-n.md` tasks passed, which are blocked, which ones are waiting on user-executed SQL, and what evidence was produced.

## Subagent Rules
- Do not perform the verification directly in the parent agent.
- Use one subagent invocation per verification task.
- Browser-backed verification subagents may use browser tools to save screenshot files into the spec folder.
- Browser-backed verification subagents should use `${CLAUDE_PLUGIN_ROOT}/scripts/get-target-url.ps1` to resolve the base URL instead of reconstructing scheme or port themselves.
- Browser-backed verification subagents must embed screenshot paths in `test-n.md` with Markdown image syntax and use only unmodified system screens, following `${CLAUDE_PLUGIN_ROOT}/skills/testing-and-proof/references/evidence-checklist.md`.
- Non-browser verification subagents must use file plus line links as the primary evidence in `test-n.md`.
- Subagents must not execute SQL that writes to a database. If such SQL is a prerequisite and the user has not confirmed it was run manually, the subagent must write the task as blocked.
- If a task fails or is blocked, the subagent must still write the current status, blockers, and captured evidence into the same `test-n.md`.

## Decision Rules
- Browser verification is the default for user-facing flows that can be exercised locally.
- Use non-browser evidence for backend-only logic, static audits, or flows that cannot be safely or reliably proven through the browser.
- If `test-plan.md` is missing or the listed `test-n.md` files do not exist, stop and ask whether `write-plan` should be run first.
- If a task requires running a `.sql` file that performs `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `CREATE`, `ALTER`, `DROP`, or any other write-side database action, do not execute it yourself. Instruct the user to run it manually and wait for confirmation before continuing.
- If the required write SQL has not been run by the user, stop that task and record it as blocked instead of trying to approximate the result with stale data, API output, or code inspection.
- If `TEST_LOCAL_STASH_SHA` is configured and the working tree is not clean before an IIS-backed task, stop and report that applying or reverting the local-test stash would be unsafe.
- If the target web csproj does not contain a valid `IISUrl`, stop and report the configuration problem before attempting verification.
- When `TEST_LOCAL_STASH_SHA` is configured, check whether the configured stash SHA exists with explicit command stdout such as `git stash list --format='%H %gd %gs'` or `git rev-parse --verify "$TEST_LOCAL_STASH_SHA^{commit}"` from the target worktree. Do not infer stash absence from terminal prompts, wrapper messages like `Command produced no output`, or other ambiguous terminal rendering.
- If `TEST_LOCAL_STASH_SHA` is configured and the stash SHA is missing or invalid, stop and report the available stash list instead of guessing.
- If `build-project` fails, stop and report the exact build blocker for that task. Do not continue to IIS startup.
- If `run-project` cannot start the site after a successful build, stop and report the exact blocker. Do not continue to browser steps for that task.
- Always stop IIS after an IIS-backed task, even if that task fails. If `TEST_LOCAL_STASH_SHA` is configured, also revert the local-test stash.
- If `TEST_LOCAL_STASH_SHA` is configured, apply stash, build, start IIS, stop IIS, and stash revert as separate terminal steps. Do not wrap these side-effect commands in one multi-line command and do not chain them with `&&`; verify each result before moving on.
- If the parsed `IISUrl` uses `https`, use that URL in browser-backed verification and do not silently fall back to `http`.

## Completion Checks
- Each targeted `test-n.md` is updated with actual result and evidence, with `n` replaced by the actual verification task number.
- Browser-backed tasks include saved screenshot files and Markdown image references.
- Non-browser tasks include file plus line evidence.
- Any task that depends on write-side SQL explicitly records whether the user ran the prerequisite script manually or whether the task is blocked waiting on that step.
- IIS Express was stopped after every IIS-backed task.
- If `TEST_LOCAL_STASH_SHA` was configured, the local-test stash changes were reverted after every IIS-backed task.