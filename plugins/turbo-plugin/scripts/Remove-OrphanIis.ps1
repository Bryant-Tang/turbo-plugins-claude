[CmdletBinding()]
param(
    [string]$Project = '',
    [string]$RemoveSite = '',
    [switch]$RemoveAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

try {
    Probe-GitVersion

    # Use Resolve-IisSettings to get the canonical (current) site name, identity hash,
    # and csproj stem consistently with the rest of the plugin.
    $settings = Resolve-IisSettings -Project $Project
    $currentSiteName = $settings.IisConfigSiteName
    $csprojStem      = [System.IO.Path]::GetFileNameWithoutExtension($settings.ProjectFile)
    $stemPattern     = "^$([regex]::Escape($csprojStem))-[0-9a-f]{8}$"

    # 1. Collect orphan processes: iisexpress.exe whose /site:<name> matches the stem-hash
    #    format but has a different hash than current.
    # v1.0 (U3) — canonical applicationhost.config is shared across worktrees and never mutated
    # at runtime; XML orphan site scan is therefore obsolete (canonical only contains current
    # project's site entries managed by VS / tp-setup, not stale per-worktree entries).
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

    # 2. Build orphan map keyed by site name (process only — no XML branch).
    $orphanMap = @{}
    foreach ($op in $orphanProcs) {
        $orphanMap[$op.SiteName] = @{ Pid = $op.Pid }
    }

    # 3. v1.0 (U3) — clean up stale per-launch temp applicationhost.config files in %TEMP%
    #    whose owning iisexpress.exe is gone. Files match pattern turbo-plugin-iis-*.config.
    #    For each file, identify-by-content (parse XML, read site name) is overkill; instead,
    #    match the running iisexpress.exe processes' -config:<path> argument and remove temp
    #    files that no live process references.
    $referencedTempFiles = @{}
    foreach ($p in $processes) {
        if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
        # IIS Express uses /config:<path> on its commandline (Start-Process emits both forward
        # slash and dash on different .NET versions; match both for robustness).
        if ($p.CommandLine -match '[/-]config:(["]?)([^"\s]+)\1') {
            $cfgPath = $Matches[2]
            try {
                $norm = Get-NormalizedAbsolutePath -Path $cfgPath
                $referencedTempFiles[$norm.ToLower()] = $true
            } catch {
                # ignore malformed paths
            }
        }
    }

    $orphanTempFiles = @()
    $tempDir = [System.IO.Path]::GetTempPath()
    if (Test-Path -LiteralPath $tempDir -PathType Container) {
        $tempCandidates = @(Get-ChildItem -LiteralPath $tempDir -Filter 'turbo-plugin-iis-*.config' -File -ErrorAction SilentlyContinue)
        foreach ($tf in $tempCandidates) {
            try {
                $norm = (Get-NormalizedAbsolutePath -Path $tf.FullName).ToLower()
            } catch {
                $norm = $tf.FullName.ToLower()
            }
            if (-not $referencedTempFiles.ContainsKey($norm)) {
                $orphanTempFiles += $tf.FullName
            }
        }
    }

    if ($orphanMap.Count -eq 0 -and $orphanTempFiles.Count -eq 0) {
        # v0.2.7+ F-U13.6 fix: if user explicitly asked to remove a specific site but no orphans
        # exist, surface a warning rather than silently exit 0 ("No orphan...") — user might
        # think the removal succeeded when actually nothing was checked against their request.
        if (-not [string]::IsNullOrWhiteSpace($RemoveSite)) {
            [Console]::Error.WriteLine("Warning: -RemoveSite '$RemoveSite' specified but no orphans found. Nothing matched your request.")
        }
        Write-Output 'No orphan IIS Express instances or stale temp applicationhost.config files found.'
        exit 0
    }

    # 4. If neither -RemoveAll nor -RemoveSite was supplied, just enumerate (the SKILL handles user prompts).
    if (-not $RemoveAll -and [string]::IsNullOrWhiteSpace($RemoveSite)) {
        foreach ($siteName in $orphanMap.Keys | Sort-Object) {
            $info = $orphanMap[$siteName]
            $pidStr = if ($null -eq $info.Pid) { '-' } else { $info.Pid }
            Write-Output "ORPHAN: $siteName process pid=$pidStr"
        }
        foreach ($tf in $orphanTempFiles | Sort-Object) {
            Write-Output "ORPHAN_TEMP: $tf"
        }
        exit 0
    }

    # 5. Perform removals (orphan processes).
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
        if ($null -ne $info.Pid) {
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
        if ($siteFailed) {
            $failedSites += [pscustomobject]@{ SiteName = $siteName; Reason = $siteReason }
        }
    }

    # 6. v1.0 (U3) — remove stale temp applicationhost.config files when -RemoveAll given.
    #    (For -RemoveSite, leave temp files alone — they're keyed by identity-hash, not site
    #    name, so we can't reliably correlate to a single requested site.)
    if ($RemoveAll -and $orphanTempFiles.Count -gt 0) {
        foreach ($tf in $orphanTempFiles) {
            try {
                Remove-Item -LiteralPath $tf -Force -ErrorAction Stop
                Write-Output "Removed orphan temp applicationhost.config: $tf"
            } catch {
                [Console]::Error.WriteLine("Warning: failed to remove orphan temp file '$tf': $($_.Exception.Message)")
            }
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
