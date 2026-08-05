[CmdletBinding()]
param(
    [string]$Branch = '',
    # U9: the agent supplies ONLY the title. The body is read from the pin file written by
    # Build-SvnCommit (body-from-file) and combined here — the agent cannot pass a free message.
    [string]$Title = '',
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Pre-initialized so the finally restore is safe even if an early statement (e.g. Probe-GitVersion)
# throws before the OutputEncoding swap below — referencing an unset var under StrictMode would
# otherwise throw inside finally and mask the original error.
$tpPrevConsoleEnc = $null

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'Missing required argument: -Branch <branch>' }
    if ([string]::IsNullOrWhiteSpace($Title)) { throw 'Missing required argument: -Title <title>' }

    # Encoding fix (zh-TW / non-ASCII filenames): plain `svn status` prints filenames in the
    # system ANSI codepage (CP_ACP, e.g. Big5), and — critically — PowerShell encodes native-
    # command ARGV using [Console]::OutputEncoding too. So we set OutputEncoding to the system
    # ANSI codepage for the whole svn-interacting region: `svn status` output decodes correctly
    # AND paths passed back to `svn add/delete/commit` are argv-encoded as ANSI, matching the
    # on-disk filenames. (NOTE: do NOT use `svn status --xml` here — its UTF-8 output would need
    # OutputEncoding=UTF8 to decode, which then mis-encodes the ANSI argv. Submit has no Chinese
    # git stdout to capture, so a single ANSI scope is safe. Restored in finally.)
    $tpPrevConsoleEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path rev-parse --verify -q MERGE_HEAD 2>$null | Out-Null
    $hasMergeHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if (-not $hasMergeHead) {
        throw "No pending merge in remote worktree '$($remote.Name)'. Run /tp-push-to-svn (which calls push-to-svn-prepare first) instead of invoking this script directly."
    }

    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'." }
    # Staleness is measured against the last revision that touched THIS branch path, never against
    # the repository HEAD -- the same rule Build-SvnCommit states at length and follows. This end
    # had the older repository-HEAD version, so only half the fix was ever applied, and it showed:
    # in a repository holding several projects, `setup` commits under sibling paths bumped HEAD and
    # this guard refused the push with "SVN HEAD changed since prepare (local r85, head r87)" while
    # r86/r87 had not touched a single byte of ours. It then sent the user to /tp-pull-from-svn,
    # which correctly found nothing to replay for this path and answered "Already up to date at SVN
    # r85" -- the two commands contradicting each other with no way forward but a manual svn update.
    #
    # Cast to [int] and compare with `-lt`, not `-ne` on strings: the working copy legitimately sits
    # ABOVE the path's last-changed-revision (a sibling path moved HEAD on), and '9' sorts after
    # '10' as a string.
    $localRev = [int]((& svn info --show-item revision $remote.Path | Out-String).Trim())
    $pathRev = [int]((& svn info --show-item last-changed-revision $svnUrl | Out-String).Trim())
    if ($localRev -lt $pathRev) {
        throw "This SVN path changed since prepare (local r$localRev, this path last changed at r$pathRev). Abort the merge with 'git -C $($remote.Path) merge --abort', then run '/tp-pull-from-svn --branch $Branch'."
    }

    # Verify no new commits were added to the branch since prepare (SHA pinning check).
    # NOTE: in a linked worktree, .git is a pointer FILE; resolve via `git rev-parse --absolute-git-dir`.
    $shaGitDir = (& git -C $remote.Path rev-parse --absolute-git-dir | Out-String).Trim()
    $shaFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_branch_sha'
    if (-not (Test-Path -LiteralPath $shaFile -PathType Leaf)) {
        # F-U(synth #18): fail-closed when MERGE_HEAD exists but the SHA pin file is missing.
        # That state means prepare didn't stage with current locking (older logic, manual MERGE_HEAD,
        # or hand-edit). Refuse to commit silently against the latest HEAD — require re-staging.
        throw "SHA pin file missing while merge state exists. Abort the merge with 'git -C $($remote.Path) merge --abort' and rerun /tp-push-to-svn to (re-)stage the merge with current locking."
    }
    $pinnedSha = (Get-Content -LiteralPath $shaFile -Raw).Trim()
    $currentSha = (& git -C $mainWorktree rev-parse $Branch | Out-String).Trim()
    if ($pinnedSha -ne $currentSha) {
        $pinShort = if ($pinnedSha.Length -ge 8) { $pinnedSha.Substring(0, 8) } else { $pinnedSha }
        $curShort = if ($currentSha.Length -ge 8) { $currentSha.Substring(0, 8) } else { $currentSha }
        throw "Branch '$Branch' has new commits since prepare (pinned: $pinShort, current: $curShort). Abort the merge with 'git -C $($remote.Path) merge --abort' and rerun /tp-push-to-svn to include new commits."
    }

    # F12: verify svn status drift — remote worktree must not have gained new files since prepare.
    $svnStatusFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_svn_status'
    if (-not (Test-Path -LiteralPath $svnStatusFile -PathType Leaf)) {
        # Fail-closed: if the svn status pin is missing while MERGE_HEAD exists, the prepare
        # step was not run with drift detection (older logic). Require re-staging.
        throw "svn-status pin file missing while merge state exists. Abort the merge with 'git -C $($remote.Path) merge --abort' and rerun /tp-push-to-svn to (re-)stage."
    }
    $snapshotLines = @((Get-Content -LiteralPath $svnStatusFile -Encoding UTF8) | Where-Object { $_ -match '\S' })
    $currentSvnLines = @((& svn status $remote.Path) | Where-Object { $_ -match '\S' })
    $snapshotPaths = @{}
    foreach ($line in $snapshotLines) {
        if ($line -match '^.\s+(.+)$') { $snapshotPaths[$Matches[1].Trim()] = $true }
    }
    $driftedFiles = @()
    foreach ($line in $currentSvnLines) {
        if ($line -match '^.\s+(.+)$') {
            $path = $Matches[1].Trim()
            if (-not $snapshotPaths.ContainsKey($path)) {
                $driftedFiles += $path
            }
        }
    }
    if ($driftedFiles.Count -gt 0) {
        $driftList = $driftedFiles -join ', '
        throw "Remote worktree changed since prepare — file(s) appeared: $driftList. Abort the merge with 'git -C $($remote.Path) merge --abort' and rerun /tp-push-to-svn to recompute."
    }

    # U9: assemble the final SVN message = agent title + LOCKED body-from-file. Read the body
    # pin (UTF-8, no BOM) written by Build-SvnCommit; fail closed if missing (same posture as the
    # SHA / svn-status pins — a missing body pin means prepare wasn't run with current locking).
    $bodyFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_svn_body'
    if (-not (Test-Path -LiteralPath $bodyFile -PathType Leaf)) {
        throw "SVN body pin file missing while merge state exists. Abort the merge with 'git -C $($remote.Path) merge --abort' and rerun /tp-push-to-svn to (re-)stage."
    }
    # ReadAllText(UTF8) — Get-Content can mis-decode UTF-8 as Big5 on zh-TW (CLAUDE.md).
    $svnBody = [System.IO.File]::ReadAllText($bodyFile, [System.Text.Encoding]::UTF8)
    # Collapse the title to a single line so the agent cannot smuggle extra body content via
    # embedded newlines ('\n' would otherwise bypass the body lock).
    $titleLine = ($Title -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($titleLine)) { throw 'Title is empty after removing line breaks.' }
    $fullMessage = "$titleLine`n$svnBody"

    # U4/KTD5: decide whether this push ADVANCES tp:last-aligned-rev (see submit-svn-commit.sh for
    # the full rationale). $tpNewAligned = the highest svn-revision trailer REACHABLE FROM THE BRANCH
    # (not main's tip, so a branch that merged an older main never over-advances). Advance only when
    # it exceeds a PRE-EXISTING stored alignment -- that excludes a main/trunk push (bridge has no tp
    # props) and any pre-U4 bridge. Folded into the content commit below; idempotent (no-op unchanged).
    # Trailer values are ASCII digits, so the ANSI OutputEncoding region does not affect the scan.
    $tpCurAligned = Get-TpBranchProp -Name 'last-aligned-rev' -Target $remote.Path
    # Greatest marked trunk revision reachable from the branch (refs/tp/svn/<N>). Because a `main`
    # push now marks the revision it created, a branch that merged main sees it here -- which the
    # trailer scan could not do (trailers existed only for PULLED revisions, so a repo that pushed
    # trunk itself never advanced its branches' alignment). 0 when the branch reaches no marker.
    $tpNewAligned = Get-SvnMaxRevReachable -RepoDir $mainWorktree -Ref $Branch
    $tpAdvance = $false
    if (-not [string]::IsNullOrWhiteSpace($tpCurAligned) -and $tpNewAligned -gt [int]$tpCurAligned) {
        $tpAdvance = $true
    }

    Write-Output "Finalising merge commit..."
    & git -C $remote.Path commit --no-edit
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed when finalising the prepared merge."
    }

    $newRev = '?'
    $noCommit = $false
    # UTF-8 (no BOM) message file: critical to keep Big5/CP_ACP from mangling non-ASCII.
    $msgFile = [System.IO.Path]::GetTempFileName()
    Push-Location $remote.Path
    try {
        Write-Utf8NoBom -Path $msgFile -Content $fullMessage

        $svnStatusLines = & svn status
        $toAdd = @()
        $toDel = @()
        $modifiedToCommit = @()

        foreach ($line in $svnStatusLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if (-not ($line -match '^([?!M])\s+(.+)$')) { continue }
            $statusChar = $Matches[1]
            $filePath   = $Matches[2].Trim()

            $eaCheckIgnore = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            & git -C $remote.Path check-ignore -q $filePath 2>$null | Out-Null
            $checkIgnoreExit = $LASTEXITCODE
            $ErrorActionPreference = $eaCheckIgnore
            if ($checkIgnoreExit -eq 0) {
                Write-Output "Skipping git-ignored ($statusChar): $filePath"
                continue
            }

            # ConvertTo-SvnTarget: append the peg-revision escape. A filename containing '@' is legal
            # in SVN and checks out fine, but passing it as a TARGET makes svn read everything after
            # the last '@' as a revision (issue #34). Escaped here at collection time so every
            # downstream svn call gets it.
            switch ($statusChar) {
                '?' { $toAdd += (ConvertTo-SvnTarget -Path $filePath) }
                '!' { $toDel += (ConvertTo-SvnTarget -Path $filePath) }
                'M' { $modifiedToCommit += (ConvertTo-SvnTarget -Path $filePath) }
            }
        }

        # `--` terminates option parsing so a filename beginning with '-' is never read as a flag.
        # It does NOT cover peg revisions -- that is what ConvertTo-SvnTarget above is for.
        if ($toAdd.Count -gt 0) {
            Write-Output "SVN adding $($toAdd.Count) new file(s)..."
            & svn add --parents -- $toAdd
            if ($LASTEXITCODE -ne 0) { throw 'svn add failed' }
        }
        if ($toDel.Count -gt 0) {
            Write-Output "SVN deleting $($toDel.Count) removed file(s)..."
            & svn delete -- $toDel
            if ($LASTEXITCODE -ne 0) { throw 'svn delete failed' }
        }

        $commitTargets = @()
        foreach ($line in (& svn status)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^([AD])\s+(.+)$') { $commitTargets += (ConvertTo-SvnTarget -Path $Matches[2].Trim()) }
        }
        $commitTargets += $modifiedToCommit

        if ($commitTargets.Count -eq 0) {
            Write-Output "No changes to commit to SVN (all pending changes are git-ignored)"
            $noCommit = $true
        } else {
            # U4/KTD5: fold the tp:last-aligned-rev advance into THIS content commit. Set the property
            # on the branch root and add '.' as a --depth empty target so ONLY its property rides along
            # (no recursion, no separate property revision). Explicit file targets still commit under
            # --depth empty (proven by new-remote-bridge.sh's svn:ignore + '.git' commit). An ordinary
            # feature push ($tpAdvance = $false) leaves the commit byte-identical -- no '.', no --depth.
            $depthArgs = @()
            if ($tpAdvance) {
                & svn propset tp:last-aligned-rev $tpNewAligned '.'
                if ($LASTEXITCODE -ne 0) { throw 'svn propset tp:last-aligned-rev failed' }
                $commitTargets += '.'
                $depthArgs = @('--depth', 'empty')
            }
            Write-Output "Committing to SVN..."
            $commitLines = & svn commit @depthArgs --file $msgFile --encoding UTF-8 -- $commitTargets
            if ($LASTEXITCODE -ne 0) {
                # A failed svn commit leaves a half-finished state that nothing else reports: the
                # merge commit was already made above, the adds/deletes are still SCHEDULED in the
                # bridge working copy, and the pins are deliberately kept so a retry need not redo
                # the merge. Previously the script said none of this and the user was left to
                # reverse-engineer it (issue #34).
                #
                # No automatic rollback: whether to retry or unwind depends on WHY svn refused, and
                # the script cannot tell. A transient failure (network, lock, credentials) should be
                # retried -- unwinding would throw away a correct merge. A rejected commit needs
                # unwinding -- retrying just fails again. So state the position and give both exits.
                $mergeSha = ''
                try { $mergeSha = (& git -C $remote.Path rev-parse --verify -q HEAD 2>$null | Out-String).Trim() } catch { $mergeSha = '' }
                if ([string]::IsNullOrWhiteSpace($mergeSha)) { $mergeSha = '<merge-sha>' }
                $pinDir = ''
                try { $pinDir = (& git -C $remote.Path rev-parse --absolute-git-dir 2>$null | Out-String).Trim() } catch { $pinDir = '' }
                [Console]::Error.WriteLine(@"

TP_TOKEN:SVN_COMMIT_FAILED_HALF_DONE
The SVN commit failed. Nothing reached SVN (an svn commit is atomic), but locally:
  - the merge commit has already been made on the bridge branch
  - the add/delete are still scheduled in the bridge working copy
  - the prepare pins are kept, so a retry does not have to redo the merge

RETRY (transient cause -- network, lock, credentials): fix the cause, re-run /tp-push-to-svn.
UNWIND (the commit was rejected and would be rejected again):
  1. svn revert -R "$($remote.Path)"
  2. git -C "$($remote.Path)" reset --hard $mergeSha^1
  3. remove the three MERGE_HEAD.tp_* files in "$pinDir"
  ORDER MATTERS: revert BEFORE reset. The other way round deletes the files from disk while
  svn still has them scheduled, which is harder to clean up than the state you are in now.
"@)
                throw 'svn commit failed'
            }
            $commitLines | ForEach-Object { Write-Output $_ }
            $newRevLine = $commitLines | Where-Object { $_ -match 'Committed revision (\d+)\.' } | Select-Object -Last 1
            if ($newRevLine -and $newRevLine -match 'Committed revision (\d+)\.') {
                $newRev = $Matches[1]
            }
            # R14 marker for a TRUNK push: this push CREATED revision $newRev, and the commit whose
            # tree is that revision is the branch tip just pushed. Recording it is what makes a
            # locally PUSHED revision resolvable -- pulls mark what they replay, pushes mark what
            # they create. Only the trunk branch is marked (refs/tp/svn/* maps TRUNK revisions; a
            # feature push creates a revision on the branch path, not on trunk).
            if ($Branch -eq 'main' -and $newRev -match '^[0-9]+$') {
                $pushedSha = (& git -C $mainWorktree rev-parse $Branch 2>$null | Out-String).Trim()
                if (-not [string]::IsNullOrWhiteSpace($pushedSha)) {
                    Set-SvnRevMark -RepoDir $mainWorktree -Rev ([int]$newRev) -Sha $pushedSha
                }
            }
        }
        # svn update is a post-commit resync; the SVN commit already succeeded above. Soften EAP so a
        # native-exe stderr write does NOT throw NativeCommandError under Set-StrictMode/EAP=Stop --
        # that throw would skip the pin cleanup below and falsely report the successful commit as
        # failed (exit 1), stranding the merge pins and wedging the next push on PENDING_MERGE.
        # Matches submit-svn-commit.sh, which runs `svn update` with `|| warn` outside `set -e`.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & svn update 2>$null | Out-Null
        $svnUpdateExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        if ($svnUpdateExit -ne 0) {
            [Console]::Error.WriteLine('Warning: svn update after commit failed. Remote worktree may be stale; run /tp-pull-from-svn to resync.')
        }
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $msgFile) {
            Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        }
    }

    # SHA pin + svn-status pin cleanup runs on every success path (committed AND no-commit-needed).
    # Failure path skips this and retains the pins for retry (pins are checked at top).
    # NOTE: in a linked worktree, .git is a pointer FILE; resolve via `git rev-parse --absolute-git-dir`.
    try {
        $shaGitDir = (& git -C $remote.Path rev-parse --absolute-git-dir | Out-String).Trim()
        $shaFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_branch_sha'
        if (Test-Path -LiteralPath $shaFile) {
            Remove-Item -LiteralPath $shaFile -Force -ErrorAction SilentlyContinue
        }
        $svnStatusFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_svn_status'
        if (Test-Path -LiteralPath $svnStatusFile) {
            Remove-Item -LiteralPath $svnStatusFile -Force -ErrorAction SilentlyContinue
        }
        $bodyFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_svn_body'
        if (Test-Path -LiteralPath $bodyFile) {
            Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Best-effort cleanup; don't fail the script on cleanup error.
    }

    if ($noCommit) { exit 0 }
    Write-Output "Pushed to SVN r$newRev"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne $tpPrevConsoleEnc) { [Console]::OutputEncoding = $tpPrevConsoleEnc }
}
