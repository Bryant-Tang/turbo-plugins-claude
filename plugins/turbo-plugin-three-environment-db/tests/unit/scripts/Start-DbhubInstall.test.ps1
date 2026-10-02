# Start-DbhubInstall.test.ps1 (Pester 5)
#
# Script under test: scripts/start-dbhub.js -- the part AFTER config resolution: installing the
# pinned dbhub into the plugin's data directory and starting it from there. npm is replaced by
# assets/fake-npm-cli.js (via TP_DBHUB_NPM_CLI), so nothing is downloaded. Twin of
# start-dbhub-install.test.sh; the reasoning (issue #200) is written there.

$script:HasNode = $null -ne (Get-Command node -ErrorAction SilentlyContinue)

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'start-dbhub.js')
    $script:FakeNpm = [System.IO.Path]::Combine($PSScriptRoot, 'assets', 'fake-npm-cli.js')
    $m = [regex]::Match([System.IO.File]::ReadAllText($script:ScriptUnderTest), '@bytebase/dbhub@(\d+\.\d+\.\d+)')
    $script:Version = $m.Groups[1].Value

    function Start-Launcher {
        param([string]$Ws, [switch]$NoWait)
        $script:OutFile = [System.IO.Path]::Combine($Ws, 'out.txt')
        $script:ErrFile = [System.IO.Path]::Combine($Ws, 'err.txt')
        $argList = @(('"' + $script:ScriptUnderTest + '"'), ('"' + $Ws + '"'))
        if ($NoWait) {
            return Start-Process -FilePath 'node' -ArgumentList $argList `
                                 -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile `
                                 -NoNewWindow -PassThru
        }
        $proc = Start-Process -FilePath 'node' -ArgumentList $argList `
                              -RedirectStandardOutput $script:OutFile -RedirectStandardError $script:ErrFile `
                              -NoNewWindow -PassThru -Wait
        return @{
            Exit   = $proc.ExitCode
            Stdout = [System.IO.File]::ReadAllText($script:OutFile)
            Stderr = [System.IO.File]::ReadAllText($script:ErrFile)
        }
    }

    function Get-NpmCalls {
        if (-not (Test-Path -LiteralPath $env:FAKE_NPM_CALLS -PathType Leaf)) { return 0 }
        return @([System.IO.File]::ReadAllLines($env:FAKE_NPM_CALLS)).Count
    }

    function Test-StagingLeft {
        param([string]$InstallDir)
        $parent = [System.IO.Path]::GetDirectoryName($InstallDir)
        if (-not (Test-Path -LiteralPath $parent)) { return $false }
        $leaf = [System.IO.Path]::GetFileName($InstallDir) + '.staging-*'
        return @(Get-ChildItem -LiteralPath $parent -Filter $leaf -Directory).Count -gt 0
    }
}

Describe 'start-dbhub install' {

    BeforeEach {
        $script:Ws = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-dbhub-inst-$([Guid]::NewGuid().ToString('N').Substring(0,12))")
        $tp = [System.IO.Path]::Combine($script:Ws, 'proj', '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tp -Force
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($tp, 'dbhub.local.toml'), "dsn = `"sqlserver://example`"`n")
        $env:CLAUDE_PLUGIN_DATA = [System.IO.Path]::Combine($script:Ws, 'data')
        $env:TP_DBHUB_NPM_CLI = $script:FakeNpm
        $env:FAKE_NPM_CALLS = [System.IO.Path]::Combine($script:Ws, 'npm-calls')
        $env:FAKE_NPM_MODE = $null
        $env:FAKE_NPM_DELAY_MS = $null
        $script:InstallDir = [System.IO.Path]::Combine($env:CLAUDE_PLUGIN_DATA, 'dbhub', $script:Version)
        $script:Marker = [System.IO.Path]::Combine($script:InstallDir, '.tp-installed')
        $script:Lock = $script:InstallDir + '.lock'
    }

    AfterEach {
        foreach ($n in @('CLAUDE_PLUGIN_DATA', 'TP_DBHUB_NPM_CLI', 'FAKE_NPM_CALLS', 'FAKE_NPM_MODE', 'FAKE_NPM_DELAY_MS')) {
            [System.Environment]::SetEnvironmentVariable($n, $null)
        }
        try { if ([System.IO.Directory]::Exists($script:Ws)) { [System.IO.Directory]::Delete($script:Ws, $true) } } catch { }
    }

    It 'first start installs, then runs dbhub with nothing else on stdout' -Skip:(-not $script:HasNode) {
        $r = Start-Launcher -Ws $script:Ws
        $r.Exit | Should -Be 0
        Get-NpmCalls | Should -Be 1
        $r.Stdout | Should -Match '(?m)^FAKE-DBHUB --transport stdio --config .*proj'
        # stdout is the MCP protocol channel; npm's own chatter must not reach it.
        $r.Stdout | Should -Not -Match 'added 1 package'
        @($r.Stdout.Trim() -split "`r?`n").Count | Should -Be 1
        Test-Path -LiteralPath $script:Marker -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:Lock | Should -BeFalse
        Test-StagingLeft -InstallDir $script:InstallDir | Should -BeFalse
    }

    It 'a second start does not touch npm' -Skip:(-not $script:HasNode) {
        $null = Start-Launcher -Ws $script:Ws
        $env:FAKE_NPM_MODE = 'fail'
        $r = Start-Launcher -Ws $script:Ws
        Get-NpmCalls | Should -Be 1
        $r.Stdout | Should -Match '(?m)^FAKE-DBHUB '
    }

    It 'a half-finished install (the #200 shape) is redone, not run' -Skip:(-not $script:HasNode) {
        $dist = [System.IO.Path]::Combine($script:InstallDir, 'node_modules', '@bytebase', 'dbhub', 'dist')
        $null = New-Item -ItemType Directory -Path $dist -Force
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dist, 'index.js'), "process.stdout.write('STALE\n')`n")
        $r = Start-Launcher -Ws $script:Ws
        Get-NpmCalls | Should -Be 1
        $r.Stdout | Should -Not -Match 'STALE'
        $r.Stdout | Should -Match '(?m)^FAKE-DBHUB '
    }

    It 'a failed install explains itself, exits 0 and keeps nothing' -Skip:(-not $script:HasNode) {
        $env:FAKE_NPM_MODE = 'fail'
        $r = Start-Launcher -Ws $script:Ws
        $r.Exit | Should -Be 0 -Because 'a non-zero exit is reported to the user as a crashed MCP server'
        $r.Stdout | Should -BeNullOrEmpty
        $r.Stderr | Should -Match 'did not finish'
        $r.Stderr | Should -Match 'E404'
        Test-Path -LiteralPath $script:InstallDir | Should -BeFalse
        Test-Path -LiteralPath $script:Lock | Should -BeFalse
        Test-StagingLeft -InstallDir $script:InstallDir | Should -BeFalse
    }

    It 'the install survives the launcher being killed' -Skip:(-not $script:HasNode) {
        $env:FAKE_NPM_MODE = 'slow'
        $env:FAKE_NPM_DELAY_MS = '3000'
        $proc = Start-Launcher -Ws $script:Ws -NoWait
        Start-Sleep -Seconds 1
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc.WaitForExit()
        Test-Path -LiteralPath $script:Marker -PathType Leaf | Should -BeFalse

        for ($i = 0; $i -lt 60; $i++) {
            if ((Test-Path -LiteralPath $script:Marker -PathType Leaf) -and -not (Test-Path -LiteralPath $script:Lock)) { break }
            Start-Sleep -Milliseconds 250
        }
        Test-Path -LiteralPath $script:Marker -PathType Leaf | Should -BeTrue

        $env:FAKE_NPM_MODE = $null
        $r = Start-Launcher -Ws $script:Ws
        Get-NpmCalls | Should -Be 1
        $r.Stdout | Should -Match '(?m)^FAKE-DBHUB '
    }

    It 'a lock left by a dead installer is taken over' -Skip:(-not $script:HasNode) {
        $null = New-Item -ItemType Directory -Path $script:Lock -Force
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Lock, 'pid'), "999999`n")
        $r = Start-Launcher -Ws $script:Ws
        $r.Stdout | Should -Match '(?m)^FAKE-DBHUB '
        Get-NpmCalls | Should -Be 1
    }
}
