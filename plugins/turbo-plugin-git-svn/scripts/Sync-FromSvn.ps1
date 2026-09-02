[CmdletBinding()]
param(
    [string]$Branch = '',
    [string]$Granularity = '',
    [string]$Range = '',
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
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

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
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
    # A bridge whose SVN path (or any parent folder) was renamed AFTER the bridge was built points at
    # a path that no longer exists, and svn's own error names that old path -- which the user never
    # typed and will not recognise. There is no way to discover the new name from here: svn follows
    # copy history backwards from an existing path, not forwards from a deleted one (issue #32). So
    # the only honest thing to do is say precisely that.
    # `2>$null` under EAP=Stop, left inline on purpose (issue #137). The worry was that a WARNING on
    # an otherwise healthy call would throw here and produce the message below -- which asserts the
    # SVN path is gone -- while SVN was in fact perfectly readable. Measured: with the
    # --non-interactive shim in lib/Common.ps1 svn has no such warning-on-success path for `svn
    # info`, so a throw here really does mean SVN could not be read, and the message is true.
    $headRevRaw = ''
    try {
        $headRevRaw = (& svn info --show-item revision $svnUrl 2>$null | Out-String).Trim()
    } catch {
        $headRevRaw = ''
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headRevRaw)) {
        throw @"
Cannot read SVN at the path this bridge is attached to:
  $svnUrl
  Either SVN is unreachable, or that path (or one of its parent folders) was renamed or removed on SVN.
  If it was renamed, re-run /tp-setup against the current URL -- a bridge cannot find its own new name.
"@
    }
    $headRev = [int]$headRevRaw
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
        # Pegged URL, not the WC: same reason as Invoke-SvnReplayDispatch's enumeration (issue #32)
        # -- a WC sitting at an older revision is bound to the path name of that revision.
        $logXml = (& svn log --xml -r "$($cur + 1):$headRev" "$svnUrl@$headRev" | Out-String)
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
        # The empty catch is doing real work here, not hiding a bug (issue #137): under EAP=Stop the
        # `2>` redirection makes any stderr write terminating, and `svn update` can legitimately
        # write one -- e.g. `W205011: Error handling externals definition`, which is a warning about
        # an external while the main tree updates fine. Swallowing it matches the paragraph above:
        # this catch-up is best-effort. Measured with the --non-interactive shim: an ordinary update,
        # a tree conflict, a locally missing file and a clean local modification all exit 0 with
        # empty stderr, so the common paths do not throw at all.
        if ($wcRevStart -lt $headRev) {
            try { & svn update $remote.Path 2>$null | Out-Null } catch { }
        }
        Write-Output "Already up to date at SVN r$cur"
        exit 0
    }

    # Granularity gate (KTD7 / R2-R4). <=5 new revisions replay per-revision silently. >5 with no
    # explicit choice -> emit a structured signal and exit 0 (NO commits, residue-free) so the SKILL
    # can prompt; distinct from the merge-conflict path which exits 1.
    # The threshold decides whether to ASK, never whether to HONOUR the answer: an explicitly passed
    # -Granularity is used at any count. (Same fix as the bootstrap side; previously a caller's
    # explicit choice was silently discarded whenever the count sat at or below the threshold.)
    $mode = 'per-revision'
    if (-not [string]::IsNullOrWhiteSpace($Granularity)) {
        $mode = $Granularity
    }
    elseif ($count -gt $TpGranularityThreshold) {
        Write-Output "TP_TOKEN:GRANULARITY_REQUIRED count=$count range=r$($cur + 1):r$headRev"
        exit 0
    }

    # Materialise the chosen granularity via the shared enumerate+replay dispatch (lib/Common.ps1),
    # the same body the first-import bootstrap (Initialize-GitSvnBridge) uses.
    Invoke-SvnReplayDispatch -RemotePath $remote.Path -RemoteName $remote.Name -Cur $cur -HeadRev $headRev -Mode $mode -Range $Range -BaseUrl $svnUrl

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
        $conflicts = (& git -C $mainWorktree -c core.quotePath=false diff --name-only --diff-filter=U | Out-String).Trim()
        # Rollback: abort the merge and return to original branch so the worktree is clean.
        # Capture each rollback op's exit code separately so we can detect rollback failure
        # and emit a distinct error (working tree may be in an inconsistent state).
        #
        # Through Read-Git, NOT `& git ... 2>$null | Out-Null` (issue #128). Under
        # $ErrorActionPreference = 'Stop', a `2>` redirection on a native command turns anything the
        # command writes to stderr into a TERMINATING error -- measured, and `2>$null` does not
        # prevent it. git warns on a healthy repo whose owner differs from the caller (CI images,
        # containers, a clone made under another account), so on those machines the throw would
        # happen HERE: the merge is never aborted, the exit-code guard below is unreachable, and the
        # conflicted worktree is left exactly as it was -- the one thing this block promises never
        # to do. Reproduced on Request-Merge.ps1 in #127.
        $abortStatus = (Read-Git -Cwd $mainWorktree -GitArgs @('merge', '--abort')).Code
        $checkoutStatus = 0
        if ($switched) {
            $checkoutStatus = (Read-Git -Cwd $mainWorktree -GitArgs @('checkout', $originalBranch)).Code
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
