---
name: finish-dev
description: 'Archive the specs folder and SQL work-item folders for a completed bugfix or feature branch. Use when a branch is merged or the work is done and specs/<type>/<slug> and sql files/*-db/<slug> folders should be moved to their respective archives locations under specs/archives/ and sql files/archives/.'
argument-hint: 'Optional: bugfix/<slug> | feature/<slug>'
user-invocable: true
---

# Finish Dev

## When to Use
- A bugfix or feature branch has been merged or the work is complete.
- The specs folder and SQL file folders for the branch should be moved out of the active working area.
- The user wants to keep the repository tidy by archiving completed work.

## Outcome
- `specs/<type>/<slug>/` is moved to `specs/archives/<type>/<slug>/`.
- Any existing `sql files/local-db/<slug>/`, `sql files/test-db/<slug>/`, and `sql files/main-db/<slug>/` folders are moved to their corresponding paths under `sql files/archives/`.
- All required archive parent directories are created if they do not already exist.

## Archive Path Rules

| Source | Archive Destination |
|---|---|
| `specs/bugfix/<slug>/` | `specs/archives/bugfix/<slug>/` |
| `specs/feature/<slug>/` | `specs/archives/feature/<slug>/` |
| `sql files/local-db/<slug>/` | `sql files/archives/local-db/<slug>/` |
| `sql files/test-db/<slug>/` | `sql files/archives/test-db/<slug>/` |
| `sql files/main-db/<slug>/` | `sql files/archives/main-db/<slug>/` |

## Procedure
1. Determine the target branch:
   - If the user passed `bugfix/<slug>` or `feature/<slug>` as the skill argument, use that.
   - Otherwise, read the current branch with `git branch --show-current`.
   - If the current branch is not a `bugfix/` or `feature/` branch, ask the user which branch to finish before continuing.
2. Extract `<type>` (`bugfix` or `feature`) and `<slug>` from the branch name.
3. Check which source paths exist:
   - `specs/<type>/<slug>/`
   - `sql files/local-db/<slug>/`
   - `sql files/test-db/<slug>/`
   - `sql files/main-db/<slug>/`
4. If none of the above exist, tell the user there is nothing to archive and stop.
5. Check whether any archive destination already exists:
   - `specs/archives/<type>/<slug>/`
   - `sql files/archives/local-db/<slug>/`
   - `sql files/archives/test-db/<slug>/`
   - `sql files/archives/main-db/<slug>/`
   - If any destination already exists, include a conflict warning in the confirmation summary and ask whether to skip or overwrite before proceeding.
6. Show a confirmation summary using `AskUserQuestion`: list every path that will be moved and its destination, including any conflict warnings. Do not make any changes until the user confirms.
7. Create any missing archive parent directories. Run each `mkdir` as a separate step; do not chain with `&&`.
   - `specs/archives/<type>/` if it does not exist
   - For each SQL env whose source folder exists: `sql files/archives/<env>/` if it does not exist
8. Move each source folder that exists. Run each move as a separate step; do not chain with `&&`.
   - Move `specs/<type>/<slug>/` to `specs/archives/<type>/<slug>/` if the source exists.
   - Move `sql files/local-db/<slug>/` to `sql files/archives/local-db/<slug>/` if the source exists.
   - Move `sql files/test-db/<slug>/` to `sql files/archives/test-db/<slug>/` if the source exists.
   - Move `sql files/main-db/<slug>/` to `sql files/archives/main-db/<slug>/` if the source exists.
9. Report which paths were moved and which were not found.

## Decision Rules
- Do not delete the git branch; branch lifecycle is outside the scope of this skill.
- Do not commit the changes; leave the file moves for the user to review and commit.
- If the archive destination already contains a folder with the same slug, warn the user and ask whether to skip or overwrite before proceeding.
- If the user cancels at the confirmation step, make no changes.
- Source paths that do not exist are silently skipped — they are not an error.
- Never chain state-changing shell commands with `&&`. Run each mkdir and each move as a separate command.

## Completion Checks
- `specs/<type>/<slug>/` no longer exists at the original active path (or was not found).
- Any moved SQL folders no longer exist at their original `sql files/<env>/<slug>/` paths.
- All moved items now exist under the corresponding `archives/` paths.
- The user was informed of what was moved and what was not found.
- No git branch was deleted and no commit was created.
