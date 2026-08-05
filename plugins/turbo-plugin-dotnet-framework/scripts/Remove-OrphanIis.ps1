[CmdletBinding()]
param(
    [string]$Project = '',
    [string]$RemoveSite = '',
    [switch]$RemoveAll,
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

try {
    Probe-GitVersion

    # KTD8: branch on whether a project is resolvable (CLI -Project or config memory).
    #   * WITH a project  → behavior UNCHANGED: scope to that project's stem-hash family and
    #     exclude its live site (Resolve-IisSettings gives the current site name + csproj stem).
    #   * NO project (truly no current project, after auto-detect removal) → fall back to the
    #     GENERIC turbo-plugin site pattern, and refuse blanket -RemoveAll so we never kill a
    #     live site we cannot identify (the agent is told to pass -Project when one exists).
    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project -AllowMissing
    if ($null -ne $target) {
        # Reuse the already-resolved target path instead of re-passing the raw $Project (which,
        # when the project came from config memory, would make Resolve-IisSettings re-read config
        # and re-resolve to the same csproj). Same result, one fewer config lookup.
        $settings = Resolve-IisSettings -Project $target.Path -RepoRoot $repoRoot
        $currentSiteName = $settings.IisConfigSiteName
        $csprojStem      = [System.IO.Path]::GetFileNameWithoutExtension($settings.ProjectFile)
        $scoped = $true
    } else {
        $currentSiteName = $null
        $csprojStem      = $null
        $scoped = $false
        if ($RemoveAll) {
            throw "Refusing -RemoveAll without a project: cannot distinguish a live site from an orphan when no current project is set. Re-run with -Project to scope to one project's orphans, or use -RemoveSite <name> to remove a specific enumerated site."
        }
    }

    # 1. Collect orphan processes: iisexpress.exe whose /site:<name> looks like a turbo-plugin
    #    site. Scoped mode matches this project's stem (different hash than current); no-project
    #    mode matches the generic <stem>-<8hex> family (no live site is known to exclude).
    # canonical applicationhost.config is shared across worktrees and never mutated
    # at runtime; XML orphan site scan is therefore obsolete (canonical only contains current
    # project's canonical site entries, not stale per-worktree ones).
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'iisexpress.exe'" -ErrorAction SilentlyContinue)
    $orphanProcs = @()
    foreach ($p in $processes) {
        if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
        if ($p.CommandLine -notmatch '/site:([^\s"]+)') { continue }
        $candidateSite = $Matches[1]
        if ($scoped) {
            $isOrphan = (Test-OrphanSiteNameMatch -CsprojStem $csprojStem -SiteName $candidateSite) -and ($candidateSite -ne $currentSiteName)
        } else {
            $isOrphan = Test-TurboPluginSiteName -SiteName $candidateSite
        }
        if ($isOrphan) {
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

    # 3. clean up stale per-launch temp files in %TEMP% whose owning iisexpress.exe is gone.
    #    One launch leaves three files, all named turbo-plugin-iis-<identity-hash>.*:
    #    the rendered .config plus the redirected .out.log / .err.log.
    #
    #    Matching is done on the IDENTITY HASH parsed out of the file name, not on the full path.
    #    Comparing paths was wrong twice over: the log files never appear on any command line at
    #    all, and %TEMP% routinely contains a space (a user folder like "First Last"), which the old
    #    non-greedy path pattern truncated at the first space -- so no live process ever matched
    #    and every temp file was reported as an orphan.
    $referencedHashes = @{}
    foreach ($p in $processes) {
        if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
        # Three quoting shapes seen in the wild: "/config:<path>" (whole switch quoted),
        # /config:"<path>" (value quoted), and /config:<path> (no spaces). Dash form matched too.
        $cfgPath = ''
        if ($p.CommandLine -match '"[/-]config:([^"]+)"') { $cfgPath = $Matches[1] }
        elseif ($p.CommandLine -match '[/-]config:"([^"]+)"') { $cfgPath = $Matches[1] }
        elseif ($p.CommandLine -match '[/-]config:(\S+)') { $cfgPath = $Matches[1] }
        if ([string]::IsNullOrWhiteSpace($cfgPath)) { continue }
        $leaf = ''
        try { $leaf = [System.IO.Path]::GetFileName($cfgPath) } catch { continue }
        if ($leaf -match '^turbo-plugin-iis-([0-9a-f]{8})\.config$') {
            $referencedHashes[$Matches[1]] = $true
        }
    }

    $orphanTempFiles = @()
    $tempDir = [System.IO.Path]::GetTempPath()
    if (Test-Path -LiteralPath $tempDir -PathType Container) {
        $tempCandidates = @(Get-ChildItem -LiteralPath $tempDir -Filter 'turbo-plugin-iis-*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^turbo-plugin-iis-[0-9a-f]{8}\.(config|out\.log|err\.log)$' })
        foreach ($tf in $tempCandidates) {
            if ($tf.Name -match '^turbo-plugin-iis-([0-9a-f]{8})\.') {
                if (-not $referencedHashes.ContainsKey($Matches[1])) {
                    $orphanTempFiles += $tf.FullName
                }
            }
        }
    }

    if ($orphanMap.Count -eq 0 -and $orphanTempFiles.Count -eq 0) {
        # fix: if user explicitly asked to remove a specific site but no orphans
        # exist, surface a warning rather than silently exit 0 ("No orphan...") — user might
        # think the removal succeeded when actually nothing was checked against their request.
        if (-not [string]::IsNullOrWhiteSpace($RemoveSite)) {
            [Console]::Error.WriteLine("Warning: -RemoveSite '$RemoveSite' specified but no orphans found. Nothing matched your request.")
        }
        Write-Output 'No orphan IIS Express instances or stale temp files found.'
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
                    # Stop-Process returns before the process is gone, and step 6 below deletes the
                    # temp files it still holds. Remove-PerLaunchTempFile retries, but waiting here
                    # removes the cause instead of absorbing it.
                    Wait-Process -Id $info.Pid -Timeout 10 -ErrorAction SilentlyContinue
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

    # 6. remove stale per-launch temp files (.config / .out.log / .err.log) when -RemoveAll given.
    #    (For -RemoveSite, leave temp files alone — they're keyed by identity-hash, not site
    #    name, so we can't reliably correlate to a single requested site.)
    if ($RemoveAll -and $orphanTempFiles.Count -gt 0) {
        foreach ($tf in $orphanTempFiles) {
            # Same retry as the stop path: this sweep can run right after killing an orphan, and
            # the just-killed process still holds its redirected .out.log / .err.log for a moment.
            $removal = Remove-PerLaunchTempFile -Path $tf
            if ($removal.Removed) {
                Write-Output "Removed orphan temp file: $tf"
            } else {
                [Console]::Error.WriteLine("Warning: failed to remove orphan temp file '$tf': $($removal.Error)")
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
