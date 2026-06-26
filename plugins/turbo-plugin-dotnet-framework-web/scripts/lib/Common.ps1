# turbo-plugin-dotnet-framework-web concern helpers (MSBuild / csproj / IIS site name /
# project-identity). Core (universal helpers + the UTF-8 encoding
# preamble + StrictMode/EAP) is dot-sourced first; this concern lib must NOT reset the
# encoding Core establishes (KTD2a). All scripts source THIS file, which transitively pulls
# in Core.ps1 from the same lib/ directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'Core.ps1'))




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
# $env:TURBO_PLUGIN_MSBUILD_PATH is deliberately NOT read — turbo-plugin is the
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

# Resolve the EXPLICIT build/run/publish target (a .csproj or .sln) for an operation.
# "Give agent the VS 2022": no auto-detection — the agent (via the SKILL) decides which
# project to act on and passes it explicitly, or it comes from the operation's config
# memory. There is deliberately no repo scan and no "multiple found" throw; an ambiguous
# repo is the agent's call to make, not the script's.
#
# Resolution chain:
#   CLI -CliProjectValue  ->  [<Section>].project  ->  (run/stop only) [build].project  ->  clear error
#
# Args:
#   -RepoRoot        absolute repo root used for config lookup + relative-path resolution.
#   -Section         'build' | 'run' | 'publish' — selects the config key and the back-compat fallback.
#                    run/stop both resolve under 'run' (run/stop share one target).
#   -CliProjectValue an explicit CLI target (pass '' / $null when not provided).
#   -AllowSolution   when set, a .sln target is allowed (build only). Otherwise a .sln throws
#                    so run/stop/publish (which read csproj XML / project identity) fail loudly.
#   -AllowMissing    when set, returns $null instead of throwing when nothing resolves. Used by
#                    tp-cleanup-orphan-iis's no-project path to branch to generic site matching.
#
# Returns: [pscustomobject] @{ Path = <absolute path>; Type = 'csproj' | 'sln' }  (or $null with -AllowMissing).
function Resolve-ProjectTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet('build', 'run', 'publish')][string]$Section,
        [string]$CliProjectValue = '',
        [switch]$AllowSolution,
        [switch]$AllowMissing
    )
    $projectPathRel = Resolve-ConfigValue -RepoRoot $RepoRoot -Section $Section -Key 'project' -CliValue $CliProjectValue -Default $null
    # Back-compat: run/stop fall back to [build].project when [run].project is unset, so users
    # who configured only [build].project before the per-operation key split keep working.
    if ([string]::IsNullOrWhiteSpace($projectPathRel) -and $Section -eq 'run') {
        $projectPathRel = Resolve-ConfigValue -RepoRoot $RepoRoot -Section 'build' -Key 'project' -CliValue $null -Default $null
    }
    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        if ($AllowMissing) { return $null }
        $hint = switch ($Section) {
            'build'   { 'Specify -Project (a .csproj or .sln) or set [build].project in .turbo-plugin/config.toml.' }
            'run'     { 'Specify -Project (a .csproj) or set [run].project (falls back to [build].project) in .turbo-plugin/config.toml.' }
            'publish' { 'Specify -Project (a .csproj) or set [publish].project in .turbo-plugin/config.toml.' }
        }
        throw "No $Section target resolved. $hint"
    }
    $projectFile = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $projectPathRel
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Project file does not exist: $projectFile"
    }
    $isSolution = ([System.IO.Path]::GetExtension($projectFile)).ToLower() -eq '.sln'
    if ($isSolution -and -not $AllowSolution) {
        throw "A .sln target is only valid for build. The $Section operation needs a .csproj, got: $projectFile"
    }
    $type = if ($isSolution) { 'sln' } else { 'csproj' }
    return [pscustomobject]@{ Path = $projectFile; Type = $type }
}

# Resolve a pubxml <PublishUrl> into the two display lines tp-publish prints (U10 / KTD8 / R15):
# the raw absolute path and a file:/// URL. For a FileSystem publish a relative PublishUrl is
# resolved against the project directory, the trailing backslash is trimmed, and the file:/// URL
# is the same path with backslashes flipped to forward slashes. For non-FileSystem methods (FTP,
# etc.) there is no local path, so both values are the URL as-is. Neither value carries trailing
# punctuation — the caller emits them verbatim for the agent to relay (no prose, no period), so the
# terminal renders them as clickable. Factored out of Publish-Web.ps1 so the two-line format is
# unit-testable without running MSBuild.
# Returns @{ Resolved = <raw path/url>; DisplayPath = <file:/// or url>; IsFileSystem = <bool> }.
function Get-PublishOutputLines {
    param(
        [Parameter(Mandatory = $true)][string]$PublishUrlRaw,
        [string]$Method = 'FileSystem',
        [string]$ProjectDir = ''
    )
    $isFileSystem = ($Method -eq 'FileSystem')
    if ($isFileSystem) {
        if ([System.IO.Path]::IsPathRooted($PublishUrlRaw)) {
            $resolved = [System.IO.Path]::GetFullPath($PublishUrlRaw)
        } else {
            $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($ProjectDir, $PublishUrlRaw))
        }
        $resolved = $resolved.TrimEnd('\')
        $displayPath = 'file:///' + ($resolved -replace '\\', '/')
    } else {
        $resolved = $PublishUrlRaw
        $displayPath = $PublishUrlRaw
    }
    return @{ Resolved = $resolved; DisplayPath = $displayPath; IsFileSystem = $isFileSystem }
}

# ─── per-operation result-template family (KTD5) ────────────────────────────────
# Each Format-*ResultLines helper returns the ORDERED display lines the executor prints under
# its result marker. The agent relays the block as the fixed per-operation result template:
# the inputs the agent chose + the target the executor actually RESOLVED (the 糾錯閘, so the
# user sees which project was acted on) + the produced artifacts (URL / publish path / site).
# Helpers compute/format lines only; the executor owns the marker line + Write-Output and the
# success/fail line (mirrors the existing Get-PublishOutputLines / PUBLISH_OUTPUT split). The
# template reports AGENT-SUPPLIED values, never MSBuild-evaluated effective values — a config
# the agent left unspecified is shown as MSBuild/solution-decided, not fabricated as Debug.

# Note for a configuration/platform the agent left unspecified (executor omits /p:, VS-aligned).
function Get-UnspecifiedConfigNote {
    return '未指定 (由 MSBuild / solution / Directory.Build.props 決定)'
}

function Format-BuildResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedTarget,
        [string]$Configuration = '',
        [string]$Platform = '',
        [switch]$IsSolution
    )
    $note = Get-UnspecifiedConfigNote
    $lines = @()
    $lines += if ($IsSolution) { "Target: $ResolvedTarget (整個 solution)" } else { "Target: $ResolvedTarget" }
    $lines += if ([string]::IsNullOrWhiteSpace($Configuration)) { "Configuration: $note" } else { "Configuration: $Configuration" }
    $lines += if ([string]::IsNullOrWhiteSpace($Platform)) { "Platform: $note" } else { "Platform: $Platform" }
    return $lines
}

function Format-RunResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedTarget,
        [Parameter(Mandatory = $true)][string]$WebUrl
    )
    # URL stays bare at end of line so the terminal keeps it clickable (no trailing punctuation).
    return @("Target: $ResolvedTarget", "URL: $WebUrl")
}

function Format-StopResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$Site,
        [string]$ResolvedTarget = ''
    )
    # "Site" is neutral (the site this stop targeted) so the template reads correctly whether a
    # process was actually stopped or none was found — the executor's own line conveys the action.
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($ResolvedTarget)) { $lines += "Target: $ResolvedTarget" }
    $lines += "Site: $Site"
    return $lines
}

