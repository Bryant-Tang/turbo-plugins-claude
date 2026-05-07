---
description: 'Release dev branches to production by merging into main, pushing main to SVN trunk, optionally aligning test-<n> back to main, and cleaning up dev worktrees. Three modes: interactive full release of a test cycle, explicit subset release, or hotfix straight to main without going through a test branch. Use when validation passes and the user wants to publish, ship, deploy to production, finalise a test cycle, or run a hotfix release.'
argument-hint: '[--n <number>] [--branch <name> ...] (at least one of --n or --branch is required)'
allowed-tools: Bash, PowerShell
---

# release

## Purpose

Compose existing tgs primitives into a single end-of-cycle workflow. After a
release succeeds, `main` and the SVN trunk reflect the new production state,
and the relevant `test-<n>` slot has been realigned (or left holding the
unreleased remainder for partial releases).

The command never invents new git mechanics — it orchestrates:

1. Merge selected dev tips into `main` (one merge commit per tip,
   `--no-ff`)
2. Delegate `/tgs:push-to-svn --branch main` (which also offers the
   release-tag prompt)
3. Optionally delegate `/tgs:reset-remote-test --n <n>` (when full release)
4. Interactively clean up the `dev-<m>` worktrees and branches whose tips are
   now in `main`

## Modes

| Mode | Flags | Behaviour |
|---|---|---|
| **A. test-cycle full / partial** | `--n <n>` and **no** `--branch` | Detect candidate dev merges in `main..test-<n>`, ask the user to pick. Full selection → reset `test-<n>`. Partial selection → skip reset (test-<n> retains the unreleased remainder). |
| **B. test-cycle explicit** | `--n <n>` and one or more `--branch <name>` | No interactive picker. Each `--branch` must match a detected merge (substring of subject). Full coverage → reset; subset → skip reset. |
| **C. hotfix** | No `--n`, one or more `--branch <name>` | Merge each branch's current HEAD straight into `main`, push to SVN. No test-<n> involvement. |

Reject input where neither `--n` nor `--branch` is given.

## Tool Preference

Read / Write / Edit / Glob / Grep / LSP for any file inspection or change.
Avoid Bash / PowerShell / Python / Node.js for filesystem operations. Bash /
PowerShell are only for invoking the helper scripts (`release-detect-merges`,
`release-merge-tips`) and for delegating to other tgs commands.

## Procedure

### Step 1: Resolve mode and validate input

- Parse `--n` and `--branch` arguments (parameter form — note that `--branch`
  may be repeated).
- If neither was given, fail with a message explaining the three modes above
  and asking which mode the user wants.
- Decide mode A / B / C from the table above.
- For modes A / B, verify `test-<n>` exists in git (otherwise reject).
- For mode C, **reject any branch whose name starts with `archives/`** —
  archived branches must not be re-released. The same exclusion applies to
  candidate detection in modes A / B (see Step 3).

### Step 2: Pre-flight checks

Verify (deferring to scripts where possible, or doing the equivalent checks
manually):

- The main worktree is clean (`git status --porcelain` empty).
- The `remote-main` worktree exists and is clean.
- (Modes A / B only) The `remote-test-<n>` worktree exists and is clean.
- main has no commits not yet pushed to SVN trunk:
  - `git -C <main-worktree> log remote/main..main` should be empty.

If any check fails, surface a clear error and stop. Do **not** continue
into release.

### Step 3: Resolve the items to release

#### Mode A (interactive detection)

Run the detection script:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/release-detect-merges.ps1" -N "1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/release-detect-merges.sh" --n "1"
```

The script outputs one line per candidate:

```
<merge_hash>|<tip_hash>|<subject>|<branch_status>
```

`<branch_status>` is one of:
- `AT_TIP:<comma-separated branches>` — branches still pointing exactly at the tip
- `ADVANCED:<comma-separated branches>` — branches that contain the tip but their HEAD has moved past it
- `NONE` — no current branch corresponds to the tip (branch deleted or renamed)

Already-released merges (tips already in `main`), SVN-bridge merges
(`pull-from-svn` artifacts), and any branches under the `archives/`
namespace are filtered out automatically — archived branches represent
completed work and must not surface as candidates.

If the output is empty, tell the user there is nothing to release on
`test-<n>` and stop.

Display the candidates in a numbered list, with each `branch_status`
translated to a human-readable annotation, and call `AskUserQuestion`
(multi-select) so the user picks which merges to release.

If the user selects nothing, stop.

Track the selected items as `(merge_hash, tip_hash, subject)` tuples.

#### Mode B (explicit subset)

Run the same detection script. For each `--branch <name>`:

- Reject names that start with `archives/`.
- Find the candidate whose `<subject>` contains `'<name>'` (the standard git
  merge subject is `Merge branch '<name>' into <test-<n>>`, so substring match
  on the quoted name is reliable).
- If none match: fail with `'<name>' is not in test-<n> candidates; use hotfix
  mode (omit --n) to release directly from the branch HEAD`.
- If multiple match (rare — duplicate name across cycles): fail with a list
  and ask the user to disambiguate by re-running mode A.

Track the resolved items.

#### Mode C (hotfix)

For each `--branch <name>`:

- Reject names that start with `archives/`.
- Verify the local branch exists (`git rev-parse --verify refs/heads/<name>`).
- If not, fail with a clear error.

Track the items as branch names (no merge_hash, no subject — those are
generated by the merge script).

### Step 4: Show the release plan and confirm

Format the plan summary like this (translate to user's language):

```
即將執行 release（模式 X）：

  1. 在 main worktree merge 以下進 main（--no-ff）：
     - <subject> (tip <short hash>)
     - ...
  2. /tgs:push-to-svn --branch main      （含 release tag 互動）
  3. <模式 A 全選 / 模式 B 全部涵蓋> /tgs:reset-remote-test --n <n>
     <模式 A 部分選 / 模式 B 子集>     test-<n> 將保留 X 個未 release 的 merge，請稍後手動跑 /tgs:reset-remote-test --n <n>
     <模式 C>                          不處理任何 test-<n>
  4. 互動式清理 dev worktree（per-tip 確認）
```

For modes A / B, compare `selected_count` with the total `detected_count`
from Step 3. If they match, mark the run as **full release** and include
step 3's reset; otherwise mark as **partial release** and include the skip
note.

For mode C, omit step 3 entirely.

Ask via `AskUserQuestion`:
- Option A: Proceed
- Option B: Cancel (default)

If the user cancels, stop.

### Step 5: Execute the merges

Modes A / B:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/release-merge-tips.ps1" -MergeCommits "<csv of selected merge hashes>"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/release-merge-tips.sh" --merge-commits "<csv of selected merge hashes>"
```

Mode C:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/release-merge-tips.ps1" -HotfixBranches "<csv of branch names>"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/release-merge-tips.sh" --hotfix-branches "<csv of branch names>"
```

The script switches the main worktree to `main`, merges each tip with
`--no-ff`, and switches back. On a merge conflict it leaves the main worktree
on `main` with the conflict in place and exits non-zero. If that happens,
report:

> 「Step 5 在 merge `<tip>` 時遇到衝突；main worktree 目前在 `main` 並停在
> conflict 狀態。請手動解決後 `git merge --continue`，或 `git merge --abort`
> 放棄；release 已停止，剩下的步驟（push、reset、cleanup）需要手動接續。」

Then stop. **Do not continue to step 6 or beyond.**

### Step 6: Push main to SVN

Delegate to the existing command:

```
/tgs:push-to-svn --branch main
```

Suggest a commit message such as `release: <comma-list of subjects>` (or
`release: hotfix <branches>` for mode C). Allow the existing command to ask
about the release tag — answer per the user's preference.

If `push-to-svn` fails, report it and stop. The merges have already landed
in local `main`; the user can re-run `push-to-svn` after fixing the issue.

### Step 7: Reset test-<n> (only when applicable)

Run only if all of the following hold:

- Mode is A or B.
- `selected_count == detected_count` (full coverage).

Delegate:

```
/tgs:reset-remote-test --n <n>
```

`reset-remote-test` will surface its own diff preview and confirmation. If it
fails, report — the prior steps remain valid; the user can rerun
`/tgs:reset-remote-test --n <n>` later.

### Step 8: Clean up dev worktrees (interactive, per item)

Iterate the released items. For each tip `T`:

1. Look up branches still pointing exactly at `T` (excluding `main`,
   `test-*`, `remote/*`, **and `archives/*`**):

```powershell
git -C <main-worktree> branch --points-at <T> --format='%(refname:short)'
```

   Filter out `main`, `test-<n>` patterns, any `remote/*`, and any
   `archives/*` (archived branches must not be touched by cleanup).

2. **If exactly one branch matches:**

   a. Find any worktree that has it checked out:

```powershell
git -C <main-worktree> worktree list --porcelain
```

   Parse the output for the `branch refs/heads/<name>` line and remember the
   `worktree <path>` that immediately precedes it.

   b. Use `AskUserQuestion` (single-select) with these options:
      - Remove worktree + delete branch
      - Delete branch only
      - Keep both (default)

   c. Execute the chosen action:
      - `git -C <main-worktree> worktree remove <path>`
      - `git -C <main-worktree> branch -D <name>`
      - Remove the worktree's folder entry from `<proj>.code-workspace`
        (load JSON, filter `folders` by `name`, write UTF-8 no BOM)

3. **If zero branches match** (branch was deleted, renamed, archived, or has
   advanced):
   - Print an informational note ("tip released; no exact branch match for
     cleanup") and skip. **Do not** delete branches that contain the tip but
     have advanced past it — that would discard untested work. Branches
     under `archives/` are skipped by design, since they have already been
     archived by `/tdp:finish-dev`.

4. **If multiple branches match** (rare): list them and ask the user to
   handle cleanup manually; skip the auto-cleanup for this tip.

### Step 9: Final summary

Print:
- Mode (A/B/C) and full-vs-partial.
- Number of tips released.
- Whether `test-<n>` was reset (or "skipped — N merges remain").
- Number of dev worktrees / branches cleaned up.
- Reminder for partial releases: `tgs:reset-remote-test --n <n>` is the
  follow-up action when test-<n> is finally cleared.

## Decision Rules

- `--n <n>` must be a positive integer when provided.
- Each `--branch <name>` must reference an existing local branch (mode C) or
  an existing detected merge (mode B).
- Branches under the `archives/` namespace are never released, never
  detected as candidates, and never cleaned up. They represent completed,
  archived work owned by `/tdp:finish-dev`.
- The merges in step 5 are non-fast-forward by design — every release leaves a
  visible merge commit on `main` for traceability.
- The whole pipeline is fail-stop. No automatic rollback. Report exactly which
  step failed so the user can resume manually.
- Can be called from any worktree in the project — every script resolves the
  main worktree itself.

## Notes

- **dev → test-<n> must be merged with `--no-ff`.** Mode A / B detection
  relies on the merge commit's parent[1] to identify the dev tip. A
  fast-forward merge produces no merge commit, so the work will be invisible
  to detection. If you discover this after the fact, either re-merge the
  branch into `test-<n>` with `--no-ff` and re-run release, or use mode C to
  release the branch HEAD directly (acknowledging that mode C releases the
  branch's *current* HEAD, not the version that was tested).
- **Partial release leaves `test-<n>` "messy" on purpose**: the unreleased
  merges and any test-only commits stay in `test-<n>`. That is normal; the
  detection in the next release run will automatically skip the merges whose
  tips have already landed in `main`. When `test-<n>` is finally empty of
  releasable work, `/tgs:reset-remote-test --n <n>` collapses everything
  back to main.
- **Test-only commits never appear as candidates.** Detection only enumerates
  merge commits; raw commits made directly on `test-<n>` are ignored. They
  are discarded when `test-<n>` is eventually reset.

## Completion Checks

- Each released tip is reachable from `main` (`git merge-base --is-ancestor
  <tip> main` succeeds).
- `main` contains a `Release: ...` merge commit per released item.
- `push-to-svn` reported success and the SVN trunk revision advanced (or
  `No changes to commit` if nothing differed at the SVN level).
- For full release: `git rev-parse test-<n>` equals `git rev-parse main`.
- For partial release: at least one merge from `test-<n>` is now in `main`,
  but `test-<n>` HEAD differs from `main` HEAD.
- Dev worktree cleanups, where confirmed, leave no entry for the removed
  worktree in `<proj>.code-workspace` and no branch in `git branch`.
- No `archives/*` branch was renamed, deleted, or otherwise touched by the
  release run.
