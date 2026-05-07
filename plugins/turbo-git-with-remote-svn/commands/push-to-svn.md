---
description: 'Push git commits from the specified branch to SVN by merging into the remote/* branch and committing from the remote-* worktree. The SVN message body lists only meaningful code commits — Merge / doc / spec / db / chore subjects are filtered out. Use when the user wants to send changes to SVN, submit to SVN, or push to SVN.'
argument-hint: 'Required: --branch <main|test-<n>>'
allowed-tools: Bash, PowerShell
---

# push-to-svn

## Purpose

Send git changes to SVN as a single, reviewable commit:

1. Verify the remote-* worktree SVN is up-to-date.
2. **Stage** the merge into `remote/*` with `git merge --no-ff --no-commit` so `svn status` reflects the actual file changes that would be pushed.
3. Show the user one consolidated confirmation page covering:
   - the git commits to be pushed (split into "kept" and "filtered out" by subject prefix)
   - the SVN file changes
   - the **complete** SVN commit message preview (title + body)
4. Finalise the merge commit (`git commit --no-edit`) and SVN-add/delete + commit to SVN.
5. Optionally create a release tag.

## Branch Mapping

| Working branch | Remote worktree | Remote git branch |
|---|---|---|
| `main` | `remote-main` | `remote/main` |
| `test-<n>` | `remote-test-<n>` | `remote/test-<n>` |

## Procedure

### Step 1: Resolve target branch

If `--branch` is not given, check the `TGS_DEFAULT_WORKING_BRANCH` environment variable. If it is set and valid (`main` or `test-<n>`), use that value. Otherwise, use `AskUserQuestion` to ask which branch to push.

### Step 2: Run the prepare script

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-prepare.ps1" -Branch "main"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-prepare.sh" --branch "main"
```

If the output contains `Nothing to push`, report to the user and stop.

If the prepare script exits non-zero (SVN not up-to-date or git worktree not clean), report the error and stop. Ask the user to run `/tgs:pull-from-svn` if SVN is behind.

Parse the prepare output (two sections separated by an empty line):

```
COMMITS
<hash>|<subject>
...

FILES
<status>|<tracked|ignored>|<path>
...
```

After this step the remote worktree is in a "merge prepared but not finalised" state. **All confirmation must happen before finalisation.**

### Step 3: Filter the commit list

Split COMMITS into two lists by **subject prefix**:

- **Filter out** any commit whose subject matches:
  - `^Merge ` (literal `Merge ` prefix — git's default merge commit subjects, including the SVN bridge merge from this prepare run)
  - `^(doc|docs|spec|db|chore)(\([^)]*\))?: ` (the non-code-change types from the commit-msg type vocabulary, with optional scope)
- **Keep** every other commit, including:
  - `feat:` / `fix:` / `refactor:` (with or without scope)
  - any commit with no recognised prefix

The filter is case-sensitive on the type prefix (lowercase `feat:`, not `FEAT:`).

Track three sets:
- `KEPT` — survives the filter, appears in the final SVN body's `本次送交內容` list
- `DROPPED` — filtered out, shown to the user as "filtered" but not in the SVN body
- `ALL` — the original ordered list (used for the all-filtered fallback below)

### Step 4: Compose the SVN commit message

**Title**:
- If `KEPT` has exactly one commit, use its subject as the title.
- If `KEPT` has multiple commits, summarise them in one short phrase (use natural-language summarisation — type prefixes may be stripped or kept depending on what reads best).
- If `KEPT` is empty (every commit was filtered out), use a short fallback title such as `chore: push without code changes` or any natural summary that fits the dropped subjects.

**Body**:
```
<title>

本次送交內容：
- <subject 1>
- <subject 2>
- ...
```

Body content rules:
- If `KEPT` is non-empty, list **kept** subjects only.
- If `KEPT` is empty (full-filter fallback), list **all** original subjects from `ALL` (degrade to no-filter so SVN history still has something concrete). Insert a single explanatory line above the bullet list, e.g.:

  ```
  <title>

  本次推送沒有程式碼層級的異動；以下為所有 git commit 主題：
  - <subject 1>
  - ...
  ```

### Step 5: Single consolidated confirmation

Use **one** `AskUserQuestion` call with a summary that includes everything the user needs to review (translate labels to user's language):

```
即將推送到 SVN（remote-<branch>）：

提交（保留進 SVN body，K 個）：
- <hash> <subject>
- ...

提交（被過濾掉，不會出現在 SVN body，D 個）：
- <hash> <subject>      ← Merge / doc / spec / db / chore
- ...

會送至 SVN 的檔案（M 個）：
+ <added file>           ← A
~ <modified file>        ← M
- <deleted file>         ← D

git 忽略（不會送 SVN，X 個）：
~ <ignored file>

即將寫入 SVN 的訊息：
---
<title>

本次送交內容：
- <subject 1>
- <subject 2>
---
```

Omit empty sections (no dropped → drop that section; no ignored → drop that section). If FILES is empty, show "(無檔案變動)".

For the full-filter fallback case, the "被過濾掉" section becomes the long one and the body listing degrades to all subjects — the summary should reflect that exactly.

Options (single-select):
- **Accept and submit** — proceed to Step 6
- **Edit title** — open a follow-up `AskUserQuestion` text input for a new title, then re-render the consolidated summary with the edited title and re-confirm. The body content (kept subjects or fallback list) is **not** edited; only the title.
- **Cancel** — run `git -C <remote-worktree-path> merge --abort` to discard the staged merge and stop.

```powershell
git -C "<remote-worktree-path>" merge --abort
```

```bash
git -C "<remote-worktree-path>" merge --abort
```

### Step 6: Run the commit script

Construct the final commit message (title + body) and call:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.ps1" -Branch "main" -Message "the full commit message here"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/push-to-svn-commit.sh" --branch "main" --message "the full commit message here"
```

Interpret the commit script output:
- **`Pushed to SVN r<rev>`** → Report success with the new SVN revision. Proceed to Step 7.
- **`No changes to commit to SVN (all pending changes are git-ignored)`** → Report to user that all pending SVN changes are git-ignored and nothing was committed to SVN. Skip Step 7 (no release tag needed).

### Step 7: Optional release tag

Use `AskUserQuestion`:
- Option A: Yes, create a release tag
- Option B: No, skip tagging

If the user chose to create a release tag, call:

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
- If the prepare script exits non-zero due to a **merge conflict**, ask the user to either resolve the conflicts inside the `remote-*` worktree (then re-invoke the command, which will detect the resolved merge and prompt to commit) or run `git -C <remote-worktree> merge --abort` to discard.
- If the prepare script exits non-zero because of an **existing pending merge** (`MERGE_HEAD` already present), tell the user to either re-run `/tgs:push-to-svn` to commit it, or abort it manually.
- If the user **cancels** at the consolidated confirmation step, run `git -C <remote-worktree> merge --abort` immediately to clean up the staged merge.
- Filtering is **commit-list only** — the **file list** in the confirmation always shows every actual change that will be pushed to SVN, regardless of which commits introduced them. Filtering only removes subjects from the body's bullet list; it does not skip files.
- Can be called from any worktree in the project.

## Completion Checks

- The commit script outputs `Pushed to SVN r<new-rev>`.
- The `remote/*` branch contains a merge commit "Merge branch '\<branch\>' into remote/\<branch\>".
- SVN HEAD revision has increased.
- The committed SVN message body's `本次送交內容` list contains only kept subjects (or the full list, in the all-filtered fallback case).
- No `Merge ` / `doc:` / `docs:` / `spec:` / `db:` / `chore:` subject appears in the body unless the all-filtered fallback was triggered.
- If the user chose to create a release tag: `git tag -l "<branch>-release-*"` shows the new tag, and `git rev-parse <tag-name>` equals `git rev-parse remote/<branch>`.
