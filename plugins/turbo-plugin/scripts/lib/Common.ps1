Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force UTF-8 for both PS host output and how PS interprets native command stdout/stderr.
# Without this, Windows PowerShell 5.1 uses the system code page (Big5 / CP950 on Chinese
# Windows), and output from native exes (svn / msbuild / iisexpress) that emit UTF-8
# bytes renders as mojibake (`?` chars or garbage). Affects every script that
# dot-sources Common.ps1.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# Also read console input as UTF-8. Guarded: in non-interactive / redirected contexts
# (CI, piped stdin — no console input handle) assigning InputEncoding throws; swallow
# it. The OutputEncoding settings above are the load-bearing part.
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Probe-GitVersion {
    $raw = (& git --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'git CLI not available on PATH.'
    }
    if ($raw -notmatch 'git version (\d+)\.(\d+)') {
        throw "Unable to parse git version from '$raw'."
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 31)) {
        throw "turbo-plugin requires Git >= 2.31 (for --path-format=absolute). Detected: $raw. Please upgrade."
    }
}

function Get-NormalizedAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Get-NormalizedAbsolutePath: empty path.'
    }

    if ($Path -match '^/([a-zA-Z])/(.*)$') {
        $Path = "$($Matches[1]):\$($Matches[2] -replace '/', '\')"
    }

    $resolved = $null
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    }

    if ($resolved -match '^([a-zA-Z]):(.*)$') {
        $resolved = "$($Matches[1].ToString().ToLower()):$($Matches[2])"
    }

    return $resolved
}

function Get-MainWorktree {
    # v0.2.7+ F-U2.3 fix: wrap git call in try/catch to prevent PS 5.1 + StrictMode + EAP=Stop
    # from bubbling raw git "fatal: not a git repository" stderr as terminating NativeCommandError
    # before our self-emitted "Not inside a git repository." throw can fire.
    $commonDir = ''
    try {
        $commonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    } catch {
        $commonDir = ''
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir)) {
        throw 'Not inside a git repository.'
    }
    $parent = [System.IO.Path]::GetDirectoryName($commonDir)
    return Get-NormalizedAbsolutePath -Path $parent
}

# Return the worktree container directory: <mainWorktree>/.turbo-plugin/worktrees.
# Single source of truth for the SVN remote worktree container — the 7 SVN script
# pairs call this instead of each hardcoding a sibling "<projName>.worktrees" path.
# If -MainWorktree is supplied it is used as-is; otherwise it is computed via
# Get-MainWorktree (which locates the main worktree from any linked worktree).
function Get-WorktreesDir {
    param([string]$MainWorktree = '')
    if ([string]::IsNullOrWhiteSpace($MainWorktree)) {
        $MainWorktree = Get-MainWorktree
    }
    return [System.IO.Path]::Combine($MainWorktree, '.turbo-plugin', 'worktrees')
}

function Test-IsMainWorktree {
    $commonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    $topLevel = (& git rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir) -or [string]::IsNullOrWhiteSpace($topLevel)) {
        return $false
    }
    $parent = Get-NormalizedAbsolutePath -Path ([System.IO.Path]::GetDirectoryName($commonDir))
    $top = Get-NormalizedAbsolutePath -Path $topLevel
    return ($parent -eq $top)
}

function Test-IsSubmodule {
    $super = (& git rev-parse --show-superproject-working-tree 2>$null | Out-String).Trim()
    return -not [string]::IsNullOrWhiteSpace($super)
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    if ($PathValue -match '^/([a-zA-Z])/(.*)$') {
        $PathValue = "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    $PathValue = $PathValue -replace '^\.[\\/]', ''
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

# Validate a branch name for remote-svn worktree mapping (v0.5.0 U7 allowlist).
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

# Map any branch to its remote-svn ref + worktree dir (v0.5.0 U7 — generalized from
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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# Compute a relative path from $From to $To, compatible with PowerShell 5.1.
# [System.IO.Path]::GetRelativePath is .NET Core / .NET 5+ only — not in .NET Framework
# (which is what powershell.exe runs on). Use System.Uri.MakeRelativeUri instead.
function Get-RelativePathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    # v0.2.7+ F-U2.9 fix: define same-path return contract explicitly. MakeRelativeUri's
    # behavior on $From == $To is ambiguous (can return "" or "../<basename>" depending on
    # trailing-separator state); callers expecting a meaningful empty result get surprised.
    $fromTrimmed = $From.TrimEnd('\','/')
    $toTrimmed = $To.TrimEnd('\','/')
    if ($fromTrimmed -eq $toTrimmed) {
        return ''
    }
    # MakeRelativeUri needs $From treated as a directory — append a separator if missing
    # so the relative path is computed from the dir, not "as a sibling of the file".
    $fromNorm = $fromTrimmed + [System.IO.Path]::DirectorySeparatorChar
    $fromUri = New-Object System.Uri($fromNorm)
    $toUri = New-Object System.Uri($To)
    $relUri = $fromUri.MakeRelativeUri($toUri)
    $rel = [System.Uri]::UnescapeDataString($relUri.ToString())
    # MakeRelativeUri returns forward slashes; convert to OS native separator
    return $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
}

# Compute the project-identity hash used for IIS Express site name suffixes
# and cross-worktree project matching. Inputs:
#   -RepoPath: an absolute path inside the worktree whose project we're identifying.
#   -CsprojRelPath: csproj path relative to the worktree top-level (forward slashes preferred).
# Returns: first 8 hex chars of sha256(git-common-dir + "#" + lower(csproj-relpath)).
function Get-ProjectIdentityHash {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$CsprojRelPath
    )

    $commonDir = (& git -C $RepoPath rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($commonDir)) {
        throw "Not a git repository: $RepoPath"
    }
    $commonDir = Get-NormalizedAbsolutePath -Path $commonDir

    $relNorm = ($CsprojRelPath -replace '\\', '/').ToLower()
    $identity = "$commonDir#$relNorm"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    return $hex.Substring(0, 8)
}

function Format-IisExpressSiteName {
    param(
        [Parameter(Mandatory = $true)][string]$CsprojPath,
        [Parameter(Mandatory = $true)][string]$IdentityHash
    )
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($CsprojPath)
    return "$stem-$IdentityHash"
}

# Locate MSBuild.exe. Lookup order (v1.0+ U2 — strict cut, no env fallback):
#   1. .turbo-plugin/config.local.toml [tools] msbuild_path  (machine-specific, gitignored)
#   2. Standard VS install paths (VS 2017/2019/2022 Enterprise/Professional/Community)
#   3. Throw with /tp-setup guidance.
# $env:TURBO_PLUGIN_MSBUILD_PATH is deliberately NOT read — turbo-plugin v1.0 is the
# first release; no legacy users to migrate. If the env var happens to be set by some
# other tool, it is ignored.
function Find-MSBuild {
    param([string]$RepoRoot = '')

    # Step 1: config.local.toml [tools] msbuild_path (via Resolve-ConfigValue's merge chain)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $configured = Resolve-ConfigValue -RepoRoot $RepoRoot -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            $resolved = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $configured
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return $resolved
            }
            throw @"
MSBuild 路徑設定指向不存在的檔案: $resolved
(來源: .turbo-plugin/config.local.toml [tools] msbuild_path)
請跑 /tp-setup 重新偵測,或手動修正 .turbo-plugin/config.local.toml 內的路徑。
"@
        }
    }

    # Step 2: probe standard VS install paths
    $candidates = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Enterprise\MSBuild\15.0\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Professional\MSBuild\15.0\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\MSBuild.exe"
    )
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($found.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($found[0])) {
        return $found[0]
    }

    # Step 3: throw with /tp-setup guidance
    throw @"
MSBuild 路徑未設定且找不到 VS 安裝。請跑 /tp-setup 互動填入 MSBuild 路徑,
或手動在 .turbo-plugin/config.local.toml 加上:
  [tools]
  msbuild_path = "C:/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe"
"@
}

# Find the single .csproj in the repo, using config or CLI arg, or auto-detecting.
# Args: -RepoRoot <path> -CliProjectValue <string-or-null>
# Returns: absolute path to the .csproj file.
# Throws if 0 or >1 .csproj found (when no config/CLI value provided) or if the configured path does not exist.
function Find-SingleCsproj {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$CliProjectValue = ''
    )
    $projectPathRel = Resolve-ConfigValue -RepoRoot $RepoRoot -Section 'build' -Key 'project' -CliValue $CliProjectValue -Default $null
    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        $candidates = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|\.vs|\.git)\\' })
        if ($candidates.Count -eq 0) {
            throw 'No .csproj found. Specify -Project, set [build].project in .turbo-plugin/config.toml, or run inside a project root.'
        }
        if ($candidates.Count -gt 1) {
            $paths = ($candidates | ForEach-Object { $_.FullName }) -join "`n  "
            throw "Multiple .csproj files found:`n  $paths`nSpecify -Project or set [build].project in .turbo-plugin/config.toml."
        }
        return $candidates[0].FullName
    }
    $projectFile = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $projectPathRel
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Project file does not exist: $projectFile"
    }
    return $projectFile
}

# Minimal TOML reader sufficient for the keys turbo-plugin emits in .turbo-plugin/config.toml.
# Returns a hashtable keyed by section name, where each value is a hashtable of key→value.
# Supports: [section] headers, `key = "string"`, `key = 'string'`, `key = <bool|int|float>`,
# `# comments`, and blank lines. Multi-line values, nested tables, and arrays are not handled.
#
# v1.0+ U1: $ConfigPath accepts either a single string or an array of paths. When given
# multiple paths, files are read in order and merged with later paths overriding earlier
# ones at key-level (shallow per-section merge). Missing files are skipped silently.
# Typical use: pass @(config.toml, config.local.toml) so the local file (gitignored,
# machine-specific) overrides the canonical version-controlled file.
function Read-TurboPluginConfig {
    param(
        [Parameter(Mandatory = $true)]$ConfigPath
    )
    $result = @{}
    # Normalize input to array of paths so callers can pass a single string or an array.
    $paths = @()
    if ($ConfigPath -is [System.Array]) {
        $paths = @($ConfigPath)
    } else {
        $paths = @($ConfigPath)
    }

    foreach ($pathItem in $paths) {
        if ([string]::IsNullOrWhiteSpace($pathItem)) { continue }
        if (-not (Test-Path -LiteralPath $pathItem -PathType Leaf)) { continue }
        $currentSection = ''
        $lines = Get-Content -LiteralPath $pathItem
        foreach ($raw in $lines) {
            $line = $raw -replace '^\s+|\s+$', ''
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith('#')) { continue }
            if ($line -match '^\[([^\]]+)\]$') {
                $currentSection = $Matches[1].Trim()
                if (-not $result.ContainsKey($currentSection)) {
                    $result[$currentSection] = @{}
                }
                continue
            }
            if ($line -match '^([A-Za-z0-9_\-]+)\s*=\s*(.+)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                # strip trailing inline comment (only if not inside a quoted string)
                if ($val -notmatch '^"' -and $val -notmatch "^'") {
                    if ($val -match '^(.*?)\s+#') {
                        $val = $Matches[1].Trim()
                    }
                }
                if ($val -match '^"(.*)"$') { $val = $Matches[1] }
                elseif ($val -match "^'(.*)'$") { $val = $Matches[1] }
                elseif ($val -eq 'true') { $val = $true }
                elseif ($val -eq 'false') { $val = $false }
                elseif ($val -match '^-?\d+$') { $val = [int]$val }
                elseif ($val -match '^-?\d+\.\d+$') { $val = [double]$val }
                if ([string]::IsNullOrEmpty($currentSection)) {
                    if (-not $result.ContainsKey('')) { $result[''] = @{} }
                    $result[''][$key] = $val
                } else {
                    # In-place overwrite — later paths override earlier ones at key level.
                    $result[$currentSection][$key] = $val
                }
            }
        }
    }
    return $result
}

# Lookup chain: CLI arg → config.toml → built-in default
#   1. $CliValue (already-resolved CLI argument; pass $null if not provided)
#   2. config.toml under repo-root .turbo-plugin/config.toml, $Section.$Key
#   3. $Default (built-in default; pass $null to skip)
function Resolve-ConfigValue {
    param(
        [string]$RepoRoot,
        [string]$Section,
        [string]$Key,
        $CliValue,
        $Default
    )
    if ($null -ne $CliValue -and -not ([string]::IsNullOrWhiteSpace([string]$CliValue))) {
        return $CliValue
    }
    # v1.0+ U1: read config.toml first then merge config.local.toml on top of it.
    # config.local.toml is gitignored (machine-specific tool paths etc.) and takes precedence.
    $configPath      = [System.IO.Path]::Combine($RepoRoot, '.turbo-plugin', 'config.toml')
    $configLocalPath = [System.IO.Path]::Combine($RepoRoot, '.turbo-plugin', 'config.local.toml')
    $cfg = Read-TurboPluginConfig -ConfigPath @($configPath, $configLocalPath)
    if ($cfg.ContainsKey($Section) -and $cfg[$Section].ContainsKey($Key)) {
        return $cfg[$Section][$Key]
    }
    if ($null -ne $Default) {
        return $Default
    }
    return $null
}
