Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'Common.ps1'))

# Locate iisexpress.exe. Lookup order (strict cut, no env fallback):
#   1. .turbo-plugin/config.local.toml [tools] iis_express_path  (machine-specific, gitignored)
#   2. Standard install paths (Program Files (x86) / Program Files)
#   3. Throw with /tp-setup guidance.
# $env:TURBO_PLUGIN_IIS_EXPRESS_PATH is deliberately NOT read — this is the first release;
# no legacy users to migrate. If the env var happens to be set externally, it is ignored.
function Find-IisExpressPath {
    param([string]$RepoRoot = '')

    # Step 1: config.local.toml [tools] iis_express_path
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $configured = Resolve-ConfigValue -RepoRoot $RepoRoot -Section 'tools' -Key 'iis_express_path' -CliValue $null -Default $null
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            $resolved = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $configured
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return $resolved
            }
            throw @"
IIS Express 路徑設定指向不存在的檔案: $resolved
(來源: .turbo-plugin/config.local.toml [tools] iis_express_path)
請跑 /tp-setup 重新偵測,或手動修正 .turbo-plugin/config.local.toml 內的路徑。
"@
        }
    }

    # Step 2: probe standard install paths
    $candidates = @(
        "${env:ProgramFiles(x86)}\IIS Express\iisexpress.exe",
        "${env:ProgramFiles}\IIS Express\iisexpress.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            return $c
        }
    }

    # Step 3: throw with /tp-setup guidance
    throw @"
IIS Express 路徑未設定且找不到標準安裝。請跑 /tp-setup 互動填入 IIS Express 路徑,
或手動在 .turbo-plugin/config.local.toml 加上:
  [tools]
  iis_express_path = "C:/Program Files/IIS Express/iisexpress.exe"
"@
}

# Decide whether a running iisexpress.exe /site:<name> belongs to the given project's
# stem-hash family (i.e. is a candidate orphan for that project).
#
# Match rule: the site name must be exactly "<csprojStem>-<8 hex>" where <csprojStem> is
# treated as a LITERAL (regex-escaped). Escaping is the load-bearing protection: a stem
# containing regex metacharacters (e.g. "My.Test") must NOT match a near-miss site name
# (e.g. "MyXTest-deadbeef"); without [regex]::Escape the '.' would match the 'X' and we
# would mistake an unrelated site for an orphan and kill it.
#
# Returns $true when $SiteName is in the stem-hash family of $CsprojStem, else $false.
function Test-OrphanSiteNameMatch {
    param(
        [Parameter(Mandatory = $true)][string]$CsprojStem,
        [Parameter(Mandatory = $true)][string]$SiteName
    )
    $stemPattern = "^$([regex]::Escape($CsprojStem))-[0-9a-f]{8}$"
    return ($SiteName -match $stemPattern)
}

# Decide whether an iisexpress.exe /site:<name> looks like ANY turbo-plugin site, regardless
# of which csproj it belongs to. The turbo-plugin site-name shape is "<stem>-<8 hex>"; the
# 8-hex identity-hash suffix is the load-bearing discriminator that keeps non-turbo-plugin
# IIS Express sites out of the match. Used by tp-cleanup-orphan-iis's NO-PROJECT path, where
# no single csproj stem is known (Test-OrphanSiteNameMatch pins a specific stem; this does not).
#
# Returns $true when $SiteName matches the generic turbo-plugin family, else $false.
function Test-TurboPluginSiteName {
    param(
        [Parameter(Mandatory = $true)][string]$SiteName
    )
    return ($SiteName -match '^.+-[0-9a-f]{8}$')
}

function Find-ApplicationhostTarget {
    param([string]$RepoRoot, [string]$ProjectFile)
    # canonical applicationhost.config lives at .turbo-plugin/applicationhost.config
    # (committed to git, cross-worktree shared, never mutated at runtime). start-iis renders a
    # per-launch temp file with physicalPath substituted to the current worktree's csproj dir.
    # VS UI manages .vs/<sln>/config/applicationhost.config independently — turbo-plugin no
    # longer reads or writes that file.
    $canonical = Join-Path $RepoRoot '.turbo-plugin/applicationhost.config'
    return $canonical
}

function Resolve-IisSettings {
    param(
        [string]$Project = ''
    )

    $repoRoot = (Get-Location).Path

    # run/stop resolve under the 'run' section (back-compat fallback to [build].project).
    # A .sln is rejected here (no -AllowSolution): IIS settings read csproj XML / project identity.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project
    $projectFile = $target.Path

    $projectContent = Get-Content -LiteralPath $projectFile -Raw
    $iisUrlMatch = [regex]::Match($projectContent, '<IISUrl>([^<]+)</IISUrl>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($iisUrlMatch.Success) {
        $iisUrl = $iisUrlMatch.Groups[1].Value.Trim()
    } else {
        # Fallback 1: IISExpressSSLPort → https://localhost:<port>
        $sslPortMatch = [regex]::Match($projectContent, '<IISExpressSSLPort>([^<]+)</IISExpressSSLPort>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($sslPortMatch.Success) {
            $iisUrl = "https://localhost:$($sslPortMatch.Groups[1].Value.Trim())"
        } else {
            # Fallback 2: DevelopmentServerPort → http://localhost:<port>
            $devPortMatch = [regex]::Match($projectContent, '<DevelopmentServerPort>([^<]+)</DevelopmentServerPort>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($devPortMatch.Success) {
                $iisUrl = "http://localhost:$($devPortMatch.Groups[1].Value.Trim())"
            } else {
                throw "Missing <IISUrl>, <IISExpressSSLPort>, and <DevelopmentServerPort> in project file: $projectFile. Ensure VS has saved IIS settings; or add manually."
            }
        }
    }
    $iisUri = $null
    if (-not [System.Uri]::TryCreate($iisUrl, [System.UriKind]::Absolute, [ref]$iisUri)) {
        throw "Invalid <IISUrl>: $iisUrl"
    }
    if ($iisUri.Port -lt 1 -or $iisUri.Port -gt 65535) {
        throw "Unable to parse port from <IISUrl>: $iisUrl"
    }

    $iisExpressPath = Find-IisExpressPath -RepoRoot $repoRoot

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
