[CmdletBinding()]
param(
    [string]$N = '',
    [switch]$DiffOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($N)) { throw 'Missing required argument: -N <number>' }
    if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }

    $idx = [int]$N
    $testBranch = "test-$idx"

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"
    $remoteWorktreePath = Join-Path $worktreesDir "remote-test-$idx"

    $existingTest = (& git -C $mainWorktree branch --list $testBranch | Out-String).Trim()
    if (-not $existingTest) { throw "Branch '$testBranch' does not exist." }
    $existingMain = (& git -C $mainWorktree branch --list 'main' | Out-String).Trim()
    if (-not $existingMain) { throw "Branch 'main' does not exist." }
    if (-not (Test-Path -LiteralPath $remoteWorktreePath -PathType Container)) {
        throw "Remote test worktree not found: $remoteWorktreePath"
    }

    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Commit or stash before reset.`n$mainStatus"
    }

    $remoteStatus = (& git -C $remoteWorktreePath status --porcelain | Out-String).Trim()
    if ($remoteStatus) {
        throw "Remote test worktree '$remoteWorktreePath' has uncommitted changes. Run /tp-push-to-svn or /tp-pull-from-svn to resolve first.`n$remoteStatus"
    }

    $loseRaw = (& git -C $mainWorktree log --oneline "main..$testBranch" | Out-String).TrimEnd("`r","`n")
    $gainRaw = (& git -C $mainWorktree log --oneline "$testBranch..main" | Out-String).TrimEnd("`r","`n")

    Write-Output 'LOSE'
    if ($loseRaw) { Write-Output $loseRaw }
    Write-Output ''
    Write-Output 'GAIN'
    if ($gainRaw) { Write-Output $gainRaw }

    if ($DiffOnly) { exit 0 }

    if (-not $loseRaw -and -not $gainRaw) {
        Write-Output ''
        Write-Output "$testBranch already equals main. Nothing to reset."
        exit 0
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    $switched = $false
    if ($originalBranch -ne $testBranch) {
        Write-Output ''
        Write-Output "Switching main worktree from '$originalBranch' to '$testBranch'..."
        & git -C $mainWorktree checkout $testBranch
        if ($LASTEXITCODE -ne 0) { throw "git checkout $testBranch failed" }
        $switched = $true
    }

    & git -C $mainWorktree reset --hard 'main'
    if ($LASTEXITCODE -ne 0) {
        if ($switched) { & git -C $mainWorktree checkout $originalBranch }
        throw "git reset --hard main failed on $testBranch"
    }

    if ($switched) {
        & git -C $mainWorktree checkout $originalBranch
        if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        Write-Output "Switched back to '$originalBranch'."
    }

    Write-Output ''
    Write-Output "Reset $testBranch to main. Run /tp-push-to-svn --branch $testBranch to publish."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
