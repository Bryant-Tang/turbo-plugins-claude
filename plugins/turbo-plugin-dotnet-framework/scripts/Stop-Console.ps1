param(
    [string]$Project = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Stop a console process THIS TOOL started and that is still running. Nothing else.
#
# Scope is deliberate (D5): there is no orphan sweep for console projects, because Visual Studio
# does not track a Ctrl+F5 process either -- matching VS means matching what it does NOT do. The
# IIS side has orphan cleanup because IIS Express instances are long-lived, named, and genuinely do
# leak; a console the user started from their own terminal is not ours to kill.
#
# A one-shot project that has already finished is the normal case, not an error: Start-Console
# waited for it, reported its output, and removed the state file. Report "nothing to stop" and
# exit 0.
try {
    Probe-GitVersion

    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot
    $stateFile = [System.IO.Path]::Combine($repoRoot, '.turbo-plugin', 'console-run.local.json')

    $resolvedTarget = ''
    try {
        $t = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project -AllowMissing
        if ($null -ne $t) { $resolvedTarget = $t.Path }
    } catch {
        # A target that cannot be resolved is not a reason to fail a stop -- there may still be a
        # recorded process to stop, and the state file carries its own project path.
        $resolvedTarget = ''
    }

    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Write-Output 'No console process recorded by this tool is running (a one-shot run finishes on its own).'
        Write-Output 'STOP_OUTPUT (relay these lines to the user as the stop result):'
        foreach ($l in (Format-ConsoleStopResultLines -ResolvedTarget $resolvedTarget -Stopped $false)) { Write-Output $l }
        exit 0
    }

    $state = $null
    try {
        $state = [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        $state = $null
    }
    if ($null -eq $state) {
        # An unreadable record is not something to act on: without a verified PID+start-time pair
        # there is nothing safe to kill. Clear it so the next run starts from a clean slate.
        try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction Stop } catch { }
        Write-Output 'The recorded console-run state was unreadable and has been cleared; nothing was stopped.'
        Write-Output 'STOP_OUTPUT (relay these lines to the user as the stop result):'
        foreach ($l in (Format-ConsoleStopResultLines -ResolvedTarget $resolvedTarget -Stopped $false)) { Write-Output $l }
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($resolvedTarget) -and $state.PSObject.Properties.Name -contains 'project') {
        $resolvedTarget = [string]$state.project
    }

    $proc = $null
    try { $proc = Get-Process -Id ([int]$state.pid) -ErrorAction Stop } catch { $proc = $null }

    # PID + start time, not PID alone: the OS reuses process ids, and killing whatever happens to
    # hold that number now would be the single worst thing this script could do.
    $isOurs = $false
    if ($null -ne $proc) {
        try {
            $recorded = [datetime]::Parse([string]$state.startTime).ToUniversalTime()
            $actual = $proc.StartTime.ToUniversalTime()
            $isOurs = ([math]::Abs(($actual - $recorded).TotalSeconds) -lt 2)
        } catch {
            $isOurs = $false
        }
    }

    if (-not $isOurs) {
        try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction Stop } catch { }
        Write-Output 'That run has already finished; nothing to stop.'
        Write-Output 'STOP_OUTPUT (relay these lines to the user as the stop result):'
        foreach ($l in (Format-ConsoleStopResultLines -ResolvedTarget $resolvedTarget -Stopped $false)) { Write-Output $l }
        exit 0
    }

    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
    Write-Output "Stopped the console process started by this tool (PID: $($proc.Id))."

    foreach ($k in @('stdout', 'stderr')) {
        if ($state.PSObject.Properties.Name -contains $k) {
            $f = [string]$state.$k
            if (-not [string]::IsNullOrWhiteSpace($f) -and (Test-Path -LiteralPath $f -PathType Leaf)) {
                try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { }
            }
        }
    }
    try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction Stop } catch { }

    Write-Output 'STOP_OUTPUT (relay these lines to the user as the stop result):'
    foreach ($l in (Format-ConsoleStopResultLines -ResolvedTarget $resolvedTarget -Stopped $true -ProcessId $proc.Id)) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
