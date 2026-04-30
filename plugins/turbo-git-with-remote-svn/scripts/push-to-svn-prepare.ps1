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
    throw "Unsupported branch '$BranchName'. Only 'main' and 'test-<n>' branches can be pushed to SVN."
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

    # Check remote worktree git status
    $remoteGitStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if ($remoteGitStatus) {
        throw "Remote worktree '$($remote.Name)' has uncommitted git changes. Resolve before pushing."
    }

    # Check SVN is up-to-date
    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'. Is it a valid SVN working copy?" }

    $localRev = (& svn info --show-item revision $remote.Path | Out-String).Trim()
    $headRev = (& svn info --show-item revision $svnUrl | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not query SVN HEAD revision for: $svnUrl" }

    if ($localRev -ne $headRev) {
        throw "Remote SVN worktree is not up to date (local r$localRev, head r$headRev). Run '/tgs:pull-from-svn --branch $Branch' first."
    }

    # Get pending commits
    $logOutput = (& git -C $mainWorktree log "$($remote.Branch)..$Branch" --reverse --pretty=format:'%h|%s' | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($logOutput)) {
        Write-Output 'Nothing to push'
        exit 0
    }

    Write-Output $logOutput
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
