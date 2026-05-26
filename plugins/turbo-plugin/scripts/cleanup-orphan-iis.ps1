[CmdletBinding()]
param(
    [string]$Project = '',
    [string]$RemoveSite = '',
    [switch]$RemoveAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'applicationhost-helpers.ps1'))
. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

try {
    Probe-GitVersion

    # Use Resolve-IisSettings to get the canonical (current) site name, identity hash,
    # csproj stem, and applicationhost.config path consistently with the rest of the plugin.
    $settings = Resolve-IisSettings -Project $Project
    $currentSiteName = $settings.IisConfigSiteName
    $csprojStem      = [System.IO.Path]::GetFileNameWithoutExtension($settings.ProjectFile)
    $stemPattern     = "^$([regex]::Escape($csprojStem))-[0-9a-f]{8}$"
    $apphostPath     = $settings.ApplicationhostConfigFile

    # 1. Collect orphan processes: iisexpress.exe whose /site:<name> matches the stem-hash
    #    format but has a different hash than current.
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'iisexpress.exe'" -ErrorAction SilentlyContinue)
    $orphanProcs = @()
    foreach ($p in $processes) {
        if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
        if ($p.CommandLine -notmatch '/site:([^\s"]+)') { continue }
        $candidateSite = $Matches[1]
        if ($candidateSite -match $stemPattern -and $candidateSite -ne $currentSiteName) {
            $orphanProcs += [pscustomobject]@{
                SiteName = $candidateSite
                Pid      = $p.ProcessId
            }
        }
    }

    # 2. Collect orphan XML site nodes: <site name="..."> in applicationhost.config matching
    #    the stem-hash format but != current site name.
    $orphanXmlSites = @()
    if (-not [string]::IsNullOrWhiteSpace($apphostPath) -and (Test-Path -LiteralPath $apphostPath -PathType Leaf)) {
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.PreserveWhitespace = $true
            $xml.Load($apphostPath)
            $sitesNode = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
            if ($null -ne $sitesNode) {
                foreach ($siteNode in @($sitesNode.SelectNodes('site'))) {
                    $name = $siteNode.GetAttribute('name')
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    if ($name -match $stemPattern -and $name -ne $currentSiteName) {
                        $orphanXmlSites += $name
                    }
                }
            }
        } catch {
            [Console]::Error.WriteLine("Warning: failed to parse applicationhost.config '$apphostPath': $($_.Exception.Message)")
        }
    }

    # 3. Merge orphan list by site name (a site can have both a running process AND an XML entry).
    $orphanMap = @{}
    foreach ($op in $orphanProcs) {
        if (-not $orphanMap.ContainsKey($op.SiteName)) {
            $orphanMap[$op.SiteName] = @{ Process = $true; Xml = $false; Pid = $op.Pid }
        } else {
            $orphanMap[$op.SiteName].Process = $true
            $orphanMap[$op.SiteName].Pid = $op.Pid
        }
    }
    foreach ($xmlSite in $orphanXmlSites) {
        if (-not $orphanMap.ContainsKey($xmlSite)) {
            $orphanMap[$xmlSite] = @{ Process = $false; Xml = $true; Pid = $null }
        } else {
            $orphanMap[$xmlSite].Xml = $true
        }
    }

    if ($orphanMap.Count -eq 0) {
        # v0.2.7+ F-U13.6 fix: if user explicitly asked to remove a specific site but no orphans
        # exist, surface a warning rather than silently exit 0 ("No orphan...") — user might
        # think the removal succeeded when actually nothing was checked against their request.
        if (-not [string]::IsNullOrWhiteSpace($RemoveSite)) {
            [Console]::Error.WriteLine("Warning: -RemoveSite '$RemoveSite' specified but no orphans found. Nothing matched your request.")
        }
        Write-Output 'No orphan IIS Express instances or applicationhost.config sites found.'
        exit 0
    }

    # 4. If neither -RemoveAll nor -RemoveSite was supplied, just enumerate (the SKILL handles user prompts).
    if (-not $RemoveAll -and [string]::IsNullOrWhiteSpace($RemoveSite)) {
        foreach ($siteName in $orphanMap.Keys | Sort-Object) {
            $info = $orphanMap[$siteName]
            $kind = if ($info.Process -and $info.Xml) { 'both' } elseif ($info.Process) { 'process' } else { 'xml' }
            $pidStr = if ($null -eq $info.Pid) { '-' } else { $info.Pid }
            Write-Output "ORPHAN: $siteName $kind pid=$pidStr"
        }
        exit 0
    }

    # 5. Perform removals.
    $sitesToRemove = @()
    if ($RemoveAll) {
        $sitesToRemove = @($orphanMap.Keys)
    } else {
        if (-not $orphanMap.ContainsKey($RemoveSite)) {
            throw "Site '$RemoveSite' is not in the orphan list. Run without -RemoveSite first to enumerate orphans."
        }
        $sitesToRemove = @($RemoveSite)
    }

    # Track partial failures across the loop so -RemoveAll can report `PARTIAL_FAILURE`
    # and exit 2 instead of silently swallowing per-site errors.
    $failedSites = @()

    foreach ($siteName in $sitesToRemove) {
        $info = $orphanMap[$siteName]
        $siteFailed = $false
        $siteReason = $null
        if ($info.Process -and $null -ne $info.Pid) {
            # Pre-check (synth F16): if the targeted process already exited between detect and stop
            # (Ctrl+C, AV kill, self-crash), treat as cleanup success rather than PARTIAL_FAILURE.
            # End-state (no running PID) is the cleanup goal; only true Stop-Process errors should fail.
            if (-not (Get-Process -Id $info.Pid -ErrorAction SilentlyContinue)) {
                Write-Output "PID $($info.Pid) already exited (site: $siteName) — treating as cleanup success."
            } else {
                try {
                    Stop-Process -Id $info.Pid -Force -ErrorAction Stop
                    Write-Output "Stopped orphan IIS Express PID $($info.Pid) (site: $siteName)"
                } catch {
                    [Console]::Error.WriteLine("Warning: failed to stop PID $($info.Pid) for site '$siteName': $($_.Exception.Message)")
                    $siteFailed = $true
                    $siteReason = "stop PID $($info.Pid) failed: $($_.Exception.Message)"
                }
            }
        }
        if ($info.Xml) {
            try {
                $result = Remove-ApplicationhostSite -ConfigPath $apphostPath -SiteName $siteName
                if ($result.Removed) {
                    Write-Output "Removed orphan applicationhost.config site '$siteName' from: $apphostPath"
                } else {
                    Write-Output "applicationhost.config site '$siteName' not found ($($result.Reason)); skipping."
                }
            } catch {
                [Console]::Error.WriteLine("Warning: failed to remove site '$siteName' from applicationhost.config: $($_.Exception.Message)")
                $siteFailed = $true
                if ($null -eq $siteReason) {
                    $siteReason = "remove applicationhost.config entry failed: $($_.Exception.Message)"
                } else {
                    $siteReason = "$siteReason; remove applicationhost.config entry failed: $($_.Exception.Message)"
                }
            }
        }
        if ($siteFailed) {
            $failedSites += [pscustomobject]@{ SiteName = $siteName; Reason = $siteReason }
        }
    }

    if ($failedSites.Count -gt 0) {
        $sitesList = ($failedSites | ForEach-Object { $_.SiteName }) -join ','
        Write-Output "PARTIAL_FAILURE: failed=$($failedSites.Count) sites=$sitesList"
        foreach ($fs in $failedSites) {
            [Console]::Error.WriteLine("  - $($fs.SiteName): $($fs.Reason)")
        }
        exit 2
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
