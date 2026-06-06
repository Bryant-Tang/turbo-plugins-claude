[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Merge the latest `main` into every local branch that is neither `main` itself nor a
# `remote-svn/*` bridge branch.
#
# NEW semantics vs the old tgs merge-main-into-all this was ported from:
#   - Exclude filter excludes `main` AND `remote-svn/*` only. The old `^archives/`
#     exclusion is DROPPED (turbo-plugin retired the dev-flow / archive worktrees).
#   - NO worktree-aware path (no Get-BranchWorktreeMap). turbo-plugin does not manage
#     dev/archive worktrees, so we operate purely in the main worktree: for each target
#     branch checkout -> merge main -> (abort on conflict) and restore the original
#     branch at the end.
#   - Conflict handling is per-branch: on conflict we `git merge --abort` THAT branch,
#     mark it CONFLICT in the output, and CONTINUE to the next branch (we never leave a
#     conflicted tree and never stop the whole run).
#
# Guard: if the main worktree is dirty at start we fail loudly before touching anything —
# merging into a dirty tree would be unsafe and the checkout dance would refuse anyway.
try {
    Probe-GitVersion

    $mainWorktree = Get-MainWorktree

    # Refuse to run from / against a dirty main worktree.
    $status = (& git -C $mainWorktree status --porcelain 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "Main worktree is dirty ($mainWorktree). Commit or stash changes before merging main into all branches."
    }

    # Collect all local branches except 'main' and 'remote-svn/*'.
    $targetBranches = @(
        (& git -C $mainWorktree branch --format='%(refname:short)' 2>$null | Out-String) -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and $_ -ne 'main' -and $_ -notmatch '^remote-svn/' }
    )

    if ($targetBranches.Count -eq 0) {
        Write-Output 'No branches to merge into (only main and remote-svn/* branches exist).'
        exit 0
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()

    $merged   = @()
    $conflict = @()

    # NOTE on stderr handling (PS 5.1): git checkout/merge write progress to stderr even on
    # success (e.g. "Switched to branch 'x'"). Under EAP=Stop, redirecting that native stderr
    # with `2>$null` makes PS 5.1 wrap it as a terminating NativeCommandError. So we call git
    # BARE here (stderr flows to the inherited handle / parent's cmd redirect) and gate purely
    # on $LASTEXITCODE — matching Sync-FromSvn.ps1. Only `merge --abort` (a recovery path whose
    # noise we want swallowed) uses `2>$null | Out-Null`.
    foreach ($branch in $targetBranches) {
        & git -C $mainWorktree checkout $branch
        if ($LASTEXITCODE -ne 0) {
            $conflict += $branch
            Write-Output "CONFLICT $branch (checkout failed)"
            continue
        }

        & git -C $mainWorktree merge main --no-ff -m "Merge branch 'main' into $branch"
        if ($LASTEXITCODE -ne 0) {
            & git -C $mainWorktree merge --abort 2>$null | Out-Null
            $conflict += $branch
            Write-Output "CONFLICT $branch (merge aborted)"
        } else {
            $merged += $branch
            Write-Output "OK $branch"
        }
    }

    # Restore the branch we started on.
    & git -C $mainWorktree checkout $originalBranch
    if ($LASTEXITCODE -ne 0) { throw "Could not switch back to original branch '$originalBranch'." }

    Write-Output ''
    Write-Output '─── Summary ─────────────────────────────────────────────────────────'
    Write-Output ("Merged cleanly: " + $(if ($merged.Count -gt 0) { $merged -join ', ' } else { '(none)' }))
    Write-Output ("CONFLICT (aborted): " + $(if ($conflict.Count -gt 0) { $conflict -join ', ' } else { '(none)' }))

    if ($conflict.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
