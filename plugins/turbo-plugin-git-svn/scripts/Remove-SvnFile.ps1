[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Remove a single path from the SVN side of a bridge, for tp-suggest-ignore's "un-track from SVN"
# paths. ONE script serves both cases, chosen by a PRE-FLIGHT classification (before any svn delete):
#
#   * git-TRACKED on the bridge (Un-track Option A: the file is in remote-svn/<branch>'s tree)
#       -> svn delete + svn commit leaves the bridge git tree dirty (a ` D` deletion), so we
#          RECONCILE: `git add -A` + a canonical `sync: svn r<rev>` commit + a `--no-ff` merge into
#          <branch>. The commit + merge formats MIRROR Sync-FromSvn EXACTLY, so remote-svn/<branch>
#          only ever carries `sync:` and merge commits (indistinguishable from a /tp-pull-from-svn).
#
#   * git-UNTRACKED / git-IGNORED (Inconsistency Option B: the file is NOT in the bridge git tree)
#       -> svn delete + svn commit leaves the bridge git tree clean (the deleted file was ignored,
#          and .svn/ is git-ignored too), so NO reconcile is needed. We verify the bridge stayed
#          clean and stop.
#
# We do NOT delegate to /tp-push-to-svn: push refuses to start on an unignored-but-untracked file
# (its main-clean gate) and skips git-ignored files (its check-ignore filter), so neither Un-track
# ordering can drive push. A direct svn delete sidesteps both.

$tpPrevConsoleEnc = $null
try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch = 'main' }
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Missing required argument: -Path <bridge-relative path>' }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    $remoteBranch = $remote.Branch
    $remoteName   = $remote.Name
    $remotePath   = $remote.Path
    if (-not (Test-Path -LiteralPath $remotePath -PathType Container)) {
        throw "Remote worktree '$remoteName' not found at: $remotePath. Run /tp-setup to bootstrap the bridge."
    }

    # ---- pre-flight (ALL checks + classification BEFORE any svn delete) ----

    # The bridge must be clean before we mutate it: a dirty bridge means uncommitted state that a
    # later `git add -A` (reconcile path) would wrongly package into the sync commit.
    $bridgeStatus = (& git -C $remotePath status --porcelain | Out-String).Trim()
    if ($bridgeStatus) {
        throw "Remote worktree '$remotePath' has uncommitted changes; resolve before removing a path.`n$bridgeStatus"
    }

    # The target must exist on disk in the bridge.
    $targetFull = [System.IO.Path]::Combine($remotePath, $Path)
    if (-not (Test-Path -LiteralPath $targetFull)) {
        throw "Path not found in bridge worktree: '$Path' (looked under $remotePath)."
    }

    # Classify git-tracked vs not, on the bridge -- this is what decides reconcile vs no-reconcile.
    # EAP-safe: soften before the 2>$null redirect so a stderr write cannot throw.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remotePath ls-files --error-unmatch -- $Path 2>$null | Out-Null
    $gitTracked = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP

    # ---- ANSI OutputEncoding region for svn (aligns non-ASCII path argv with on-disk names;
    # matches Submit-SvnCommit.ps1). git messages here are ASCII, so a single region is safe. ----
    $tpPrevConsoleEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)

    $svnRev = ''
    Push-Location $remotePath
    try {
        # svn-tracked check + local-modification (M) detection. `svn status <path>` prints nothing
        # for a clean tracked file, `?` for unversioned, `M` when locally modified.
        $svnStat = (& svn status -- $Path | Out-String)
        $svnStatFirst = ''
        foreach ($ln in ($svnStat -split "`n")) {
            if ($ln.Trim().Length -gt 0) { $svnStatFirst = $ln.Substring(0, 1); break }
        }
        if ($svnStatFirst -eq '?') {
            throw "Path '$Path' is not tracked by SVN (svn status '?'); there is nothing to delete from SVN. Use tp-suggest-ignore's git-only option instead."
        }
        $useForce = ($svnStatFirst -eq 'M')

        # svn delete (+ --force when locally modified) then commit via a UTF-8 no-BOM message file
        # (never `svn commit -m` -- CP_ACP would mangle a non-ASCII path/message).
        if ($useForce) { & svn delete --force -- $Path } else { & svn delete -- $Path }
        if ($LASTEXITCODE -ne 0) { throw "svn delete failed for: $Path" }

        $msgFile = [System.IO.Path]::GetTempFileName()
        try {
            Write-Utf8NoBom -Path $msgFile -Content "remove $Path from svn (turbo-plugin)"
            & svn commit --file $msgFile --encoding UTF-8 -- $Path
            if ($LASTEXITCODE -ne 0) { throw "svn commit (delete) failed for: $Path" }
        } finally {
            if (Test-Path -LiteralPath $msgFile) { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
        }

        # post-commit resync + read the new revision (EAP-soften: svn update is a resync, its stderr
        # must not throw and falsely report the successful commit as failed).
        $eaU = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & svn update 2>$null | Out-Null
        $ErrorActionPreference = $eaU
        $svnRev = (& svn info --show-item revision | Out-String).Trim()
    } finally {
        Pop-Location
    }

    # Restore console encoding before the git reconcile region.
    [Console]::OutputEncoding = $tpPrevConsoleEnc
    $tpPrevConsoleEnc = $null

    if ($gitTracked) {
        # ---- reconcile (Un-track A): record the deletion on remote-svn/<branch>, then merge into
        # <branch>. Commit + merge formats MIRROR Sync-FromSvn exactly (user invariant). ----
        & git -C $remotePath add -A
        if ($LASTEXITCODE -ne 0) { throw 'git add -A failed in bridge worktree' }
        & git -C $remotePath commit -m "sync: svn r$svnRev"
        if ($LASTEXITCODE -ne 0) { throw 'git commit (sync) failed in bridge worktree' }

        $mainStatus = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
        if ($mainStatus) {
            throw "Main worktree has uncommitted changes; cannot merge the SVN removal into '$Branch'. Commit or stash first.`n$mainStatus"
        }

        $originalBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD | Out-String).Trim()
        $switched = $false
        if ($originalBranch -ne $Branch) {
            & git -C $mainWorktree checkout $Branch
            if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
            $switched = $true
        }

        & git -C $mainWorktree merge $remoteBranch --no-ff -m "Merge branch '$remoteBranch' into $Branch"
        $mergeExit = $LASTEXITCODE
        if ($mergeExit -ne 0) {
            $conflicts = (& git -C $mainWorktree diff --name-only --diff-filter=U | Out-String).Trim()
            & git -C $mainWorktree merge --abort 2>$null | Out-Null
            $abortStatus = $LASTEXITCODE
            $checkoutStatus = 0
            if ($switched) {
                & git -C $mainWorktree checkout $originalBranch 2>$null | Out-Null
                $checkoutStatus = $LASTEXITCODE
            }
            if ($abortStatus -ne 0 -or $checkoutStatus -ne 0) {
                throw "Merge conflict; automatic rollback failed (abort exit=$abortStatus, checkout exit=$checkoutStatus). Working tree is in an inconsistent state. Resolve manually before re-running."
            }
            throw "Merge conflict merging '$remoteBranch' into '$Branch' (unexpected for a deletion). The merge has been aborted and '$originalBranch' restored. Conflicting files:`n$conflicts"
        }

        if ($switched) {
            & git -C $mainWorktree checkout $originalBranch
            if ($LASTEXITCODE -ne 0) { throw "Could not switch back to '$originalBranch'" }
        }

        Write-Output "Removed '$Path' from SVN (r$svnRev) and reconciled the bridge into '$Branch'."
    } else {
        # ---- no-reconcile (Inconsistency B: file was git-ignored): the bridge git tree is unchanged.
        # Verify that, and fail loudly if not (would mean the path was actually git-tracked). ----
        $postStatus = (& git -C $remotePath status --porcelain | Out-String).Trim()
        if ($postStatus) {
            throw "Unexpected bridge changes after removing a git-ignored path ('$Path'); the path may actually be git-tracked. Investigate before proceeding.`n$postStatus"
        }
        Write-Output "Removed git-ignored '$Path' from SVN (r$svnRev); bridge git tree unchanged."
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne $tpPrevConsoleEnc) { [Console]::OutputEncoding = $tpPrevConsoleEnc }
}
