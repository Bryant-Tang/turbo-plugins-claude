[CmdletBinding()]
param(
    [string]$N = '',
    [string]$SvnUrl = ''
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
    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required' }

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
        Get-ChildItem -LiteralPath $worktreesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^remote-test-(\d+)$' } | ForEach-Object {
            $num = [int]$Matches[1]
            if ($num -gt $maxN) { $maxN = $num }
        }
        $idx = $maxN + 1
    } else {
        if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }
        $idx = [int]$N
    }

    $testBranch = "test-$idx"
    $remoteBranch = "remote/test-$idx"
    $remoteWorktreeName = "remote-test-$idx"
    $remoteWorktreePath = Join-Path $worktreesDir $remoteWorktreeName

    # Check for conflicts
    $existingBranches = (& git -C $mainWorktree branch --list $testBranch | Out-String).Trim()
    if ($existingBranches) { throw "Branch '$testBranch' already exists." }
    if (Test-Path -LiteralPath $remoteWorktreePath) { throw "Worktree '$remoteWorktreeName' already exists at: $remoteWorktreePath" }

    Write-Output "Creating test environment $idx..."

    # Branch remote/test-N from the init commit (repo root) so the worktree starts with only
    # .gitignore; this avoids an SVN obstruction conflict when checking out SVN content that
    # overlaps with files already present from remote/main.
    $initCommit = (& git -C $mainWorktree rev-list --max-parents=0 HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-list failed" }

    & git -C $mainWorktree branch $remoteBranch $initCommit
    if ($LASTEXITCODE -ne 0) { throw "git branch $remoteBranch failed" }

    & git -C $mainWorktree branch $testBranch 'main'
    if ($LASTEXITCODE -ne 0) { throw "git branch $testBranch failed" }

    & git -C $mainWorktree worktree add $remoteWorktreePath $remoteBranch
    if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }

    # Check if the SVN URL already exists; if not, create it via svn copy from remote-main
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & svn info $SvnUrl 2>&1 | Out-Null
    $svnExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP

    if (-not $svnExists) {
        $remotemainPath = Join-Path $worktreesDir 'remote-main'
        $mainSvnUrl = (& svn info --show-item url $remotemainPath | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Could not get main SVN URL from remote-main worktree." }
        Write-Output "SVN path '$SvnUrl' does not exist. Creating from '$mainSvnUrl'..."
        & svn copy $mainSvnUrl $SvnUrl -m "create $testBranch branch"
        if ($LASTEXITCODE -ne 0) { throw "svn copy failed" }
    } else {
        Write-Output "SVN path exists, will checkout: $SvnUrl"
    }
    Write-Output "Running: svn checkout $SvnUrl $remoteWorktreePath"
    & svn checkout $SvnUrl $remoteWorktreePath
    if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

    # Set svn:ignore so git metadata files are never accidentally committed to SVN
    Push-Location $remoteWorktreePath
    try {
        & svn propset svn:ignore ".git`n.gitignore" '.'
        if ($LASTEXITCODE -ne 0) { throw 'svn propset svn:ignore failed' }
        & svn commit -m 'svn:ignore git metadata'
        if ($LASTEXITCODE -ne 0) { throw 'svn commit svn:ignore failed' }
    } finally {
        Pop-Location
    }

    Update-Workspace -WorkspaceFile $workspaceFile -FolderName $remoteWorktreeName -FolderPath "$projName.worktrees/$remoteWorktreeName"

    Write-Output ""
    Write-Output "Test environment $idx created."
    Write-Output "  Branch        : $testBranch  (use 'git checkout $testBranch' in main worktree)"
    Write-Output "  SVN worktree  : $remoteWorktreePath"

    Write-Output ""
    Write-Output "Next step: run '/tgs:pull-from-svn --branch $testBranch' to complete the initial SVN sync."
    Write-Output ""
    Write-Output "Recommended: open Claude Code in the main worktree and run /tgs:setup to configure"
    Write-Output "  tgs environment variable defaults. Main worktree: $mainWorktree"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
