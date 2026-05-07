[CmdletBinding()]
param(
    [string]$Name = '',
    [string]$Base = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

try {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Missing required argument: -Name <full-branch-name>' }
    if ([string]::IsNullOrWhiteSpace($Base)) { throw 'Missing required argument: -Base <base-branch>' }

    if ($Name -notmatch '^[A-Za-z0-9._/\-]+$') {
        throw "Invalid branch name '$Name'. Use only letters, digits, dot, underscore, slash, hyphen."
    }

    $mainWorktree = Get-MainWorktree

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $mainWorktree rev-parse --verify -q "refs/heads/$Name" 2>$null | Out-Null
    $nameExists = ($LASTEXITCODE -eq 0)
    & git -C $mainWorktree rev-parse --verify -q "refs/heads/$Base" 2>$null | Out-Null
    $baseExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea

    if ($nameExists) { throw "Branch '$Name' already exists." }
    if (-not $baseExists) { throw "Base branch '$Base' does not exist." }

    $status = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($status) {
        throw "Main worktree has uncommitted changes. Commit or stash before creating a new branch.`n$status"
    }

    & git -C $mainWorktree checkout -b $Name $Base
    if ($LASTEXITCODE -ne 0) { throw "git checkout -b '$Name' '$Base' failed" }

    Write-Output "Created branch '$Name' from '$Base' in main worktree."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
