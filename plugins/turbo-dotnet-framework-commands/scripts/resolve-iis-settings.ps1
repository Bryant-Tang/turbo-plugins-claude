Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoPath {
    param(
        [string]$RepoRoot,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    # Convert Git Bash Unix drive path: /c/foo/bar → C:\foo\bar
    if ($PathValue -match '^/([a-zA-Z])/(.*)$') {
        $PathValue = "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    $PathValue = $PathValue -replace '^\.[\\/]', ''
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

function Resolve-IisSettings {
    param([string]$ScriptDir = $PSScriptRoot)

    $repoRoot = (Get-Location).Path
    $projectPathRel = $env:BUILD_PROJECT_PATH
    $iisExpressPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $env:RUN_IIS_EXPRESS_PATH
    $applicationHostConfigValue = $env:RUN_IIS_APPLICATIONHOST_CONFIG_PATH

    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        throw 'Missing BUILD_PROJECT_PATH environment variable'
    }

    $projectFile = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $projectPathRel

    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Configured project file does not exist: $projectFile"
    }

    $projectContent = Get-Content -LiteralPath $projectFile -Raw
    $iisUrlMatch = [regex]::Match($projectContent, '<IISUrl>([^<]+)</IISUrl>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $iisUrl = $null

    if ($iisUrlMatch.Success) {
        $iisUrl = $iisUrlMatch.Groups[1].Value.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($iisUrl)) {
        throw "Missing IISUrl in project file: $projectFile"
    }

    $iisUri = $null

    if (-not [System.Uri]::TryCreate($iisUrl, [System.UriKind]::Absolute, [ref]$iisUri)) {
        throw "Invalid IISUrl in project file: $iisUrl"
    }

    if ([string]::IsNullOrWhiteSpace($iisUri.Scheme)) {
        throw "Unable to parse scheme from IISUrl in project file: $iisUrl"
    }

    if ($iisUri.Port -lt 1 -or $iisUri.Port -gt 65535) {
        throw "Unable to parse port from IISUrl in project file: $iisUrl"
    }

    $siteRoot = Split-Path -Parent $projectFile
    $applicationhostConfigFile = $null
    $iisConfigSiteName = $null

    if (-not [string]::IsNullOrWhiteSpace($applicationHostConfigValue)) {
        $applicationhostConfigFile = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $applicationHostConfigValue

        if (-not (Test-Path -LiteralPath $applicationhostConfigFile -PathType Leaf)) {
            throw "Configured applicationhost.config does not exist: $applicationhostConfigFile"
        }

        [xml]$applicationhostXml = Get-Content -LiteralPath $applicationhostConfigFile -Raw
        $projectDirName = Split-Path -Leaf $siteRoot
        $siteNodes = @($applicationhostXml.SelectNodes('//site'))
        $matchedSite = $siteNodes | Where-Object { [string]$_.name -eq $projectDirName } | Select-Object -First 1

        if ($null -eq $matchedSite) {
            foreach ($site in $siteNodes) {
                $siteName = [string]$site.name

                foreach ($binding in @($site.bindings.binding)) {
                    $protocol = [string]$binding.protocol
                    $bindingInformation = [string]$binding.bindingInformation

                    if ([string]::IsNullOrWhiteSpace($protocol) -or [string]::IsNullOrWhiteSpace($bindingInformation)) {
                        continue
                    }

                    $bindingParts = $bindingInformation.Split(':')

                    if ($bindingParts.Length -lt 2) {
                        continue
                    }

                    $bindingPort = $bindingParts[1]

                    if ($protocol.Equals($iisUri.Scheme, [System.StringComparison]::OrdinalIgnoreCase) -and $bindingPort -eq $iisUri.Port.ToString()) {
                        $iisConfigSiteName = $siteName
                        break
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace($iisConfigSiteName)) {
                    break
                }
            }
        }
        else {
            $iisConfigSiteName = [string]$matchedSite.name
        }

        if ([string]::IsNullOrWhiteSpace($iisConfigSiteName)) {
            throw "Unable to find a matching IIS site in applicationhost.config: $applicationhostConfigFile`nExpected a site matching project path, IISUrl port, or project folder name: $projectDirName"
        }
    }

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        ProjectFile = $projectFile
        IisUrl = $iisUrl
        IisScheme = $iisUri.Scheme
        IisPort = $iisUri.Port.ToString()
        SiteRoot = $siteRoot
        IisExpressPath = $iisExpressPath
        ApplicationhostConfigFile = $applicationhostConfigFile
        IisConfigSiteName = $iisConfigSiteName
    }
}
