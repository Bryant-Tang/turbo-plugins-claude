[CmdletBinding()]
param(
    [string]$Branch = '',
    # U9: the agent supplies ONLY the title. The body is read from the pin file written by
    # Build-SvnCommit (body-from-file) and combined here — the agent cannot pass a free message.
    [string]$Title = ''
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

    $mainWorktree = Get-MainWorktree
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
    $localRev = (& svn info --show-item revision $remote.Path | Out-String).Trim()
    $headRev = (& svn info --show-item revision $svnUrl | Out-String).Trim()
    if ($localRev -ne $headRev) {
        throw "SVN HEAD changed since prepare (local r$localRev, head r$headRev). Abort the merge with 'git -C $($remote.Path) merge --abort', then run '/tp-pull-from-svn --branch $Branch'."
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
    $fullMessage = "$titleLine`n`n$svnBody"

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

            switch ($statusChar) {
                '?' { $toAdd += $filePath }
                '!' { $toDel += $filePath }
                'M' { $modifiedToCommit += $filePath }
            }
        }

        # `--` terminates option parsing so a filename beginning with '-' is never read as a flag.
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
            if ($line -match '^([AD])\s+(.+)$') { $commitTargets += $Matches[2].Trim() }
        }
        $commitTargets += $modifiedToCommit

        if ($commitTargets.Count -eq 0) {
            Write-Output "No changes to commit to SVN (all pending changes are git-ignored)"
            $noCommit = $true
        } else {
            Write-Output "Committing to SVN..."
            $commitLines = & svn commit --file $msgFile --encoding UTF-8 -- $commitTargets
            if ($LASTEXITCODE -ne 0) { throw 'svn commit failed' }
            $commitLines | ForEach-Object { Write-Output $_ }
            $newRevLine = $commitLines | Where-Object { $_ -match 'Committed revision (\d+)\.' } | Select-Object -Last 1
            if ($newRevLine -and $newRevLine -match 'Committed revision (\d+)\.') {
                $newRev = $Matches[1]
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
