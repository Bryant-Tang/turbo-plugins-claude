param(
    [string]$Branch = '',
    [string]$Message = ''
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
    throw "Unsupported branch '$BranchName'. Only 'main' and 'test-<n>' branches can be pushed to SVN."
}

try {
    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'Missing required argument: -Branch <main|test-<n>>' }
    if ([string]::IsNullOrWhiteSpace($Message)) { throw 'Missing required argument: -Message <commit-message>' }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    # Re-validate SVN is up-to-date (guard against race condition)
    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'." }
    $localRev = (& svn info --show-item revision $remote.Path | Out-String).Trim()
    $headRev = (& svn info --show-item revision $svnUrl | Out-String).Trim()
    if ($localRev -ne $headRev) {
        throw "SVN HEAD changed since prepare (local r$localRev, head r$headRev). Run '/tgs:pull-from-svn --branch $Branch' first."
    }

    # Re-validate remote worktree git status
    $remoteGitStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if ($remoteGitStatus) {
        throw "Remote worktree '$($remote.Name)' has uncommitted changes. Resolve before committing."
    }

    # Merge working branch into remote branch
    Write-Output "Merging '$Branch' into '$($remote.Branch)'..."
    & git -C $remote.Path merge $Branch --no-ff -m "Merge branch '$Branch' into $($remote.Branch)"
    if ($LASTEXITCODE -ne 0) {
        $conflicts = (& git -C $remote.Path diff --name-only --diff-filter=U | Out-String).Trim()
        throw "Merge conflict in remote worktree. Resolve the following files in '$($remote.Name)', then retry:`n$conflicts"
    }

    # Handle SVN untracked and missing files
    Push-Location $remote.Path
    try {
        $svnStatusLines = & svn status
        $toAdd = @()
        $toDel = @()
        foreach ($line in $svnStatusLines) {
            if ($line -match '^\?\s+(.+)$') { $toAdd += $Matches[1].Trim() }
            if ($line -match '^!\s+(.+)$')  { $toDel += $Matches[1].Trim() }
        }
        if ($toAdd.Count -gt 0) {
            Write-Output "SVN adding $($toAdd.Count) new file(s)..."
            & svn add --parents $toAdd
            if ($LASTEXITCODE -ne 0) { throw 'svn add failed' }
        }
        if ($toDel.Count -gt 0) {
            Write-Output "SVN deleting $($toDel.Count) removed file(s)..."
            & svn delete $toDel
            if ($LASTEXITCODE -ne 0) { throw 'svn delete failed' }
        }

        Write-Output "Committing to SVN..."
        $commitLines = & svn commit -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'svn commit failed' }
        $commitLines | ForEach-Object { Write-Output $_ }
        $newRevLine = $commitLines | Where-Object { $_ -match 'Committed revision (\d+)\.' } | Select-Object -Last 1
        if ($newRevLine -and $newRevLine -match 'Committed revision (\d+)\.') {
            $newRev = $Matches[1]
        } else {
            $newRev = '?'
        }
        # Update working copy revision so subsequent prepare checks see the correct local revision
        & svn update | Out-Null
    } finally {
        Pop-Location
    }

    Write-Output "Pushed to SVN r$newRev"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
