---
name: start-dev
description: 'Start a new bugfix or feature workflow by creating or switching to a dedicated branch and matching specs folder. Use when a new requirement needs its own bugfix/<slug> or feature/<slug> branch and corresponding specs/bugfix/<slug>/ or specs/feature/<slug>/ folder. Goal definition is handled separately by write-goal — this skill stops once the branch and specs folder are ready.'
argument-hint: 'Optional: bugfix/<slug> | feature/<slug>'
user-invocable: true
---

# Start Dev

## When to Use
- A new bug fix starts and it should live on its own `bugfix/<slug>` branch.
- A new feature starts and it should live on its own `feature/<slug>` branch.

## Outcome
- One dedicated branch name is confirmed.
- The branch exists in git (created via `/tgs:create-branch` if it did not already exist).
- One matching specs folder exists under `specs/bugfix/` or `specs/feature/`.
- The work is ready for `write-goal` to define the requirement.

## Plugin Boundary

This skill belongs to tdp's dev workflow. It owns the **dev workflow conventions** — the `<type>/<slug>` branch namespace, the matching `specs/<type>/<slug>/` folder, and the SQL slug folders. It **delegates** branch creation to tgs's `/tgs:create-branch` primitive instead of running `git` directly, so that branch lifecycle has a single owner (tgs) and `release` / `archive` see consistent state.

This skill requires the `turbo-git-with-remote-svn` (tgs) plugin to be installed.

## Naming And Path Rules
- Every requirement gets exactly one dedicated branch.
- Branch names must start with `bugfix/` or `feature/`.
- The slug after the prefix may contain English letters (upper and lower case), digits, and hyphens only. Spaces and other special characters are not allowed. Examples: `feature/add-payment-flow`, `bugfix/fix-login-error`.
- `bugfix/<slug>` maps to `specs/bugfix/<slug>/`.
- `feature/<slug>` maps to `specs/feature/<slug>/`.
- SQL work-item folders for this branch must use the same `<slug>`: `sql files/local-db/<slug>/`, `sql files/test-db/<slug>/`, and `sql files/main-db/<slug>/`. This allows `finish-dev` to detect and archive them automatically when the work is complete.
- Do not mix unrelated requirements in one branch or one specs folder.

## Procedure
1. Determine whether the requirement is a bug fix or a feature.
2. Determine the branch slug. If the slug is ambiguous, ask the user before creating or reusing any branch or specs path.
3. Confirm the intended branch name with the user.
4. **Branch handling**:
   - **If the branch does not yet exist**, delegate to `/tgs:create-branch` to create it from `main` and switch to it. tgs handles all pre-flight checks (target name not in use, `main` exists, main worktree clean) and reports back.

     ```
     /tgs:create-branch --name <type>/<slug> --base main
     ```

     If `/tgs:create-branch` fails (e.g., because the working tree is dirty), surface its error to the user and stop — do not retry with raw `git` commands. The user must commit, stash, or otherwise make the working tree safe before re-running `/tdp:start-dev`.

   - **If the branch already exists**, switch to it with `git checkout <type>/<slug>` after verifying the working tree is clean (`git status --porcelain` empty). If the tree is not clean, stop and explain the blocker instead of forcing a branch change.
5. Create the matching specs folder under `specs/<type>/<slug>/` if it does not exist. **Folder creation stays in tdp** — tgs has no opinion about `specs/` layout.

## Decision Rules
- If the user bundled more than one independent requirement together, split them into separate branches and separate specs folders instead of sharing one workflow.
- If an existing branch name or specs path does not match the requirement, ask whether to create a new one instead of silently reusing the wrong location.
- Never run `git checkout -b` directly from this skill. New branch creation always goes through `/tgs:create-branch` so that tgs remains the single owner of branch lifecycle.
- Branch slugs must not collide with the `archives/` namespace. Names like `feature/<slug>` and `bugfix/<slug>` are safe; tgs's `archive` primitive handles the move into `archives/<type>/<slug>` later.

## Completion Checks
- Branch name follows the prefix rule (`bugfix/<slug>` or `feature/<slug>`).
- Branch exists in git (`git rev-parse --verify refs/heads/<type>/<slug>` succeeds).
- HEAD of the main worktree is on the dedicated branch.
- Specs folder matches the branch slug and exists at `specs/<type>/<slug>/`.

## Handoff

After the branch and specs folder are ready, tell the user:

> 分支與 specs 資料夾準備好了。接下來請執行 `/tdp:write-goal` 建立並討論 `goal.md`，把需求範圍、預期結果、限制、影響與驗證方向釐清到可進入規劃的程度。
