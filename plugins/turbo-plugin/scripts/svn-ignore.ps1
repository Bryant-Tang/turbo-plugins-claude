[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

# Manual arg parsing so `-Add p1 -Add p2` works when invoked via
# `powershell -File ...` (which would otherwise stringify an array param).
$Add    = @()
$Remove = @()
$Path   = '.'

$i = 0
$argList = @()
if ($null -ne $Arguments) { $argList = @($Arguments) }
while ($i -lt $argList.Count) {
    $a = $argList[$i]
    switch ($a) {
        '-Add' {
            if ($i + 1 -ge $argList.Count) { throw "Argument '-Add' requires a value." }
            $Add += $argList[$i + 1]; $i += 2
        }
        '-Remove' {
            if ($i + 1 -ge $argList.Count) { throw "Argument '-Remove' requires a value." }
            $Remove += $argList[$i + 1]; $i += 2
        }
        '-Path' {
            if ($i + 1 -ge $argList.Count) { throw "Argument '-Path' requires a value." }
            $Path = $argList[$i + 1]; $i += 2
        }
        default { throw "Unknown argument: '$a'" }
    }
}

function Get-SvnIgnorePatterns {
    param([string]$TargetPath)
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $raw = (& svn propget svn:ignore $TargetPath 2>$null | Out-String)
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $ea
    if ($exit -ne 0) { return ,@() }
    return ,@($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
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
        throw "Worktrees directory not found: $worktreesDir. Run /tp-setup to bootstrap the SVN remote worktrees."
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

    # ── ADD (two-pass: propset all → verify → commit all) ─────────────────────
    if ($Add.Count -gt 0) {
        # Pass 1: compute and apply propset to all worktrees; collect which need commit.
        $pendingAdd = @{}  # wt → @{ ToAdd = ...; NewPatterns = ... }
        $propsetFailed = @()

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
                try {
                    Set-SvnIgnorePatterns -Patterns $newPatterns -TargetPath $Path -WorktreeName $wtName
                    $pendingAdd[$wt] = @{ ToAdd = $toAdd; NewPatterns = $newPatterns }
                } catch {
                    $propsetFailed += $wtName
                }
            } finally {
                Pop-Location
            }
        }

        # If any propset failed, revert all that succeeded and abort.
        if ($propsetFailed.Count -gt 0) {
            foreach ($wt in $pendingAdd.Keys) {
                Push-Location $wt
                try { & svn revert $Path 2>$null | Out-Null } finally { Pop-Location }
            }
            throw "svn propset svn:ignore failed in: $($propsetFailed -join ', '). All worktrees reverted. Resolve SVN issues and retry."
        }

        # Pass 2: commit each worktree. Capture per-iteration failure into a structured report so
        # partial commits are surfaced clearly — already-committed worktrees cannot be rolled back.
        $succeeded = @()
        $failed    = @()
        foreach ($wt in $pendingAdd.Keys) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            $info = $pendingAdd[$wt]
            Push-Location $wt
            try {
                try {
                    $eaSvnCommitAdd = $ErrorActionPreference
                    $ErrorActionPreference = 'SilentlyContinue'
                    & svn commit -m "svn:ignore: add $($info.ToAdd -join ', ')" 2>$null | Out-Null
                    $svnCommitExit = $LASTEXITCODE
                    $ErrorActionPreference = $eaSvnCommitAdd
                    if ($svnCommitExit -ne 0) { throw "svn commit returned exit code $svnCommitExit" }
                    Write-Output "Added '$($info.ToAdd -join "', '")' to svn:ignore in '$wtName'"
                    $succeeded += $wtName
                } catch {
                    $failed += "${wtName}: $($_.Exception.Message)"
                }
            } finally {
                Pop-Location
            }
        }
        if ($failed.Count -gt 0) {
            [Console]::Error.WriteLine("svn-ignore: pass-2 partial failure.")
            [Console]::Error.WriteLine("Succeeded ($($succeeded.Count) worktrees): $($succeeded -join ', ')")
            [Console]::Error.WriteLine("Failed ($($failed.Count) worktrees):")
            foreach ($f in $failed) { [Console]::Error.WriteLine("  $f") }
            [Console]::Error.WriteLine("Already-committed worktrees cannot be rolled back. Inspect and 'svn revert' the failed worktrees manually.")
            exit 1
        }
        exit 0
    }

    # ── REMOVE (two-pass: propset all → verify → commit all) ──────────────────
    if ($Remove.Count -gt 0) {
        # Pass 1: compute and apply propset/propdel to all worktrees.
        $pendingRemove = @{}  # wt → @{ ToRemove = ... }
        $propsetFailed = @()

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
                try {
                    if ($newPatterns.Count -eq 0) {
                        & svn propdel svn:ignore $Path
                        if ($LASTEXITCODE -ne 0) { throw "svn propdel failed in '$wtName'" }
                    } else {
                        Set-SvnIgnorePatterns -Patterns $newPatterns -TargetPath $Path -WorktreeName $wtName
                    }
                    $pendingRemove[$wt] = @{ ToRemove = $toRemove }
                } catch {
                    $propsetFailed += $wtName
                }
            } finally {
                Pop-Location
            }
        }

        # If any propset/propdel failed, revert all that succeeded and abort.
        if ($propsetFailed.Count -gt 0) {
            foreach ($wt in $pendingRemove.Keys) {
                Push-Location $wt
                try { & svn revert $Path 2>$null | Out-Null } finally { Pop-Location }
            }
            throw "svn propset/propdel svn:ignore failed in: $($propsetFailed -join ', '). All worktrees reverted. Resolve SVN issues and retry."
        }

        # Pass 2: commit each worktree. Capture per-iteration failure into a structured report so
        # partial commits are surfaced clearly — already-committed worktrees cannot be rolled back.
        $succeeded = @()
        $failed    = @()
        foreach ($wt in $pendingRemove.Keys) {
            $wtName = [System.IO.Path]::GetFileName($wt)
            $info = $pendingRemove[$wt]
            Push-Location $wt
            try {
                try {
                    $eaSvnCommitRemove = $ErrorActionPreference
                    $ErrorActionPreference = 'SilentlyContinue'
                    & svn commit -m "svn:ignore: remove $($info.ToRemove -join ', ')" 2>$null | Out-Null
                    $svnCommitExit = $LASTEXITCODE
                    $ErrorActionPreference = $eaSvnCommitRemove
                    if ($svnCommitExit -ne 0) { throw "svn commit returned exit code $svnCommitExit" }
                    Write-Output "Removed '$($info.ToRemove -join "', '")' from svn:ignore in '$wtName'"
                    $succeeded += $wtName
                } catch {
                    $failed += "${wtName}: $($_.Exception.Message)"
                }
            } finally {
                Pop-Location
            }
        }
        if ($failed.Count -gt 0) {
            [Console]::Error.WriteLine("svn-ignore: pass-2 partial failure.")
            [Console]::Error.WriteLine("Succeeded ($($succeeded.Count) worktrees): $($succeeded -join ', ')")
            [Console]::Error.WriteLine("Failed ($($failed.Count) worktrees):")
            foreach ($f in $failed) { [Console]::Error.WriteLine("  $f") }
            [Console]::Error.WriteLine("Already-committed worktrees cannot be rolled back. Inspect and 'svn revert' the failed worktrees manually.")
            exit 1
        }
        exit 0
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
