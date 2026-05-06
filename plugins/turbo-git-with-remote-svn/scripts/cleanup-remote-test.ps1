[CmdletBinding()]
param(
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

function Remove-WorkspaceEntry {
    param([string]$WorkspaceFile, [string]$FolderName)
    if (-not (Test-Path -LiteralPath $WorkspaceFile)) { return $false }
    $ws = Get-Content -LiteralPath $WorkspaceFile -Raw | ConvertFrom-Json
    $folders = @($ws.folders)
    $kept = @($folders | Where-Object { $_.name -ne $FolderName })
    if ($kept.Count -eq $folders.Count) { return $false }
    $ws.folders = $kept
    $json = $ws | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -FilePath $WorkspaceFile -Content $json
    return $true
}

try {
    if ([string]::IsNullOrWhiteSpace($N)) { throw 'Missing required argument: -N <number>' }
    if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }

    $idx = [int]$N
    $testBranch = "test-$idx"
    $remoteBranch = "remote/test-$idx"
    $remoteWorktreeName = "remote-test-$idx"

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $rootDir = [System.IO.Path]::GetDirectoryName($mainWorktree)
    $worktreesDir = Join-Path $rootDir "$projName.worktrees"
    $workspaceFile = Join-Path $rootDir "$projName.code-workspace"
    $remoteWorktreePath = Join-Path $worktreesDir $remoteWorktreeName

    # Pre-flight: not currently checked out on test-<n>
    $currentBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()
    if ($currentBranch -eq $testBranch) {
        throw "Main worktree is currently on '$testBranch'. Switch to 'main' first (e.g. 'git checkout main') before cleanup."
    }

    # Pre-flight: main worktree clean
    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Commit or stash before cleanup.`n$mainStatus"
    }

    # Pre-flight: remote-test-<n> worktree clean (only if it exists)
    if (Test-Path -LiteralPath $remoteWorktreePath -PathType Container) {
        $remoteStatus = (& git -C $remoteWorktreePath status --porcelain | Out-String).Trim()
        if ($remoteStatus) {
            throw "Remote test worktree '$remoteWorktreePath' has uncommitted changes. Run /tgs:push-to-svn or /tgs:pull-from-svn before cleanup.`n$remoteStatus"
        }
    }

    Write-Output "Removing test environment $idx..."

    # Remove the worktree (if present)
    if (Test-Path -LiteralPath $remoteWorktreePath) {
        & git -C $mainWorktree worktree remove --force $remoteWorktreePath
        if ($LASTEXITCODE -ne 0) { throw "git worktree remove $remoteWorktreeName failed" }
        Write-Output "  - Removed worktree: $remoteWorktreePath"
    } else {
        Write-Output "  - Worktree '$remoteWorktreeName' was not present, skipping."
    }

    # Delete branches (use -D to allow even if not merged; this is intentional retirement)
    $existingTest = (& git -C $mainWorktree branch --list $testBranch | Out-String).Trim()
    if ($existingTest) {
        & git -C $mainWorktree branch -D $testBranch
        if ($LASTEXITCODE -ne 0) { throw "git branch -D $testBranch failed" }
        Write-Output "  - Deleted branch: $testBranch"
    } else {
        Write-Output "  - Branch '$testBranch' was not present, skipping."
    }

    $existingRemote = (& git -C $mainWorktree branch --list $remoteBranch | Out-String).Trim()
    if ($existingRemote) {
        & git -C $mainWorktree branch -D $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git branch -D $remoteBranch failed" }
        Write-Output "  - Deleted branch: $remoteBranch"
    } else {
        Write-Output "  - Branch '$remoteBranch' was not present, skipping."
    }

    # Workspace cleanup
    if (Test-Path -LiteralPath $workspaceFile) {
        $removed = Remove-WorkspaceEntry -WorkspaceFile $workspaceFile -FolderName $remoteWorktreeName
        if ($removed) {
            Write-Output "  - Removed workspace entry: $remoteWorktreeName"
        } else {
            Write-Output "  - Workspace entry '$remoteWorktreeName' was not present, skipping."
        }
    } else {
        Write-Output "  - No code-workspace file found, skipping workspace cleanup."
    }

    Write-Output ''
    Write-Output "Cleanup complete for test-$idx."
    Write-Output "Note: SVN path is preserved as history. Next /tgs:create-remote-test will use a fresh number; if you want to reuse the same SVN URL, pass --svn-url to a new test slot."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
