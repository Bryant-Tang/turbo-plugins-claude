[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Manual arg parsing so `-Move p1 -Move p2` works when invoked via
# `powershell -File ...` (which would otherwise stringify an array param).
$BranchFrom = ''
$BranchTo   = ''
$Move       = @()

$i = 0
$argList = @()
if ($null -ne $Arguments) { $argList = @($Arguments) }
while ($i -lt $argList.Count) {
    $a = $argList[$i]
    switch ($a) {
        '-BranchFrom' {
            if ($i + 1 -ge $argList.Count) { throw "Argument '-BranchFrom' requires a value." }
            $BranchFrom = $argList[$i + 1]; $i += 2
        }
        '-BranchTo' {
            if ($i + 1 -ge $argList.Count) { throw "Argument '-BranchTo' requires a value." }
            $BranchTo = $argList[$i + 1]; $i += 2
        }
        '-Move' {
            if ($i + 1 -ge $argList.Count) { throw "Argument '-Move' requires a value." }
            $Move += $argList[$i + 1]; $i += 2
        }
        default { throw "Unknown argument: '$a'" }
    }
}

function Get-MainWorktree {
    $commonGitDir = (& git rev-parse --git-common-dir | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
    return [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonGitDir))
}

try {
    if ([string]::IsNullOrWhiteSpace($BranchFrom)) { throw 'Missing required argument: -BranchFrom <old-name>' }
    if ([string]::IsNullOrWhiteSpace($BranchTo)) { throw 'Missing required argument: -BranchTo <new-name>' }
    if (-not $Move -or $Move.Count -eq 0) { throw 'Missing required argument: -Move <from>=<to> (at least one)' }

    if ($BranchFrom -notmatch '^[A-Za-z0-9._/\-]+$') { throw "Invalid -BranchFrom value '$BranchFrom'." }
    if ($BranchTo -notmatch '^[A-Za-z0-9._/\-]+$') { throw "Invalid -BranchTo value '$BranchTo'." }

    $moves = @()
    foreach ($entry in $Move) {
        $idx = $entry.IndexOf('=')
        if ($idx -lt 1 -or $idx -ge ($entry.Length - 1)) {
            throw "Invalid -Move entry '$entry'. Expected format: <from>=<to>"
        }
        $fromRel = $entry.Substring(0, $idx)
        $toRel = $entry.Substring($idx + 1)
        if ([string]::IsNullOrWhiteSpace($fromRel) -or [string]::IsNullOrWhiteSpace($toRel)) {
            throw "Invalid -Move entry '$entry'. Both <from> and <to> are required."
        }
        $moves += [pscustomobject]@{ From = $fromRel; To = $toRel }
    }

    $mainWorktree = Get-MainWorktree

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $mainWorktree rev-parse --verify -q "refs/heads/$BranchFrom" 2>$null | Out-Null
    $fromExists = ($LASTEXITCODE -eq 0)
    & git -C $mainWorktree rev-parse --verify -q "refs/heads/$BranchTo" 2>$null | Out-Null
    $toExists = ($LASTEXITCODE -eq 0)
    & git -C $mainWorktree rev-parse --verify -q "refs/heads/main" 2>$null | Out-Null
    $mainExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea

    if (-not $fromExists) { throw "Source branch '$BranchFrom' does not exist." }
    if ($toExists) { throw "Target branch '$BranchTo' already exists." }
    if (-not $mainExists) { throw "main branch does not exist; cannot verify merged state." }

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $mainWorktree merge-base --is-ancestor $BranchFrom 'main' 2>$null | Out-Null
    $isMerged = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if (-not $isMerged) {
        throw "Source branch '$BranchFrom' is not yet merged into 'main'. Merge it first (e.g. via /tgs:release) before archiving."
    }

    $status = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($status) {
        throw "Main worktree has uncommitted changes. Commit or stash before archiving.`n$status"
    }

    $currentBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()
    if ($currentBranch -eq $BranchFrom) {
        throw "Main worktree is currently on '$BranchFrom'. Switch off before archiving."
    }

    $worktreeOutput = (& git -C $mainWorktree worktree list --porcelain | Out-String)
    $worktreeLines = $worktreeOutput -split "`r?`n"
    foreach ($line in $worktreeLines) {
        if ($line -eq "branch refs/heads/$BranchFrom") {
            throw "Branch '$BranchFrom' is checked out in another worktree. Switch that worktree off the branch before archiving."
        }
    }

    foreach ($m in $moves) {
        $fromPath = Join-Path $mainWorktree $m.From
        $toPath = Join-Path $mainWorktree $m.To
        if (-not (Test-Path -LiteralPath $fromPath)) {
            throw "Source path does not exist: $($m.From)"
        }
        if (Test-Path -LiteralPath $toPath) {
            throw "Destination path already exists: $($m.To)"
        }
    }

    & git -C $mainWorktree branch -m $BranchFrom $BranchTo
    if ($LASTEXITCODE -ne 0) { throw "git branch -m '$BranchFrom' '$BranchTo' failed" }
    Write-Output "Renamed branch '$BranchFrom' -> '$BranchTo'."

    $moved = @()
    $moveError = $null
    foreach ($m in $moves) {
        $fromPath = Join-Path $mainWorktree $m.From
        $toPath = Join-Path $mainWorktree $m.To
        try {
            $toParent = [System.IO.Path]::GetDirectoryName($toPath)
            if ($toParent -and -not (Test-Path -LiteralPath $toParent)) {
                New-Item -ItemType Directory -Force -Path $toParent | Out-Null
            }
            Move-Item -LiteralPath $fromPath -Destination $toPath
            $moved += [pscustomobject]@{ FromAbs = $fromPath; ToAbs = $toPath; FromRel = $m.From; ToRel = $m.To }
            Write-Output "Moved '$($m.From)' -> '$($m.To)'."
        }
        catch {
            $moveError = "Failed to move '$($m.From)' -> '$($m.To)': $($_.Exception.Message)"
            break
        }
    }

    if ($moveError) {
        Write-Output ''
        Write-Output 'Rolling back due to move failure...'
        $rollbackErrors = @()
        for ($i = $moved.Count - 1; $i -ge 0; $i--) {
            $mv = $moved[$i]
            try {
                Move-Item -LiteralPath $mv.ToAbs -Destination $mv.FromAbs
            }
            catch {
                $rollbackErrors += "Could not restore '$($mv.ToRel)' -> '$($mv.FromRel)': $($_.Exception.Message)"
            }
        }
        try {
            & git -C $mainWorktree branch -m $BranchTo $BranchFrom
            if ($LASTEXITCODE -ne 0) { throw "git branch -m '$BranchTo' '$BranchFrom' failed" }
        }
        catch {
            $rollbackErrors += "Could not revert branch rename '$BranchTo' -> '$BranchFrom': $($_.Exception.Message)"
        }
        if ($rollbackErrors.Count -gt 0) {
            $msg = "Archive failed mid-way and rollback was incomplete.`nOriginal error: $moveError`nRollback errors:`n  - " + ($rollbackErrors -join "`n  - ")
            throw $msg
        }
        else {
            throw "Archive failed mid-way; rollback succeeded. Original error: $moveError"
        }
    }

    Write-Output "Archive complete: '$BranchFrom' -> '$BranchTo' with $($moves.Count) folder move(s)."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
