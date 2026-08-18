param(
    [string]$Project = '',
    [string]$Arguments = '',
    [string]$WorkingDirectory = '',
    [string]$Configuration = '',
    [int]$Timeout = 0,
    [string]$RepoRoot = '',
    # Internal. Set only when this script re-enters itself as the launcher process described below;
    # never passed by a user or by the SKILL.
    [string]$LaunchSpec = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# ── internal launcher mode ───────────────────────────────────────────────────
# Started by the main path below through Win32_Process.Create, and doing exactly one thing: being a
# process the agent harness did NOT spawn. The console it starts inherits THIS process's handles,
# and this process inherited none of the harness's, so a console that outlives the run cannot hold
# the harness's output pipe open (issue #82). Measured: launcher exits, pipe reaches EOF.
#
# The spec arrives as a FILE, and that is the other half of the design. The user's -Arguments string
# reaches Start-Process -ArgumentList untouched -- straight to CreateProcess, no shell anywhere --
# which is what it did before this fix. Routing it through `cmd /s /c` instead was measured to be
# actively wrong, not merely risky:
#   sent `a&b`            -> the program received NOTHING; cmd ran `b` as a second command
#   sent `%USERNAME%`     -> silently expanded, and split into two arguments
#   sent `"%USERNAME%"`   -> STILL expanded; double quotes do not protect `%`
#   sent `x & echo PWNED` -> PWNED executed
# Escaping was rejected as the fix: `^` works outside quotes but is literal inside them, so getting
# it right means parsing the user's own quoting state -- the kind of code whose bugs are silent.
if (-not [string]::IsNullOrWhiteSpace($LaunchSpec)) {
    $spec = Get-Content -LiteralPath $LaunchSpec -Raw | ConvertFrom-Json
    $sp = @{
        FilePath               = $spec.exe
        WorkingDirectory       = $spec.workDir
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $spec.stdout
        RedirectStandardError  = $spec.stderr
    }
    if (-not [string]::IsNullOrWhiteSpace($spec.arguments)) { $sp['ArgumentList'] = $spec.arguments }
    $child = Start-Process @sp
    # Touch .Handle immediately. Without it a `Start-Process -PassThru` object reports ExitCode as
    # $null after the process ends -- even after WaitForExit() -- because the process handle was
    # never cached. Measured on PS 5.1.
    $null = $child.Handle
    [System.IO.File]::WriteAllText($spec.pidFile, [string]$child.Id)
    $child.WaitForExit()
    [System.IO.File]::WriteAllText($spec.codeFile, [string]$child.ExitCode)
    exit 0
}

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
    $tempExitCode = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-console-$stamp.code.txt")
    $tempPidFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-console-$stamp.pid.txt")
    $tempSpecFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-console-$stamp.spec.json")

    Write-Output "Running $exePath"
    if (-not [string]::IsNullOrWhiteSpace($runArgs)) { Write-Output "  Arguments:         $runArgs" }
    Write-Output "  Working directory: $workDir"

    # LAUNCHED VIA WMI, NOT Start-Process -- the same correctness fix as Start-Iis.ps1 (issue #82).
    #
    # Start-Process -NoNewWindow means UseShellExecute=$false, which makes CreateProcess pass
    # bInheritHandles=TRUE, so the launched program receives every inheritable handle this process
    # holds -- including the write end of the pipe the agent harness gave this powershell.exe. For a
    # one-shot run that is harmless (the program exits and the pipe closes with it), but a console
    # that is STILL RUNNING past the timeout is deliberately left alive: it then holds that write
    # end open after this script exits, the reader never sees EOF, and the harness's tool call never
    # returns. Measured directly, launcher started with a real stdout pipe and then allowed to exit:
    #   Start-Process -NoNewWindow -> launcher exited, pipe NEVER reached EOF
    #   Win32_Process.Create       -> launcher exited, pipe reached EOF immediately
    # Win32_Process.Create builds the process from the WMI service, so it inherits nothing of ours.
    #
    # CREATE_NEW_CONSOLE (16) + SW_HIDE (0): a console program with no console of its own can die on
    # startup, and the new one must not be visible.
    #
    # What gets launched is THIS SCRIPT AGAIN, in -LaunchSpec mode (see the top of the file), not
    # the program and not a shell. That intermediary is what keeps the user's -Arguments away from
    # any parser: it reads the spec from a file and hands the string straight to
    # Start-Process -ArgumentList, exactly as this script always did. A `cmd /s /c` wrapper was
    # tried first and is measurably unsafe -- `a&b` lost the second half to cmd, `%USERNAME%` was
    # expanded even inside double quotes, and `x & echo PWNED` ran.
    #
    # The exit code and the program's PID come back as FILES, written by the intermediary. Reading
    # them from a process object would not be reliable here: opening a handle right after
    # Win32_Process.Create fails about 1 in 25 times when the program exits instantly (measured over
    # 25 runs), and retrying cannot help because Create only returns once the process exists -- so a
    # failure means it is already gone. A program that exits instantly is exactly the crashing one
    # whose exit code matters most, and the old code turned an unreadable code into 0, i.e. a failed
    # run reported as success.
    $psHost = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    # NOT named $launchSpec: PowerShell variable names are case-insensitive, so that would BE the
    # [string]$LaunchSpec parameter, and assigning an object to it silently coerces via ToString()
    # -- the spec file then contains "@{exe=...; arguments=...}" instead of JSON, the intermediary
    # fails to read a property, and the only symptom is a launch that never reports back.
    $specObject = [pscustomobject]@{
        exe       = $exePath
        arguments = $runArgs
        workDir   = $workDir
        stdout    = $tempStdout
        stderr    = $tempStderr
        pidFile   = $tempPidFile
        codeFile  = $tempExitCode
    }
    Write-Utf8NoBom -Path $tempSpecFile -Content (($specObject | ConvertTo-Json -Depth 3) + "`n")

    # Only paths WE built go on this command line, and CreateProcess (not a shell) parses it.
    $spawnCommandLine = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -LaunchSpec "{2}"' -f `
        $psHost, $PSCommandPath, $tempSpecFile

    $startupClass = Get-CimClass -ClassName Win32_ProcessStartup
    $startupInfo = New-CimInstance -CimClass $startupClass -ClientOnly -Property @{
        CreateFlags = [uint32]16   # CREATE_NEW_CONSOLE
        ShowWindow  = [uint16]0    # SW_HIDE
    }
    $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine               = $spawnCommandLine
        CurrentDirectory          = $workDir
        ProcessStartupInformation = $startupInfo
    }
    if ($null -eq $spawn -or $spawn.ReturnValue -ne 0) {
        $rv = if ($null -eq $spawn) { 'null' } else { $spawn.ReturnValue }
        throw "無法啟動 console 程式:Win32_Process.Create 回傳 $rv。"
    }
    $helperPid = [int]$spawn.ProcessId

    $cfgTimeout = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'run' -Key 'console_timeout_seconds' -CliValue $null -Default $null
    $timeoutSeconds = if ($Timeout -gt 0) { $Timeout } elseif ($null -ne $cfgTimeout) { [int]$cfgTimeout } else { 30 }

    # The exit-code file appearing IS "the program finished" -- the intermediary writes it only
    # after WaitForExit returned, so it is a signal that does not depend on holding a process handle.
    $waitDeadline = (Get-Date).AddSeconds($timeoutSeconds)
    $exited = $false
    while ((Get-Date) -lt $waitDeadline) {
        if ([System.IO.File]::Exists($tempExitCode)) { $exited = $true; break }
        Start-Sleep -Milliseconds 100
    }

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
        # The file exists, but the write is not atomic: cmd may still be flushing it when the
        # existence check won the race. Re-read until it parses rather than reading a half-written
        # (or still-empty) file once and calling it an exit code.
        $rawCode = ''
        for ($i = 0; $i -lt 20; $i++) {
            try { $rawCode = [System.IO.File]::ReadAllText($tempExitCode) } catch { $rawCode = '' }
            if ($rawCode -match '^\s*-?\d+\s*$') { break }
            Start-Sleep -Milliseconds 50
        }
        # Relay the program's own output BEFORE deciding anything about the exit code: if the code
        # turns out to be unreadable we still owe the user what the program said.
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) { Write-Output $stdoutText.TrimEnd() }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) { [Console]::Error.WriteLine($stderrText.TrimEnd()) }
        # .NET, not Remove-Item: -LiteralPath still mangles a `~`, which every temp path has on a
        # machine with an 8.3 user profile -- and these `catch { }` blocks would have swallowed that
        # failure silently, leaking a temp file per run. See Remove-PerLaunchTempFile in Common.ps1.
        foreach ($f in @($tempStdout, $tempStderr, $tempExitCode, $tempPidFile, $tempSpecFile)) {
            if (Test-Path -LiteralPath $f -PathType Leaf) { try { [System.IO.File]::Delete($f) } catch { } }
        }
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            try { [System.IO.File]::Delete($stateFile) } catch { }
        }
        # Fail loudly rather than substituting a number. Reporting 0 for a run whose code could not
        # be read is the exact silent failure this whole path is built to prevent.
        if ($rawCode -notmatch '^\s*(-?\d+)\s*$') {
            throw "console 程式已結束,但讀不回它的離開碼(檔案內容:'$rawCode')。"
        }
        $exitCode = [int]$Matches[1]
        # One-shot: the output and the exit code ARE the result, so relay them and clean up. No
        # state file is written -- there is nothing left to stop.
        Write-Output 'RUN_OUTPUT (relay these lines to the user as the run result):'
        foreach ($l in (Format-ConsoleRunResultLines -ResolvedTarget $projectFile -ExePath $exePath -ExitCode $exitCode)) { Write-Output $l }
        exit $exitCode
    }

    # Still running past the timeout: a long-lived console. Record just enough for Stop-Console to
    # be SURE it is stopping the same process -- a PID alone is reused by the OS, so the start time
    # is recorded with it and both must match.
    # The PID to record is the PROGRAM's, not the intermediary's: Stop-Console stops what the user
    # started, and the intermediary exits by itself once the program does. The intermediary wrote it
    # to a file as soon as it had it, so it is read rather than searched for -- no WMI query, and
    # nothing to get wrong when an assembly name contains a quote or matches another process.
    $rawPid = ''
    for ($i = 0; $i -lt 40; $i++) {
        if ([System.IO.File]::Exists($tempPidFile)) {
            try { $rawPid = [System.IO.File]::ReadAllText($tempPidFile) } catch { $rawPid = '' }
            if ($rawPid -match '^\s*\d+\s*$') { break }
        }
        Start-Sleep -Milliseconds 50
    }
    if ($rawPid -notmatch '^\s*(\d+)\s*$') {
        throw "console 程式在 ${timeoutSeconds}s 後仍未結束,但讀不回它的行程 ID(檔案:$tempPidFile)。"
    }
    $process = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        throw "console 程式在 ${timeoutSeconds}s 後仍未結束,但無法開啟它的行程(PID $($Matches[1]))。"
    }

    $tpDir = [System.IO.Path]::Combine($repoRoot, '.turbo-plugin')
    if (-not (Test-Path -LiteralPath $tpDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $tpDir -Force }
    $state = [pscustomobject]@{
        pid       = $process.Id
        startTime = $process.StartTime.ToUniversalTime().ToString('o')
        exePath   = $exePath
        project   = $projectFile
        stdout    = $tempStdout
        stderr    = $tempStderr
        # Written by the intermediary when the program eventually ends. Recorded so Stop-Console can
        # clean them up with the other two instead of leaving temp files behind per stopped run.
        exitCode  = $tempExitCode
        pidFile   = $tempPidFile
        spec      = $tempSpecFile
        # The intermediary's own PID. Stop-Console stops the PROGRAM, and only after that does the
        # intermediary write the exit-code file and exit -- so deleting that file without waiting
        # for it races the write and loses (the same shape as the Stop-Process teardown race already
        # handled there). Recording it makes that wait possible.
        helperPid = $helperPid
    }
    Write-Utf8NoBom -Path $stateFile -Content (($state | ConvertTo-Json -Depth 3) + "`n")

    Write-Output 'RUN_OUTPUT (relay these lines to the user as the run result):'
    foreach ($l in (Format-ConsoleRunResultLines -ResolvedTarget $projectFile -ExePath $exePath -ProcessId $process.Id -LogPath $tempStdout)) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
