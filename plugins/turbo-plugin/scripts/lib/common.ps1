Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force UTF-8 for both PS host output and how PS interprets native command stdout/stderr.
# Without this, Windows PowerShell 5.1 uses the system code page (Big5 / CP950 on Chinese
# Windows), and output from native exes (svn / msbuild / iisexpress) that emit UTF-8
# bytes renders as mojibake (`?` chars or garbage). Affects every script that
# dot-sources common.ps1.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

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

function Resolve-RemoteWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$BranchName,
        [Parameter(Mandatory = $true)][string]$WorktreesDir
    )

    if ($BranchName -eq 'main') {
        return @{
            Name   = 'remote-main'
            Branch = 'remote/main'
            Path   = Join-Path $WorktreesDir 'remote-main'
        }
    }
    if ($BranchName -match '^test-(\d+)$') {
        $n = $Matches[1]
        return @{
            Name   = "remote-test-$n"
            Branch = "remote/test-$n"
            Path   = Join-Path $WorktreesDir "remote-test-$n"
        }
    }
    throw "Unsupported branch '$BranchName'. Only 'main' and 'test-<n>' branches can be synced from SVN."
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

# Locate MSBuild.exe by probing TURBO_PLUGIN_MSBUILD_PATH env first, then standard VS install paths.
# Throws if MSBuild cannot be found.
function Find-MSBuild {
    param([string]$RepoRoot = '')
    $envPath = $env:TURBO_PLUGIN_MSBUILD_PATH
    if (-not [string]::IsNullOrWhiteSpace($envPath)) {
        if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
            $envPath = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $envPath
        } else {
            $envPath = [System.IO.Path]::GetFullPath($envPath)
        }
        if (Test-Path -LiteralPath $envPath -PathType Leaf) {
            return $envPath
        }
        throw "TURBO_PLUGIN_MSBUILD_PATH points to a non-existent file: $envPath"
    }
    $candidates = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($found)) {
        throw "MSBuild not found. Set user-level env ``TURBO_PLUGIN_MSBUILD_PATH`` to MSBuild.exe absolute path (~/.claude/settings.json)."
    }
    return $found
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
# Module-scope guard so the schema_version mismatch warning is emitted only ONCE per process,
# regardless of how many Resolve-ConfigValue calls a single script makes.
$script:_TpSchemaWarned = $false

function Test-TurboPluginConfigSchema {
    param([Parameter(Mandatory = $true)]$Config)
    if ($script:_TpSchemaWarned) { return }
    if ($null -eq $Config) { return }
    # `schema_version` is a top-level key (no section), so it lives under the empty-string section.
    if (-not $Config.ContainsKey('')) { return }
    $topLevel = $Config['']
    if (-not $topLevel.ContainsKey('schema_version')) { return }
    $version = $topLevel['schema_version']
    # schema_version 2 adds [svn] force_bash. Versions 1 and 2 are both recognized.
    if ($version -ne 1 -and $version -ne 2) {
        [Console]::Error.WriteLine("turbo-plugin: .turbo-plugin/config.toml schema_version=$version is not recognized (expected 1 or 2); some settings may be ignored. Run /tp-setup option (c) to upgrade.")
        $script:_TpSchemaWarned = $true
    }
}

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
    Test-TurboPluginConfigSchema -Config $cfg
    if ($cfg.ContainsKey($Section) -and $cfg[$Section].ContainsKey($Key)) {
        return $cfg[$Section][$Key]
    }
    if ($null -ne $Default) {
        return $Default
    }
    return $null
}
