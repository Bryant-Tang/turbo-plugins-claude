[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [string]$Path = '',
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
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

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
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

    # Contain the path BEFORE anything irreversible. Everything below this point leads to
    # `svn delete` + `svn commit` against the SHARED repository, so a path that escapes the bridge
    # worktree must stop here, not be discovered afterwards.
    $targetFull = Resolve-PathWithinWorktree -Root $remotePath -RelativePath $Path

    # The target must exist on disk in the bridge.
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

    # Reconcile-path pre-flight (still BEFORE any svn delete). The reconcile branch commits a
    # `sync:` on remote-svn/<branch> and merges it into <branch>; these must be verified up front,
    # because `svn delete`+`svn commit` are irreversible and a failure AFTER them would leave the
    # SVN copy gone plus an orphaned sync commit on the bridge.
    if ($gitTracked) {
        # main worktree must be clean for the merge (mirror Sync-FromSvn.ps1:27-30).
        $mainStatusPre = (& git -C $mainWorktree status --porcelain | Out-String).Trim()
        if ($mainStatusPre) {
            throw "Main worktree has uncommitted changes; cannot merge the SVN removal into '$Branch'. Commit or stash first (nothing has been changed).`n$mainStatusPre"
        }
        # remote-svn/<branch> must not carry an ORPHANED sync commit -- a `sync: svn r<N>` (non-merge)
        # left ahead of <branch> by an interrupted pull/removal, which the reconcile merge would drag in.
        # `--no-merges` is load-bearing: a normal push leaves a benign `Merge branch '<branch>' into
        # remote-svn/<branch>` MERGE commit ahead of <branch> (content already in <branch>); that steady
        # state must NOT trip this guard. Only a non-merge sync is a genuine orphan. (mirror Sync-FromSvn.ps1.)
        $unmerged = (& git -C $mainWorktree log --oneline --no-merges "$Branch..$remoteBranch" | Out-String).Trim()
        if ($unmerged) {
            throw "remote-svn/$Branch has unmerged sync commit(s) ahead of '$Branch'; resolve first (run /tp-pull-from-svn, or 'git -C $mainWorktree merge $remoteBranch'), then retry. Nothing has been changed.`n$unmerged"
        }
        # Data-safety: the caller (Un-track A) must have `git rm --cached` the path on <branch> FIRST
        # so the file stays on disk. If <branch> still tracks it, the reconcile merge would DELETE the
        # local copy -- refuse rather than lose the file the user asked to keep.
        $prevEAP2 = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & git -C $mainWorktree ls-files --error-unmatch -- $Path 2>$null | Out-Null
        $mainTracks = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevEAP2
        if ($mainTracks) {
            throw "Path '$Path' is still git-tracked in the main worktree on '$Branch'. Run 'git rm --cached -- $Path' + commit first (keeps the local file); refusing so the reconcile merge does not delete it."
        }
    }

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
        if ($LASTEXITCODE -ne 0) { throw "svn status failed for: $Path" }
        $svnStatFirst = ''
        foreach ($ln in ($svnStat -split "`n")) {
            if ($ln.Trim().Length -gt 0) { $svnStatFirst = $ln.Substring(0, 1); break }
        }
        if ($svnStatFirst -eq '?') {
            throw "Path '$Path' is not tracked by SVN (svn status '?'); there is nothing to delete from SVN. Use tp-suggest-ignore's git-only option instead."
        }
        $useForce = ($svnStatFirst -eq 'M')

        # svn delete (+ --force when locally modified) then commit via a UTF-8 no-BOM message file
        # (never `svn commit -m` -- CP_ACP would mangle a non-ASCII path/message). If delete or commit
        # fails, `svn revert` the path so the bridge working copy is left CLEAN -- otherwise a dangling
        # scheduled deletion wedges the next /tp-pull-from-svn and re-runs of this script.
        $msgFile = [System.IO.Path]::GetTempFileName()
        # A filename containing '@' is legal in SVN, but passing it as a TARGET makes svn read
        # everything after the last '@' as a peg revision and fail with E200009 (issue #34). `--`
        # does not cover this -- it only terminates option parsing. Messages keep the RAW path.
        $svnTarget = ConvertTo-SvnTarget -Path $Path
        try {
            if ($useForce) { & svn delete --force -- $svnTarget } else { & svn delete -- $svnTarget }
            if ($LASTEXITCODE -ne 0) { throw "svn delete failed for: $Path" }
            Write-Utf8NoBom -Path $msgFile -Content "remove $Path from svn (turbo-plugin)"
            # EAP-soften the commit so a native stderr write does not throw before we can revert.
            $eaCommit = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & svn commit --file $msgFile --encoding UTF-8 -- $svnTarget
            $commitRc = $LASTEXITCODE
            $ErrorActionPreference = $eaCommit
            if ($commitRc -ne 0) { throw "svn commit (delete) failed for: $Path" }
        } catch {
            $eaRevert = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            & svn revert -- $svnTarget 2>$null | Out-Null
            $ErrorActionPreference = $eaRevert
            throw
        } finally {
            # .NET, not Remove-Item: -LiteralPath mangles a temp path whose user-profile segment is
            # an 8.3 short alias, and -ErrorAction cannot suppress it. See Submit-SvnCommit.ps1.
            if (Test-Path -LiteralPath $msgFile) { try { [System.IO.File]::Delete($msgFile) } catch { } }
        }

        # post-commit resync + read the new revision (EAP-soften: svn update is a resync, its stderr
        # must not throw and falsely report the successful commit as failed).
        $eaU = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & svn update 2>$null | Out-Null
        $svnUpdateRc = $LASTEXITCODE
        $ErrorActionPreference = $eaU
        if ($svnUpdateRc -ne 0) {
            [Console]::Error.WriteLine('Warning: svn update after commit failed. Remote worktree may be stale; run /tp-pull-from-svn to resync.')
        }
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

        # (main-clean / unmerged-sync / main-untracks-path were all verified in pre-flight, before
        # the irreversible svn delete, so the merge below is known-safe here.)
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
            # Read-Git, not `& git ... 2>$null | Out-Null`: under EAP=Stop a `2>` redirection makes
            # any stderr output a terminating error, so on a machine where git warns (dubious
            # ownership) the throw would land here and skip the whole rollback -- see the same
            # block in Sync-FromSvn.ps1 for the full account (issue #128).
            $abortStatus = (Read-Git -Cwd $mainWorktree -GitArgs @('merge', '--abort')).Code
            $checkoutStatus = 0
            if ($switched) {
                $checkoutStatus = (Read-Git -Cwd $mainWorktree -GitArgs @('checkout', $originalBranch)).Code
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
