[CmdletBinding()]
param(
    [string]$N = '',
    [string]$SvnUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required' }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    if (-not (Test-Path -LiteralPath $worktreesDir)) {
        throw "Worktrees directory not found: $worktreesDir. Run /tp-setup first to bootstrap."
    }

    if ([string]::IsNullOrWhiteSpace($N)) {
        $maxN = 0
        Get-ChildItem -LiteralPath $worktreesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^remote-test-(\d+)$' } | ForEach-Object {
            $num = [int]$Matches[1]
            if ($num -gt $maxN) { $maxN = $num }
        }
        $idx = $maxN + 1
    } else {
        if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }
        $idx = [int]$N
    }

    $testBranch = "test-$idx"
    $remoteBranch = "remote/test-$idx"
    $remoteWorktreeName = "remote-test-$idx"
    $remoteWorktreePath = Join-Path $worktreesDir $remoteWorktreeName

    $existingBranches = (& git -C $mainWorktree branch --list $testBranch | Out-String).Trim()
    if ($existingBranches) { throw "Branch '$testBranch' already exists." }
    if (Test-Path -LiteralPath $remoteWorktreePath) { throw "Worktree '$remoteWorktreeName' already exists at: $remoteWorktreePath" }

    Write-Output "Creating test environment $idx..."

    $initCommit = (& git -C $mainWorktree rev-list --max-parents=0 HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-list failed" }

    & git -C $mainWorktree branch $remoteBranch $initCommit
    if ($LASTEXITCODE -ne 0) { throw "git branch $remoteBranch failed" }

    & git -C $mainWorktree branch $testBranch 'main'
    if ($LASTEXITCODE -ne 0) { throw "git branch $testBranch failed" }

    & git -C $mainWorktree worktree add $remoteWorktreePath $remoteBranch
    if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }

    # Wrap SVN setup in try/catch so partial state is rolled back on failure.
    try {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & svn info $SvnUrl 2>&1 | Out-Null
        $svnExists = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevEAP

        if (-not $svnExists) {
            $remotemainPath = Join-Path $worktreesDir 'remote-main'
            $mainSvnUrl = (& svn info --show-item url $remotemainPath | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { throw "Could not get main SVN URL from remote-main worktree." }
            Write-Output "SVN path '$SvnUrl' does not exist. Creating from '$mainSvnUrl'..."
            & svn copy $mainSvnUrl $SvnUrl -m "create $testBranch branch"
            if ($LASTEXITCODE -ne 0) { throw "svn copy failed" }
        } else {
            Write-Output "SVN path exists, will checkout: $SvnUrl"
        }
        Write-Output "Running: svn checkout $SvnUrl $remoteWorktreePath"
        & svn checkout $SvnUrl $remoteWorktreePath
        if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

        $remotemainPath = Join-Path $worktreesDir 'remote-main'
        $ignoreToApply = '.git' + [System.Environment]::NewLine + '.gitignore'
        if (Test-Path -LiteralPath $remotemainPath -PathType Container) {
            $inherited = (& svn propget svn:ignore $remotemainPath 2>&1 | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($inherited)) { $ignoreToApply = $inherited }
        }
        Push-Location $remoteWorktreePath
        try {
            & svn propset svn:ignore $ignoreToApply '.'
            if ($LASTEXITCODE -ne 0) { throw 'svn propset svn:ignore failed' }
            & svn commit -m 'svn:ignore: copy from remote-main'
            if ($LASTEXITCODE -ne 0) { throw 'svn commit svn:ignore failed' }
        } finally {
            Pop-Location
        }
    } catch {
        # Rollback: remove the SVN worktree and both branches, then rethrow.
        Write-Output "SVN setup failed; rolling back git state..."
        & git -C $mainWorktree worktree remove --force $remoteWorktreePath 2>$null | Out-Null
        & git -C $mainWorktree branch -D $remoteBranch 2>$null | Out-Null
        & git -C $mainWorktree branch -D $testBranch 2>$null | Out-Null
        throw
    }

    Write-Output ""
    Write-Output "Test environment $idx created."
    Write-Output "  Branch        : $testBranch  (use 'git checkout $testBranch' in main worktree)"
    Write-Output "  SVN worktree  : $remoteWorktreePath"
    Write-Output ""
    Write-Output "Next step: run '/tp-pull-from-svn --branch $testBranch' to complete the initial SVN sync."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
