# turbo-plugin SVN concern helpers. Core (universal helpers + the UTF-8 encoding
# preamble + StrictMode/EAP) is dot-sourced first; this concern lib must NOT reset the
# encoding Core establishes (KTD2a). All scripts source THIS file, which transitively pulls
# in Core.ps1 from the same lib/ directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'Core.ps1'))

# Granularity gate threshold (KTD7/R2/R3): per-revision SILENTLY at or below this many new
# revisions; ABOVE it the granularity choice is offered. One shared definition for Sync-FromSvn.ps1
# and Initialize-GitSvnBridge.ps1 (dot-sourced into their scope) so the two never drift.
$script:TpGranularityThreshold = 5


# Return the worktree container directory: <mainWorktree>/.turbo-plugin/worktrees.
# git-svn concern (the SVN remote worktree container) -- the SVN script pairs call this
# instead of each hardcoding a sibling path. If -MainWorktree is supplied it is used as-is;
# otherwise it is computed via Get-MainWorktree (defined in Core.ps1, sourced above).
function Get-WorktreesDir {
    param([string]$MainWorktree = '')
    if ([string]::IsNullOrWhiteSpace($MainWorktree)) {
        $MainWorktree = Get-MainWorktree
    }
    return [System.IO.Path]::Combine($MainWorktree, '.turbo-plugin', 'worktrees')
}


# Validate a branch name for remote-svn worktree mapping (allowlist).
# Throws with a sanitization message on rejection. 'main' is the canonical trust
# anchor and always passes; other casings of 'main' are rejected so they cannot
# impersonate the anchor directory.
function Assert-ValidRemoteBranchName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$BranchName)

    if ([string]::IsNullOrEmpty($BranchName)) {
        throw "Invalid branch name: empty."
    }
    # Case-SENSITIVE: only the exact lowercase 'main' is the trust anchor. Other
    # casings (Main / MAIN) fall through to the reserved-name rejection below.
    if ($BranchName -ceq 'main') { return }

    if ($BranchName.Contains('..')) {
        throw "Invalid branch name '$BranchName': must not contain '..'."
    }
    if ($BranchName.StartsWith('-')) {
        throw "Invalid branch name '$BranchName': must not start with '-'."
    }
    if ($BranchName -match '[\s.]$') {
        throw "Invalid branch name '$BranchName': must not end with '.' or whitespace."
    }
    # Allowlist: letters, digits, '.', '_', '-', '/'. Rejects '\', ':', spaces,
    # control characters, and any other separator.
    if ($BranchName -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "Invalid branch name '$BranchName': only letters, digits, '.', '_', '-', and '/' are allowed."
    }
    # Reserved names (case-insensitive): the 'main' anchor dir (any non-exact casing)
    # plus Windows reserved device names, checked against the dash-form and each
    # '/'-separated segment.
    $segments = @(($BranchName -replace '/', '-')) + ($BranchName -split '/')
    foreach ($seg in $segments) {
        $low = $seg.ToLowerInvariant()
        if ($low -eq 'main' -or $low -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
            throw "Invalid branch name '$BranchName': '$seg' is a reserved name."
        }
    }
}

# Returns the existing remote-svn branch that collides with $BranchName (maps to the
# same worktree dir name but is a different ref), or $null when there is no collision.
# Pure: the caller supplies the existing branch list (e.g. from
# `git branch --list 'remote-svn/*'` with the 'remote-svn/' prefix stripped).
function Find-RemoteWorktreeCollision {
    param(
        [Parameter(Mandatory = $true)][string]$BranchName,
        [string[]]$ExistingBranches
    )
    if ($null -eq $ExistingBranches) { return $null }
    $dash = $BranchName -replace '/', '-'
    foreach ($existing in $ExistingBranches) {
        if ([string]::IsNullOrEmpty($existing)) { continue }
        if ($existing -eq $BranchName) { continue }
        if (($existing -replace '/', '-') -eq $dash) {
            return $existing
        }
    }
    return $null
}

# Map any branch to its remote-svn ref + worktree dir (generalized from
# the old hard-coded main / test-<n>). Mapping:
#   ref      = remote-svn/<branch>                 (slashes preserved)
#   worktree = remote-svn-<branch with '/' -> '-'>
# Sanitization + MAX_PATH guard run here; collision is the caller's concern
# (Find-RemoteWorktreeCollision) since it needs the live branch list.
function Resolve-RemoteWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$BranchName,
        [Parameter(Mandatory = $true)][string]$WorktreesDir
    )

    Assert-ValidRemoteBranchName -BranchName $BranchName

    $dash = $BranchName -replace '/', '-'
    $name = "remote-svn-$dash"
    $path = [System.IO.Path]::Combine($WorktreesDir, $name)

    # MAX_PATH guard — distinct from the sanitization rejection above. Windows PS 5.1
    # / .NET Framework cannot create paths longer than 260 chars without long-path
    # support; fail loudly with guidance rather than letting the create blow up later.
    # MAX_PATH (260) counts the terminating NUL, so the usable string length is 259 —
    # reject at >= 260 (a 260-char path passes -gt 260 but Windows still refuses it).
    if ($path.Length -ge 260) {
        throw "Worktree path exceeds the Windows MAX_PATH limit (260): '$path' is $($path.Length) chars. Shorten the clone path, or enable long-path support (git config core.longpaths true, or the \\?\ prefix)."
    }

    return @{
        Name   = $name
        Branch = "remote-svn/$BranchName"
        Path   = $path
    }
}

# Normalize an SVN URL for boundary-safe trust comparison:
#   - trim a single trailing slash
#   - lowercase scheme + authority (host[:port]); for file:// also lowercase the
#     Windows drive letter immediately after the leading slash(es)
#   - percent-decode the whole thing
# Returns the normalized string. Does NOT validate the URL beyond this; callers
# must still apply the boundary-prefix check.
function ConvertTo-NormalizedSvnUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $u = $Url.Trim()
    # percent-decode first so encoded slashes / drive letters normalize too.
    $u = [System.Uri]::UnescapeDataString($u)
    # split scheme://rest so we only lowercase scheme + authority, not the path.
    if ($u -match '^([A-Za-z][A-Za-z0-9+.\-]*://)([^/]*)(/.*)?$') {
        $scheme = $Matches[1].ToLowerInvariant()
        $authority = $Matches[2].ToLowerInvariant()
        $rest = if ($null -ne $Matches[3]) { $Matches[3] } else { '' }
        $u = "$scheme$authority$rest"
    } elseif ($u -match '^([A-Za-z][A-Za-z0-9+.\-]*:)(.*)$') {
        # scheme without authority (rare); lowercase scheme only.
        $u = $Matches[1].ToLowerInvariant() + $Matches[2]
    }
    # file:// drive letter — lowercase the drive letter after the leading slashes
    # (e.g. file:///C:/Repo -> file:///c:/Repo). Authority is empty for file URLs.
    if ($u -match '^(file://)(/*)([A-Za-z])(:.*)$') {
        $u = $Matches[1] + $Matches[2] + $Matches[3].ToLowerInvariant() + $Matches[4]
    }
    # trim a single trailing slash
    if ($u.Length -gt 1 -and $u.EndsWith('/')) {
        $u = $u.Substring(0, $u.Length - 1)
    }
    return $u
}

# Assert that a caller-supplied SVN URL falls under the trusted repository root.
# Inputs:
#   -TrustedWorkingCopy: path to a working copy we trust (e.g. remote-svn-main). Its
#       `svn info --show-item repos-root-url` defines the trust base. MUST be
#       repos-root-url (not the trunk url) so legitimate sibling branches under
#       branches/ aren't falsely rejected.
#   -CandidateUrl: the untrusted URL to validate before any svn side effect.
# Behavior (fail closed):
#   - If repos-root-url can't be obtained (path missing / not a WC / server
#     unreachable) -> throw. The caller MUST NOT be able to swallow this and proceed.
#   - Candidate containing `..` traversal -> throw.
#   - After normalizing both ends (trailing slash, scheme/host case, file:// drive
#     letter, percent-decode), pass only when candidate == base OR
#     candidate startswith (base + '/'). Bare StartsWith(base) is rejected to stop
#     `repos` matching `repos-evil` (prefix confusion).
# On success: returns the normalized trusted base (for diagnostics); on any failure: throw.
function Assert-TrustedSvnUrl {
    param(
        [Parameter(Mandatory = $true)][string]$TrustedWorkingCopy,
        [Parameter(Mandatory = $true)][string]$CandidateUrl
    )

    if ([string]::IsNullOrWhiteSpace($CandidateUrl)) {
        throw 'Assert-TrustedSvnUrl: empty candidate URL.'
    }

    # Reject path traversal outright — `..` must never appear in a trusted URL.
    if ($CandidateUrl -match '(^|[/\\])\.\.([/\\]|$)') {
        throw "Untrusted SVN URL (path traversal '..' not allowed): $CandidateUrl"
    }

    # Obtain the trust base from the trusted working copy. Fail closed on any error.
    $base = ''
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $base = (& svn info --show-item repos-root-url $TrustedWorkingCopy 2>$null | Out-String).Trim()
    } catch {
        $base = ''
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($base)) {
        throw "Assert-TrustedSvnUrl: could not determine trusted repos-root-url from '$TrustedWorkingCopy' (path missing, not a working copy, or SVN unreachable). Refusing to proceed (fail closed). Run /tp-setup to bootstrap remote-svn-main."
    }

    $normBase = ConvertTo-NormalizedSvnUrl -Url $base
    $normCand = ConvertTo-NormalizedSvnUrl -Url $CandidateUrl

    # Re-check traversal AFTER percent-decoding — a percent-encoded `..` (%2e%2e)
    # passes the raw check above but decodes here; without this it could slip under
    # the boundary prefix as `<base>/../...`.
    if ($normCand -match '(^|[/\\])\.\.([/\\]|$)') {
        throw "Untrusted SVN URL (encoded path traversal '..' not allowed): $CandidateUrl"
    }

    # Boundary-safe ordinal comparison (both ends already lowercased where it matters).
    $isTrusted = ($normCand -eq $normBase) -or $normCand.StartsWith($normBase + '/', [System.StringComparison]::Ordinal)
    if (-not $isTrusted) {
        throw "Untrusted SVN URL: '$CandidateUrl' is not under trusted repository root '$base'. Refusing to proceed."
    }

    return $normBase
}

# Build the LOCKED SVN commit body for a push range. The body is a deterministic, '- '-prefixed
# list of EVERY non-merge commit subject (oldest first), one per line — git itself applies the
# '- ' prefix and the ordering, so the same commit set always yields a byte-identical body.
#
# Merge commits are excluded by parent count (--no-merges), NOT by a 'Merge ' subject-prefix
# match (KTD6/R11). There is NO commit-type filtering: docs/test/chore subjects all go in (R11).
# Subjects come straight from git's --pretty formatter, so backticks, '$', quotes, and a leading
# '- ' in a subject survive without any PowerShell interpolation.
#
# Capture happens OUTSIDE the ANSI OutputEncoding scope used for svn — commit subjects are UTF-8
# (KTD6); callers must invoke this while the console encoding is still the default (UTF-8 capable).
# Returns the body string ('' when the range has no non-merge commit).
function Get-SvnPushBody {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][string]$Range
    )
    # git may warn on stderr; under EAP=Stop that throws NativeCommandError, so soften locally.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $lines = & git -C $RepoDir log $Range --no-merges --reverse --pretty=format:'- %s' 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($null -eq $lines) { return '' }
    # Force array so a single-commit result still joins as a line (PS unwraps scalars).
    return (@($lines) -join "`n")
}

# --- Per-revision SVN replay primitives (U1) ---------------------------------
# PowerShell peers of svn_enumerate_revisions / svn_replay_commit / svn_floor_commit_for_rev
# (common.sh). All three are pure git + XML (NO native svn call here — the caller captures the
# svn log and passes the XML string in), so git output stays UTF-8 (Core.ps1 default) and no
# ANSI OutputEncoding scoping is needed. Keep this block ASCII so the file's existing BOM is the
# only reason it holds non-ASCII bytes.

# Enumerate revisions from an `svn log --xml` document (passed as a Unicode string) into
# per-revision objects { Rev; Author; Date; Message } in ASCENDING revision order. System.Xml
# entity-decodes InnerText and preserves multi-line / CJK messages verbatim. Behavior-matched
# to common.sh's svn_enumerate_revisions (shape differs: objects here vs a NUL record stream there).
function Get-SvnRevisions {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogXml)

    $result = @()
    if ([string]::IsNullOrWhiteSpace($LogXml)) { return $result }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($LogXml)

    $entries = $doc.SelectNodes('/log/logentry')
    foreach ($e in $entries) {
        $rev = [int]$e.GetAttribute('revision')
        $authorNode = $e.SelectSingleNode('author')
        $dateNode   = $e.SelectSingleNode('date')
        $msgNode    = $e.SelectSingleNode('msg')
        $author  = if ($authorNode) { $authorNode.InnerText } else { '' }
        $date    = if ($dateNode)   { $dateNode.InnerText }   else { '' }
        $message = if ($msgNode)    { $msgNode.InnerText -replace "\r", '' } else { '' }
        $result += [pscustomobject]@{
            Rev     = $rev
            Author  = $author
            Date    = $date
            Message = $message
        }
    }
    # Force array (a single-entry result would otherwise unwrap to a scalar and break .Count / indexing).
    return @($result | Sort-Object -Property Rev)
}

# Replay one SVN revision as a git commit on the CURRENT HEAD of -RepoDir (in production the
# remote-svn/<branch> worktree, already `svn update`d to this revision's tree). Returns a token:
#   'SKIP:idempotent'  HEAD already carries a commit with this revision's `svn-revision:` trailer
#                      (KTD4 idempotency — an interrupted-then-rerun pull mints no duplicate).
#   'SKIP:empty'       `git add -A` left the index unchanged (tree identical to parent) → no commit.
#   'COMMIT:<sha>'     committed. Author = "<svn-username> <>" (raw username, empty <> email; KTD2),
#                      SVN date as the git AUTHOR-date (committer-date = replay moment; KTD6),
#                      message = SVN message + blank line + `svn-revision: <rev>` trailer (KTD3).
# commit.cleanup is pinned to 'whitespace' so a '#'-leading message line survives (default 'strip'
# would delete it) while the trailer paragraph is still recognized.
function Invoke-SvnReplayCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][int]$Rev,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Author,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Date,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    # git warns on stderr (LF/CRLF etc); under EAP=Stop that throws NativeCommandError, so soften
    # locally and drive control flow off $LASTEXITCODE (mind the PS5.1 EAP=Stop stderr-throw trap).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        # Idempotency: exact `svn-revision: <rev>` trailer already on HEAD → skip. git log exits 0
        # with empty output when nothing matches (only a bad ref errors, which we tolerate).
        $pattern = '^svn-revision: ' + $Rev + '$'
        $existing = & git -C $RepoDir log HEAD -n 1 -E --grep=$pattern --format='%H' 2>$null
        if (-not [string]::IsNullOrWhiteSpace((@($existing) -join ''))) {
            return 'SKIP:idempotent'
        }

        & git -C $RepoDir add -A 2>$null | Out-Null
        # Guard the stage: a failed `git add -A` leaves the index unchanged, which the empty-delta
        # check below would misread as "identical tree" → SKIP:empty, silently dropping this
        # revision's commit + trailer (and corrupting the trailer-scan cur/floor lookups). The bash
        # sibling fails loud here via `set -e`; mirror Invoke-SvnBoundaryCommit's own add-guard.
        if ($LASTEXITCODE -ne 0) { throw "Invoke-SvnReplayCommit: git add -A failed for r$Rev (exit $LASTEXITCODE)." }

        # Empty index (tree identical to parent) → skip. --quiet writes nothing to stderr, so
        # $LASTEXITCODE is reliable: 0 = no staged changes, 1 = staged changes.
        & git -C $RepoDir diff --cached --quiet 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return 'SKIP:empty'
        }

        # git dislikes the .000000Z microseconds svn emits; keep it to whole seconds.
        $dateGit = $Date -replace '\.\d+Z$', 'Z'

        # Robustness (security review): defang any BODY line mimicking our own `svn-revision:` trailer
        # so a crafted SVN message can't inject a lookalike the trailer scans would trust. Indent a
        # col-0 match by one space (breaks the '^svn-revision:' anchor; survives --cleanup=whitespace).
        # Mirror of the sed defang in svn_replay_commit (common.sh). Only the tool's final -m is real.
        $safeMessage = (($Message -split "`n") | ForEach-Object {
            if ($_ -match '^svn-revision:') { ' ' + $_ } else { $_ }
        }) -join "`n"

        $authorArg = @()
        if (-not [string]::IsNullOrEmpty($Author)) {
            $authorArg = @("--author=$Author <>")
        }

        & git -C $RepoDir -c commit.gpgsign=false commit --cleanup=whitespace @authorArg `
            --date=$dateGit -m $safeMessage -m ('svn-revision: ' + $Rev) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Invoke-SvnReplayCommit: git commit failed for r$Rev (exit $LASTEXITCODE)."
        }

        $sha = (& git -C $RepoDir rev-parse HEAD 2>$null | Out-String).Trim()
        return "COMMIT:$sha"
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# --- Shared per-revision replay loop (U3 pull + U7 first-import bootstrap) -----
# One shared body so the steady-state pull (Sync-FromSvn) and the first-import bootstrap
# (Initialize-GitSvnBridge) mint IDENTICAL commit shapes (author / date / trailer). Both callers own
# their own >5 granularity GATE (the residue-free "needs choice" exit differs per caller); this code
# only MATERIALISES an already-chosen mode against a bridge worktree at the resume baseline.

# Replay ONE svn revision: svn update -r R in the bridge worktree, assert the WC is uniformly at R
# (KTD4 sparse guard), then hand off to Invoke-SvnReplayCommit. Returns the U1 token.
function Invoke-SvnOneReplay {
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
# Subject `sync: svn r<rev>` (steady-state shape) + a second -m appending the `svn-revision: <rev>`
# trailer so floor-lookup (U5) treats the squashed range as a single boundary. Skips an empty delta.
function Invoke-SvnBoundaryCommit {
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

# Enumerate r(Cur+1)..HeadRev on the bridge worktree, then materialise commits per -Mode:
#   per-revision : one replay commit per revision (empty deltas skipped)
#   squash       : one boundary commit at HeadRev
#   range        : per-revision inside <lo>:<hi> (from -Range), squash the leading + trailing rest
# Re-enumerates from the WC so the caller only hands over the decided mode.
function Invoke-SvnReplayDispatch {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][string]$RemoteName,
        [Parameter(Mandatory = $true)][int]$Cur,
        [Parameter(Mandatory = $true)][int]$HeadRev,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Range = ''
    )
    # KTD4 sparse guard: a full (infinite-depth) checkout is required so `svn update -r R` yields a
    # uniform per-revision tree -- otherwise an empty post-update delta could mean "sparse update",
    # not "identical tree". Assert once, before the loop.
    $depth = (& svn info --show-item depth $RemotePath | Out-String).Trim()
    if ($depth -ne 'infinity') {
        throw "Remote worktree depth is '$depth', not 'infinity'; per-revision replay needs a full checkout."
    }

    $revs = @()
    if ($Cur -lt $HeadRev) {
        $logXml = (& svn log --xml -r "$($Cur + 1):$HeadRev" $RemotePath | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "svn log failed for r$($Cur + 1):r$HeadRev" }
        $revs = @(Get-SvnRevisions -LogXml $logXml)
    }

    if ($Mode -eq 'per-revision') {
        Write-Output "Replaying $(@($revs).Count) SVN revision(s) r$($Cur + 1)..r$HeadRev into $RemoteName..."
        foreach ($rec in $revs) {
            $null = Invoke-SvnOneReplay -RemotePath $RemotePath -Rev $rec.Rev -Author $rec.Author -Date $rec.Date -Message $rec.Message
        }
    }
    elseif ($Mode -eq 'squash') {
        Write-Output "Squashing SVN r$($Cur + 1)..r$HeadRev into one commit in $RemoteName..."
        Push-Location $RemotePath
        try {
            & svn update
            if ($LASTEXITCODE -ne 0) { throw 'svn update failed' }
        } finally {
            Pop-Location
        }
        Invoke-SvnBoundaryCommit -RemotePath $RemotePath -Rev $HeadRev
    }
    elseif ($Mode -eq 'range') {
        if ($Range -notmatch '^[0-9]+:[0-9]+$') {
            throw "Granularity 'range' requires -Range <lo>:<hi> (got '$Range')."
        }
        $loRaw, $hiRaw = $Range -split ':', 2
        $lo = [Math]::Max([int]$loRaw, $Cur + 1)
        $hi = [Math]::Min([int]$hiRaw, $HeadRev)
        if ($lo -gt $hi) { throw "Granularity range r$loRaw:r$hiRaw does not overlap the pending r$($Cur + 1):r$HeadRev." }
        Write-Output "Replaying r$lo..r$hi per-revision, squashing the rest, into $RemoteName..."
        # Leading squash: r(cur+1)..r(lo-1) -> one boundary commit at r(lo-1). Skipped when lo==cur+1.
        if (($lo - 1) -ge ($Cur + 1)) {
            Push-Location $RemotePath
            try {
                & svn update -r ($lo - 1)
                if ($LASTEXITCODE -ne 0) { throw "svn update -r $($lo - 1) failed" }
            } finally {
                Pop-Location
            }
            Invoke-SvnBoundaryCommit -RemotePath $RemotePath -Rev ($lo - 1)
        }
        # Per-revision inside [lo,hi].
        foreach ($rec in $revs) {
            if ($rec.Rev -ge $lo -and $rec.Rev -le $hi) {
                $null = Invoke-SvnOneReplay -RemotePath $RemotePath -Rev $rec.Rev -Author $rec.Author -Date $rec.Date -Message $rec.Message
            }
        }
        # Trailing squash: r(hi+1)..rHEAD -> one boundary commit at rHEAD. Skipped when hi>=HeadRev.
        if ($hi -lt $HeadRev) {
            Push-Location $RemotePath
            try {
                & svn update
                if ($LASTEXITCODE -ne 0) { throw 'svn update failed' }
            } finally {
                Pop-Location
            }
            Invoke-SvnBoundaryCommit -RemotePath $RemotePath -Rev $HeadRev
        }
    }
    else {
        throw "Unknown granularity '$Mode' (expected per-revision | squash | range)."
    }
}

# Floor revision->commit lookup (KTD3 floor semantics, R8/R14). Over `main` (STRICTLY main, never
# HEAD), return the SHA of the newest commit whose `svn-revision:` trailer value is the GREATEST
# value <= -TargetRev (SVN revisions are sparse, so an arbitrary target usually has no exact match).
#   - Returns exactly ONE SHA on success.
#   - Returns $null when no commit carries a value <= target (genuine "predates earliest").
#   - THROWS when that greatest value <= target is carried by MORE THAN ONE commit — the ambiguous
#     multi-match that reproduced the `not a valid object name` failure (6962db7 / 6f73114).
function Get-SvnFloorCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][int]$TargetRev
    )

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $shas = @(& git -C $RepoDir log main --format='%H' 2>$null)
        $bestRev = $null; $bestSha = $null; $bestCount = 0
        foreach ($sha in $shas) {
            if ([string]::IsNullOrWhiteSpace($sha)) { continue }
            # Parse the trailer straight out of the raw body (version-independent; avoids the
            # %(trailers) newline quirks). Take the LAST svn-revision line if several appear.
            $bodyLines = & git -C $RepoDir show -s --format='%B' $sha 2>$null
            $body = (@($bodyLines) -join "`n")
            $matched = [regex]::Matches($body, '(?m)^svn-revision:[ ]([0-9]+)[ ]*\r?$')
            if ($matched.Count -eq 0) { continue }
            $val = [int]$matched[$matched.Count - 1].Groups[1].Value
            if ($val -gt $TargetRev) { continue }
            if ($null -eq $bestRev -or $val -gt $bestRev) {
                $bestRev = $val; $bestSha = $sha; $bestCount = 1
            } elseif ($val -eq $bestRev) {
                $bestCount++
                $bestSha = $sha
            }
        }
        if ($null -eq $bestRev) { return $null }
        if ($bestCount -gt 1) {
            throw "Get-SvnFloorCommit: revision r$bestRev is carried by $bestCount commits on 'main' (ambiguous floor for r$TargetRev). Refusing to return a non-unique base."
        }
        return $bestSha
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# Highest replayed revision on `main` (KTD4 resume point; the checkout grading bound `cur`, U5).
# Scans the SAME `svn-revision:` trailer as Get-SvnFloorCommit, STRICTLY on `main` (never HEAD).
# Returns the GREATEST replayed revision value as [int], or 0 when `main` carries no replayed
# revision. Used to grade a target R against cur BEFORE the floor lookup: R > cur means the aligned
# revision has not been replayed yet (pull first) rather than "predates earliest".
# Greatest `svn-revision:` trailer value reachable from -Ref. Centralized trailer-scan primitive
# (security/maintainability review): one place parses the trailer, so idempotency/floor/highest/
# alignment stay consistent and robust. Takes only the LAST `^svn-revision:` line PER COMMIT (the
# tool-appended trailer position) -- a stray lookalike earlier in a body is ignored, and replay
# bodies are additionally defanged at mint time (Invoke-SvnReplayCommit). Returns [int], 0 when none.
function Get-SvnMaxTrailerRev {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $shas = @(& git -C $RepoDir log $Ref --format='%H' 2>$null)
        $best = 0
        foreach ($sha in $shas) {
            if ([string]::IsNullOrWhiteSpace($sha)) { continue }
            $bodyLines = & git -C $RepoDir show -s --format='%B' $sha 2>$null
            $body = (@($bodyLines) -join "`n")
            $matched = [regex]::Matches($body, '(?m)^svn-revision:[ ]([0-9]+)[ ]*\r?$')
            if ($matched.Count -eq 0) { continue }
            $val = [int]$matched[$matched.Count - 1].Groups[1].Value
            if ($val -gt $best) { $best = $val }
        }
        return $best
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Get-SvnHighestReplayedRev {
    param([Parameter(Mandatory = $true)][string]$RepoDir)
    return (Get-SvnMaxTrailerRev -RepoDir $RepoDir -Ref 'main')
}

# --- tp:* branch-metadata property helpers (U2) ------------------------------
# PowerShell peers of svn_copyfrom_rev_xml / get_svn_branch_copyfrom_rev / get_tp_branch_prop /
# set_tp_branch_prop (common.sh). Read/write the two branch-metadata SVN properties the bridge
# cannot otherwise share (KTD5) plus the trunk copyfrom-rev a branch was `svn copy`-ed from. Keep
# this block ASCII so the file's existing BOM is the only reason it holds non-ASCII bytes.

# Extract the trunk copyfrom-rev of a branch from an `svn log -v --stop-on-copy --xml` document
# (passed as a string). Under --stop-on-copy the OLDEST logentry (smallest revision) IS the copy,
# whose branch-root path carries copyfrom-rev="N" (the TRUNK revision the branch was copied from) --
# NOT the branch's own creation revision (the logentry's revision, which never touched trunk and
# carries no svn-revision: trailer). Returns the value as a string, or '' when the XML has no
# copyfrom path. Reuses XmlDocument.LoadXml + SelectNodes (mirrors Get-SvnLog.ps1); GetAttribute
# returns '' for a missing attribute, so the IsNullOrWhiteSpace guard is correct.
function Get-SvnCopyfromRevFromXml {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Xml)

    if ([string]::IsNullOrWhiteSpace($Xml)) { return '' }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $logRoot = $doc.SelectSingleNode('/log')
    if ($null -eq $logRoot) { return '' }
    # @()-wrap so a single logentry does not unwrap to a scalar (five-taboo #5).
    $entries = @($logRoot.SelectNodes('logentry'))
    if ($entries.Count -eq 0) { return '' }

    $minRev = $null; $minEntry = $null
    foreach ($e in $entries) {
        $r = $e.GetAttribute('revision')
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $ri = [int]$r
        if ($null -eq $minRev -or $ri -lt $minRev) { $minRev = $ri; $minEntry = $e }
    }
    if ($null -eq $minEntry) { return '' }
    foreach ($p in @($minEntry.SelectNodes('paths/path'))) {
        $cfr = $p.GetAttribute('copyfrom-rev')
        if (-not [string]::IsNullOrWhiteSpace($cfr)) { return $cfr }
    }
    return ''
}

# Thin wrapper: run svn for a branch URL, feed its XML to the pure parser. Softens EAP so a native
# stderr write cannot throw a NativeCommandError under EAP=Stop; throws on a genuine non-zero exit
# so callers never treat empty as "not a copy".
function Get-SvnBranchCopyfromRev {
    param([Parameter(Mandatory = $true)][string]$BranchUrl)

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $xml = (& svn log -v --stop-on-copy --xml $BranchUrl 2>$null | Out-String)
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) { throw "svn log --stop-on-copy failed for $BranchUrl" }
    return (Get-SvnCopyfromRevFromXml -Xml $xml)
}

# Getter: return the value of tp:<Name> on -Target (a branch URL or a working-copy path), or ''
# when the property is absent. `svn propget` on a missing custom property exits NON-ZERO with empty
# output (observed rc=1 on 1.14), so we suppress stderr, soften EAP (so a stderr write cannot throw
# under EAP=Stop -- precedent: Assert-TrustedSvnUrl), and do NOT trust the exit code. Trim the
# trailing CR/LF propget + Out-String append.
function Get-TpBranchProp {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $val = (& svn propget "tp:$Name" $Target 2>$null | Out-String)
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($null -eq $val) { return '' }
    return ($val -replace '(\r?\n)+$', '')
}

# Setter: in the branch working copy set tp:<Name>=<Value>, then a SCOPED property commit and an
# `svn update`. `--depth empty` + the explicit '.' target is load-bearing -- the fb42a63 fix that
# stops `svn checkout --force` overlay drift being swept into the commit; the trailing `svn update`
# clears the mixed-revision lag so the next build falsely-demand-a-pull check passes. Push-Location
# + explicit $LASTEXITCODE checks after each native call mirror New-RemoteBridge.ps1. Fixed ASCII msg.
function Set-TpBranchProp {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$WorkingCopy
    )
    Push-Location -LiteralPath $WorkingCopy
    try {
        & svn propset "tp:$Name" $Value '.'
        if ($LASTEXITCODE -ne 0) { throw "svn propset tp:$Name failed" }
        & svn commit --depth empty -m "set tp:$Name (turbo-plugin metadata)" '.'
        if ($LASTEXITCODE -ne 0) { throw "svn commit tp:$Name failed" }
        & svn update | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "svn update after tp:$Name commit failed" }
    } finally {
        Pop-Location
    }
}

