# Stop-Iis.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework-web/scripts/Stop-Iis.ps1
# Behavior: 跑 [iis] enabled gate;若 enabled,從 CIM 找 iisexpress.exe 並用 /site:<name> match 殺。
#   無 instance → echo 提示 + exit 0;temp apphost 也順便清掉。
#
# Cases:
#   1. No IIS running: fresh fixture (沒有 iisexpress) → exit 0 + stdout 含「No IIS Express
#      process found for site」
#   2. [iis] enabled = false consistency: 改 config.toml 為 disabled → exit ≠ 0,stderr 含「IIS 已停用」
#   3. SKILL entry: 再呼叫 no-running case → 行為一致

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Stop-Iis.ps1')

    $script:TestRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'test-turbo-plugin')
    $script:CfgPath  = [System.IO.Path]::Combine($script:TestRoot, '.turbo-plugin', 'config.toml')

    # ─── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ───
    # wrap each git call so stderr noise doesn't trigger NativeCommandError termination.
    function Invoke-GitSilent {
        $allArgs = $args
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git @allArgs 2>$null | Out-Null
        } catch {
            # tolerate;tests assert outcomes from script-under-test, not fixture-init noise
        } finally {
            $ErrorActionPreference = $oldEap
        }
    }

    function Ensure-FixtureGit {
        if (-not [System.IO.Directory]::Exists($script:TestRoot)) { return $false }
        if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:TestRoot, '.git'))) {
            Push-Location -LiteralPath $script:TestRoot
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                Invoke-GitSilent add -A
                & git -c commit.gpgsign=false commit -q -m init *>$null
            } finally { Pop-Location }
        }
        return $true
    }

    function Set-IisEnabled {
        param([bool]$Enabled)
        if (-not [System.IO.File]::Exists($script:CfgPath)) { throw "cfg not found: $script:CfgPath" }
        $text = [System.IO.File]::ReadAllText($script:CfgPath, [System.Text.Encoding]::UTF8)
        $valueLine = if ($Enabled) { 'enabled = true' } else { 'enabled = false' }
        $patched = [regex]::Replace($text, '(?m)^enabled\s*=\s*(true|false)\s*$', $valueLine)
        [System.IO.File]::WriteAllText($script:CfgPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
    }

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
        $oldLoc = Get-Location
        try {
            Set-Location -LiteralPath $WorkDir
            $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
            $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
            try {
                # Quote -File (and any spaced ExtraArg) so a spaced repo/parent path (AE8) survives
                # Start-Process's naive space-join of -ArgumentList.
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) + @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
                $proc = Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList $argList -WorkingDirectory $WorkDir `
                    -RedirectStandardOutput $tmpStdout -RedirectStandardError $tmpStderr `
                    -NoNewWindow -PassThru -Wait
                $stdout = if (Test-Path -LiteralPath $tmpStdout -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStdout, [System.Text.Encoding]::UTF8) } else { '' }
                $stderr = if (Test-Path -LiteralPath $tmpStderr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStderr, [System.Text.Encoding]::UTF8) } else { '' }
                return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode }
            } finally {
                foreach ($t in @($tmpStdout, $tmpStderr)) {
                    if (Test-Path -LiteralPath $t -PathType Leaf) {
                        try { [System.IO.File]::Delete($t) } catch { }
                    }
                }
            }
        } finally { Set-Location -LiteralPath $oldLoc }
    }

    $script:FixtureReady = Ensure-FixtureGit
}

Describe 'Stop-Iis' {

    It 'fixture git repo is present (Reset-Fixture should have created it)' {
        $script:FixtureReady | Should -BeTrue
    }

    Context 'Case 1: no IIS running (fresh fixture, [iis]=true default)' {
        BeforeAll { $script:r1 = Invoke-Script -WorkDir $script:TestRoot }

        It 'no-IIS exit 0' { $script:r1.Exit | Should -Be 0 }
        It 'stdout 含 No IIS Express process found' {
            $script:r1.Stdout | Should -Match 'No IIS Express process found'
        }
        It 'emits STOP_OUTPUT template with the targeted site (KTD5)' {
            $script:r1.Stdout | Should -Match 'STOP_OUTPUT'
            $script:r1.Stdout | Should -Match 'Site: HelloApp-[0-9a-f]{8}'
        }
    }

    Context 'Case 4: .sln target rejected (run/stop need a csproj)' {
        BeforeAll {
            $script:rSln = Invoke-Script -WorkDir $script:TestRoot -ExtraArgs @('-Project', 'HelloApp.sln')
            $script:rSlnCombined = $script:rSln.Stdout + "`n" + $script:rSln.Stderr
        }
        It '.sln exit != 0' { ($script:rSln.Exit -ne 0) | Should -BeTrue }
        It '.sln message mentions .sln' { $script:rSlnCombined | Should -Match '\.sln' }
    }

    Context 'Case 2: [iis] disabled consistency' {
        BeforeAll {
            Set-IisEnabled -Enabled $false
            try {
                $script:r2 = Invoke-Script -WorkDir $script:TestRoot
            } finally {
                Set-IisEnabled -Enabled $true
            }
        }

        It '[iis]=false exit ≠ 0' { ($script:r2.Exit -ne 0) | Should -BeTrue }
        It 'stderr 含 IIS 已停用' {
            ($script:r2.Stdout + "`n" + $script:r2.Stderr) | Should -Match 'IIS 已停用'
        }
    }

    Context 'Case 3: SKILL entry re-invoke (no-running) → 一致' {
        BeforeAll { $script:r3 = Invoke-Script -WorkDir $script:TestRoot }

        It 'SKILL-entry no-IIS exit 0' { $script:r3.Exit | Should -Be 0 }
        It '訊息一致' { $script:r3.Stdout | Should -Match 'No IIS Express process found' }
    }
}
