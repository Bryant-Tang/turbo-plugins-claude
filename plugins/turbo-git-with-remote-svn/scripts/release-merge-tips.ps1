[CmdletBinding()]
param(
    [string]$MergeCommits = '',
    [string]$HotfixBranches = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

try {
    $hasMerges = -not [string]::IsNullOrWhiteSpace($MergeCommits)
    $hasHotfix = -not [string]::IsNullOrWhiteSpace($HotfixBranches)
    if ($hasMerges -and $hasHotfix) {
        throw 'Provide exactly one of -MergeCommits or -HotfixBranches, not both.'
    }
    if (-not $hasMerges -and -not $hasHotfix) {
        throw 'Missing required argument: -MergeCommits "<csv>" or -HotfixBranches "<csv>".'
    }

    $mainWorktree = Get-MainWorktree

    # Build (tip, subject) pairs
    $items = @()
    if ($hasMerges) {
        foreach ($m in ($MergeCommits -split ',' | Where-Object { $_ -ne '' })) {
            $m = $m.Trim()
            $tip = (& git -C $mainWorktree rev-parse "$m^2" | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $tip) { throw "Cannot resolve parent[1] of merge commit $m" }
            $subject = (& git -C $mainWorktree log -1 --format=%s $m | Out-String).TrimEnd("`r","`n")
            if ($LASTEXITCODE -ne 0) { throw "Cannot read subject of merge commit $m" }
            $items += [PSCustomObject]@{ Tip = $tip; Message = "Release: $subject" }
        }
    }
    else {
        foreach ($b in ($HotfixBranches -split ',' | Where-Object { $_ -ne '' })) {
            $b = $b.Trim()
            $tip = (& git -C $mainWorktree rev-parse --verify "refs/heads/$b" | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $tip) { throw "Branch '$b' does not exist." }
            $items += [PSCustomObject]@{ Tip = $tip; Message = "Release: Hotfix: $b" }
        }
    }

    if ($items.Count -eq 0) { throw 'No items to release.' }

    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Commit or stash before release.`n$mainStatus"
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    $switched = $false
    if ($originalBranch -ne 'main') {
        Write-Output "Switching main worktree from '$originalBranch' to 'main'..."
        & git -C $mainWorktree checkout 'main'
        if ($LASTEXITCODE -ne 0) { throw "git checkout main failed" }
        $switched = $true
    }

    foreach ($item in $items) {
        Write-Output "Merging $($item.Tip) into main with subject: $($item.Message)"
        & git -C $mainWorktree merge --no-ff $item.Tip -m $item.Message
        if ($LASTEXITCODE -ne 0) {
            $conflicts = (& git -C $mainWorktree diff --name-only --diff-filter=U | Out-String).Trim()
            $restoreNote = if ($switched) { " After resolving, switch back to '$originalBranch' (e.g. 'git checkout $originalBranch')." } else { '' }
            [Console]::Error.WriteLine("Merge conflict on $($item.Tip). Resolve in main worktree (currently on 'main') and run 'git merge --continue', then re-run /tgs:release for any remaining items.$restoreNote`nConflicting files:`n$conflicts")
            exit 1
        }
    }

    if ($switched) {
        & git -C $mainWorktree checkout $originalBranch
        if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        Write-Output "Switched back to '$originalBranch'."
    }

    Write-Output ''
    Write-Output ("Merged {0} tip(s) into main." -f $items.Count)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
