param(
    [string]$Project = '',
    [int]$Timeout = 0,
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'ApplicationHostHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

function Find-IisInstanceByPort {
    param([string]$Port, [string]$ApphostConfigFile, [string]$RuntimeSiteName = '')
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

    # Our own instance runs against a TEMP copy of canonical whose site was renamed to the
    # identity-hashed runtime name, so the canonical-derived set never contains it. Register it
    # explicitly -- otherwise "same project already on this port" could never match and we would
    # launch a second instance onto an occupied port. Only when the set is non-empty: an empty set
    # is the "canonical unreadable / no site on this port" fallback that matches every instance,
    # and seeding one name into it would silently narrow that fallback.
    if (-not [string]::IsNullOrWhiteSpace($RuntimeSiteName) -and $apphostSiteNames.Count -gt 0) {
        $apphostSiteNames[$RuntimeSiteName] = $true
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

# Read back whatever IIS Express managed to say before dying. Its own message is the only thing
# that distinguishes "your config is unloadable" from "the port is taken" from "the site name is
# wrong" -- previously the failure pointed at a TraceLogFiles directory that does not even exist on
# a normal install, so every launch failure looked identical and told the user nothing.
function Get-IisLaunchLogTail {
    param([string[]]$LogPaths, [int]$MaxLines = 12)
    $lines = @()
    foreach ($p in $LogPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $content = @(Get-Content -LiteralPath $p -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } catch {
            continue
        }
        if ($content.Count -eq 0) { continue }
        $lines += @($content | Select-Object -Last $MaxLines)
    }
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join "`n")
}

# Win32_Process.Create is handed a cmd.exe command line (see the launch site for why), so the PID it
# returns is the SHELL's, not the server's. Everything downstream means the iisexpress.exe
# underneath -- the PID we report, Wait-PortListening's premature-exit check, Stop-Iis -- so resolve
# it here and hand back a real Process object.
#
# `cmd /c` waits for its child, so the shell staying alive is the signal that the server is still
# running; the shell disappearing before any iisexpress.exe shows up means the launch died outright,
# and that is exactly when IIS Express's own message matters most -- so it is read back here rather
# than leaving the caller with a bare timeout.
function Wait-IisExpressProcess {
    param([uint32]$ShellProcessId, [int]$Seconds = 20, [string[]]$LogPaths = @())
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $child = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ShellProcessId AND Name='iisexpress.exe'" -ErrorAction SilentlyContinue)
        if ($child.Count -gt 0) {
            $p = Get-Process -Id $child[0].ProcessId -ErrorAction SilentlyContinue
            if ($null -ne $p) { return $p }
        }
        $shell = @(Get-CimInstance Win32_Process -Filter "ProcessId=$ShellProcessId" -ErrorAction SilentlyContinue)
        if ($shell.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
    $detail = Get-IisLaunchLogTail -LogPaths $LogPaths
    $msg = 'IIS Express 沒有啟動起來(找不到 iisexpress.exe 行程)。'
    if (-not [string]::IsNullOrWhiteSpace($detail)) { $msg += "`nIIS Express 自己的訊息:`n$detail" }
    throw $msg
}

function Wait-PortListening {
    param([string]$Port, [int]$Seconds, [System.Diagnostics.Process]$Process, [string[]]$LogPaths = @())
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            $detail = Get-IisLaunchLogTail -LogPaths $LogPaths
            $msg = "IIS Express process (PID $($Process.Id)) exited prematurely with exit code $($Process.ExitCode)."
            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                $msg += "`nIIS Express 自己的訊息:`n$detail"
            } else {
                $msg += ' IIS Express 沒有留下任何訊息。'
            }
            throw $msg
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
    $repoRootForIisCheck = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot
    $iisEnabled = Resolve-ConfigValue -RepoRoot $repoRootForIisCheck -Section 'iis' -Key 'enabled' -CliValue $null -Default $true
    if ($iisEnabled -eq $false) {
        throw @"
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
"@
    }

    $settings = Resolve-IisSettings -Project $Project -RepoRoot $RepoRoot

    # apphost-mode is always required (port-mode removed); ensure the canonical config file is set.
    if ([string]::IsNullOrWhiteSpace($settings.ApplicationhostConfigFile)) {
        throw 'applicationhost.config 路徑無法解析,無法啟動 IIS Express。'
    }
    # Find-IisExpressPath (in lib/IisHelpers.ps1) throws on missing/invalid path;
    # guard kept as defensive layer in case caller short-circuits the helper.
    if (-not (Test-Path -LiteralPath $settings.IisExpressPath -PathType Leaf)) {
        throw "IIS Express executable does not exist: $($settings.IisExpressPath)"
    }

    # The site entry must exist in canonical applicationhost.config before launching -- and if it
    # does not, it is CREATED HERE rather than demanded of the user. Everything the entry needs is
    # already in the csproj, so a first run can simply produce it; Visual Studio works the same way,
    # its config appears when you first run a project. Requiring a separate setup command first only
    # ever produced a dead end.
    #
    # Canonical carries the PLAIN csproj-stem name -- exactly what Visual Studio writes -- so a
    # config copied from VS works unchanged and the shared file stays free of machine-specific
    # data. The identity-hashed runtime name is applied to the per-launch temp copy further down.
    # A canonical that already uses the hashed name is still accepted: repos set up before this
    # split have one, and forcing a migration would buy nothing.
    $canonicalSiteInFile = $settings.CanonicalSiteName
    $siteEntry = $null
    $configUnusable = $false
    if (Test-Path -LiteralPath $settings.ApplicationhostConfigFile -PathType Leaf) {
        $apphostXml = New-Object System.Xml.XmlDocument
        $apphostXml.PreserveWhitespace = $true
        $apphostXml.Load($settings.ApplicationhostConfigFile)
        # A config with no <configSections> can never be loaded by IIS Express, whatever sites it
        # lists. Route it into the initializer too, which rebuilds it and carries the sites over --
        # otherwise a repo that already has such a file would keep failing forever, since the
        # site-lookup below would find its entry and conclude everything was fine.
        $configUnusable = ($null -eq $apphostXml.SelectSingleNode('/configuration/configSections'))
        $siteEntry = Find-ApplicationhostSite -Xml $apphostXml -SiteName $canonicalSiteInFile
        if ($null -eq $siteEntry) {
            $canonicalSiteInFile = $settings.IisConfigSiteName
            $siteEntry = Find-ApplicationhostSite -Xml $apphostXml -SiteName $canonicalSiteInFile
        }
    }
    if (($null -eq $siteEntry) -or $configUnusable) {
        # When a usable entry was already found (we are only here to rebuild an unloadable file),
        # pass THAT name through: asking for the canonical name instead would append a second site
        # on the same port next to the salvaged one.
        $siteToEnsure = if ($null -ne $siteEntry) { $canonicalSiteInFile } else { $settings.CanonicalSiteName }
        $bootstrap = Initialize-ApplicationhostSite `
            -ConfigPath $settings.ApplicationhostConfigFile `
            -TemplatePath (Get-ApplicationhostTemplatePath -IisExpressPath $settings.IisExpressPath) `
            -SiteName $siteToEnsure `
            -Binding $settings.Binding
        if ($bootstrap.ConfigCreated) {
            Write-Output "Generated applicationhost.config (site: $($settings.CanonicalSiteName)): $($settings.ApplicationhostConfigFile)"
        } elseif ($bootstrap.ConfigRebuilt) {
            Write-Output "Rebuilt applicationhost.config (previous content could not be loaded by IIS Express): $($settings.ApplicationhostConfigFile)"
        } else {
            Write-Output "Added site '$($settings.CanonicalSiteName)' to applicationhost.config: $($settings.ApplicationhostConfigFile)"
        }
        $canonicalSiteInFile = $siteToEnsure
        $verifyXml = New-Object System.Xml.XmlDocument
        $verifyXml.PreserveWhitespace = $true
        $verifyXml.Load($settings.ApplicationhostConfigFile)
        if ($null -eq (Find-ApplicationhostSite -Xml $verifyXml -SiteName $canonicalSiteInFile)) {
            throw "已寫入 applicationhost.config,但裡面仍找不到名為 '$canonicalSiteInFile' 的站台:$($settings.ApplicationhostConfigFile)"
        }
    }

    # Existing instance on the same port? (port check still uses the canonical config —
    # site name + binding info come from canonical, both unchanged at runtime).
    $occupants = Find-IisInstanceByPort -Port $settings.IisPort -ApphostConfigFile $settings.ApplicationhostConfigFile -RuntimeSiteName $settings.IisConfigSiteName
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
                # Wait for the process to actually be gone rather than hoping a fixed sleep covers
                # it. This restart re-renders the SAME per-launch temp files and re-redirects onto
                # the same .out.log / .err.log paths, so a previous instance that has not yet
                # released its handles makes the relaunch fail on "file in use".
                Wait-Process -Id $proc.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
            }
            # Small settle on top of the waits: the port itself takes a moment to be released even
            # after the owning process is gone.
            Start-Sleep -Milliseconds 200
        } else {
            $otherSites = ($occupants | ForEach-Object { $_.SiteName }) -join ', '
            throw "Port $($settings.IisPort) occupied by different project: PIDs $($occupants.ProcessId -join ', ') (sites: $otherSites). Stop the other instance or change this project's IIS port."
        }
    }

    # render a per-launch temp applicationhost.config:
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
    # Per-launch log files share the temp config's identity-hash naming so tp-cleanup-orphan-iis
    # recognises and cleans them as one set.
    $tempStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-plugin-iis-$($settings.IdentityHash).out.log")
    $tempStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-plugin-iis-$($settings.IdentityHash).err.log")
    foreach ($stale in @($tempApphost, $tempStdout, $tempStderr)) {
        if (Test-Path -LiteralPath $stale -PathType Leaf) {
            try {
                # .NET, not Remove-Item: -LiteralPath still mangles a `~`, which every temp path has
                # on a machine with an 8.3 user profile. See Remove-PerLaunchTempFile in Common.ps1.
                [System.IO.File]::Delete($stale)
            } catch {
                Write-Output "Note: failed to remove stale temp file '$stale': $($_.Exception.Message)"
            }
        }
    }
    Copy-Item -LiteralPath $settings.ApplicationhostConfigFile -Destination $tempApphost -Force

    # Patch physicalPath in the temp file. Try placeholder substitution first (cheap, line-level);
    # if no substitution happened, fall back to XML SetAttribute for the resolved site name —
    # this handles the case where canonical was sourced from VS with concrete absolute paths
    # (e.g. a config copied out of Visual Studio by hand).
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
            Update-ApplicationhostConfig -ConfigPath $tempApphost -SiteName $canonicalSiteInFile -NewPhysicalPath $settings.SiteRoot | Out-Null
        } catch {
            Write-Output "Note: failed to patch physicalPath in temp apphost '$tempApphost': $($_.Exception.Message)"
        }
    }

    # Apply the identity-hashed RUNTIME site name to the temp copy ONLY. This is what puts the
    # project identity onto the iisexpress command line -- how Stop-Iis / Remove-OrphanIis find
    # this instance, and how a sibling worktree's instance is recognised as "the same project"
    # rather than an unrelated one squatting the port -- while the shared canonical file keeps the
    # plain project name and stays portable across machines and clones.
    if ($canonicalSiteInFile -ine $settings.IisConfigSiteName) {
        $null = Rename-ApplicationhostSite -ConfigPath $tempApphost -FromName $canonicalSiteInFile -ToName $settings.IisConfigSiteName
    }

    # LAUNCHED VIA WMI, NOT Start-Process -- and that is a correctness fix, not a style choice.
    #
    # Start-Process -NoNewWindow means UseShellExecute=$false, which makes CreateProcess pass
    # bInheritHandles=TRUE. The long-lived iisexpress.exe therefore receives EVERY inheritable
    # handle this process holds, including the WRITE END OF THE PIPE the agent harness gave this
    # powershell.exe to collect its output. When this script exits the server keeps that write end
    # open, the reader never sees EOF, and the harness's tool call never finishes -- the session UI
    # hangs until it is restarted (issue #82). -RedirectStandardOutput/-Error do not help: they
    # replace two of the three standard handles and leave everything else inherited.
    #
    # Win32_Process.Create builds the process from the WMI service, so it inherits nothing of ours.
    # Measured here, launcher process started with a real stdout PIPE and then allowed to exit:
    #   Start-Process -NoNewWindow -> launcher exited, pipe NEVER reached EOF
    #   Win32_Process.Create       -> launcher exited, pipe reached EOF immediately
    #
    # CREATE_NEW_CONSOLE (16) is required: without a console of its own IIS Express finds no usable
    # stdin and exits with code 0 before binding the port. SW_HIDE (0) keeps that console invisible,
    # which is what a background dev server should do. -WindowStyle is still wrong for the original
    # reason (it forces UseShellExecute=$true and dies the same way).
    #
    # The command line goes through cmd.exe ONLY to keep the stdout/stderr redirection:
    # Win32_Process.Create cannot redirect, and those two files are the only place a failed launch
    # leaves its reason (Get-IisLaunchLogTail reads them, and a config IIS Express rejects is the
    # most common failure). `cmd /s /c` takes the rest of the line verbatim after stripping the
    # outer quotes, so the inner quoting survives intact. cmd waits for the server, so one extra
    # cmd.exe lives alongside it and exits by itself when the server stops.
    #
    # Arguments stay quoted EXPLICITLY: the temp config lives under %TEMP%, whose path routinely
    # contains a space (IIS Express then reports "Command-line switches must be preceded by '-' or
    # '/'"). The `/` switch prefix, the quoting shape and the `/site:` token are all load-bearing --
    # Stop-Iis and Remove-OrphanIis identify this instance by matching them on its command line.
    $comspec = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { 'cmd.exe' } else { $env:ComSpec }
    $innerCommandLine = '"{0}" "/config:{1}" "/site:{2}" >"{3}" 2>"{4}"' -f `
        $settings.IisExpressPath, $tempApphost, $settings.IisConfigSiteName, $tempStdout, $tempStderr
    $spawnCommandLine = '{0} /s /c "{1}"' -f $comspec, $innerCommandLine
    try {
        $startupClass = Get-CimClass -ClassName Win32_ProcessStartup
        $startupInfo = New-CimInstance -CimClass $startupClass -ClientOnly -Property @{
            CreateFlags = [uint32]16   # CREATE_NEW_CONSOLE
            ShowWindow  = [uint16]0    # SW_HIDE
        }
        $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine               = $spawnCommandLine
            ProcessStartupInformation = $startupInfo
        }
        if ($null -eq $spawn -or $spawn.ReturnValue -ne 0) {
            $rv = if ($null -eq $spawn) { 'null' } else { $spawn.ReturnValue }
            throw "無法啟動 IIS Express:Win32_Process.Create 回傳 $rv。"
        }
        $process = Wait-IisExpressProcess -ShellProcessId $spawn.ProcessId -LogPaths @($tempStdout, $tempStderr)
    } catch {
        # Nothing was launched, so the temp files rendered a moment ago are dead weight. Remove them
        # here instead of leaving files behind that tp-cleanup-orphan-iis would later report as
        # orphans. Only this branch cleans up: once a process exists it is READING/WRITING them.
        foreach ($f in @($tempApphost, $tempStdout, $tempStderr)) {
            if (Test-Path -LiteralPath $f -PathType Leaf) {
                # .NET, not Remove-Item: -LiteralPath still mangles a `~`, which every temp path has
                # on a machine with an 8.3 user profile -- and this `catch { }` would have swallowed
                # that failure silently. See Remove-PerLaunchTempFile in Common.ps1.
                try { [System.IO.File]::Delete($f) } catch { }
            }
        }
        throw
    }
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

    if (-not (Wait-PortListening -Port $settings.IisPort -Seconds $timeoutSeconds -Process $process -LogPaths @($tempStdout, $tempStderr))) {
        $tail = Get-IisLaunchLogTail -LogPaths @($tempStdout, $tempStderr)
        $msg = "IIS Express started (PID $($process.Id)) but port $($settings.IisPort) is not LISTENING after ${timeoutSeconds}s. 可調高 .turbo-plugin/config.toml 的 [run].listening_timeout_seconds。"
        if (-not [string]::IsNullOrWhiteSpace($tail)) { $msg += "`nIIS Express 自己的訊息:`n$tail" }
        throw $msg
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
