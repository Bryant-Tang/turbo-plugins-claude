param(
    [string]$Project = '',
    [int]$Timeout = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'ApplicationHostHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

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

    # Defensive layer: [iis] enabled = false short-circuits IIS-touching scripts even
    # when invoked directly (SKILL layer also checks; this guards programmatic callers).
    $repoRootForIisCheck = (Get-Location).Path
    $iisEnabled = Resolve-ConfigValue -RepoRoot $repoRootForIisCheck -Section 'iis' -Key 'enabled' -CliValue $null -Default $true
    if ($iisEnabled -eq $false) {
        throw @"
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
"@
    }

    $settings = Resolve-IisSettings -Project $Project

    # apphost-mode is always required (port-mode removed); ensure the canonical config file is set.
    if ([string]::IsNullOrWhiteSpace($settings.ApplicationhostConfigFile)) {
        throw "applicationhost.config 路徑無法解析。請執行 /tp-setup 建立 .turbo-plugin/applicationhost.config。"
    }
    # Find-IisExpressPath (in lib/IisHelpers.ps1) throws on missing/invalid path
    # since v1.0 (U2); guard kept as defensive layer in case caller short-circuits the helper.
    if (-not (Test-Path -LiteralPath $settings.IisExpressPath -PathType Leaf)) {
        throw "IIS Express executable does not exist: $($settings.IisExpressPath)"
    }
    if (-not (Test-Path -LiteralPath $settings.ApplicationhostConfigFile -PathType Leaf)) {
        throw "canonical applicationhost.config does not exist at: $($settings.ApplicationhostConfigFile). 請執行 /tp-setup 從 VS 複製或建立空白 template。"
    }

    # Pre-validate: the site entry must exist in canonical applicationhost.config before launching.
    $apphostXml = New-Object System.Xml.XmlDocument
    $apphostXml.PreserveWhitespace = $true
    $apphostXml.Load($settings.ApplicationhostConfigFile)
    $siteEntry = Find-ApplicationhostSite -Xml $apphostXml -SiteName $settings.IisConfigSiteName
    if ($null -eq $siteEntry) {
        throw "applicationhost.config 缺對應 site '$($settings.IisConfigSiteName)'。請先用 Visual Studio 開 .sln 一次讓 VS 自動建立 site 條目,然後執行 /tp-setup 重新從 VS 複製到 .turbo-plugin/applicationhost.config。"
    }

    # Existing instance on the same port? (port check still uses the canonical config —
    # site name + binding info come from canonical, both unchanged at runtime).
    $occupants = Find-IisInstanceByPort -Port $settings.IisPort -ApphostConfigFile $settings.ApplicationhostConfigFile
    if ($occupants.Count -gt 0) {
        $sameProject = @($occupants | Where-Object { $_.SiteName -ieq $settings.IisConfigSiteName })
        if ($sameProject.Count -gt 0) {
            Write-Output "Same project IIS Express already on port $($settings.IisPort). Stopping previous instance(s) (PIDs: $($sameProject.ProcessId -join ', ')) before restart."
            foreach ($proc in $sameProject) {
                try {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                } catch {
                    Write-Output "  PID $($proc.ProcessId) already exited or unstoppable: $($_.Exception.Message)"
                }
            }
            Start-Sleep -Milliseconds 500
        } else {
            $otherSites = ($occupants | ForEach-Object { $_.SiteName }) -join ', '
            throw "Port $($settings.IisPort) occupied by different project: PIDs $($occupants.ProcessId -join ', ') (sites: $otherSites). Stop the other instance or change this project's IIS port."
        }
    }

    # v1.0 (U3) — render a per-launch temp applicationhost.config:
    #   1. Delete any stale temp file from a previous run (same identity-hash).
    #   2. Copy canonical → %TEMP%\turbo-plugin-iis-<identity-hash>.config.
    #   3. In the temp file, replace the __TURBO_PLUGIN_PHYSICAL_PATH__ placeholder
    #      with the current worktree's csproj dir. If the placeholder is not present
    #      (canonical came from VS with a real absolute path), fall back to
    #      SetAttribute on physicalPath via Update-ApplicationhostConfig.
    #   4. Launch iisexpress with -config:<temp>.
    # Canonical is never mutated — committed content stays portable across machines.
    # Same project on every worktree resolves to the same identity-hash, hence the
    # same temp filename — by design, since IIS Express for one project never runs
    # concurrently across worktrees (port/site/bindings all derive from the project
    # file and collide if two instances were attempted).
    $tempApphost = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-plugin-iis-$($settings.IdentityHash).config")
    if (Test-Path -LiteralPath $tempApphost -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $tempApphost -Force -ErrorAction Stop
        } catch {
            Write-Output "Note: failed to remove stale temp apphost '$tempApphost': $($_.Exception.Message)"
        }
    }
    Copy-Item -LiteralPath $settings.ApplicationhostConfigFile -Destination $tempApphost -Force

    # Patch physicalPath in the temp file. Try placeholder substitution first (cheap, line-level);
    # if no substitution happened, fall back to XML SetAttribute for the resolved site name —
    # this handles the case where canonical was sourced from VS with concrete absolute paths
    # (e.g. before U5 tp-setup placeholder rewrite shipped).
    $placeholder = '__TURBO_PLUGIN_PHYSICAL_PATH__'
    # XML attribute values escape backslash as-is (no \ escaping required), but `&`, `<`, `"`
    # must be encoded. csproj paths can contain `&` (rare) on Windows; encode defensively.
    $physicalPathXmlEscaped = $settings.SiteRoot.Replace('&', '&amp;').Replace('<', '&lt;').Replace('"', '&quot;')
    $rawText = [System.IO.File]::ReadAllText($tempApphost, [System.Text.Encoding]::UTF8)
    if ($rawText.Contains($placeholder)) {
        $patched = $rawText.Replace($placeholder, $physicalPathXmlEscaped)
        # Preserve UTF-8 BOM if canonical had one; otherwise write without BOM (XML decl byte-exact).
        $bytes = [System.IO.File]::ReadAllBytes($tempApphost)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $encoding = if ($hasBom) { New-Object System.Text.UTF8Encoding($true) } else { New-Object System.Text.UTF8Encoding($false) }
        [System.IO.File]::WriteAllText($tempApphost, $patched, $encoding)
    } else {
        # No placeholder — canonical likely came from VS with concrete absolute path(s).
        # Use Update-ApplicationhostConfig on the temp file (canonical untouched).
        try {
            Update-ApplicationhostConfig -ConfigPath $tempApphost -SiteName $settings.IisConfigSiteName -NewPhysicalPath $settings.SiteRoot | Out-Null
        } catch {
            Write-Output "Note: failed to patch physicalPath in temp apphost '$tempApphost': $($_.Exception.Message)"
        }
    }

    $process = Start-Process -FilePath $settings.IisExpressPath -ArgumentList @("/config:$tempApphost", "/site:$($settings.IisConfigSiteName)") -WindowStyle Hidden -PassThru
    Write-Output "Started IIS Express (site: $($settings.IisConfigSiteName), PID: $($process.Id), config: $tempApphost)"

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

    # RUN result template (KTD5): report the RESOLVED target (糾錯閘) + the web URL. run serves
    # the last build output, so there is no configuration to report. URL stays bare/clickable.
    Write-Output 'RUN_OUTPUT (relay these lines to the user as the run result):'
    foreach ($l in (Format-RunResultLines -ResolvedTarget $settings.ProjectFile -WebUrl $settings.IisUrl)) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
