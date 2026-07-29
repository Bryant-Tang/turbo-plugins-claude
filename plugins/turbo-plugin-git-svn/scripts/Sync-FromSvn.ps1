[CmdletBinding()]
param(
    [string]$Branch = '',
    [string]$Granularity = '',
    [string]$Range = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# U3/U7: the per-revision replay loop (svn update -r R -> replay-commit, squash boundary commits,
# granularity dispatch) now lives in lib/Common.ps1 (Invoke-SvnOneReplay / Invoke-SvnBoundaryCommit /
# Invoke-SvnReplayDispatch), shared verbatim with the first-import bootstrap (Initialize-GitSvnBridge).
# This script keeps only the resume-point (`cur`) derivation + the granularity GATE, then delegates.

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
        $aheadRaw = & git -C $mainWorktree log --no-merges --format='%H' "$Branch..$($remote.Branch)" 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    # Marker-aware: a replay commit is MARKED by refs/tp/svn/<N> and is resumable state, not an
    # orphan. Only an UNMARKED non-merge commit ahead is a real orphan.
    $markedShas = @{}
    foreach ($m in (Get-SvnRevMarks -RepoDir $mainWorktree)) { $markedShas[$m.Sha] = $true }
    $aheadLines = @($aheadRaw | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9a-f]{40}$' })
    $orphans = @($aheadLines | Where-Object { -not $markedShas.ContainsKey($_) })
    if (@($orphans).Count -gt 0) {
        $orphanDisplay = $orphans -join "`n"
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

    # cur (resume point) = the greatest MARKED revision reachable from the bridge branch, floored by
    # the WC's own revision (a clean bridge WC guarantees its content == git HEAD tree, so
    # wcRevStart is a valid "already in git" floor even for a baseline predating any marker).
    $maxMark = Get-SvnMaxRevReachable -RepoDir $mainWorktree -Ref $remote.Branch
    $cur = (@([int]$maxMark) + @($wcRevStart) | Measure-Object -Maximum).Maximum

    # Count pending revisions r(cur+1)..headRev for the granularity GATE. Invoke-SvnReplayDispatch
    # re-enumerates the full records; here we only need the COUNT. Guard the reversed/empty range so
    # svn 1.14.x never sees a `lo>hi` range (it errors "No such revision" on cur+1 > headRev).
    $count = 0
    if ($cur -lt $headRev) {
        $logXml = (& svn log --xml -r "$($cur + 1):$headRev" $remote.Path | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "svn log failed for r$($cur + 1):r$headRev" }
        $count = @(Get-SvnRevisions -LogXml $logXml).Count
    }
    $unmergedAhead = @($aheadLines).Count

    # Nothing new to replay and nothing resumable ahead -> up to date.
    if ($count -eq 0 -and $unmergedAhead -eq 0) {
        # The working copy legitimately sits below the repository HEAD in a repository shared with
        # other projects: a sibling path's commit bumps the global revision without touching ours.
        # Catch it up anyway. It costs one no-op update, and a working copy left permanently behind
        # makes every later pull re-enumerate an ever-growing range of revisions that were never
        # ours. Failure is not fatal here -- we are already reporting "up to date".
        if ($wcRevStart -lt $headRev) {
            try { & svn update $remote.Path 2>$null | Out-Null } catch { }
        }
        Write-Output "Already up to date at SVN r$cur"
        exit 0
    }

    # Granularity gate (KTD7 / R2-R4). <=5 new revisions replay per-revision silently. >5 with no
    # explicit choice -> emit a structured signal and exit 0 (NO commits, residue-free) so the SKILL
    # can prompt; distinct from the merge-conflict path which exits 1.
    $mode = 'per-revision'
    if ($count -gt $TpGranularityThreshold) {
        if ([string]::IsNullOrWhiteSpace($Granularity)) {
            Write-Output "TP_TOKEN:GRANULARITY_REQUIRED count=$count range=r$($cur + 1):r$headRev"
            exit 0
        }
        $mode = $Granularity
    }

    # Materialise the chosen granularity via the shared enumerate+replay dispatch (lib/Common.ps1),
    # the same body the first-import bootstrap (Initialize-GitSvnBridge) uses.
    Invoke-SvnReplayDispatch -RemotePath $remote.Path -RemoteName $remote.Name -Cur $cur -HeadRev $headRev -Mode $mode -Range $Range

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
