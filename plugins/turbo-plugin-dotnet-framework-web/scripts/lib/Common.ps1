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

