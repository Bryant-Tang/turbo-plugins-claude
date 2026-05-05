[CmdletBinding()]
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

    # Check no existing merge state (left over from a previous prepare that wasn't committed/aborted)
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path rev-parse --verify -q MERGE_HEAD 2>$null | Out-Null
    $hasMergeHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if ($hasMergeHead) {
        throw "Remote worktree '$($remote.Name)' has a pending merge (.git/MERGE_HEAD exists). Run '/tgs:push-to-svn' to commit it, or 'git -C $($remote.Path) merge --abort' to discard."
    }

    # Check remote worktree git status (clean tree expected before staging the merge)
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

    # Stage the merge so svn status reflects the actual file changes that would be pushed.
    # --no-ff forces a merge commit; --no-commit lets us preview before finalising.
    # The commit message is stashed in .git/MERGE_MSG and reused when push-to-svn-commit runs `git commit --no-edit`.
    # EAP wrapper: git merge writes informational messages ("Automatic merge went well...") to stderr;
    # under PS 5.1 with $ErrorActionPreference = 'Stop' those are wrapped as ErrorRecord and terminate.
    $mergeMsg = "Merge branch '$Branch' into $($remote.Branch)"
    $ea3 = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path merge --no-ff --no-commit -m $mergeMsg $Branch 2>&1 | Out-Null
    $mergeExit = $LASTEXITCODE
    $ErrorActionPreference = $ea3
    if ($mergeExit -ne 0) {
        $conflicts = (& git -C $remote.Path diff --name-only --diff-filter=U | Out-String).Trim()
        throw "Merge conflict in remote worktree. Resolve the following files in '$($remote.Name)', then re-run, or abort with 'git -C $($remote.Path) merge --abort':`n$conflicts"
    }

    Write-Output 'COMMITS'
    Write-Output $logOutput
    Write-Output ''
    Write-Output 'FILES'
    Push-Location $remote.Path
    try {
        $statusLines = & svn status
        foreach ($line in $statusLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.Length -lt 9) { continue }
            $statusChar = $line.Substring(0, 1)
            $filepath   = $line.Substring(8).Trim()
            if (-not $filepath) { continue }
            $diffStatus = switch ($statusChar) {
                '?' { 'A' }
                '!' { 'D' }
                'M' { 'M' }
                default { $null }
            }
            if (-not $diffStatus) { continue }

            $ea2 = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            & git -C $remote.Path check-ignore -q $filepath 2>$null | Out-Null
            $isIgnored = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $ea2

            if ($isIgnored) {
                Write-Output "$diffStatus|ignored|$filepath"
            } else {
                Write-Output "$diffStatus|tracked|$filepath"
            }
        }
    } finally {
        Pop-Location
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
