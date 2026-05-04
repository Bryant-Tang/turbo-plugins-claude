[CmdletBinding()]
param(
    [string[]]$Add    = @(),
    [string[]]$Remove = @(),
    [string]$Path     = '.'
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
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $raw = (& svn propget svn:ignore $TargetPath 2>$null | Out-String)
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $ea
    if ($exit -ne 0) { return @() }
    return @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Set-SvnIgnorePatterns {
    param([string[]]$Patterns, [string]$TargetPath, [string]$WorktreeName)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, ($Patterns -join "`r`n"), $enc)
        & svn propset svn:ignore --file $tmp $TargetPath
        if ($LASTEXITCODE -ne 0) { throw "svn propset failed in '$WorktreeName'" }
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

try {
    if ($Add.Count -gt 0 -and $Remove.Count -gt 0) {
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
    if ($Add.Count -eq 0 -and $Remove.Count -eq 0) {
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
    if ($Add.Count -gt 0) {
        foreach ($wt in $remoteWorktrees) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            Push-Location $wt
            try {
                $ea = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                $svnDirty = (& svn status 2>$null | Where-Object { $_ -match '^([MACDR!~]|.[MC])' } | Out-String).Trim()
                $ErrorActionPreference = $ea
                if ($svnDirty) {
                    Write-Output "Warning: '$wtName' has pending SVN changes — skipping (commit or revert first)"
                    continue
                }

                $patterns = Get-SvnIgnorePatterns -TargetPath $Path
                $toAdd    = @($Add | Where-Object { $patterns -notcontains $_ })
                foreach ($p in @($Add | Where-Object { $patterns -contains $_ })) {
                    Write-Output "'$wtName': '$p' already in svn:ignore — skipping"
                }
                if ($toAdd.Count -eq 0) { continue }

                # Warn if any new pattern matches already-tracked SVN files (best effort)
                $ea = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                $allTracked = @(& svn list -R $Path 2>$null | Where-Object { $_ -ne $null })
                $ErrorActionPreference = $ea
                foreach ($p in $toAdd) {
                    $matchingTracked = @($allTracked | Where-Object {
                        $item = $_.TrimEnd('/')
                        ($item -like $p) -or ([System.IO.Path]::GetFileName($item) -like $p)
                    })
                    if ($matchingTracked.Count -gt 0) {
                        Write-Output "Warning ('$wtName'): svn:ignore won't affect already-tracked files matching '$p':"
                        $matchingTracked | Select-Object -First 5 | ForEach-Object { Write-Output "  $_" }
                        if ($matchingTracked.Count -gt 5) { Write-Output "  ... ($($matchingTracked.Count) total)" }
                        Write-Output "  To stop pushing modifications, use 'git rm --cached' + .gitignore instead."
                    }
                }

                $newPatterns = $patterns + $toAdd
                Set-SvnIgnorePatterns -Patterns $newPatterns -TargetPath $Path -WorktreeName $wtName
                & svn commit -m "svn:ignore: add $($toAdd -join ', ')"
                if ($LASTEXITCODE -ne 0) { throw "svn commit failed in '$wtName'" }
                Write-Output "Added '$($toAdd -join "', '")' to svn:ignore in '$wtName'"
            } finally {
                Pop-Location
            }
        }
        exit 0
    }

    # ── REMOVE ────────────────────────────────────────────────────────────────
    if ($Remove.Count -gt 0) {
        foreach ($wt in $remoteWorktrees) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            Push-Location $wt
            try {
                $ea = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                $svnDirty = (& svn status 2>$null | Where-Object { $_ -match '^([MACDR!~]|.[MC])' } | Out-String).Trim()
                $ErrorActionPreference = $ea
                if ($svnDirty) {
                    Write-Output "Warning: '$wtName' has pending SVN changes — skipping (commit or revert first)"
                    continue
                }

                $patterns  = Get-SvnIgnorePatterns -TargetPath $Path
                $toRemove  = @($Remove | Where-Object { $patterns -contains $_ })
                foreach ($p in @($Remove | Where-Object { $patterns -notcontains $_ })) {
                    Write-Output "'$wtName': '$p' not found in svn:ignore — skipping"
                }
                if ($toRemove.Count -eq 0) { continue }

                $newPatterns = @($patterns | Where-Object { $toRemove -notcontains $_ })
                if ($newPatterns.Count -eq 0) {
                    & svn propdel svn:ignore $Path
                    if ($LASTEXITCODE -ne 0) { throw "svn propdel failed in '$wtName'" }
                } else {
                    Set-SvnIgnorePatterns -Patterns $newPatterns -TargetPath $Path -WorktreeName $wtName
                }
                & svn commit -m "svn:ignore: remove $($toRemove -join ', ')"
                if ($LASTEXITCODE -ne 0) { throw "svn commit failed in '$wtName'" }
                Write-Output "Removed '$($toRemove -join "', '")' from svn:ignore in '$wtName'"
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
