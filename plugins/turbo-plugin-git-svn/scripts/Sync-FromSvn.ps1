[CmdletBinding()]
param(
    [string]$Branch = '',
    [string]$Granularity = '',
    [string]$Range = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Replay one SVN revision (U3): svn update -r R in the bridge worktree, assert the WC is uniformly
# at R (guards against a sparse/partial update masquerading as an empty delta -- KTD4), then hand
# off to U1's Invoke-SvnReplayCommit (empty-delta + idempotent skips live there). Returns the U1
# token (COMMIT:<sha> / SKIP:empty / SKIP:idempotent) for the caller to surface if desired.
function Invoke-OneReplay {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][int]$Rev,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Author,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Date,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    Push-Location $RemotePath
    try {
        & svn update -r $Rev
        if ($LASTEXITCODE -ne 0) { throw "svn update -r $Rev failed" }
    } finally {
        Pop-Location
    }
    $wc = [int]((& svn info --show-item revision $RemotePath | Out-String).Trim())
    if ($wc -ne $Rev) { throw "Remote worktree not uniformly at r$Rev (got r$wc); refusing per-revision replay." }
    return (Invoke-SvnReplayCommit -RepoDir $RemotePath -Rev $Rev -Author $Author -Date $Date -Message $Message)
}

# Squash the current SVN HEAD-of-range into ONE boundary commit on the bridge worktree's HEAD.
# Subject stays `sync: svn r<rev>` (steady-state shape) but a second -m appends the
# `svn-revision: <rev>` trailer so floor-lookup (U5) treats the squashed range as a single boundary
# (plan line 297). Skips when `git add -A` leaves the index unchanged (empty delta).
function Invoke-BoundaryCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][int]$Rev
    )
    & git -C $RemotePath add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed in remote worktree' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & git -C $RemotePath diff --cached --quiet 2>$null | Out-Null
        $hasChanges = ($LASTEXITCODE -ne 0)
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($hasChanges) {
        & git -C $RemotePath -c commit.gpgsign=false commit -m "sync: svn r$Rev" -m "svn-revision: $Rev"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed in remote worktree' }
    }
}

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Missing required argument: -Branch <branch>'
    }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
    if ($mainStatus) {
        throw "Main worktree has uncommitted changes. Please commit or stash before pulling from SVN.`n$mainStatus"
    }

    # Dirty-check the remote worktree. `.svn/` is now in the bridge's .gitignore
    # (synced from main by New-RemoteBridge), so git ignores SVN's binary metadata and we no
    # longer hand-filter `.svn/*`; genuine manual edits are still caught and would otherwise be
    # packaged into the sync commit.
    $remoteStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if ($remoteStatus) {
        throw "Remote worktree '$($remote.Path)' has uncommitted changes — these would be packaged into the sync commit. Resolve before pulling.`n$remoteStatus"
    }

    # F-U(synth #11) + U3: detect a previously-orphaned remote sync commit (a prior pull committed on
    # remote-svn/<branch> but the merge into $Branch was aborted). Refuse until resolved.
    # `--no-merges` is load-bearing: a normal push leaves a benign `Merge branch '<branch>' into
    # remote-svn/<branch>` MERGE commit ahead of $Branch (content already in $Branch); that steady
    # state must NOT trip this guard.
    # U3 REFINEMENT (trailer-aware): the per-revision model's own replay commits carry an
    # `svn-revision:` trailer and ARE the resumable state -- an interrupted per-revision pull re-runs
    # and continues them, so those must NOT be treated as orphans. Only a non-merge commit ahead that
    # carries NO svn-revision trailer (a legacy `sync:` lump, or a genuinely orphaned aborted merge)
    # is a real orphan. This single refinement is what lets "resume" and "orphan still fires" coexist.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $aheadRaw = & git -C $mainWorktree log --no-merges --format='%H%x09%(trailers:key=svn-revision,valueonly)' "$Branch..$($remote.Branch)" 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $aheadLines = @($aheadRaw | Where-Object { $_ })
    $orphans = @($aheadLines | Where-Object {
        $parts = $_ -split "`t", 2
        $trailer = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        [string]::IsNullOrEmpty($trailer)
    })
    if (@($orphans).Count -gt 0) {
        $orphanDisplay = @($orphans | ForEach-Object { ($_ -split "`t", 2)[0] }) -join "`n"
        throw "remote/$($remote.Branch) has $(@($orphans).Count) unmerged sync commit(s) ahead of '$Branch':`n$orphanDisplay`n`nResolve via manual merge (git -C $mainWorktree merge $($remote.Branch)) or rerun /tp-pull-from-svn after the conflict is committed."
    }

    $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()

    # --- U3: per-revision replay loop with granularity control -------------------
    # Resolve the branch URL + repo HEAD (URL side, not the WC -- the WC reports only its
    # checked-out revision, not what SVN has). wcRevStart is the WC baseline captured BEFORE the
    # loop mutates it with `svn update -r R`.
    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'. Is it a valid SVN working copy?" }
    $headRev = [int]((& svn info --show-item revision $svnUrl | Out-String).Trim())
    $wcRevStart = [int]((& svn info --show-item revision $remote.Path | Out-String).Trim())

    # KTD4 sparse guard: a full (infinite-depth) checkout is required so `svn update -r R` yields a
    # uniform per-revision tree -- otherwise an empty post-update delta could mean "sparse update",
    # not "identical tree". Assert once, before the loop.
    $depth = (& svn info --show-item depth $remote.Path | Out-String).Trim()
    if ($depth -ne 'infinity') {
        throw "Remote worktree depth is '$depth', not 'infinity'; per-revision replay needs a full checkout."
    }

    # cur (resume point) = the greatest already-replayed `svn-revision:` trailer on the bridge branch,
    # floored by the WC's own revision. The wcRevStart term is the legacy-lump / transition floor:
    # a clean bridge WC guarantees its content == git HEAD tree, so wcRevStart is a valid
    # "already in git" floor even when the baseline lump commit carries no trailer. Forward-only
    # (never backfills lump history); collapses to the plan's trailer-only intent once U7 lands.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $trailerRaw = & git -C $mainWorktree log $remote.Branch --format='%(trailers:key=svn-revision,valueonly)' 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $trailerVals = @($trailerRaw | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ })
    $cur = (@($trailerVals) + @($wcRevStart) | Measure-Object -Maximum).Maximum

    # Enumerate r(cur+1)..headRev via U1. Guard the reversed/empty range so svn 1.14.x never sees a
    # `lo>hi` range (it errors "No such revision" on cur+1 > headRev).
    $revs = @()
    if ($cur -lt $headRev) {
        $logXml = (& svn log --xml -r "$($cur + 1):$headRev" $remote.Path | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "svn log failed for r$($cur + 1):r$headRev" }
        $revs = @(Get-SvnRevisions -LogXml $logXml)
    }
    $count = @($revs).Count
    $unmergedAhead = @($aheadLines).Count

    # Nothing new to replay and nothing resumable ahead -> up to date.
    if ($count -eq 0 -and $unmergedAhead -eq 0) {
        Write-Output "Already up to date at SVN r$cur"
        exit 0
    }

    # Granularity gate (KTD7 / R2-R4). <=5 new revisions replay per-revision silently. >5 with no
    # explicit choice -> emit a structured signal and exit 0 (NO commits, residue-free) so the SKILL
    # can prompt; distinct from the merge-conflict path which exits 1.
    $mode = 'per-revision'
    if ($count -gt 5) {
        if ([string]::IsNullOrWhiteSpace($Granularity)) {
            Write-Output "TP_TOKEN:GRANULARITY_REQUIRED count=$count range=r$($cur + 1):r$headRev"
            exit 0
        }
        $mode = $Granularity
    }

    if ($mode -eq 'per-revision') {
        Write-Output "Replaying $count SVN revision(s) r$($cur + 1)..r$headRev into $($remote.Name)..."
        foreach ($r in $revs) {
            $null = Invoke-OneReplay -RemotePath $remote.Path -Rev $r.Rev -Author $r.Author -Date $r.Date -Message $r.Message
        }
    }
    elseif ($mode -eq 'squash') {
        Write-Output "Squashing SVN r$($cur + 1)..r$headRev into one commit in $($remote.Name)..."
        Push-Location $remote.Path
        try {
            & svn update
            if ($LASTEXITCODE -ne 0) { throw 'svn update failed' }
        } finally {
            Pop-Location
        }
        Invoke-BoundaryCommit -RemotePath $remote.Path -Rev $headRev
    }
    elseif ($mode -eq 'range') {
        if ($Range -notmatch '^[0-9]+:[0-9]+$') {
            throw "Granularity 'range' requires -Range <lo>:<hi> (got '$Range')."
        }
        $loRaw, $hiRaw = $Range -split ':', 2
        $lo = [Math]::Max([int]$loRaw, $cur + 1)
        $hi = [Math]::Min([int]$hiRaw, $headRev)
        if ($lo -gt $hi) { throw "Granularity range r$loRaw:r$hiRaw does not overlap the pending r$($cur + 1):r$headRev." }
        Write-Output "Replaying r$lo..r$hi per-revision, squashing the rest, into $($remote.Name)..."
        # Leading squash: r(cur+1)..r(lo-1) -> one boundary commit at r(lo-1). Skipped when lo==cur+1.
        if (($lo - 1) -ge ($cur + 1)) {
            Push-Location $remote.Path
            try {
                & svn update -r ($lo - 1)
                if ($LASTEXITCODE -ne 0) { throw "svn update -r $($lo - 1) failed" }
            } finally {
                Pop-Location
            }
            Invoke-BoundaryCommit -RemotePath $remote.Path -Rev ($lo - 1)
        }
        # Per-revision inside [lo,hi].
        foreach ($r in $revs) {
            if ($r.Rev -ge $lo -and $r.Rev -le $hi) {
                $null = Invoke-OneReplay -RemotePath $remote.Path -Rev $r.Rev -Author $r.Author -Date $r.Date -Message $r.Message
            }
        }
        # Trailing squash: r(hi+1)..rHEAD -> one boundary commit at rHEAD. Skipped when hi>=headRev.
        if ($hi -lt $headRev) {
            Push-Location $remote.Path
            try {
                & svn update
                if ($LASTEXITCODE -ne 0) { throw 'svn update failed' }
            } finally {
                Pop-Location
            }
            Invoke-BoundaryCommit -RemotePath $remote.Path -Rev $headRev
        }
    }
    else {
        throw "Unknown granularity '$Granularity' (expected per-revision | squash | range)."
    }

    $switched = $false
    if ($originalBranch -ne $Branch) {
        Write-Output "Switching main worktree from '$originalBranch' to '$Branch'..."
        & git -C $mainWorktree checkout $Branch
        if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
        $switched = $true
    }

    & git -C $mainWorktree merge $remote.Branch --no-ff -m "Merge branch '$($remote.Branch)' into $Branch"
    $mergeExit = $LASTEXITCODE

    if ($mergeExit -ne 0) {
        $conflicts = (& git -C $mainWorktree diff --name-only --diff-filter=U | Out-String).Trim()
        # Rollback: abort the merge and return to original branch so the worktree is clean.
        # Capture each rollback op's exit code separately so we can detect rollback failure
        # and emit a distinct error (working tree may be in an inconsistent state).
        & git -C $mainWorktree merge --abort 2>$null | Out-Null
        $abortStatus = $LASTEXITCODE
        $checkoutStatus = 0
        if ($switched) {
            & git -C $mainWorktree checkout $originalBranch 2>$null | Out-Null
            $checkoutStatus = $LASTEXITCODE
        }
        if ($abortStatus -ne 0 -or $checkoutStatus -ne 0) {
            throw "Merge conflict detected; automatic rollback failed (abort exit=$abortStatus, checkout exit=$checkoutStatus). Working tree is in an inconsistent state. Resolve manually before re-running."
        }
        throw "Merge conflict detected. The merge has been aborted and main worktree restored to '$originalBranch'. Conflicting files:`n$conflicts`n`nResolve conflicts manually, commit, then rerun '/tp-pull-from-svn'."
    }

    if ($switched) {
        & git -C $mainWorktree checkout $originalBranch
        if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        Write-Output "Switched back to '$originalBranch'."
    }

    Write-Output "Pulled SVN r$($cur + 1)..r$headRev into $Branch ($count revision(s), $mode)"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
