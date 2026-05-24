[CmdletBinding()]
param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'common.ps1')

try {
    Probe-GitVersion

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

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path rev-parse --verify -q MERGE_HEAD 2>$null | Out-Null
    $hasMergeHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if ($hasMergeHead) {
        # Emit a structured token so tp-push-to-svn SKILL can offer abort/continue/cancel options.
        Write-Output "PENDING_MERGE_DETECTED $($remote.Path)"
        exit 0
    }

    $remoteGitStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if ($remoteGitStatus) {
        throw "Remote worktree '$($remote.Name)' has uncommitted git changes. Resolve before pushing."
    }

    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'. Is it a valid SVN working copy?" }

    $localRev = (& svn info --show-item revision $remote.Path | Out-String).Trim()
    $headRev = (& svn info --show-item revision $svnUrl | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not query SVN HEAD revision for: $svnUrl" }

    if ($localRev -ne $headRev) {
        throw "Remote SVN worktree is not up to date (local r$localRev, head r$headRev). Run '/tp-pull-from-svn --branch $Branch' first."
    }

    $logOutput = (& git -C $mainWorktree log "$($remote.Branch)..$Branch" --reverse --pretty=format:'%h|%s' | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($logOutput)) {
        Write-Output 'Nothing to push'
        exit 0
    }

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

    # Pin the source branch HEAD SHA so push-to-svn-commit can detect new commits added after prepare.
    # NOTE: in a linked worktree, .git is a pointer FILE (not a directory). Use `git rev-parse --absolute-git-dir`
    # to resolve the pointer to the actual linked-worktree gitdir (which IS a directory).
    $branchHeadSha = (& git -C $mainWorktree rev-parse $Branch | Out-String).Trim()
    $shaGitDir = (& git -C $remote.Path rev-parse --absolute-git-dir | Out-String).Trim()
    $shaFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_branch_sha'
    Write-Utf8NoBom -Path $shaFile -Content $branchHeadSha

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
