[CmdletBinding()]
param(
    [string]$Branch = '',
    [switch]$DiffOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'Missing required argument: -Branch <name>' }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree
    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    $remoteWorktreePath = $remote.Path

    $existingBranch = (& git -C $mainWorktree branch --list $Branch | Out-String).Trim()
    if (-not $existingBranch) { throw "Branch '$Branch' does not exist." }
    $existingMain = (& git -C $mainWorktree branch --list 'main' | Out-String).Trim()
    if (-not $existingMain) { throw "Branch 'main' does not exist." }
    if (-not (Test-Path -LiteralPath $remoteWorktreePath -PathType Container)) {
        throw "Remote-svn worktree not found: $remoteWorktreePath"
    }

    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Commit or stash before reset.`n$mainStatus"
    }

    # v0.2.7+ F-U18.svn-state fix: filter out .svn/* paths from git status check.
    # .svn/wc.db is SVN's binary metadata, modified by every svn operation (including
    # the svn status/info that push-to-svn / pull-from-svn themselves run). Treating
    # it as "uncommitted user change" creates a deadlock - user is told to run
    # push/pull to resolve, but those commands also touch .svn/wc.db.
    $remoteStatusRaw = (& git -C $remoteWorktreePath status --porcelain | Out-String).Trim()
    $remoteStatusLines = @($remoteStatusRaw -split "`n" | Where-Object {
        $_ -and ($_ -notmatch '^\s*[?MADRC!]+\s+\.svn[/\\]')
    })
    if ($remoteStatusLines.Count -gt 0) {
        $remoteStatus = $remoteStatusLines -join "`n"
        throw "Remote-svn worktree '$remoteWorktreePath' has uncommitted changes. Run /tp-push-to-svn or /tp-pull-from-svn to resolve first.`n$remoteStatus"
    }

    $loseRaw = (& git -C $mainWorktree log --oneline "main..$Branch" | Out-String).TrimEnd("`r","`n")
    $gainRaw = (& git -C $mainWorktree log --oneline "$Branch..main" | Out-String).TrimEnd("`r","`n")

    Write-Output 'LOSE'
    if ($loseRaw) { Write-Output $loseRaw }
    Write-Output ''
    Write-Output 'GAIN'
    if ($gainRaw) { Write-Output $gainRaw }

    # F25: emit file-impact preview - list files that would be svn-deleted on the next push.
    # This lets the SKILL prompt the user before they commit to the reset.
    $filesLost = (& git -C $mainWorktree diff --name-status "main..$($remote.Branch)" 2>$null | Out-String).Trim()
    Write-Output ''
    Write-Output 'FILES_LOST_AFTER_PUSH'
    if ($filesLost) { Write-Output $filesLost }

    if ($DiffOnly) { exit 0 }

    if (-not $loseRaw -and -not $gainRaw) {
        Write-Output ''
        Write-Output "$Branch already equals main. Nothing to reset."
        exit 0
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    $switched = $false
    if ($originalBranch -ne $Branch) {
        Write-Output ''
        Write-Output "Switching main worktree from '$originalBranch' to '$Branch'..."
        & git -C $mainWorktree checkout $Branch
        if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
        $switched = $true
    }

    & git -C $mainWorktree reset --hard 'main'
    if ($LASTEXITCODE -ne 0) {
        if ($switched) { & git -C $mainWorktree checkout $originalBranch }
        throw "git reset --hard main failed on $Branch"
    }

    if ($switched) {
        & git -C $mainWorktree checkout $originalBranch
        if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        Write-Output "Switched back to '$originalBranch'."
    }

    Write-Output ''
    Write-Output "Reset $Branch to main. Run /tp-push-to-svn --branch $Branch to publish."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
