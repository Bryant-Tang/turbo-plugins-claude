param(
    [string]$Project = '',
    [string]$Arguments = '',
    [string]$WorkingDirectory = '',
    [string]$Configuration = '',
    [int]$Timeout = 0,
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Run a .NET Framework CONSOLE project's built executable -- the console half of "give the agent a
# VS 2022". Visual Studio's Ctrl+F5 is the model: it runs the exe with the arguments and working
# directory stored per MACHINE in <project>.csproj.user, and it does not track the process
# afterwards. We store the same two settings in .turbo-plugin/config.local.toml [run], which is
# gitignored for the same reason VS keeps them out of the .csproj: they are one developer's.
#
# Deliberately NOT here (D5, "match VS, do not exceed it"): no publish (VS has no publish for a
# .NET Framework console -- right-click Publish is ClickOnce, a different thing), and no orphan
# cleanup (VS does not track a Ctrl+F5 process either).
#
# Waiting: most console projects are one-shot -- a report tool, a migration -- and the useful
# result is its output and exit code, so we wait. A long-running one would hang that wait forever,
# so the wait is bounded: past the timeout we report it as still running, record the PID, and
# leave it alone. Stop-Console then has something to stop.
try {
    Probe-GitVersion

    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot

    # run/stop share the 'run' section (which falls back to [build].project). A .sln is rejected --
    # running needs one project, and the exe path is derived from this csproj.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project
    $projectFile = $target.Path
    $projectDir = [System.IO.Path]::GetDirectoryName($projectFile)

    # Guard, even though the SKILL is supposed to dispatch on this: running a class library or a web
    # project produces no exe, and "file not found" would be a confusing way to learn that.
    $outputType = Get-MsbuildProperty -Path $projectFile -Name 'OutputType'
    if ([string]::IsNullOrWhiteSpace($outputType)) {
        throw "Cannot tell what kind of project this is: $projectFile has no <OutputType>. A console project declares Exe (or WinExe)."
    }
    if ($outputType -notmatch '^(Exe|WinExe)$') {
        throw "Not a console project: $projectFile has <OutputType>$outputType</OutputType>. Use the IIS Express path for a web project."
    }

    # Which exe. AssemblyName defaults to the csproj stem, exactly as MSBuild does.
    $assemblyName = Get-MsbuildProperty -Path $projectFile -Name 'AssemblyName'
    if ([string]::IsNullOrWhiteSpace($assemblyName)) {
        $assemblyName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile)
    }
    $binDir = [System.IO.Path]::Combine($projectDir, 'bin')

    $cfg = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'run' -Key 'configuration' -CliValue $Configuration -Default $null
    $exePath = ''
    if (-not [string]::IsNullOrWhiteSpace($cfg)) {
        $exePath = [System.IO.Path]::Combine($binDir, $cfg, "$assemblyName.exe")
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
            throw "No built executable for configuration '$cfg': $exePath`nBuild the project first."
        }
    } else {
        # No configuration named: run the most recently BUILT one. That is what "run what I just
        # built" means, and it avoids inventing a default that disagrees with whatever the last
        # build actually produced (build deliberately omits /p:Configuration, VS-aligned).
        $candidates = @()
        if (Test-Path -LiteralPath $binDir -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $binDir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { [System.IO.Path]::Combine($_.FullName, "$assemblyName.exe") } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending)
        }
        if (@($candidates).Count -eq 0) {
            throw "No built executable found under $binDir (looked for $assemblyName.exe in each configuration folder). Build the project first."
        }
        $exePath = $candidates[0]
    }

    # Arguments / working directory: CLI wins, then the per-machine memory, then the exe's own
    # folder (which is what VS uses when the .csproj.user says nothing).
    $runArgs = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'run' -Key 'arguments' -CliValue $Arguments -Default $null
    $workDirRaw = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'run' -Key 'working_directory' -CliValue $WorkingDirectory -Default $null
    $workDir = if ([string]::IsNullOrWhiteSpace($workDirRaw)) {
        [System.IO.Path]::GetDirectoryName($exePath)
    } else {
        Resolve-RepoPath -RepoRoot $repoRoot -PathValue $workDirRaw
    }
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
        throw "Working directory does not exist: $workDir"
    }

    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $tempStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-console-$stamp.out.log")
    $tempStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-console-$stamp.err.log")

    Write-Output "Running $exePath"
    if (-not [string]::IsNullOrWhiteSpace($runArgs)) { Write-Output "  Arguments:         $runArgs" }
    Write-Output "  Working directory: $workDir"

    # -NoNewWindow so the process is a child we can wait on and redirect, instead of a detached
    # console window whose output nobody sees. Two separate files: Start-Process rejects one path
    # for both streams.
    $spArgs = @{
        FilePath               = $exePath
        WorkingDirectory       = $workDir
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $tempStdout
        RedirectStandardError  = $tempStderr
    }
    if (-not [string]::IsNullOrWhiteSpace($runArgs)) { $spArgs['ArgumentList'] = $runArgs }
    $process = Start-Process @spArgs

    # Touch .Handle immediately. Without it, a `Start-Process -PassThru` object reports
    # ExitCode as $NULL after the process ends -- even after WaitForExit() -- because the
    # process handle was never cached. Null then binds to the [int] parameter of the result
    # template as 0, so EVERY run would report "Exit code: 0" and this script would exit 0,
    # silently turning a failed console run into a success. Measured on PS 5.1; reading .Handle
    # once, up front, is the fix.
    $null = $process.Handle

    $cfgTimeout = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'run' -Key 'console_timeout_seconds' -CliValue $null -Default $null
    $timeoutSeconds = if ($Timeout -gt 0) { $Timeout } elseif ($null -ne $cfgTimeout) { [int]$cfgTimeout } else { 30 }

    $exited = $process.WaitForExit($timeoutSeconds * 1000)

    $stdoutText = ''
    $stderrText = ''
    foreach ($pair in @(@{ P = $tempStdout; N = 'stdout' }, @{ P = $tempStderr; N = 'stderr' })) {
        if (Test-Path -LiteralPath $pair.P -PathType Leaf) {
            try { $t = [System.IO.File]::ReadAllText($pair.P) } catch { $t = '' }
            if ($pair.N -eq 'stdout') { $stdoutText = $t } else { $stderrText = $t }
        }
    }

    $stateFile = [System.IO.Path]::Combine($repoRoot, '.turbo-plugin', 'console-run.local.json')

    if ($exited) {
        # One-shot: the output and the exit code ARE the result, so relay them and clean up. No
        # state file is written -- there is nothing left to stop.
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) { Write-Output $stdoutText.TrimEnd() }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) { [Console]::Error.WriteLine($stderrText.TrimEnd()) }
        foreach ($f in @($tempStdout, $tempStderr)) {
            if (Test-Path -LiteralPath $f -PathType Leaf) { try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { } }
        }
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction Stop } catch { }
        }
        Write-Output 'RUN_OUTPUT (relay these lines to the user as the run result):'
        foreach ($l in (Format-ConsoleRunResultLines -ResolvedTarget $projectFile -ExePath $exePath -ExitCode $process.ExitCode)) { Write-Output $l }
        exit $process.ExitCode
    }

    # Still running past the timeout: a long-lived console. Record just enough for Stop-Console to
    # be SURE it is stopping the same process -- a PID alone is reused by the OS, so the start time
    # is recorded with it and both must match.
    $tpDir = [System.IO.Path]::Combine($repoRoot, '.turbo-plugin')
    if (-not (Test-Path -LiteralPath $tpDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $tpDir -Force }
    $state = [pscustomobject]@{
        pid       = $process.Id
        startTime = $process.StartTime.ToUniversalTime().ToString('o')
        exePath   = $exePath
        project   = $projectFile
        stdout    = $tempStdout
        stderr    = $tempStderr
    }
    Write-Utf8NoBom -Path $stateFile -Content (($state | ConvertTo-Json -Depth 3) + "`n")

    Write-Output 'RUN_OUTPUT (relay these lines to the user as the run result):'
    foreach ($l in (Format-ConsoleRunResultLines -ResolvedTarget $projectFile -ExePath $exePath -ProcessId $process.Id -LogPath $tempStdout)) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
