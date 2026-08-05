# Console.test.ps1 (Pester 5)
#
# Scripts under test: scripts/Start-Console.ps1 + scripts/Stop-Console.ps1 -- the console half of
# "give the agent a VS 2022" (U11).
#
# No MSBuild here. A "built executable" is faked by COPYING a small system exe to the path the
# script derives (bin/<cfg>/<AssemblyName>.exe): where.exe for the one-shot shape (prints, exits)
# and ping.exe for the long-running shape (survives a redirected stdout, unlike timeout.exe, which
# refuses when input is redirected). What is under test is the script's resolution, waiting,
# reporting and process bookkeeping -- none of which needs a real .NET build.

# Computed at DISCOVERY time, not in BeforeAll: Pester 5 evaluates `-Skip:` while discovering, so a
# flag set in BeforeAll reads back as $null there and every case silently SKIPs on a machine that
# can run them perfectly well.
$script:CanRunConsoleCases = ($null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) -and
                             (Test-Path -LiteralPath ([System.IO.Path]::Combine($env:SystemRoot, 'System32', 'where.exe'))) -and
                             (Test-Path -LiteralPath ([System.IO.Path]::Combine($env:SystemRoot, 'System32', 'PING.EXE')))

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:StartScript = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Start-Console.ps1')
    $script:StopScript  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Stop-Console.ps1')

    function New-ConsoleSandbox {
        param([string]$Tag, [string]$OutputType = 'Exe')
        $dir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-console-$Tag-$([Guid]::NewGuid().ToString('N').Substring(0,10))")
        $null = New-Item -ItemType Directory -Path $dir -Force
        $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($dir, '.turbo-plugin')) -Force
        $csproj = @"
<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <OutputType>$OutputType</OutputType>
    <AssemblyName>ReportTool</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
"@
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, 'ReportTool.csproj'), $csproj, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($dir, '.turbo-plugin', 'config.toml'),
            "[run]`r`nproject = `"ReportTool.csproj`"`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
        # Start-Console calls Probe-GitVersion and resolves paths against the repo root; a git repo
        # is the ordinary shape and costs nothing here.
        Push-Location -LiteralPath $dir
        try {
            & git init -q 2>$null | Out-Null
            & git config user.email 'test@example.invalid' 2>$null | Out-Null
            & git config user.name 'Test' 2>$null | Out-Null
        } finally { Pop-Location }
        return $dir
    }

    function Add-FakeBuiltExe {
        param([string]$SandboxDir, [string]$Configuration = 'Debug', [ValidateSet('oneshot', 'longrunning')][string]$Kind = 'oneshot')
        $binCfg = [System.IO.Path]::Combine($SandboxDir, 'bin', $Configuration)
        $null = New-Item -ItemType Directory -Path $binCfg -Force
        $source = if ($Kind -eq 'oneshot') {
            [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'where.exe')
        } else {
            [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'PING.EXE')
        }
        $dest = [System.IO.Path]::Combine($binCfg, 'ReportTool.exe')
        Copy-Item -LiteralPath $source -Destination $dest -Force
        return $dest
    }

    # Read a file that another process still has open for writing.
    function Read-SharedText {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        $fs = $null; $sr = $null
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } catch {
            return ''
        } finally {
            if ($null -ne $sr) { $sr.Dispose() }
            if ($null -ne $fs) { $fs.Dispose() }
        }
    }

    function Remove-ConsoleSandbox {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try { if ([System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::Delete($Dir, $true) } } catch { }
    }

    function Invoke-ConsoleScript {
        param([string]$ScriptPath, [string]$WorkDir, [string[]]$ScriptArgs = @())
        $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-cons-out-$([Guid]::NewGuid().ToString('N')).txt")
        $errFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-cons-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"')) +
                       @($ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $WorkDir `
                                  -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                                  -NoNewWindow -PassThru -Wait
            $out = if (Test-Path -LiteralPath $outFile -PathType Leaf) { [System.IO.File]::ReadAllText($outFile) } else { '' }
            $err = if (Test-Path -LiteralPath $errFile -PathType Leaf) { [System.IO.File]::ReadAllText($errFile) } else { '' }
            return @{ Stdout = $out; Stderr = $err; Combined = ($out + "`n" + $err); Exit = $proc.ExitCode }
        } finally {
            foreach ($f in @($outFile, $errFile)) {
                if (Test-Path -LiteralPath $f -PathType Leaf) { try { [System.IO.File]::Delete($f) } catch { } }
            }
        }
    }
}

Describe 'Start-Console / Stop-Console (U11)' {

    It 'both scripts exist' {
        Test-Path -LiteralPath $script:StartScript -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:StopScript -PathType Leaf | Should -BeTrue
    }

    It 'refuses a project that is not a console project, naming the OutputType' -Skip:(-not $script:CanRunConsoleCases) {
        # The SKILL dispatches on project type, but running a Library produces no exe and
        # "file not found" would be a confusing way to learn that.
        $sb = New-ConsoleSandbox -Tag 'lib' -OutputType 'Library'
        try {
            $r = Invoke-ConsoleScript -ScriptPath $script:StartScript -WorkDir $sb
            $r.Exit | Should -Not -Be 0
            $r.Combined | Should -Match 'Not a console project'
            $r.Combined | Should -Match 'Library'
        } finally { Remove-ConsoleSandbox -Dir $sb }
    }

    It 'says to build first when there is no executable' -Skip:(-not $script:CanRunConsoleCases) {
        $sb = New-ConsoleSandbox -Tag 'nobuild'
        try {
            $r = Invoke-ConsoleScript -ScriptPath $script:StartScript -WorkDir $sb
            $r.Exit | Should -Not -Be 0
            $r.Combined | Should -Match '(?i)build the project first'
        } finally { Remove-ConsoleSandbox -Dir $sb }
    }

    It 'runs a one-shot to completion and reports its exit code, leaving no state behind' -Skip:(-not $script:CanRunConsoleCases) {
        $sb = New-ConsoleSandbox -Tag 'oneshot'
        try {
            $null = Add-FakeBuiltExe -SandboxDir $sb -Kind 'oneshot'
            # where.exe with a name it will find: exits 0 quickly and prints a path.
            # 'where.exe' is a name the copied where.exe will resolve, so it exits 0 with output.
            $r = Invoke-ConsoleScript -ScriptPath $script:StartScript -WorkDir $sb -ScriptArgs @('-Arguments', 'where.exe')
            $r.Exit | Should -Be 0
            $r.Stdout | Should -Match 'RUN_OUTPUT'
            $r.Stdout | Should -Match 'Target:.*ReportTool\.csproj'
            $r.Stdout | Should -Match 'Executable:.*ReportTool\.exe'
            $r.Stdout | Should -Match 'Exit code: 0'
            # A finished one-shot has nothing to stop, so no state file may be left.
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($sb, '.turbo-plugin', 'console-run.local.json'))) | Should -BeFalse
        } finally { Remove-ConsoleSandbox -Dir $sb }
    }

    It 'passes the exit code of a failing one-shot straight through' -Skip:(-not $script:CanRunConsoleCases) {
        $sb = New-ConsoleSandbox -Tag 'oneshotfail'
        try {
            $null = Add-FakeBuiltExe -SandboxDir $sb -Kind 'oneshot'
            # where.exe exits 1 when it finds nothing -- the console equivalent of "the tool ran and
            # reported a failure", which must not be flattened into success.
            $r = Invoke-ConsoleScript -ScriptPath $script:StartScript -WorkDir $sb -ScriptArgs @('-Arguments', 'no-such-binary-xyz.exe')
            $r.Exit | Should -Be 1
            $r.Stdout | Should -Match 'Exit code: 1'
        } finally { Remove-ConsoleSandbox -Dir $sb }
    }

    It 'reports a long-running console as still running, records it, and Stop-Console stops it' -Skip:(-not $script:CanRunConsoleCases) {
        $sb = New-ConsoleSandbox -Tag 'longrun'
        $stateFile = [System.IO.Path]::Combine($sb, '.turbo-plugin', 'console-run.local.json')
        $recordedPid = 0
        try {
            $null = Add-FakeBuiltExe -SandboxDir $sb -Kind 'longrunning'
            # NOT the -Wait harness used elsewhere. The launched console inherits the redirected
            # stdout handle, so `Start-Process -Wait` on the powershell child does not return until
            # the GRANDCHILD also exits -- i.e. it would wait out the full ping and there would be
            # nothing still running left to observe. Launch detached and poll for the state file.
            $startOut = [System.IO.Path]::Combine($sb, 'start.out.txt')
            $launcher = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:StartScript + '"'),
                                '-Arguments', '"-n 60 127.0.0.1"', '-Timeout', '2') `
                -WorkingDirectory $sb -NoNewWindow -PassThru -RedirectStandardOutput $startOut `
                -RedirectStandardError ([System.IO.Path]::Combine($sb, 'start.err.txt'))
            $null = $launcher.Handle

            # Wait for the STATUS LINE, not just the state file. Start-Console records the run and
            # then prints its status, so polling only for the state file and reading the output on
            # the very next line races that ordering: on a fast dev box the line is always there,
            # on a loaded CI runner it is not yet -- green that depended on the machine's speed.
            # Shared read throughout: the launched console inherited this handle and still holds
            # it, so ReadAllText would fail with "used by another process".
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            $startText = ''
            while ([datetime]::UtcNow -lt $deadline) {
                if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
                    $startText = Read-SharedText -Path $startOut
                    if ($startText -match 'Status: still running') { break }
                }
                Start-Sleep -Milliseconds 250
            }
            (Test-Path -LiteralPath $stateFile) | Should -BeTrue -Because 'a console still running past the wait must be recorded'
            $startText | Should -Match 'Status: still running'

            $state = [System.IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
            $recordedPid = [int]$state.pid
            # PID alone is not enough to identify a process later (the OS reuses ids), so the start
            # time must be recorded with it.
            $state.startTime | Should -Not -BeNullOrEmpty
            (Get-Process -Id $recordedPid -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty

            # The per-launch redirect logs the stop path is supposed to clean up. Captured BEFORE
            # the stop, because the stop deletes the state file that names them.
            $launchLogs = @()
            foreach ($k in @('stdout', 'stderr')) {
                if ($state.PSObject.Properties.Name -contains $k) {
                    $v = [string]$state.$k
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $launchLogs += $v }
                }
            }
            $launchLogs.Count | Should -BeGreaterThan 0 -Because 'otherwise the no-leak assertion below proves nothing'

            $s = Invoke-ConsoleScript -ScriptPath $script:StopScript -WorkDir $sb
            $s.Exit | Should -Be 0
            $s.Stdout | Should -Match 'STOP_OUTPUT'
            $s.Stdout | Should -Match 'Stopped: yes'
            Start-Sleep -Milliseconds 300
            (Get-Process -Id $recordedPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
            (Test-Path -LiteralPath $stateFile) | Should -BeFalse

            # Stop-Process returns BEFORE the killed process releases these handles, so deleting
            # them on the next line loses the race -- and the old code swallowed the failure, so the
            # leak was silent. A stop that reports success must leave nothing behind.
            foreach ($lg in $launchLogs) {
                (Test-Path -LiteralPath $lg) | Should -BeFalse -Because "stop must not leak the per-launch log $lg"
            }
            $s.Stdout | Should -Not -Match 'failed to remove per-launch temp file'
        } finally {
            if ($recordedPid -gt 0) { try { Stop-Process -Id $recordedPid -Force -ErrorAction SilentlyContinue } catch { } }
            Remove-ConsoleSandbox -Dir $sb
        }
    }

    # A source lock, not a behavioral test -- and it exists because the behavioral one is not
    # enough. The long-running case above asserts "the stop leaves no per-launch log behind", but
    # on a dev machine that assertion stays GREEN with the fix removed: ping.exe tears down far
    # faster than iisexpress.exe, so the race never fires there. Keep that assertion as a
    # regression net (it will catch a leak on a slower host), but it cannot prove the fix is
    # needed, so "wait for the process to really exit" and "say so when removal fails" are pinned
    # here instead.
    #
    # Background: Stop-Process only requests termination and returns; the killed process still
    # holds the stdout/stderr files Start-Console redirected. The IIS path was fixed for exactly
    # this (Stop-Iis.ps1) and this sibling script was missed -- caught in PR review, not by tests.
    It 'Stop-Console waits for the process to exit and reports a removal it could not do' {
        $src = [System.IO.File]::ReadAllText($script:StopScript)

        $src | Should -Match 'Wait-Process\s+-Id'
        $src | Should -Match 'Wait-Process[^\r\n]*-Timeout\s+\d+'

        # Removal must go through the retrying helper, and must no longer swallow the failure with
        # `catch { }`: a stop that reports success while quietly leaking a file leaves the user
        # with no way to even know something leaked.
        $src | Should -Match 'Remove-PerLaunchTempFile'
        $src | Should -Match 'failed to remove per-launch temp file'
    }

    It 'stopping when nothing is running is a normal outcome, not an error' -Skip:(-not $script:CanRunConsoleCases) {
        # The common shape for a console project IS one-shot: it has already finished by the time
        # anyone asks to stop it. That must read as "nothing to stop", not as a failure.
        $sb = New-ConsoleSandbox -Tag 'stopnothing'
        try {
            $r = Invoke-ConsoleScript -ScriptPath $script:StopScript -WorkDir $sb
            $r.Exit | Should -Be 0
            $r.Stdout | Should -Match 'STOP_OUTPUT'
            $r.Stdout | Should -Match 'Stopped: nothing was running'
        } finally { Remove-ConsoleSandbox -Dir $sb }
    }

    It 'does not kill a reused PID: a stale record is discarded, not acted on' -Skip:(-not $script:CanRunConsoleCases) {
        # The worst thing this script could do is kill whatever process happens to hold a recycled
        # id. A record whose start time does not match the live process must be dropped.
        $sb = New-ConsoleSandbox -Tag 'stalepid'
        try {
            $victim = Start-Process -FilePath ([System.IO.Path]::Combine($env:SystemRoot, 'System32', 'PING.EXE')) `
                                    -ArgumentList '-n 60 127.0.0.1' -NoNewWindow -PassThru `
                                    -RedirectStandardOutput ([System.IO.Path]::Combine($sb, 'victim.log'))
            try {
                $state = [pscustomobject]@{
                    pid       = $victim.Id
                    startTime = ([datetime]'2001-01-01T00:00:00Z').ToString('o')   # deliberately wrong
                    exePath   = 'x'
                    project   = 'x'
                }
                [System.IO.File]::WriteAllText(
                    [System.IO.Path]::Combine($sb, '.turbo-plugin', 'console-run.local.json'),
                    ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

                $r = Invoke-ConsoleScript -ScriptPath $script:StopScript -WorkDir $sb
                $r.Exit | Should -Be 0
                $r.Stdout | Should -Match 'Stopped: nothing was running'
                (Get-Process -Id $victim.Id -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because 'an unrelated process must survive'
            } finally {
                try { Stop-Process -Id $victim.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        } finally { Remove-ConsoleSandbox -Dir $sb }
    }
}
