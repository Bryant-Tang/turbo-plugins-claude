[CmdletBinding()]
param(
    [string]$Add    = '',
    [string]$Remove = '',
    [string]$Path   = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

function Get-SvnIgnorePatterns {
    param([string]$TargetPath)
    $raw = (& svn propget svn:ignore $TargetPath 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

try {
    if (-not [string]::IsNullOrWhiteSpace($Add) -and -not [string]::IsNullOrWhiteSpace($Remove)) {
        throw 'Use either -Add or -Remove, not both.'
    }

    $mainWorktree = Get-MainWorktree
    $projName     = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    if (-not (Test-Path -LiteralPath $worktreesDir -PathType Container)) {
        throw "Worktrees directory not found: $worktreesDir. Are you inside a tgs project?"
    }

    $remoteWorktrees = @(
        Get-ChildItem -LiteralPath $worktreesDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^remote-(main|test-\d+)$' } |
        ForEach-Object { $_.FullName }
    )

    if ($remoteWorktrees.Count -eq 0) {
        throw "No remote worktrees found in: $worktreesDir"
    }

    # ── LIST ──────────────────────────────────────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($Add) -and [string]::IsNullOrWhiteSpace($Remove)) {
        $remotemainPath = Join-Path $worktreesDir 'remote-main'
        if (-not (Test-Path -LiteralPath $remotemainPath -PathType Container)) {
            throw "remote-main worktree not found at: $remotemainPath"
        }
        Push-Location $remotemainPath
        try { $canonical = Get-SvnIgnorePatterns -TargetPath $Path } finally { Pop-Location }

        if ($canonical.Count -eq 0) {
            Write-Output "No SVN ignore patterns at '$Path'"
        } else {
            Write-Output "SVN ignore patterns at '$Path':"
            $canonical | ForEach-Object { Write-Output "  $_" }
        }

        foreach ($wt in $remoteWorktrees) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            if ($wtName -eq 'remote-main') { continue }
            Push-Location $wt
            try { $wtPatterns = Get-SvnIgnorePatterns -TargetPath $Path } finally { Pop-Location }
            $diff = Compare-Object -ReferenceObject @($canonical) -DifferenceObject @($wtPatterns) -ErrorAction SilentlyContinue
            if ($diff) { Write-Output "Warning: svn:ignore in '$wtName' differs from remote-main — run 'svn-ignore --add/--remove' to re-sync" }
        }
        exit 0
    }

    # ── ADD ───────────────────────────────────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($Add)) {
        foreach ($wt in $remoteWorktrees) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            Push-Location $wt
            try {
                $svnDirty = (& svn status | Out-String).Trim()
                if ($svnDirty) {
                    Write-Output "Warning: '$wtName' has pending SVN changes — skipping (commit or revert first)"
                    continue
                }

                $patterns = Get-SvnIgnorePatterns -TargetPath $Path
                if ($patterns -contains $Add) {
                    Write-Output "'$wtName': '$Add' already in svn:ignore — skipping"
                    continue
                }

                # Warn if pattern matches already-tracked SVN files (best effort)
                $allTracked = @(& svn list -R $Path 2>$null | Where-Object { $_ -ne $null })
                $matchingTracked = @($allTracked | Where-Object {
                    $item = $_.TrimEnd('/')
                    ($item -like $Add) -or ([System.IO.Path]::GetFileName($item) -like $Add)
                })
                if ($matchingTracked.Count -gt 0) {
                    Write-Output "Warning ('$wtName'): svn:ignore won't affect already-tracked files:"
                    $matchingTracked | Select-Object -First 5 | ForEach-Object { Write-Output "  $_" }
                    if ($matchingTracked.Count -gt 5) { Write-Output "  ... ($($matchingTracked.Count) total)" }
                    Write-Output "  To stop pushing modifications, use 'git rm --cached' + .gitignore instead."
                }

                $newPatterns = $patterns + $Add
                & svn propset svn:ignore ($newPatterns -join "`n") $Path
                if ($LASTEXITCODE -ne 0) { throw "svn propset failed in '$wtName'" }
                & svn commit -m "svn:ignore: add $Add"
                if ($LASTEXITCODE -ne 0) { throw "svn commit failed in '$wtName'" }
                Write-Output "Added '$Add' to svn:ignore in '$wtName'"
            } finally {
                Pop-Location
            }
        }
        exit 0
    }

    # ── REMOVE ────────────────────────────────────────────────────────────────
    if (-not [string]::IsNullOrWhiteSpace($Remove)) {
        foreach ($wt in $remoteWorktrees) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            Push-Location $wt
            try {
                $svnDirty = (& svn status | Out-String).Trim()
                if ($svnDirty) {
                    Write-Output "Warning: '$wtName' has pending SVN changes — skipping (commit or revert first)"
                    continue
                }

                $patterns = Get-SvnIgnorePatterns -TargetPath $Path
                if ($patterns -notcontains $Remove) {
                    Write-Output "'$wtName': '$Remove' not found in svn:ignore — skipping"
                    continue
                }

                $newPatterns = @($patterns | Where-Object { $_ -ne $Remove })
                if ($newPatterns.Count -eq 0) {
                    & svn propdel svn:ignore $Path
                    if ($LASTEXITCODE -ne 0) { throw "svn propdel failed in '$wtName'" }
                } else {
                    & svn propset svn:ignore ($newPatterns -join "`n") $Path
                    if ($LASTEXITCODE -ne 0) { throw "svn propset failed in '$wtName'" }
                }
                & svn commit -m "svn:ignore: remove $Remove"
                if ($LASTEXITCODE -ne 0) { throw "svn commit failed in '$wtName'" }
                Write-Output "Removed '$Remove' from svn:ignore in '$wtName'"
            } finally {
                Pop-Location
            }
        }
        exit 0
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
