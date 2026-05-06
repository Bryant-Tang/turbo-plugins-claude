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
    # Removes a single folder entry from a VS Code workspace file using
    # line-based manipulation, mirroring the .sh version's surgical approach
    # so the rest of the file (indentation, key order, trailing newline) is
    # preserved verbatim.
    param([string]$WorkspaceFile, [string]$FolderName)
    if (-not (Test-Path -LiteralPath $WorkspaceFile -PathType Leaf)) { return $false }

    $rawContent = [System.IO.File]::ReadAllText($WorkspaceFile)
    $eol = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hadTrailingNewline = $rawContent.EndsWith("`n")

    # Split keeping line content only (no terminators)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($rawContent -split "`r?`n")) { [void]$lines.Add($l) }
    # If file ended with a newline, the split produced a trailing empty string
    # we want to drop (we'll add the trailing newline back at the end).
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    $namePattern = '"name"\s*:\s*"' + [regex]::Escape($FolderName) + '"'
    $targetIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $namePattern) { $targetIdx = $i; break }
    }
    if ($targetIdx -lt 0) { return $false }

    $targetLine = $lines[$targetIdx]
    if ($targetLine.Contains('{') -and $targetLine.Contains('}')) {
        # Single-line entry
        if ($targetLine -match ',\s*$') {
            $lines.RemoveAt($targetIdx)
        } else {
            # Last entry; drop trailing comma on previous folder line
            $prev = $targetIdx - 1
            if ($prev -ge 0) {
                $lines[$prev] = $lines[$prev] -replace ',\s*$', ''
            }
            $lines.RemoveAt($targetIdx)
        }
    } else {
        # Multi-line entry: walk back to opening brace at start of a line and
        # forward to closing brace at start of a line.
        $startIdx = $targetIdx
        while ($startIdx -gt 0 -and $lines[$startIdx] -notmatch '^\s*\{') {
            $startIdx--
        }
        $endIdx = $targetIdx
        while ($endIdx -lt $lines.Count - 1 -and $lines[$endIdx] -notmatch '^\s*\}') {
            $endIdx++
        }
        $hadTrailingComma = $lines[$endIdx] -match '\},\s*$'

        for ($i = $endIdx; $i -ge $startIdx; $i--) { $lines.RemoveAt($i) }

        if (-not $hadTrailingComma) {
            # Was the last folder block; trim the trailing comma off the new
            # last entry (skipping blank lines).
            for ($i = $startIdx - 1; $i -ge 0; $i--) {
                if ($lines[$i].Trim() -ne '') {
                    $lines[$i] = $lines[$i] -replace '\},\s*$', '}'
                    break
                }
            }
        }
    }

    $newContent = ($lines -join $eol)
    if ($hadTrailingNewline) { $newContent += $eol }
    Write-Utf8NoBom -FilePath $WorkspaceFile -Content $newContent
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
    if (Test-Path -LiteralPath $remoteWorktreePath -PathType Container) {
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
    if (Test-Path -LiteralPath $workspaceFile -PathType Leaf) {
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
