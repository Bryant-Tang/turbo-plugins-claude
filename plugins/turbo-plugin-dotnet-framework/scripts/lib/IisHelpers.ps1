Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'Common.ps1'))

# Locate iisexpress.exe. Lookup order (strict cut, no env fallback):
#   1. .turbo-plugin/config.local.toml [tools] iis_express_path  (machine-specific, gitignored)
#   2. Standard install paths (Program Files (x86) / Program Files)
#   3. Throw, pointing at config.local.toml.
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
請修正該檔內的路徑,或整行移除改用自動偵測。
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

    # Step 3: throw, pointing at the one place a path can be pinned.
    throw @"
找不到 IIS Express。請安裝 IIS Express(不需要完整的 Visual Studio),
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

# --- IIS Express development certificate ------------------------------------
# Installing IIS Express drops this certificate (with its private key) into LocalMachine\My and
# pre-binds ports 44300-44399 to it in http.sys -- which is why VS projects pick an SSL port from
# that range and https works out of the box. What the installer does NOT do is make it TRUSTED:
# that is the one-time prompt Visual Studio shows, and it writes to CurrentUser\Root, i.e. per
# Windows user. So a fresh machine, a fresh user profile, or someone who never ran an https
# project in VS will get a browser certificate warning even though the site serves fine.

# The IIS Express development certificate, or $null. Prefers a FriendlyName match, falls back to a
# CN=localhost self-signed cert; among several, the one that expires last wins.
function Get-IisExpressDevCert {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $all = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)
        $named = @($all | Where-Object { $_.FriendlyName -match 'IIS Express' })
        # @() around the whole if-expression, not just its branches: assigning a single-element
        # array through an if-expression unwraps it to a scalar, and the .Count read below then
        # throws under StrictMode -- silently, because the catch turns it into "no certificate
        # found". A machine with exactly one certificate hits this every time.
        $candidates = @(if ($named.Count -gt 0) { $named } else { $all | Where-Object { $_.Subject -match 'CN=localhost' } })
        if ($candidates.Count -eq 0) { return $null }
        return (@($candidates | Sort-Object -Property NotAfter -Descending))[0]
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# Is $Certificate present in this user's trusted-root store? Compared by thumbprint, never by
# subject: several unrelated dev certs use CN=localhost (ASP.NET Core ships one too) and matching
# on the name would report the wrong one as trusted.
function Test-IisExpressCertTrusted {
    param($Certificate)
    if ($null -eq $Certificate) { return $false }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $hit = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint })
        return ($hit.Count -gt 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# Parse the IIS Express wiring out of a .csproj. Every input Visual Studio uses to synthesise its
# <site> entry lives in these elements, which is what lets New-ApphostConfig reproduce VS's output
# instead of requiring the user to open VS once just to generate a config file.
# Returns: Url / Uri / Port / SslPort ('' when absent) / ClassicPipeline (bool).
# Throws when none of the three port-bearing elements is present -- deliberately, because Visual
# Studio can be configured to keep them in the (gitignored) .csproj.user instead, and silently
# guessing a port would produce a site that binds the wrong thing.
function Get-IisProjectBinding {
    param([Parameter(Mandatory = $true)][string]$ProjectFile)

    $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $projectContent = Get-Content -LiteralPath $ProjectFile -Raw

    $sslPort = ''
    $sslPortMatch = [regex]::Match($projectContent, '<IISExpressSSLPort>([^<]+)</IISExpressSSLPort>', $ic)
    if ($sslPortMatch.Success) { $sslPort = $sslPortMatch.Groups[1].Value.Trim() }

    $iisUrlMatch = [regex]::Match($projectContent, '<IISUrl>([^<]+)</IISUrl>', $ic)
    if ($iisUrlMatch.Success) {
        $iisUrl = $iisUrlMatch.Groups[1].Value.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($sslPort)) {
        # Fallback 1: IISExpressSSLPort → https://localhost:<port>
        $iisUrl = "https://localhost:$sslPort"
    } else {
        # Fallback 2: DevelopmentServerPort → http://localhost:<port>
        $devPortMatch = [regex]::Match($projectContent, '<DevelopmentServerPort>([^<]+)</DevelopmentServerPort>', $ic)
        if ($devPortMatch.Success) {
            $iisUrl = "http://localhost:$($devPortMatch.Groups[1].Value.Trim())"
        } else {
            throw "Missing <IISUrl>, <IISExpressSSLPort>, and <DevelopmentServerPort> in project file: $ProjectFile. Ensure VS has saved IIS settings; or add manually."
        }
    }

    $iisUri = $null
    if (-not [System.Uri]::TryCreate($iisUrl, [System.UriKind]::Absolute, [ref]$iisUri)) {
        throw "Invalid <IISUrl>: $iisUrl"
    }
    if ($iisUri.Port -lt 1 -or $iisUri.Port -gt 65535) {
        throw "Unable to parse port from <IISUrl>: $iisUrl"
    }

    $classic = [regex]::IsMatch($projectContent, '<IISExpressUseClassicPipelineMode>\s*true\s*</IISExpressUseClassicPipelineMode>', $ic)

    return [pscustomobject]@{
        Url             = $iisUrl
        Uri             = $iisUri
        Port            = $iisUri.Port.ToString()
        SslPort         = $sslPort
        ClassicPipeline = $classic
    }
}

function Resolve-IisSettings {
    param(
        [string]$Project = '',
        [string]$RepoRoot = ''
    )

    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot

    # run/stop resolve under the 'run' section (back-compat fallback to [build].project).
    # A .sln is rejected here (no -AllowSolution): IIS settings read csproj XML / project identity.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project
    $projectFile = $target.Path

    $binding = Get-IisProjectBinding -ProjectFile $projectFile
    $iisUrl = $binding.Url
    $iisUri = $binding.Uri

    $iisExpressPath = Find-IisExpressPath -RepoRoot $repoRoot

    # `git -C $repoRoot`, not a bare `git`: with -RepoRoot naming a sibling project the ambient cwd
    # is a different repository, and its toplevel would produce a wrong relative path -> a wrong
    # identity hash -> a runtime site name that stop / orphan-cleanup cannot match back.
    $topLevel = (& git -C $repoRoot rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($topLevel)) { throw 'Not inside a git repository.' }
    $topLevel = Get-NormalizedAbsolutePath -Path $topLevel
    $projectAbs = Get-NormalizedAbsolutePath -Path $projectFile
    $relPath = (Get-RelativePathSafe -From $topLevel -To $projectAbs) -replace '\\', '/'
    $identityHash = Get-ProjectIdentityHash -RepoPath $topLevel -CsprojRelPath $relPath
    # Two site names, deliberately different (see Start-Iis for the full rationale):
    #   CanonicalSiteName -- the name as it appears in the SHARED, version-controlled
    #     .turbo-plugin/applicationhost.config. It is the csproj stem, which is exactly what
    #     Visual Studio writes, so a config copied from VS works unchanged and carries nothing
    #     machine-specific into git.
    #   IisConfigSiteName -- the RUNTIME name, carrying the project-identity hash. It only ever
    #     appears in the per-launch temp config and on the iisexpress command line, which is where
    #     Stop-Iis / Remove-OrphanIis read it back from.
    $canonicalSiteName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile)
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
        CanonicalSiteName = $canonicalSiteName
        IdentityHash = $identityHash
        # The parsed csproj IIS wiring, carried through so Start-Iis can generate a missing
        # applicationhost.config on the spot without re-reading and re-parsing the project file.
        Binding = $binding
    }
}

# Remove-PerLaunchTempFile lives in Common.ps1 (dot-sourced above). It started here, but the
# console launcher needs the identical retry and has no business loading IIS helpers -- and the
# problem it solves (a just-killed process still holding its redirected stdout/stderr) is not an
# IIS concern at all.
