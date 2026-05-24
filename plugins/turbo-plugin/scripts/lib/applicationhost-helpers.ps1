Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# turbo-plugin IIS-specific helpers — .ps1-only.
# Bash callers (PostToolUse hook, stop-iis.sh, etc.) are themselves thin wrappers
# that re-enter PowerShell, so a .sh sibling is intentionally not provided.

function Find-ApplicationhostSite {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory = $true)][string]$SiteName
    )

    $sitesNode = $Xml.SelectSingleNode('/configuration/system.applicationHost/sites')
    if ($null -eq $sitesNode) {
        return $null
    }
    # Case-insensitive match: IIS Express treats site names case-insensitively, and
    # Format-IisExpressSiteName feeds from a relpath that's already lowercased by
    # Get-ProjectIdentityHash, so the only case variation comes from how VS writes
    # the site entry on first launch.
    foreach ($node in @($sitesNode.SelectNodes('site'))) {
        if ($node.GetAttribute('name') -eq $SiteName) {
            return $node
        }
    }
    return $null
}

# Private helper: atomic-write the XML document to ConfigPath via a unique temp file
# + Move-Item. Shared by Update-ApplicationhostConfig and Remove-ApplicationhostSite.
function Save-ApplicationhostConfigAtomically {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Xml,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )
    # Unique temp name avoids collision when concurrent EnterWorktree hooks fire
    # against the same applicationhost.config from sibling worktrees.
    $tempPath = "$ConfigPath.tmp.$PID.$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $false
    $settings.OmitXmlDeclaration = $false
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::None

    $writer = $null
    try {
        $writer = [System.Xml.XmlWriter]::Create($tempPath, $settings)
        $Xml.Save($writer)
    } finally {
        if ($null -ne $writer) {
            $writer.Close()
        }
    }

    try {
        Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
    } catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

# Atomically + idempotently update <virtualDirectory physicalPath> (and
# <application physicalPath> when present) for a named site in applicationhost.config.
# Returns @{ Updated = <bool>; SiteName = <string>; OldPaths = <array>; NewPath = <string> }.
function Update-ApplicationhostConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$SiteName,
        [Parameter(Mandatory = $true)][string]$NewPhysicalPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "applicationhost.config not found: $ConfigPath"
    }
    if ([string]::IsNullOrWhiteSpace($SiteName)) {
        throw 'Update-ApplicationhostConfig: SiteName is required.'
    }
    if ([string]::IsNullOrWhiteSpace($NewPhysicalPath)) {
        throw 'Update-ApplicationhostConfig: NewPhysicalPath is required.'
    }

    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($ConfigPath)

    $site = Find-ApplicationhostSite -Xml $xml -SiteName $SiteName
    if ($null -eq $site) {
        throw "Site '$SiteName' not found in applicationhost.config: $ConfigPath"
    }

    $oldPaths = @()
    $changed = $false

    foreach ($app in @($site.SelectNodes('application'))) {
        if ($app.HasAttribute('physicalPath')) {
            $cur = $app.GetAttribute('physicalPath')
            $oldPaths += $cur
            if ($cur -ne $NewPhysicalPath) {
                $app.SetAttribute('physicalPath', $NewPhysicalPath)
                $changed = $true
            }
        }
        foreach ($vd in @($app.SelectNodes('virtualDirectory'))) {
            if ($vd.HasAttribute('physicalPath')) {
                $cur = $vd.GetAttribute('physicalPath')
                $oldPaths += $cur
                if ($cur -ne $NewPhysicalPath) {
                    $vd.SetAttribute('physicalPath', $NewPhysicalPath)
                    $changed = $true
                }
            }
        }
    }

    if (-not $changed) {
        Write-Verbose "idempotent skip: applicationhost.config already correct"
        return @{
            Updated  = $false
            SiteName = $SiteName
            OldPaths = $oldPaths
            NewPath  = $NewPhysicalPath
            Reason   = 'physicalPath already matches; idempotent skip'
        }
    }

    Save-ApplicationhostConfigAtomically -Xml $xml -ConfigPath $ConfigPath

    return @{
        Updated  = $true
        SiteName = $SiteName
        OldPaths = $oldPaths
        NewPath  = $NewPhysicalPath
    }
}

# Atomically remove a named <site> node from applicationhost.config.
# Mirrors Update-ApplicationhostConfig's atomic temp-file + Move-Item pattern.
# Returns @{ Removed = <bool>; SiteName = <string>; Reason? = <string> }.
function Remove-ApplicationhostSite {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$SiteName
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "applicationhost.config not found: $ConfigPath"
    }
    if ([string]::IsNullOrWhiteSpace($SiteName)) {
        throw 'Remove-ApplicationhostSite: SiteName is required.'
    }

    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($ConfigPath)

    $site = Find-ApplicationhostSite -Xml $xml -SiteName $SiteName
    if ($null -eq $site) {
        return @{
            Removed  = $false
            SiteName = $SiteName
            Reason   = 'site not found; nothing to do'
        }
    }

    [void]$site.ParentNode.RemoveChild($site)

    Save-ApplicationhostConfigAtomically -Xml $xml -ConfigPath $ConfigPath

    return @{
        Removed  = $true
        SiteName = $SiteName
    }
}
