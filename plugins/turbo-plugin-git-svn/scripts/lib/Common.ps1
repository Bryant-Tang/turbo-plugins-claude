# turbo-plugin SVN concern helpers. Core (universal helpers + the UTF-8 encoding
# preamble + StrictMode/EAP) is dot-sourced first; this concern lib must NOT reset the
# encoding Core establishes (KTD2a). All scripts source THIS file, which transitively pulls
# in Core.ps1 from the same lib/ directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'Core.ps1'))


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

