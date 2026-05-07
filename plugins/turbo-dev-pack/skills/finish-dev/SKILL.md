---
name: finish-dev
description: 'Archive a completed bugfix or feature workflow by renaming its branch into the archives/ namespace and moving its specs and SQL folders into the archives/ trees. Use when a branch has been merged into main and the user wants to archive the work — branch rename and folder moves happen as a single delegated tgs:archive call.'
argument-hint: 'Optional: bugfix/<slug> | feature/<slug>'
user-invocable: true
---

# Finish Dev

## When to Use
- A bugfix or feature branch has been merged into `main` (typically via `/tgs:release`) and the work is complete.
- The branch should move into the `archives/` namespace and its specs / SQL folders should follow into their archived locations.
- The user wants to keep both the git branch list and the working file tree tidy by archiving completed work in one shot.

## Outcome
- The git branch is renamed: `<type>/<slug>` → `archives/<type>/<slug>`.
- `specs/<type>/<slug>/` is moved to `specs/archives/<type>/<slug>/`.
- Any existing `sql files/local-db/<slug>/`, `sql files/test-db/<slug>/`, and `sql files/main-db/<slug>/` folders are moved to their corresponding paths under `sql files/archives/`.
- The branch rename and all folder moves happen as a single delegated `/tgs:archive` call, with rollback on partial failure.

## Plugin Boundary

This skill belongs to tdp's dev workflow. It owns the **archive conventions** — the `archives/<type>/<slug>` branch namespace, the `specs/archives/<type>/<slug>/` folder layout, and the `sql files/archives/<env>-db/<slug>/` SQL folder layout. It **delegates** the actual rename + move execution to tgs's `/tgs:archive` primitive, which knows nothing about these conventions but provides atomicity and rollback.

This skill requires the `turbo-git-with-remote-svn` (tgs) plugin to be installed.

## Archive Path Rules

| Source | Archive Destination |
|---|---|
| Branch `<type>/<slug>` | Branch `archives/<type>/<slug>` |
| `specs/bugfix/<slug>/` | `specs/archives/bugfix/<slug>/` |
| `specs/feature/<slug>/` | `specs/archives/feature/<slug>/` |
| `sql files/local-db/<slug>/` | `sql files/archives/local-db/<slug>/` |
| `sql files/test-db/<slug>/` | `sql files/archives/test-db/<slug>/` |
| `sql files/main-db/<slug>/` | `sql files/archives/main-db/<slug>/` |

## Procedure

### Step 1: Determine the target branch

- If the user passed `bugfix/<slug>` or `feature/<slug>` as the skill argument, use that.
- Otherwise, read the current branch with `git branch --show-current`.
- If the current branch is not a `bugfix/` or `feature/` branch (e.g. it is `main`, an `archives/*`, a `dev-<n>`, or a `test-<n>`), ask the user which branch to finish before continuing.
- Reject input where the branch already starts with `archives/` — that branch has been archived already.

Extract `<type>` (`bugfix` or `feature`) and `<slug>` from the branch name.

### Step 2: Inventory source folders

Check which of the following exist (each is independent — any subset may be present):

- `specs/<type>/<slug>/`
- `sql files/local-db/<slug>/`
- `sql files/test-db/<slug>/`
- `sql files/main-db/<slug>/`

If **none** of these exist, tell the user there is nothing to archive and stop. (`/tgs:archive` requires at least one folder move; if the user wants to rename the branch alone they must do that manually.)

### Step 3: Build the move mappings

For each source folder that exists, build one path-mapping entry for the `--move` argument:

| Source | Target |
|---|---|
| `specs/<type>/<slug>/` | `specs/archives/<type>/<slug>/` |
| `sql files/<env>-db/<slug>/` (any env) | `sql files/archives/<env>-db/<slug>/` |

Skip entries whose source does not exist.

### Step 4: Show confirmation summary

Using `AskUserQuestion`, present a single confirmation page that lists:

- The branch rename: `<type>/<slug>` → `archives/<type>/<slug>`
- Each folder move (only those with an existing source)
- Any pre-detected conflicts (target paths or target branch already exist) — surface these as warnings; the user can still cancel

Options:
- Proceed (default to **not** selected so the user must consciously confirm)
- Cancel

If the user cancels, make no changes.

### Step 5: Switch off the target branch if necessary

`/tgs:archive` rejects renaming the branch the main worktree is currently on. If the current branch is `<type>/<slug>`, switch to `main` first:

```powershell
git -C <main-worktree> checkout main
```

```bash
git -C "$MAIN_WORKTREE" checkout main
```

If the working tree is dirty and the checkout fails, surface the error and stop. Do not force the switch.

### Step 6: Delegate to /tgs:archive

Compose the call with all `--move` mappings collected in Step 3. **Both PowerShell and bash use repeated `--move` / `-Move` flags** (one flag per mapping). Do not concatenate paths into a single comma-separated value — the script intentionally treats each repeated flag as a discrete mapping so paths with commas / equals signs would be unambiguous.

```
/tgs:archive --branch-from <type>/<slug> --branch-to archives/<type>/<slug> \
    --move "specs/<type>/<slug>=specs/archives/<type>/<slug>" \
    --move "sql files/local-db/<slug>=sql files/archives/local-db/<slug>" \
    --move "sql files/test-db/<slug>=sql files/archives/test-db/<slug>" \
    --move "sql files/main-db/<slug>=sql files/archives/main-db/<slug>"
```

(Include only the `--move` lines for folders that actually exist.)

`/tgs:archive` performs its own pre-flight checks — among them, the source branch must already be an ancestor of `main` (i.e. merged). If the branch is not yet merged, the command will reject with a clear message; ask the user to merge first (typically via `/tgs:release`) and re-run `/tdp:finish-dev`.

### Step 7: Report

Surface `/tgs:archive`'s output to the user. On success, summarise:
- The new branch name (`archives/<type>/<slug>`)
- The folder moves that were performed
- Any folders that did not exist and were therefore not moved

On failure, report exactly what `/tgs:archive` reported (including any rollback details).

## Decision Rules
- The git branch rename is **inside** this skill's scope (handled via `/tgs:archive`). This is the new behaviour — the previous version of `finish-dev` left the branch alone.
- This skill never deletes a branch; the rename into `archives/` preserves the full git history.
- Do not commit the file moves; leave the resulting working-tree state for the user to review and commit (typical `chore:` commit).
- If the user cancels at the confirmation step, make no changes.
- Source folders that do not exist are silently skipped — they are not an error, but if **all** are absent the skill stops at Step 2.
- Never chain state-changing shell commands with `&&`. Run each `git checkout` and the `/tgs:archive` invocation as separate steps.
- Branches already under `archives/` are rejected at Step 1 — they cannot be archived twice.

## Completion Checks
- `git rev-parse --verify refs/heads/<type>/<slug>` fails (branch no longer exists at the active name).
- `git rev-parse --verify refs/heads/archives/<type>/<slug>` succeeds (branch exists in the archives namespace).
- The originally-listed source folders no longer exist at their active paths (or never existed).
- All moved folders exist under the corresponding `archives/` paths.
- The user was informed of what was moved and what was skipped.
- No commit was created automatically.
