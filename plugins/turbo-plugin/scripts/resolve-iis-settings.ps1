Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

function Find-IisExpressPath {
    if (-not [string]::IsNullOrWhiteSpace($env:TURBO_PLUGIN_IIS_EXPRESS_PATH)) {
        return Get-NormalizedAbsolutePath -Path $env:TURBO_PLUGIN_IIS_EXPRESS_PATH
    }
    $candidates = @(
        "${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe",
        "${env:ProgramFiles}\IIS Express\iisexpress.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            return $c
        }
    }
    return $null
}

function Find-ApplicationhostTarget {
    param([string]$RepoRoot, [string]$ProjectFile)
    $slnFile = @(Get-ChildItem -LiteralPath $RepoRoot -Filter '*.sln' -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $slnFile) { return $null }
    $slnStem = [System.IO.Path]::GetFileNameWithoutExtension($slnFile.FullName)
    return Join-Path $RepoRoot ".vs/$slnStem/config/applicationhost.config"
}

function Resolve-IisSettings {
    param(
        [string]$Project = ''
    )

    $repoRoot = (Get-Location).Path

    $projectFile = Find-SingleCsproj -RepoRoot $repoRoot -CliProjectValue $Project

    $projectContent = Get-Content -LiteralPath $projectFile -Raw
    $iisUrlMatch = [regex]::Match($projectContent, '<IISUrl>([^<]+)</IISUrl>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $iisUrlMatch.Success) {
        throw "Missing <IISUrl> in project file: $projectFile. Ensure VS has saved IIS settings; or add manually."
    }
    $iisUrl = $iisUrlMatch.Groups[1].Value.Trim()
    $iisUri = $null
    if (-not [System.Uri]::TryCreate($iisUrl, [System.UriKind]::Absolute, [ref]$iisUri)) {
        throw "Invalid <IISUrl>: $iisUrl"
    }
    if ($iisUri.Port -lt 1 -or $iisUri.Port -gt 65535) {
        throw "Unable to parse port from <IISUrl>: $iisUrl"
    }

    $iisExpressPath = Find-IisExpressPath

    $topLevel = (& git rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($topLevel)) { throw 'Not inside a git repository.' }
    $topLevel = Get-NormalizedAbsolutePath -Path $topLevel
    $projectAbs = Get-NormalizedAbsolutePath -Path $projectFile
    $relPath = (Get-RelativePathSafe -From $topLevel -To $projectAbs) -replace '\\', '/'
    $identityHash = Get-ProjectIdentityHash -RepoPath $topLevel -CsprojRelPath $relPath
    $siteName = Format-IisExpressSiteName -CsprojPath $projectFile -IdentityHash $identityHash

    $apphostTarget = Find-ApplicationhostTarget -RepoRoot $repoRoot -ProjectFile $projectFile

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        ProjectFile = $projectFile
        IisUrl = $iisUrl
        IisScheme = $iisUri.Scheme
        IisPort = $iisUri.Port.ToString()
        SiteRoot = [System.IO.Path]::GetDirectoryName($projectFile)
        IisExpressPath = $iisExpressPath
        ApplicationhostConfigFile = $apphostTarget
        IisConfigSiteName = $siteName
        IdentityHash = $identityHash
    }
}
