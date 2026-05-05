---
name: push-to-svn
description: 'Push git commits from the specified branch to SVN by merging into the remote/* branch and committing from the remote-* worktree. Use when the user wants to send changes to SVN, submit to SVN, or push to SVN.'
argument-hint: 'Required: --branch <main|test-<n>>'
user-invocable: true
---

# push-to-svn

## Purpose

Send git changes to SVN:
1. Verify the remote-* worktree SVN is up-to-date
2. **Stage** the merge into `remote/*` with `git merge --no-ff --no-commit` so `svn status` reflects the actual file changes that would be pushed
3. Show the pending git commits and the SVN-side file change list to the user for confirmation
4. Generate a commit message; on user-cancel, abort the staged merge with `git merge --abort`
5. Finalise the merge commit (`git commit --no-edit`) and SVN-add/delete + commit to SVN

## Branch Mapping

| Working branch | Remote worktree | Remote git branch |
|---|---|---|
| `main` | `remote-main` | `remote/main` |
| `test-<n>` | `remote-test-<n>` | `remote/test-<n>` |

## Procedure

1. If `--branch` is not given, check the `TGS_DEFAULT_WORKING_BRANCH` environment variable. If it is set and valid (`main` or `test-<n>`), use that value. Otherwise, use `AskUserQuestion` to ask which branch to push.

2. Run the prepare script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-prepare.ps1" -Branch "main"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-prepare.sh" --branch "main"
```

3. If the output contains `Nothing to push`, report to the user and stop.

4. If the prepare script exits non-zero (SVN not up-to-date or git worktree not clean), report the error to the user and stop. Ask the user to run `/tgs:pull-from-svn` if SVN is behind.

5. Parse the prepare script output, which has two sections separated by an empty line:

   ```
   COMMITS
   <hash>|<subject>
   ...

   FILES
   <status>|<tracked|ignored>|<path>
   ...
   ```

   - **COMMITS** section: one `<hash>|<subject>` per line.
   - **FILES** section: one `<status>|<tracked|ignored>|<path>` per line. `<status>` is `A` (added), `M` (modified), or `D` (deleted) derived from `svn status` after the staged merge. `<tracked>` items will be pushed to SVN; `<ignored>` items match `.gitignore` and **will be skipped** by the commit script. (Files matching `svn:ignore` are auto-filtered by SVN and won't appear at all.)

   **Note**: at this point the prepare script has already run `git merge --no-ff --no-commit` in the remote worktree. The remote worktree is in a "merge prepared but not finalised" state.

6. Show the user a summary of what will be pushed, then call `AskUserQuestion` to confirm:

   Format the summary like this (translate labels to user's language):

   ```
   即將推送到 SVN（remote-<branch>）：

   提交（N 個）：
   - <hash> <subject>
   - <hash> <subject>

   會送至 SVN 的檔案（M 個）：
   + <added file>           ← A
   ~ <modified file>        ← M
   - <deleted file>         ← D

   git 忽略（不會送 SVN，K 個）：
   ~ <ignored file>
   ```

   Omit the "git 忽略" section if there are no ignored files. If the FILES section is empty, show "(無檔案變動)".

   Then ask via `AskUserQuestion`:
   - Option A: Proceed
   - Option B: Cancel

   If user picks **Cancel** → run `git merge --abort` in the remote worktree to discard the staged merge, then stop and report aborted. Do not run the commit script.

   ```powershell
   git -C "<remote-worktree-path>" merge --abort
   ```

   ```bash
   git -C "<remote-worktree-path>" merge --abort
   ```

7. Compose the SVN commit message from the COMMITS section:
   - **Title**: if there is only one commit, use its subject; otherwise summarise all subjects in one short phrase.
   - **Body**: fixed format shown below.
   ```
   <title>

   本次送交內容：
   - <commit1 subject>
   - <commit2 subject>
   ```

8. Show the proposed title to the user with `AskUserQuestion`:
   - Option A: Use the suggested title (show it in the description)
   - Option B: Enter a custom title

9. Construct the final commit message (title + body with the confirmed title) and call the commit script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.ps1" -Branch "main" -Message "the full commit message here"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.sh" --branch "main" --message "the full commit message here"
```

10. Interpret the commit script output:
    - **"Pushed to SVN r\<rev\>"** → Report success with the new SVN revision. Proceed to step 11.
    - **"No changes to commit to SVN (all pending changes are git-ignored)"** → Report to user that all pending SVN changes are git-ignored and nothing was committed to SVN. Skip step 11 (no release tag needed).

11. Use `AskUserQuestion` to ask the user whether to add a release tag on this push:
    - Option A: Yes, create a release tag
    - Option B: No, skip tagging

12. If the user chose to create a release tag, call the tag-release script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.ps1" -Branch "main"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.sh" --branch "main"
```

    Report the created tag name from the script output to the user.

## Decision Rules

- Only `main` and `test-<n>` are valid branch names. Reject others.
- The prepare script stages the merge with `--no-ff --no-commit` so SVN can see the actual file changes; the commit script re-validates SVN state and finalises the staged merge with `git commit --no-edit`.
- If the prepare script exits non-zero due to a **merge conflict**, ask the user to either resolve the conflicts inside the `remote-*` worktree (then re-invoke the SKILL, which will detect the resolved merge and prompt to commit) or run `git -C <remote-worktree> merge --abort` to discard.
- If the prepare script exits non-zero because of an **existing pending merge** (`MERGE_HEAD` already present), tell the user to either re-run `/tgs:push-to-svn` to commit it, or abort it manually.
- If the user **cancels** at the confirmation step, run `git -C <remote-worktree> merge --abort` immediately to clean up the staged merge.
- Can be called from any worktree in the project.

## Completion Checks

- The commit script outputs "Pushed to SVN r\<new-rev\>".
- The `remote/*` branch contains a merge commit "Merge branch '\<branch\>' into remote/\<branch\>".
- SVN HEAD revision has increased.
- If the user chose to create a release tag: `git tag -l "<branch>-release-*"` shows the new tag, and `git rev-parse <tag-name>` equals `git rev-parse remote/<branch>`.
