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
2. Show the pending git commits and generate a commit message
3. Merge the working branch into `remote/*`
4. SVN-add/delete any new or removed files and commit to SVN

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

5. Parse the commit list from the prepare script output (one `<hash>|<subject>` per line). Compose the SVN commit message:
   - **Title**: if there is only one commit, use its subject; otherwise summarise all subjects in one short phrase.
   - **Body**: fixed format shown below.
   ```
   <title>

   本次送交內容：
   - <commit1 subject>
   - <commit2 subject>
   ```

6. Show the proposed title to the user with `AskUserQuestion`:
   - Option A: Use the suggested title (show it in the description)
   - Option B: Enter a custom title

7. Construct the final commit message (title + body with the confirmed title) and call the commit script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.ps1" -Branch "main" -Message "the full commit message here"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.sh" --branch "main" --message "the full commit message here"
```

8. Interpret the commit script output:
   - **"Pushed to SVN r\<rev\>"** → Report success with the new SVN revision. Proceed to step 9.
   - **"No changes to commit to SVN (all pending changes are git-ignored)"** → Report to user that all pending SVN changes are git-ignored and nothing was committed to SVN. Skip step 9 (no release tag needed).

9. Use `AskUserQuestion` to ask the user whether to add a release tag on this push:
   - Option A: Yes, create a release tag
   - Option B: No, skip tagging

10. If the user chose to create a release tag, call the tag-release script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.ps1" -Branch "main"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tag-release.sh" --branch "main"
```

    Report the created tag name from the script output to the user.

## Decision Rules

- Only `main` and `test-<n>` are valid branch names. Reject others.
- The prepare script re-validates SVN state at commit time as well, so a race condition between prepare and commit will be caught.
- If the commit script exits non-zero due to a merge conflict in the remote worktree, ask the user to resolve the conflict inside the `remote-*` worktree, then retry.
- Can be called from any worktree in the project.

## Completion Checks

- The commit script outputs "Pushed to SVN r\<new-rev\>".
- The `remote/*` branch contains a merge commit "Merge branch '\<branch\>' into remote/\<branch\>".
- SVN HEAD revision has increased.
- If the user chose to create a release tag: `git tag -l "<branch>-release-*"` shows the new tag, and `git rev-parse <tag-name>` equals `git rev-parse remote/<branch>`.
