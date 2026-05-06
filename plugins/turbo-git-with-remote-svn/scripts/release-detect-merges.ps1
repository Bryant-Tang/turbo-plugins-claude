[CmdletBinding()]
param(
    [string]$N = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

function Test-IsAncestor {
    param([string]$Repo, [string]$Ancestor, [string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $false }
    & git -C $Repo merge-base --is-ancestor $Ancestor $Ref 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-RefExists {
    param([string]$Repo, [string]$Ref)
    & git -C $Repo rev-parse --verify --quiet $Ref 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

try {
    if ([string]::IsNullOrWhiteSpace($N)) { throw 'Missing required argument: -N <number>' }
    if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }

    $idx = [int]$N
    $testBranch = "test-$idx"
    $remoteTestBranch = "remote/test-$idx"
    $remoteMain = 'remote/main'

    $mainWorktree = Get-MainWorktree

    if (-not (Test-RefExists -Repo $mainWorktree -Ref $testBranch)) {
        throw "Branch '$testBranch' does not exist."
    }
    if (-not (Test-RefExists -Repo $mainWorktree -Ref 'main')) {
        throw "Branch 'main' does not exist."
    }

    $hasRemoteMain = Test-RefExists -Repo $mainWorktree -Ref $remoteMain
    $hasRemoteTest = Test-RefExists -Repo $mainWorktree -Ref $remoteTestBranch

    # Collect candidate merge commits on test-<n>'s first-parent line that are not in main
    $logRaw = (& git -C $mainWorktree log --merges --first-parent --format='%H|%P|%s' "main..$testBranch" | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "git log failed for main..$testBranch" }

    $lines = $logRaw -split "`r?`n" | Where-Object { $_ -ne '' }

    foreach ($line in $lines) {
        $parts = $line -split '\|', 3
        if ($parts.Count -lt 3) { continue }
        $mergeHash = $parts[0]
        $parents = $parts[1] -split ' '
        $subject = $parts[2]

        if ($parents.Count -lt 2) { continue }
        $tip = $parents[1]

        # Filter 1: SVN bridge merges (tip reachable from remote/main or remote/test-<n>)
        if ($hasRemoteMain -and (Test-IsAncestor -Repo $mainWorktree -Ancestor $tip -Ref $remoteMain)) { continue }
        if ($hasRemoteTest -and (Test-IsAncestor -Repo $mainWorktree -Ancestor $tip -Ref $remoteTestBranch)) { continue }

        # Filter 2: tip already in main (previously partial-released)
        if (Test-IsAncestor -Repo $mainWorktree -Ancestor $tip -Ref 'main') { continue }

        # Annotate current branch correspondence
        $pointsAt = (& git -C $mainWorktree branch --points-at $tip --format='%(refname:short)' | Out-String).Trim() -split "`r?`n" |
            Where-Object { $_ -ne '' -and $_ -ne 'main' -and $_ -notmatch '^test-\d+$' -and $_ -notmatch '^remote/' }
        $pointsAt = @($pointsAt)

        $contains = (& git -C $mainWorktree branch --contains $tip --format='%(refname:short)' | Out-String).Trim() -split "`r?`n" |
            Where-Object { $_ -ne '' -and $_ -ne 'main' -and $_ -notmatch '^test-\d+$' -and $_ -notmatch '^remote/' }
        $contains = @($contains)

        if ($pointsAt.Count -gt 0) {
            $branchStatus = 'AT_TIP:' + ($pointsAt -join ',')
        }
        elseif ($contains.Count -gt 0) {
            $branchStatus = 'ADVANCED:' + ($contains -join ',')
        }
        else {
            $branchStatus = 'NONE'
        }

        Write-Output ("{0}|{1}|{2}|{3}" -f $mergeHash, $tip, $subject, $branchStatus)
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
