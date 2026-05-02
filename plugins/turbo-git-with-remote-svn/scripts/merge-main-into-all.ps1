[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

function Get-BranchWorktreeMap {
    param([string]$MainWorktree)
    $output = (& git -C $MainWorktree worktree list --porcelain | Out-String) -split "`n"
    $map = @{}
    $currentPath = $null
    foreach ($line in $output) {
        $line = $line.Trim()
        if ($line -match '^worktree (.+)$') {
            $currentPath = $Matches[1].Trim()
        } elseif ($line -match '^branch refs/heads/(.+)$') {
            $map[$Matches[1].Trim()] = $currentPath
        }
    }
    return $map
}

try {
    $mainWorktree = Get-MainWorktree

    # Collect all local branches except 'main' and 'remote/*'
    $targetBranches = (& git -C $mainWorktree branch --format='%(refname:short)' | Out-String) -split "`n" |
                      ForEach-Object { $_.Trim() } |
                      Where-Object { $_ -ne '' -and $_ -ne 'main' -and $_ -notmatch '^remote/' }

    if (-not $targetBranches) {
        Write-Output 'No branches to merge into (only main and remote/* branches exist).'
        exit 0
    }

    $branchWorktreeMap = Get-BranchWorktreeMap -MainWorktree $mainWorktree
    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    $hasConflict = $false

    foreach ($branch in $targetBranches) {
        $dedicatedWorktree = $branchWorktreeMap[$branch]
        $useMainWorktree = (-not $dedicatedWorktree) -or ($dedicatedWorktree -eq $mainWorktree)

        if (-not $useMainWorktree) {
            # Branch is checked out in its own worktree
            $status = (& git -C $dedicatedWorktree status --porcelain | Out-String).Trim()
            if ($status) {
                Write-Output "SKIP $branch (dirty: $dedicatedWorktree)"
                continue
            }

            & git -C $dedicatedWorktree merge main --no-ff -m "Merge branch 'main' into $branch"
            if ($LASTEXITCODE -ne 0) {
                & git -C $dedicatedWorktree merge --abort
                Write-Output "CONFLICT $branch (merge aborted)"
                $hasConflict = $true
            } else {
                Write-Output "OK $branch"
            }
        } else {
            # Branch is not currently checked out anywhere; use main worktree
            $status = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
            if ($status) {
                Write-Output "SKIP $branch (main worktree is dirty)"
                continue
            }

            & git -C $mainWorktree checkout $branch
            if ($LASTEXITCODE -ne 0) {
                Write-Output "SKIP $branch (checkout failed)"
                continue
            }

            & git -C $mainWorktree merge main --no-ff -m "Merge branch 'main' into $branch"
            $mergeExit = $LASTEXITCODE

            if ($mergeExit -ne 0) {
                & git -C $mainWorktree merge --abort
                Write-Output "CONFLICT $branch (merge aborted)"
                $hasConflict = $true
            } else {
                Write-Output "OK $branch"
            }

            & git -C $mainWorktree checkout $originalBranch
            if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        }
    }

    if ($hasConflict) { exit 1 }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
