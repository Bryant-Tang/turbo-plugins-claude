param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

function Resolve-RemoteWorktree {
    param([string]$BranchName, [string]$WorktreesDir)
    if ($BranchName -eq 'main') {
        return @{ Name = 'remote-main'; Branch = 'remote/main'; Path = Join-Path $WorktreesDir 'remote-main' }
    }
    if ($BranchName -match '^test-(\d+)$') {
        $n = $Matches[1]
        return @{ Name = "remote-test-$n"; Branch = "remote/test-$n"; Path = Join-Path $WorktreesDir "remote-test-$n" }
    }
    throw "Unsupported branch '$BranchName'. Only 'main' and 'test-<n>' branches can be synced from SVN."
}

try {
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Missing required argument: -Branch <main|test-<n>>'
    }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    # Check main worktree is clean before any branch switching
    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Please commit or stash before pulling from SVN.`n$mainStatus"
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    # SVN update
    Write-Output "Running svn update in $($remote.Name)..."
    Push-Location $remote.Path
    try {
        & svn update
        if ($LASTEXITCODE -ne 0) { throw 'svn update failed' }
        $svnRev = (& svn info --show-item revision | Out-String).Trim()
    } finally {
        Pop-Location
    }

    # Check if git sees any changes
    $remoteStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if (-not $remoteStatus) {
        Write-Output "Already up to date at SVN r$svnRev"
        exit 0
    }

    # Commit SVN changes to remote/* branch
    & git -C $remote.Path add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed in remote worktree' }
    & git -C $remote.Path commit -m "sync: svn r$svnRev"
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed in remote worktree' }

    # Switch to target branch in main worktree if needed
    $switched = $false
    if ($originalBranch -ne $Branch) {
        Write-Output "Switching main worktree from '$originalBranch' to '$Branch'..."
        & git -C $mainWorktree checkout $Branch
        if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
        $switched = $true
    }

    # Merge remote branch into working branch
    & git -C $mainWorktree merge $remote.Branch --no-ff -m "Merge branch '$($remote.Branch)' into $Branch"
    $mergeExit = $LASTEXITCODE

    if ($mergeExit -ne 0) {
        $conflicts = (& git -C $mainWorktree diff --name-only --diff-filter=U | Out-String).Trim()
        throw "Merge conflict detected. Resolve the following files in the main worktree, then run 'git merge --continue':`n$conflicts`n`nNote: main worktree is now on branch '$Branch'. Switch back to '$originalBranch' manually when done."
    }

    # Switch back to original branch if we switched
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
