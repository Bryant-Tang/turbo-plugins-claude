[CmdletBinding()]
param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# System ANSI codepage (CP_ACP, e.g. 950/Big5 on zh-TW). `svn` reads/writes filenames in this
# codepage, and PowerShell encodes native-command ARGV using [Console]::OutputEncoding. We scope
# OutputEncoding=ANSI ONLY around `svn status` (so non-ASCII filenames decode + round-trip
# correctly), and keep `git log` OUTSIDE that scope (git emits UTF-8 commit subjects, which must
# NOT be decoded as Big5). Do NOT use `svn status --xml` here: its UTF-8 output would require
# OutputEncoding=UTF8, which then mis-encodes the ANSI argv on the commit side.
$tpAnsiEnc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)

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

    # F23: detect --branch mismatch — emit a structured token when the requested branch differs
    # from the current HEAD so the SKILL can prompt for user confirmation before pushing.
    # prefix with TP_TOKEN: to match the pre-flight contract — the SKILL
    # only trusts TP_TOKEN:-prefixed lines, so the backstop must use the same prefix or the
    # warning is silently dropped on the normal push path.
    $currentHeadBranch = (& git -C $mainWorktree rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($currentHeadBranch) -and $currentHeadBranch -ne $Branch) {
        Write-Output "TP_TOKEN:BRANCH_MISMATCH_WARNING current=$currentHeadBranch requested=$Branch"
    }

    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path rev-parse --verify -q MERGE_HEAD 2>$null | Out-Null
    $hasMergeHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if ($hasMergeHead) {
        # Emit a structured token so tp-push-to-svn SKILL can offer abort/continue/cancel options.
        Write-Output "PENDING_MERGE_DETECTED $($remote.Path)"
        exit 0
    }

    $remoteGitStatus = (& git -C $remote.Path status --porcelain | Out-String).Trim()
    if ($remoteGitStatus) {
        throw "Remote worktree '$($remote.Name)' has uncommitted git changes. Resolve before pushing."
    }

    $svnUrl = (& svn info --show-item url $remote.Path | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not get SVN URL from '$($remote.Name)'. Is it a valid SVN working copy?" }

    $localRev = (& svn info --show-item revision $remote.Path | Out-String).Trim()
    $headRev = (& svn info --show-item revision $svnUrl | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Could not query SVN HEAD revision for: $svnUrl" }

    if ($localRev -ne $headRev) {
        throw "Remote SVN worktree is not up to date (local r$localRev, head r$headRev). Run '/tp-pull-from-svn --branch $Branch' first."
    }

    $range = "$($remote.Branch)..$Branch"

    # Empty range (no new commits at all, merges included) → nothing to push (existing short-circuit).
    $eaCount = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $rangeCount = (& git -C $mainWorktree rev-list --count $range 2>$null | Out-String).Trim()
    $ErrorActionPreference = $eaCount
    if ([string]::IsNullOrWhiteSpace($rangeCount) -or $rangeCount -eq '0') {
        Write-Output 'Nothing to push'
        exit 0
    }

    # Locked SVN body = every NON-merge subject (no commit-type filtering; merges excluded by
    # parent count). git subjects are UTF-8, so this MUST run OUTSIDE the ANSI OutputEncoding scope
    # used for svn below (KTD6). The body is later persisted to a pin file so push-to-svn-commit
    # combines it with the agent-supplied title — the agent cannot alter the body.
    $svnBody = Get-SvnPushBody -RepoDir $mainWorktree -Range $range

    if ([string]::IsNullOrWhiteSpace($svnBody)) {
        # Range has commits, but ALL of them are merges → no code-level subjects for the body.
        # Hard-stop BEFORE staging a merge: this keeps the SVN body and the release-tag rule
        # consistent (a tag fires only when a real merge commit is produced — none is here).
        throw "Only merge commit(s) in range '$range': nothing to record in the SVN body. Add a non-merge commit (or rebase), then retry."
    }

    $mergeMsg = "Merge branch '$Branch' into $($remote.Branch)"
    $ea3 = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $remote.Path merge --no-ff --no-commit -m $mergeMsg $Branch 2>$null | Out-Null
    $mergeExit = $LASTEXITCODE
    $ErrorActionPreference = $ea3
    if ($mergeExit -ne 0) {
        $conflicts = (& git -C $remote.Path diff --name-only --diff-filter=U | Out-String).Trim()
        throw "Merge conflict in remote worktree. Resolve the following files in '$($remote.Name)', then re-run, or abort with 'git -C $($remote.Path) merge --abort':`n$conflicts"
    }

    # Pin the source branch HEAD SHA so push-to-svn-commit can detect new commits added after prepare.
    # NOTE: in a linked worktree, .git is a pointer FILE (not a directory). Use `git rev-parse --absolute-git-dir`
    # to resolve the pointer to the actual linked-worktree gitdir (which IS a directory).
    $branchHeadSha = (& git -C $mainWorktree rev-parse $Branch | Out-String).Trim()
    $shaGitDir = (& git -C $remote.Path rev-parse --absolute-git-dir | Out-String).Trim()
    $shaFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_branch_sha'
    Write-Utf8NoBom -Path $shaFile -Content $branchHeadSha

    # F12: also snapshot svn status so push-to-svn-commit can detect files added/removed
    # in the remote worktree after prepare (drift guard in addition to SHA pin).
    # Capture before any svn-add/svn-delete — this is the starting state.
    # Capture under ANSI OutputEncoding so non-ASCII filenames decode to correct Unicode, then
    # persist as UTF-8 (matching how submit reads the snapshot back with -Encoding UTF8).
    $svnStatusFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_svn_status'
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $tpAnsiEnc
    try {
        $svnStatusSnap = (& svn status $remote.Path | Out-String)
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
    Write-Utf8NoBom -Path $svnStatusFile -Content $svnStatusSnap

    # Persist the LOCKED body alongside the other prepare-time pins. push-to-svn-commit reads this
    # back (body-from-file) and combines it with the agent's title; the agent never sees a free
    # --message, so the body cannot be tampered with after prepare. Cleaned up on commit success.
    $bodyFile = Join-Path $shaGitDir 'MERGE_HEAD.tp_svn_body'
    Write-Utf8NoBom -Path $bodyFile -Content $svnBody

    # Build the FILES section under ANSI OutputEncoding (correct Unicode paths), collect into a
    # list, then emit after restoring the encoding so all stdout is encoded consistently.
    $fileLines = @()
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = $tpAnsiEnc
    try {
        Push-Location $remote.Path
        try {
            $statusLines = & svn status
            foreach ($line in $statusLines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line.Length -lt 9) { continue }
                $statusChar = $line.Substring(0, 1)
                $filepath   = $line.Substring(8).Trim()
                if (-not $filepath) { continue }
                $diffStatus = switch ($statusChar) {
                    '?' { 'A' }
                    '!' { 'D' }
                    'M' { 'M' }
                    default { $null }
                }
                if (-not $diffStatus) { continue }

                $ea2 = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                & git -C $remote.Path check-ignore -q $filepath 2>$null | Out-Null
                $isIgnored = ($LASTEXITCODE -eq 0)
                $ErrorActionPreference = $ea2

                if ($isIgnored) {
                    $fileLines += "$diffStatus|ignored|$filepath"
                } else {
                    $fileLines += "$diffStatus|tracked|$filepath"
                }
            }
        } finally {
            Pop-Location
        }
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }

    # Emit the locked body (for the SKILL to display) + the file list. The body shown here is the
    # SAME string written to the pin file, so what the user confirms is what gets committed.
    Write-Output 'BODY'
    Write-Output $svnBody
    Write-Output ''
    Write-Output 'FILES'
    foreach ($fl in $fileLines) { Write-Output $fl }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
