param(
    [string]$Project = '',
    [int]$Timeout = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'applicationhost-helpers.ps1'))
. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

function Find-IisInstanceByPort {
    param([string]$Port, [string]$ApphostConfigFile)
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'iisexpress.exe'" -ErrorAction SilentlyContinue)
    $matched = @()

    # Build a set of site names from the apphost config for port matching
    $apphostSiteNames = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApphostConfigFile) -and (Test-Path -LiteralPath $ApphostConfigFile -PathType Leaf)) {
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($ApphostConfigFile)
            $sitesNode = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
            if ($null -ne $sitesNode) {
                foreach ($site in @($sitesNode.SelectNodes('site'))) {
                    $sName = $site.GetAttribute('name')
                    foreach ($binding in @($site.SelectNodes('bindings/binding'))) {
                        $info = $binding.GetAttribute('bindingInformation')
                        # bindingInformation format: "*:<port>:hostname" or "*:<port>:"
                        if ($info -match ':(\d+):') {
                            if ($Matches[1] -eq $Port) {
                                $apphostSiteNames[$sName] = $true
                            }
                        }
                    }
                }
            }
        } catch { <# ignore parse errors; fall back to commandLine only #> }
    }

    foreach ($p in $processes) {
        if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
        # Use anchored regex to extract site name from /site:<name>
        if ($p.CommandLine -match '/site:([^\s"]+)') {
            $siteName = $Matches[1]
            # Include if site name is in the apphost binding for this port, or if apphost lookup unavailable
            if ($apphostSiteNames.Count -eq 0 -or $apphostSiteNames.ContainsKey($siteName)) {
                $matched += [pscustomobject]@{
                    ProcessId   = $p.ProcessId
                    CommandLine = $p.CommandLine
                    SiteName    = $siteName
                }
            }
        }
    }
    return ,$matched
}

function Wait-PortListening {
    param([string]$Port, [int]$Seconds, [System.Diagnostics.Process]$Process)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            throw "IIS Express process (PID $($Process.Id)) exited prematurely with exit code $($Process.ExitCode). Check $env:LOCALAPPDATA\IISExpress\TraceLogFiles\ for crash details."
        }
        $listening = @((& netstat -ano) | Select-String -Pattern ":$Port\b" | Where-Object { $_ -match 'LISTENING' })
        if ($listening.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

try {
    Probe-GitVersion
    $settings = Resolve-IisSettings -Project $Project

    # apphost-mode is always required (port-mode removed); ensure the config file is set.
    if ([string]::IsNullOrWhiteSpace($settings.ApplicationhostConfigFile)) {
        throw "applicationhost.config target not found (.vs/<sln>/config/applicationhost.config). Ensure /tp-setup created the config or open the .sln in Visual Studio once to generate it."
    }
    if ([string]::IsNullOrWhiteSpace($settings.IisExpressPath)) {
        throw "IIS Express not found. Set user-level env ``TURBO_PLUGIN_IIS_EXPRESS_PATH`` to iisexpress.exe absolute path."
    }
    if (-not (Test-Path -LiteralPath $settings.IisExpressPath -PathType Leaf)) {
        throw "IIS Express executable does not exist: $($settings.IisExpressPath)"
    }
    if (-not (Test-Path -LiteralPath $settings.ApplicationhostConfigFile -PathType Leaf)) {
        throw "applicationhost.config does not exist at: $($settings.ApplicationhostConfigFile). Open the .sln in Visual Studio once or run /tp-setup."
    }

    # Pre-validate: the site entry must exist in applicationhost.config before launching.
    $apphostXml = New-Object System.Xml.XmlDocument
    $apphostXml.Load($settings.ApplicationhostConfigFile)
    $siteEntry = Find-ApplicationhostSite -Xml $apphostXml -SiteName $settings.IisConfigSiteName
    if ($null -eq $siteEntry) {
        throw "applicationhost.config 缺對應 site '$($settings.IisConfigSiteName)'。請先用 Visual Studio 開 .sln 一次讓 VS 自動建立 site 條目,或執行 /tp-setup 補設定。"
    }

    # Existing instance on the same port?
    $occupants = Find-IisInstanceByPort -Port $settings.IisPort -ApphostConfigFile $settings.ApplicationhostConfigFile
    if ($occupants.Count -gt 0) {
        $sameProject = @($occupants | Where-Object { $_.SiteName -eq $settings.IisConfigSiteName })
        if ($sameProject.Count -gt 0) {
            Write-Output "Same project IIS Express already on port $($settings.IisPort). Stopping previous instance(s) (PIDs: $($sameProject.ProcessId -join ', ')) before restart."
            $sameProject | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
            Start-Sleep -Milliseconds 500
        } else {
            $otherSites = ($occupants | ForEach-Object { $_.SiteName }) -join ', '
            throw "Port $($settings.IisPort) occupied by different project: PIDs $($occupants.ProcessId -join ', ') (sites: $otherSites). Stop the other instance or change this project's IIS port."
        }
    }

    # Refresh applicationhost.config physicalPath for current worktree before starting.
    try {
        Update-ApplicationhostConfig -ConfigPath $settings.ApplicationhostConfigFile -SiteName $settings.IisConfigSiteName -NewPhysicalPath $settings.SiteRoot | Out-Null
    } catch {
        Write-Output "Note: $($_.Exception.Message)"
    }

    $process = Start-Process -FilePath $settings.IisExpressPath -ArgumentList @("/config:$($settings.ApplicationhostConfigFile)", "/site:$($settings.IisConfigSiteName)") -WindowStyle Hidden -PassThru
    Write-Output "Started IIS Express (site: $($settings.IisConfigSiteName), PID: $($process.Id))"

    $repoRoot = $settings.RepoRoot
    $cfgTimeout = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'run' -Key 'listening_timeout_seconds' -CliValue $null -Default $null
    $timeoutSeconds = if ($Timeout -gt 0) {
        $Timeout
    } elseif ($null -ne $cfgTimeout) {
        [int]$cfgTimeout
    } else {
        30
    }

    if (-not (Wait-PortListening -Port $settings.IisPort -Seconds $timeoutSeconds -Process $process)) {
        throw "IIS Express started (PID $($process.Id)) but port $($settings.IisPort) is not LISTENING after ${timeoutSeconds}s. Check the IIS Express log or raise [run].listening_timeout_seconds in .turbo-plugin/config.toml."
    }
    Write-Output "Listening on $($settings.IisUrl)"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
