[CmdletBinding()]
param(
    [string]$Branch = '',
    [string]$Message = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'common.ps1')

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'Missing required argument: -Branch <main|test-<n>>' }
    if ([string]::IsNullOrWhiteSpace($Message)) { throw 'Missing required argument: -Message <commit-message>' }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path rev-parse --verify -q MERGE_HEAD 2>$null | Out-Null
    $hasMergeHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if (-not $hasMergeHead) {
        throw "No pending merge in remote worktree '$($remote.Name)'. Run /tp-push-to-svn (which calls push-to-svn-prepare first) instead of invoking this script directly."
    }

    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'." }
    $localRev = (& svn info --show-item revision $remote.Path | Out-String).Trim()
    $headRev = (& svn info --show-item revision $svnUrl | Out-String).Trim()
    if ($localRev -ne $headRev) {
        throw "SVN HEAD changed since prepare (local r$localRev, head r$headRev). Abort the merge with 'git -C $($remote.Path) merge --abort', then run '/tp-pull-from-svn --branch $Branch'."
    }

    # Verify no new commits were added to the branch since prepare (SHA pinning check).
    # NOTE: in a linked worktree, .git is a pointer FILE; resolve via `git rev-parse --absolute-git-dir`.
    $shaGitDir = (& git -C $remote.Path rev-parse --absolute-git-dir | Out-String).Trim()
    $shaFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_branch_sha'
    if (Test-Path -LiteralPath $shaFile -PathType Leaf) {
        $pinnedSha = (Get-Content -LiteralPath $shaFile -Raw).Trim()
        $currentSha = (& git -C $mainWorktree rev-parse $Branch | Out-String).Trim()
        if ($pinnedSha -ne $currentSha) {
            $pinShort = if ($pinnedSha.Length -ge 8) { $pinnedSha.Substring(0, 8) } else { $pinnedSha }
            $curShort = if ($currentSha.Length -ge 8) { $currentSha.Substring(0, 8) } else { $currentSha }
            throw "Branch '$Branch' has new commits since prepare (pinned: $pinShort, current: $curShort). Abort the merge with 'git -C $($remote.Path) merge --abort' and rerun /tp-push-to-svn to include new commits."
        }
    }

    Write-Output "Finalising merge commit..."
    & git -C $remote.Path commit --no-edit
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed when finalising the prepared merge."
    }

    $newRev = '?'
    $noCommit = $false
    # UTF-8 (no BOM) message file: critical to keep Big5/CP_ACP from mangling non-ASCII.
    $msgFile = [System.IO.Path]::GetTempFileName()
    Push-Location $remote.Path
    try {
        Write-Utf8NoBom -Path $msgFile -Content $Message

        $svnStatusLines = & svn status
        $toAdd = @()
        $toDel = @()
        $modifiedToCommit = @()

        foreach ($line in $svnStatusLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (-not ($line -match '^([?!M])\s+(.+)$')) { continue }
            $statusChar = $Matches[1]
            $filePath   = $Matches[2].Trim()

            & git -C $remote.Path check-ignore -q $filePath 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Output "Skipping git-ignored ($statusChar): $filePath"
                continue
            }

            switch ($statusChar) {
                '?' { $toAdd += $filePath }
                '!' { $toDel += $filePath }
                'M' { $modifiedToCommit += $filePath }
            }
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

        $commitTargets = @()
        foreach ($line in (& svn status)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^([AD])\s+(.+)$') { $commitTargets += $Matches[2].Trim() }
        }
        $commitTargets += $modifiedToCommit

        if ($commitTargets.Count -eq 0) {
            Write-Output "No changes to commit to SVN (all pending changes are git-ignored)"
            $noCommit = $true
        } else {
            Write-Output "Committing to SVN..."
            $commitLines = & svn commit $commitTargets --file $msgFile --encoding UTF-8
            if ($LASTEXITCODE -ne 0) { throw 'svn commit failed' }
            $commitLines | ForEach-Object { Write-Output $_ }
            $newRevLine = $commitLines | Where-Object { $_ -match 'Committed revision (\d+)\.' } | Select-Object -Last 1
            if ($newRevLine -and $newRevLine -match 'Committed revision (\d+)\.') {
                $newRev = $Matches[1]
            }
        }
        & svn update | Out-Null
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $msgFile) {
            Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        }
    }

    # SHA pin cleanup runs on every success path (committed AND no-commit-needed).
    # Failure path skips this and retains the pin for retry (pin is checked at top).
    # NOTE: in a linked worktree, .git is a pointer FILE; resolve via `git rev-parse --absolute-git-dir`.
    try {
        $shaGitDir = (& git -C $remote.Path rev-parse --absolute-git-dir | Out-String).Trim()
        $shaFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_branch_sha'
        if (Test-Path -LiteralPath $shaFile) {
            Remove-Item -LiteralPath $shaFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Best-effort cleanup; don't fail the script on cleanup error.
    }

    if ($noCommit) { exit 0 }
    Write-Output "Pushed to SVN r$newRev"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
