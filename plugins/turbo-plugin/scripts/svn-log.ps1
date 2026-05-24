[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [int]$Limit = 50,
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

try {
    Probe-GitVersion

    if ($Limit -lt 1) {
        throw "Limit must be a positive integer (got '$Limit')."
    }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    # Strip " (...)" only from SVN log header lines (r<n> | author | ...) to remove path suffixes.
    # Body lines (commit message content) are left unchanged.
    $headerPattern = '^r\d+\s*\|'
    if ($VerboseOutput) {
        & svn log -v --limit $Limit $remote.Path | ForEach-Object {
            if ($_ -match $headerPattern) { $_ -replace ' \([^)]*\)', '' } else { $_ }
        }
    } else {
        & svn log --limit $Limit $remote.Path | ForEach-Object {
            if ($_ -match $headerPattern) { $_ -replace ' \([^)]*\)', '' } else { $_ }
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "svn log failed (exit $LASTEXITCODE)" }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
