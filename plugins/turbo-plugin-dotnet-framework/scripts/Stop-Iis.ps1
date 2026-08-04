param(
    [string]$Project = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

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

    if ([string]::IsNullOrWhiteSpace($settings.IisConfigSiteName)) {
        throw 'No IIS site name resolved; cannot identify which IIS Express instance to stop.'
    }

    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'iisexpress.exe'" -ErrorAction SilentlyContinue)

    # Anchored site-name match: extract /site:<name> and compare exactly (no substring/glob ambiguity).
    $matched = @($processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
        $_.CommandLine -match '/site:([^\s"]+)' -and
        $Matches[1] -ieq $settings.IisConfigSiteName
    })

    if ($matched.Count -eq 0) {
        Write-Output "No IIS Express process found for site '$($settings.IisConfigSiteName)'."

        # Secondary scan: look for same csproj-stem but different hash (orphan from worktree rename).
        $csprojStem = [System.IO.Path]::GetFileNameWithoutExtension($settings.ProjectFile)
        $stemPattern = "^$([regex]::Escape($csprojStem))-[0-9a-f]{8}$"
        $orphans = @($processes | Where-Object {
            if ([string]::IsNullOrWhiteSpace($_.CommandLine)) { return $false }
            if ($_.CommandLine -notmatch '/site:([^\s"]+)') { return $false }
            # Capture $Matches[1] into a local before the next -match clobbers it.
            $candidateSite = $Matches[1]
            $candidateSite -match $stemPattern -and $candidateSite -ne $settings.IisConfigSiteName
        })
        if ($orphans.Count -gt 0) {
            $orphanList = ($orphans | ForEach-Object {
                $null = $_.CommandLine -match '/site:([^\s"]+)'
                "PID $($_.ProcessId) site=$($Matches[1])"
            }) -join '; '
            Write-Output "tp-stop 用當前 identity 撈不到 instance,但偵測到下列同 csproj-stem 但不同 hash 的 instance — 可能是 worktree rename 留的 orphan: $orphanList。請手動殺或跑 /tp-cleanup-orphan-iis."
        }
        # STOP result template (KTD5): report which site/target this stop acted on (糾錯閘),
        # even when no process was found. stop never triggers save-back.
        Write-Output 'STOP_OUTPUT (relay these lines to the user as the stop result):'
        foreach ($l in (Format-StopResultLines -Site $settings.IisConfigSiteName -ResolvedTarget $settings.ProjectFile)) { Write-Output $l }
        exit 0
    }

    foreach ($p in $matched) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Output "Stopped IIS Express PID $($p.ProcessId) (site: $($settings.IisConfigSiteName))"
        } catch {
            Write-Output "PID $($p.ProcessId) already exited: $($_.Exception.Message)"
        }
        # Stop-Process only *requests* termination and returns immediately -- the process is still
        # alive, still holding the stdout/stderr files Start-Iis redirected into %TEMP%. Deleting
        # them on the next line therefore races the teardown and loses. Wait for the process to
        # actually be gone first; that is the cause, and the retry inside
        # Remove-PerLaunchTempFile only covers the tail after it.
        Wait-Process -Id $p.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
    }

    # Clean up EVERY per-launch temp file this launch created, so a subsequent start-iis round
    # begins from a fresh copy of canonical -- and so a later cleanup-orphan-iis has nothing left
    # to report.
    #
    # The two redirect logs used to be left behind: only the .config was removed here, and the logs
    # were swept solely by remove-orphan-iis -RemoveAll. So after a perfectly clean stop, running
    # the orphan cleanup announced leftovers (ORPHAN_TEMP x2) -- and the user has no way to tell
    # "residue from the run I just shut down properly" from "something really is still running".
    # A stop that reports success must leave nothing for the cleanup tool to find. All three names
    # derive from the same IdentityHash, so this removes exactly this launch's files and cannot
    # touch another project's.
    $tempBase = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-plugin-iis-$($settings.IdentityHash)")
    foreach ($leftover in @("$tempBase.config", "$tempBase.out.log", "$tempBase.err.log")) {
        if (-not (Test-Path -LiteralPath $leftover -PathType Leaf)) { continue }
        $removal = Remove-PerLaunchTempFile -Path $leftover
        if ($removal.Removed) {
            Write-Output "Removed per-launch temp file: $leftover"
        } else {
            Write-Output "Note: failed to remove per-launch temp file '$leftover': $($removal.Error)"
        }
    }

    # STOP result template (KTD5): report which site/target was stopped (糾錯閘). No save-back.
    Write-Output 'STOP_OUTPUT (relay these lines to the user as the stop result):'
    foreach ($l in (Format-StopResultLines -Site $settings.IisConfigSiteName -ResolvedTarget $settings.ProjectFile)) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
