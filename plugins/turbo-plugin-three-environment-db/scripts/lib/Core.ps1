Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force UTF-8 for both PS host output and how PS interprets native command stdout/stderr.
# Without this, Windows PowerShell 5.1 uses the system code page (Big5 / CP950 on Chinese
# Windows), and output from native exes (svn / msbuild / iisexpress) that emit UTF-8
# bytes renders as mojibake (`?` chars or garbage). Affects every script that
# dot-sources Core.ps1 (directly, or transitively via a concern lib).
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
        throw "Git >= 2.31 is required (for --path-format=absolute). Detected: $raw. Please upgrade."
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

# Resolve an optional explicit repository root into the value handed to `git -C`.
#
# Omitted / empty returns '.', and `git -C .` is a no-op — so callers that pass nothing keep the
# historical behaviour exactly: git resolves the repository by walking up from whatever directory
# the process happens to be standing in. A supplied path is normalized (Git Bash /c/foo -> c:\foo)
# and asserted to be a real directory here, so a typo fails with a message naming the argument
# instead of surfacing later as git's own "cannot change to ..." mid-operation.
#
# Why this exists: deriving the target from the ambient cwd is how the marketplace repo once got a
# bridge bootstrapped into it. Every entry script now accepts -RepoRoot so the caller can name the
# repository outright, which is also what makes a multi-project workspace (several sibling repos
# under one session root) workable.
function Resolve-GitRoot {
    param([string]$RepoRoot = '')

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        return '.'
    }
    $normalized = Get-NormalizedAbsolutePath -Path $RepoRoot
    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        throw "Repo root not found (or not a directory): $RepoRoot"
    }
    return $normalized
}

function Get-MainWorktree {
    param([string]$RepoRoot = '')

    $root = Resolve-GitRoot -RepoRoot $RepoRoot
    # fix: wrap git call in try/catch to prevent PS 5.1 + StrictMode + EAP=Stop
    # from bubbling raw git "fatal: not a git repository" stderr as terminating NativeCommandError
    # before our self-emitted "Not inside a git repository." throw can fire.
    $commonDir = ''
    try {
        $commonDir = (& git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    } catch {
        $commonDir = ''
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir)) {
        throw 'Not inside a git repository.'
    }
    $parent = [System.IO.Path]::GetDirectoryName($commonDir)
    return Get-NormalizedAbsolutePath -Path $parent
}

function Test-IsMainWorktree {
    param([string]$RepoRoot = '')

    $root = Resolve-GitRoot -RepoRoot $RepoRoot
    $commonDir = (& git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    $topLevel = (& git -C $root rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir) -or [string]::IsNullOrWhiteSpace($topLevel)) {
        return $false
    }
    $parent = Get-NormalizedAbsolutePath -Path ([System.IO.Path]::GetDirectoryName($commonDir))
    $top = Get-NormalizedAbsolutePath -Path $topLevel
    return ($parent -eq $top)
}

function Test-IsSubmodule {
    param([string]$RepoRoot = '')

    $root = Resolve-GitRoot -RepoRoot $RepoRoot
    $super = (& git -C $root rev-parse --show-superproject-working-tree 2>$null | Out-String).Trim()
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
    # fix: define same-path return contract explicitly. MakeRelativeUri's
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

# Minimal TOML reader sufficient for the keys turbo-plugin emits in .turbo-plugin/config.toml.
# Returns a hashtable keyed by section name, where each value is a hashtable of key→value.
# Supports: [section] headers, `key = "string"`, `key = 'string'`, `key = <bool|int|float>`,
# `# comments`, and blank lines. Multi-line values, nested tables, and arrays are not handled.
#
# $ConfigPath accepts either a single string or an array of paths. When given
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
    $paths = @($ConfigPath)

    foreach ($pathItem in $paths) {
        if ([string]::IsNullOrWhiteSpace($pathItem)) { continue }
        if (-not (Test-Path -LiteralPath $pathItem -PathType Leaf)) { continue }
        $currentSection = ''
        # -Encoding UTF8 is load-bearing. Without it, Windows PowerShell 5.1's Get-Content decodes
        # using the system ANSI code page (cp950 on zh-TW Windows), and that does not merely garble
        # non-ASCII text -- it swallows line breaks. A `[section]` header then gets merged into the
        # preceding comment line, is skipped by the StartsWith('#') test below, and every key under
        # that section silently vanishes: no parse error, no warning, the config simply behaves as
        # if it had never been written. Measured on a real config: 9 lines read back as 5.
        # Hardcoding UTF8 is correct rather than a guess -- the TOML spec requires UTF-8 -- and it
        # handles both BOM and BOM-less files on 5.1.
        $lines = Get-Content -LiteralPath $pathItem -Encoding UTF8
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
    # read config.toml first then merge config.local.toml on top of it.
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
