[CmdletBinding()]
param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Missing required argument: -Branch <branch>'
    }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Please commit or stash before pulling from SVN.`n$mainStatus"
    }

    # Dirty-check the remote worktree. v0.5.0 U12: `.svn/` is now in the bridge's .gitignore
    # (synced from main by New-RemoteBridge), so git ignores SVN's binary metadata and we no
    # longer hand-filter `.svn/*`; genuine manual edits are still caught and would otherwise be
    # packaged into the sync commit.
    $remoteStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if ($remoteStatus) {
        throw "Remote worktree '$($remote.Path)' has uncommitted changes — these would be packaged into the sync commit. Resolve before pulling.`n$remoteStatus"
    }

    # F-U(synth #11): detect previously-orphaned remote sync commit (svn update + git commit
    # succeeded last time but the subsequent merge into $Branch was aborted). Refuse fast-path
    # until the user resolves it (manual merge or rerun /tp-pull-from-svn after committing conflict resolution).
    $unmergedRemoteRaw = (& git -C $mainWorktree log --oneline "$Branch..$($remote.Branch)" | Out-String).TrimEnd("`r","`n")
    $unmergedRemoteLines = @($unmergedRemoteRaw -split "`n" | Where-Object { $_ })
    if ($unmergedRemoteLines.Count -gt 0) {
        $unmergedDisplay = $unmergedRemoteLines -join "`n"
        throw "remote/$($remote.Branch) has $($unmergedRemoteLines.Count) unmerged sync commit(s) ahead of '$Branch':`n$unmergedDisplay`n`nResolve via manual merge (git -C $mainWorktree merge $($remote.Branch)) or rerun /tp-pull-from-svn after the conflict is committed."
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    Write-Output "Running svn update in $($remote.Name)..."
    Push-Location $remote.Path
    try {
        & svn update
        if ($LASTEXITCODE -ne 0) { throw 'svn update failed' }
        $svnRev = (& svn info --show-item revision | Out-String).Trim()
    } finally {
        Pop-Location
    }

    $remoteStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if (-not $remoteStatus) {
        Write-Output "Already up to date at SVN r$svnRev"
        exit 0
    }

    & git -C $remote.Path add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed in remote worktree' }
    & git -C $remote.Path commit -m "sync: svn r$svnRev"
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed in remote worktree' }

    $switched = $false
    if ($originalBranch -ne $Branch) {
        Write-Output "Switching main worktree from '$originalBranch' to '$Branch'..."
        & git -C $mainWorktree checkout $Branch
        if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
        $switched = $true
    }

    & git -C $mainWorktree merge $remote.Branch --no-ff -m "Merge branch '$($remote.Branch)' into $Branch"
    $mergeExit = $LASTEXITCODE

    if ($mergeExit -ne 0) {
        $conflicts = (& git -C $mainWorktree diff --name-only --diff-filter=U | Out-String).Trim()
        # Rollback: abort the merge and return to original branch so the worktree is clean.
        # Capture each rollback op's exit code separately so we can detect rollback failure
        # and emit a distinct error (working tree may be in an inconsistent state).
        & git -C $mainWorktree merge --abort 2>$null | Out-Null
        $abortStatus = $LASTEXITCODE
        $checkoutStatus = 0
        if ($switched) {
            & git -C $mainWorktree checkout $originalBranch 2>$null | Out-Null
            $checkoutStatus = $LASTEXITCODE
        }
        if ($abortStatus -ne 0 -or $checkoutStatus -ne 0) {
            throw "Merge conflict detected; automatic rollback failed (abort exit=$abortStatus, checkout exit=$checkoutStatus). Working tree is in an inconsistent state. Resolve manually before re-running."
        }
        throw "Merge conflict detected. The merge has been aborted and main worktree restored to '$originalBranch'. Conflicting files:`n$conflicts`n`nResolve conflicts manually, commit, then rerun '/tp-pull-from-svn'."
    }

    if ($switched) {
        & git -C $mainWorktree checkout $originalBranch
        if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        Write-Output "Switched back to '$originalBranch'."
    }

    Write-Output "Pulled SVN r$svnRev into $Branch"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
