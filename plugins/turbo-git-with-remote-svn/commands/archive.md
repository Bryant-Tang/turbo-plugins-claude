---
description: 'Atomically rename a git branch and move one or more directories. Pre-flight checks the rename target does not exist, the source branch and source paths exist, destinations are clear, and the source branch is already merged into main. On move failure, attempts a best-effort rollback. Use when a higher-level workflow needs to archive a unit of work atomically.'
argument-hint: 'Required: --branch-from <old> --branch-to <new> --move <from>=<to> (repeatable)'
allowed-tools: Bash, PowerShell
---

# archive

Performs a near-atomic rename + move operation as a single primitive:

1. Renames the source git branch to the target name (single atomic git op).
2. Moves each `<from>` directory to its `<to>` location, in the order given.
3. On any failure during the moves, attempts a best-effort rollback: moves already-moved folders back to their original locations (in reverse order), then renames the branch back.

The command does not know about any project-specific naming convention. Callers (e.g. `/tdp:finish-dev`) compute the rename and the path mappings.

Run from any worktree of the project; the script auto-locates the main worktree.

## Arguments

| Argument | Required | Description |
|---|---|---|
| `--branch-from` / `-BranchFrom` | Yes | Source branch name |
| `--branch-to` / `-BranchTo` | Yes | Target branch name (must not already exist) |
| `--move` / `-Move` | Yes (≥1) | Path mapping `<from>=<to>`. Paths are relative to the main worktree |

## Pre-flight Checks

The script verifies before making any changes:

1. Source branch exists; target branch does not exist.
2. Source branch is an ancestor of `main` (its work is already merged).
3. Main worktree is clean (no uncommitted changes).
4. Main worktree is not currently on the source branch.
5. Source branch is not currently checked out in any other worktree.
6. Each `--move` source path exists and each destination path does not exist.
7. Branch names match the safe character set `[A-Za-z0-9._/-]+`.

If any check fails, the script exits non-zero with a clear message and modifies no state.

## Execution

Both shells use **repeated** `--move` / `-Move` flags (one flag per mapping). PowerShell's array parameter binding does not survive the `powershell -File ...` boundary cleanly when the caller is itself a PowerShell, so the script uses manual argument parsing to support repeated flags consistently with the bash version.

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/archive.ps1" `
    -BranchFrom "feature/user-login" `
    -BranchTo "archives/feature/user-login" `
    -Move "specs/feature/user-login=specs/archives/feature/user-login" `
    -Move "sql files/local-db/user-login=sql files/archives/local-db/user-login"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/archive.sh" \
    --branch-from "feature/user-login" \
    --branch-to "archives/feature/user-login" \
    --move "specs/feature/user-login=specs/archives/feature/user-login" \
    --move "sql files/local-db/user-login=sql files/archives/local-db/user-login"
```

## Output

Per-step lines:

- `Renamed branch '<from>' -> '<to>'.`
- `Moved '<from>' -> '<to>'.` per folder
- `Archive complete: ...` on success

On failure mid-execution, an error to stderr followed by either:

- `Archive failed mid-way; rollback succeeded.` (clean recovery), or
- `Archive failed mid-way and rollback was incomplete.` followed by the precise list of unsuccessful rollback steps (manual recovery needed).

## Caller Conventions

This is a primitive — it does not validate that names follow `archives/<type>/<slug>` or that paths follow `specs/<type>/<slug>` style. Callers compute those.

Typical caller: `/tdp:finish-dev` constructs the slug-based mapping (branch + spec folder + zero-to-three SQL folders) and invokes this command once per slug.
