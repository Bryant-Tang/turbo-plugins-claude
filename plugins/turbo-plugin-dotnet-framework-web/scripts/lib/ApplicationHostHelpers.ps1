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
        if ($node.GetAttribute('name') -ieq $SiteName) {
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

# The applicationhost.config template to generate from: IIS Express's OWN default config, which
# ships next to iisexpress.exe at <install>\AppServer\applicationhost.config.
#
# This must not be a skeleton we write ourselves. A working applicationhost.config is ~1000 lines:
# the <configSections> declarations alone are load-bearing (without the one for
# system.applicationHost, IIS Express refuses the file outright), and beyond that the whole
# <system.webServer> block of globalModules / modules / handlers / isapiFilters is what actually
# makes it serve ASP.NET. A hand-written 40-line file parses as XML and is completely unusable --
# which is exactly what shipped before, because nothing in the test suite ever asked IIS Express
# whether it could load the result.
#
# The shipped file is safe to start from: it contains no machine-specific absolute paths, only
# %IIS_BIN% / %IIS_USER_HOME% / %AppData% / %windir% style variables that IIS Express expands at
# runtime, and it already defines Clr4IntegratedAppPool / Clr4ClassicAppPool -- the two pools the
# generated <site> references. This is also what Visual Studio does for its own per-solution config.
function Get-ApplicationhostTemplatePath {
    param([Parameter(Mandatory = $true)][string]$IisExpressPath)

    $installDir = [System.IO.Path]::GetDirectoryName($IisExpressPath)
    $template = [System.IO.Path]::Combine($installDir, 'AppServer', 'applicationhost.config')
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        throw @"
找不到 IIS Express 內建的 applicationhost.config 範本:$template
產生設定檔需要它(自行拼一份是行不通的:少了 <configSections> 與 <system.webServer> 的模組宣告,
IIS Express 會直接拒絕載入)。請確認 IIS Express 安裝完整,必要時重新安裝。
"@
    }
    return $template
}

# Ensure an applicationhost.config exists at $ConfigPath and carries a <site> for one project.
#
# This is what lets the config be created LAZILY, on the first run, instead of by a separate setup
# step: every input Visual Studio uses to synthesise a <site> already lives in the .csproj, so
# there is nothing to ask the user. Visual Studio behaves the same way -- its config appears the
# first time you run a project, not when you install VS.
#
# The site is written in CANONICAL shape: the plain project name plus a physicalPath placeholder --
# nothing machine-specific, safe to commit and share. The identity-hashed runtime name and the real
# worktree path are applied by Start-Iis to the per-launch temp copy only.
#
# A usable existing config is never rebuilt: a missing site is APPENDED to it, so a repo with
# several web projects accumulates one <site> per project the way Visual Studio's shared config
# does, and a site that is already there (possibly hand-tuned, or copied from VS) is left untouched.
# The one exception is a config that IIS Express could never load at all -- see the self-heal below.
#
# $Binding is a Get-IisProjectBinding result (Uri / Port / SslPort / ClassicPipeline). It is passed
# in rather than parsed here so this file stays free of any dependency on IisHelpers.ps1.
#
# Returns @{ ConfigCreated; ConfigRebuilt; SiteAdded = <bool>; SiteName; AppPool; ConfigPath }.
function Initialize-ApplicationhostSite {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$SiteName,
        [Parameter(Mandatory = $true)]$Binding
    )

    $created = $false
    $rebuilt = $false
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $xml.Load($ConfigPath)

        # Self-heal a config that can never work. <configSections> is the one part IIS Express
        # refuses to run without ("cannot read configuration section 'system.applicationHost'
        # because it is missing a section declaration"), so its absence means the file was written
        # by something that did not start from a real applicationhost.config -- including an early
        # version of this very script. Rebuild from the template and carry the existing <site>
        # entries over, rather than making the user work out that the file has to be deleted.
        if ($null -eq $xml.SelectSingleNode('/configuration/configSections')) {
            if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
                throw "找不到 applicationhost.config 範本:$TemplatePath"
            }
            $salvagedSites = @($xml.SelectNodes('/configuration/system.applicationHost/sites/site'))
            $fresh = New-Object System.Xml.XmlDocument
            $fresh.PreserveWhitespace = $true
            $fresh.Load($TemplatePath)
            $freshSites = $fresh.SelectSingleNode('/configuration/system.applicationHost/sites')
            if ($null -eq $freshSites) {
                throw "applicationhost.config 範本缺少 <sites> 節點:$TemplatePath"
            }
            foreach ($stockSite in @($freshSites.SelectNodes('site'))) {
                [void]$stockSite.ParentNode.RemoveChild($stockSite)
            }
            foreach ($old in $salvagedSites) {
                [void]$freshSites.AppendChild($fresh.ImportNode($old, $true))
            }
            $xml = $fresh
            $rebuilt = $true
        }
    } else {
        if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
            throw "找不到 applicationhost.config 範本:$TemplatePath"
        }
        $xml.Load($TemplatePath)
        $created = $true
    }

    $sitesNode = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
    if ($null -eq $sitesNode) {
        $offender = if ($created) { $TemplatePath } else { $ConfigPath }
        throw "applicationhost.config 缺少 <sites> 節點,無法加入站台:$offender"
    }

    # Starting from IIS Express's own config means inheriting its demo site ("Development Web Site"
    # on :8080, serving an empty directory). Drop it on creation so the file this repo shares only
    # ever lists real projects -- and so its port never collides with anything. Only on creation:
    # an existing config's sites belong to this repo and are never touched.
    if ($created) {
        foreach ($stockSite in @($sitesNode.SelectNodes('site'))) {
            [void]$stockSite.ParentNode.RemoveChild($stockSite)
        }
    }

    $appPool = if ($Binding.ClassicPipeline) { 'Clr4ClassicAppPool' } else { 'Clr4IntegratedAppPool' }

    if ($null -ne (Find-ApplicationhostSite -Xml $xml -SiteName $SiteName)) {
        # A rebuild still has to be written out even though no site was added -- the whole point is
        # that the file on disk was unusable.
        if ($rebuilt) { Save-ApplicationhostConfigAtomically -Xml $xml -ConfigPath $ConfigPath }
        return @{
            ConfigCreated = $false
            ConfigRebuilt = $rebuilt
            SiteAdded     = $false
            SiteName      = $SiteName
            AppPool       = $appPool
            ConfigPath    = $ConfigPath
        }
    }

    # Site ids must be unique within the file. Take the next id above whatever is already present
    # rather than a hardcoded 1, so a second project appended later does not collide with the first.
    $maxId = 0
    foreach ($existing in @($sitesNode.SelectNodes('site'))) {
        $idValue = 0
        if ([int]::TryParse($existing.GetAttribute('id'), [ref]$idValue) -and $idValue -gt $maxId) {
            $maxId = $idValue
        }
    }

    $siteEl = $xml.CreateElement('site')
    $siteEl.SetAttribute('name', $SiteName)
    $siteEl.SetAttribute('id', ($maxId + 1).ToString())

    $appEl = $xml.CreateElement('application')
    $appEl.SetAttribute('path', '/')
    $appEl.SetAttribute('applicationPool', $appPool)
    $vdirEl = $xml.CreateElement('virtualDirectory')
    $vdirEl.SetAttribute('path', '/')
    # Placeholder, not a real path: Start-Iis substitutes the current worktree at launch time, so
    # the committed file stays valid on every machine and in every worktree.
    $vdirEl.SetAttribute('physicalPath', '__TURBO_PLUGIN_PHYSICAL_PATH__')
    $null = $appEl.AppendChild($vdirEl)
    $null = $siteEl.AppendChild($appEl)

    $bindingsEl = $xml.CreateElement('bindings')
    $primary = $xml.CreateElement('binding')
    $primary.SetAttribute('protocol', $Binding.Uri.Scheme)
    $primary.SetAttribute('bindingInformation', "*:$($Binding.Port):localhost")
    $null = $bindingsEl.AppendChild($primary)
    if ((-not [string]::IsNullOrWhiteSpace($Binding.SslPort)) -and ($Binding.SslPort -ne $Binding.Port)) {
        $https = $xml.CreateElement('binding')
        $https.SetAttribute('protocol', 'https')
        $https.SetAttribute('bindingInformation', "*:$($Binding.SslPort):localhost")
        $null = $bindingsEl.AppendChild($https)
    }
    $null = $siteEl.AppendChild($bindingsEl)
    $null = $sitesNode.AppendChild($siteEl)

    $configDir = [System.IO.Path]::GetDirectoryName($ConfigPath)
    if ((-not [string]::IsNullOrWhiteSpace($configDir)) -and (-not (Test-Path -LiteralPath $configDir -PathType Container))) {
        $null = New-Item -ItemType Directory -Path $configDir -Force
    }
    Save-ApplicationhostConfigAtomically -Xml $xml -ConfigPath $ConfigPath

    return @{
        ConfigCreated = $created
        ConfigRebuilt = $rebuilt
        SiteAdded     = $true
        SiteName      = $SiteName
        AppPool       = $appPool
        ConfigPath    = $ConfigPath
    }
}

# Atomically + idempotently update <virtualDirectory physicalPath> (and
# <application physicalPath> when present) for a named site in applicationhost.config.
# Returns @{ Updated = <bool>; SiteName = <string>; OldPaths = <array>; NewPath = <string> }.
# Rename a <site> entry in place. This is what keeps the project-identity hash OUT of the
# shared, version-controlled canonical config: the canonical file carries the plain csproj-stem
# name (exactly what Visual Studio writes), and Start-Iis renames it to the hashed runtime name
# only in the per-launch temp copy. The running iisexpress therefore still advertises the identity
# on its command line -- which is how Stop-Iis and Remove-OrphanIis find it -- while nothing
# machine-specific ever reaches git.
# Returns $true when a rename happened, $false when FromName was not found. Renaming onto a name
# that already exists is refused: two sites sharing a name is not a state IIS Express can serve.
function Rename-ApplicationhostSite {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$FromName,
        [Parameter(Mandatory = $true)][string]$ToName
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "applicationhost.config not found: $ConfigPath"
    }
    if ([string]::IsNullOrWhiteSpace($FromName) -or [string]::IsNullOrWhiteSpace($ToName)) {
        throw 'Rename-ApplicationhostSite: FromName and ToName are required.'
    }
    if ($FromName -ieq $ToName) { return $false }

    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($ConfigPath)

    $site = Find-ApplicationhostSite -Xml $xml -SiteName $FromName
    if ($null -eq $site) { return $false }

    if ($null -ne (Find-ApplicationhostSite -Xml $xml -SiteName $ToName)) {
        throw "Rename-ApplicationhostSite: a site named '$ToName' already exists in $ConfigPath."
    }

    $site.SetAttribute('name', $ToName)
    Save-ApplicationhostConfigAtomically -Xml $xml -ConfigPath $ConfigPath
    return $true
}

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

# Scan csproj files in a worktree and refresh applicationhost.config physicalPaths.
# Shared by sessionstart.ps1 (Branch (i)) and posttooluse-enterworktree.ps1 — both used to
# duplicate this loop (csproj-scan + identity-hash + Update-ApplicationhostConfig).
# Returns: PSCustomObject with UpdatedCount + Errors fields.
function Invoke-ApplicationhostRefresh {
    param(
        [Parameter(Mandatory = $true)][string]$WorktreePath,
        [Parameter(Mandatory = $true)][string]$ApphostTarget
    )

    $csprojFiles = @(Get-ChildItem -LiteralPath $WorktreePath -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|\.vs|\.git)\\' })

    $updates = @()
    $errors = @()
    foreach ($csproj in $csprojFiles) {
        $rel = Get-RelativePathSafe -From $WorktreePath -To $csproj.FullName
        $hash = Get-ProjectIdentityHash -RepoPath $WorktreePath -CsprojRelPath $rel
        $siteName = Format-IisExpressSiteName -CsprojPath $csproj.FullName -IdentityHash $hash
        $newPhysicalPath = [System.IO.Path]::GetDirectoryName($csproj.FullName)
        try {
            $result = Update-ApplicationhostConfig -ConfigPath $ApphostTarget -SiteName $siteName -NewPhysicalPath $newPhysicalPath
            $updates += $result
        } catch {
            $errMsg = $_.Exception.Message
            # Site not yet registered — that's expected; only collect unexpected failures.
            if ($errMsg -notmatch 'not found in applicationhost\.config') {
                $errors += $errMsg
            }
        }
    }

    # @(...) wrap required: single-element pipeline returns the unwrapped object whose .Count
    # would read the hashtable's KEY count, not the array length.
    $updatedCount = @($updates | Where-Object { $_.Updated }).Count
    return [pscustomobject]@{ UpdatedCount = $updatedCount; Errors = $errors }
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
