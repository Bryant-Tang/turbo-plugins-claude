param(
    [string]$Branch = '',
    [string]$N = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$FilePath, [string]$Content)
    [System.IO.File]::WriteAllText($FilePath, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

function Update-Workspace {
    param([string]$WorkspaceFile, [string]$FolderName, [string]$FolderPath)
    if (-not (Test-Path -LiteralPath $WorkspaceFile)) {
        throw "Workspace file not found: $WorkspaceFile"
    }
    $ws = Get-Content -LiteralPath $WorkspaceFile -Raw | ConvertFrom-Json
    $newFolder = [PSCustomObject]@{ name = $FolderName; path = $FolderPath }
    $ws.folders = @($ws.folders) + $newFolder
    $json = $ws | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -FilePath $WorkspaceFile -Content $json
}

try {
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Missing required argument: -Branch <branch>'
    }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"
    $workspaceFile = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.code-workspace"

    if (-not (Test-Path -LiteralPath $worktreesDir)) {
        throw "Worktrees directory not found: $worktreesDir. Are you inside a tgs project?"
    }

    # Resolve <n>
    if ([string]::IsNullOrWhiteSpace($N)) {
        $maxN = 0
        Get-ChildItem -LiteralPath $worktreesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^dev-(\d+)$' } | ForEach-Object {
            $num = [int]$Matches[1]
            if ($num -gt $maxN) { $maxN = $num }
        }
        $idx = $maxN + 1
    } else {
        if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }
        $idx = [int]$N
    }

    $devWorktreeName = "dev-$idx"
    $devWorktreePath = Join-Path $worktreesDir $devWorktreeName

    if (Test-Path -LiteralPath $devWorktreePath) {
        throw "Worktree '$devWorktreeName' already exists at: $devWorktreePath"
    }

    # Create branch if it does not exist
    $existingBranch = (& git -C $mainWorktree branch --list $Branch | Out-String).Trim()
    if (-not $existingBranch) {
        Write-Output "Branch '$Branch' does not exist. Creating from HEAD of main..."
        & git -C $mainWorktree branch $Branch
        if ($LASTEXITCODE -ne 0) { throw "git branch $Branch failed" }
    }

    & git -C $mainWorktree worktree add $devWorktreePath $Branch
    if ($LASTEXITCODE -ne 0) { throw "git worktree add $devWorktreeName failed" }

    Update-Workspace -WorkspaceFile $workspaceFile -FolderName $devWorktreeName -FolderPath "$projName.worktrees/$devWorktreeName"

    Write-Output ""
    Write-Output "Dev worktree '$devWorktreeName' created."
    Write-Output "  Branch   : $Branch"
    Write-Output "  Location : $devWorktreePath"
    Write-Output ""
    Write-Output "Recommended: open Claude Code in '$devWorktreePath' and run /tgs:setup to configure"
    Write-Output "  tgs environment variable defaults for that working directory."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
