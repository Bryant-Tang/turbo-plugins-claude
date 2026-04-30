param(
    [string]$Branch = '',
    [string]$Limit = '',
    [switch]$Verbose
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
        return @{ Name = 'remote-main'; Path = Join-Path $WorktreesDir 'remote-main' }
    }
    if ($BranchName -match '^test-(\d+)$') {
        $n = $Matches[1]
        return @{ Name = "remote-test-$n"; Path = Join-Path $WorktreesDir "remote-test-$n" }
    }
    throw "Unsupported branch '$BranchName'. Only 'main' and 'test-<n>' branches are supported."
}

try {
    # Resolve defaults (CLI arg > env var > built-in default)
    $resolvedBranch = if (-not [string]::IsNullOrWhiteSpace($Branch)) { $Branch }
                      elseif (-not [string]::IsNullOrWhiteSpace($env:TGS_SVN_LOG_DEFAULT_BRANCH)) { $env:TGS_SVN_LOG_DEFAULT_BRANCH }
                      else { 'main' }

    $resolvedLimitStr = if (-not [string]::IsNullOrWhiteSpace($Limit)) { $Limit }
                        elseif (-not [string]::IsNullOrWhiteSpace($env:TGS_SVN_LOG_DEFAULT_LIMIT)) { $env:TGS_SVN_LOG_DEFAULT_LIMIT }
                        else { '50' }
    $resolvedLimit = 0
    if (-not [int]::TryParse($resolvedLimitStr, [ref]$resolvedLimit) -or $resolvedLimit -lt 1) {
        throw "Limit must be a positive integer (got '$resolvedLimitStr')."
    }

    $verboseMode = $Verbose.IsPresent -or ($env:TGS_SVN_LOG_DEFAULT_VERBOSE -ieq '1') -or ($env:TGS_SVN_LOG_DEFAULT_VERBOSE -ieq 'true')

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    $remote = Resolve-RemoteWorktree -BranchName $resolvedBranch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    if ($verboseMode) {
        & svn log -v --limit $resolvedLimit $remote.Path | ForEach-Object { $_ -replace ' \([^)]*\)', '' }
    } else {
        & svn log --limit $resolvedLimit $remote.Path | ForEach-Object { $_ -replace ' \([^)]*\)', '' }
    }
    if ($LASTEXITCODE -ne 0) { throw "svn log failed (exit $LASTEXITCODE)" }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
