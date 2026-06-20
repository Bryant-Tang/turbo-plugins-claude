# Compress-Content.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin/scripts/Compress-Content.ps1
#
# Scope (U4 plan):
#   - no [frontend] section in config.toml → skip + exit 0
#   - [frontend].dir points to missing directory → throw
#   - trust hash NOT approved → TRUST_REQUIRED token emitted + exit non-zero
#   - happy + 中文 source body byte-preserve (R18 source body axis):  package.json + .cs with
#     中文 string literal + approved trust hash + build_command = Copy-Item Sample.cs bin/ →
#     verify bin/Sample.cs bytes equal source bytes (UTF-8 canonical filesystem byte preservation).
#   - trust-gate side-effect cases (U4 / R4): blocked vs ran via sentinel-file observation.

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # ScriptsCommon.ps1 is the shared (non-Assert) helper lib: Invoke-PsScript / New-Sandbox /
    # Remove-Sandbox. (AssertHelpers is intentionally NOT sourced — asserts go through Pester Should.)
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $script:PluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:PluginRoot, 'scripts', 'Compress-Content.ps1')

    $script:ResetScript = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'reset', 'Reset-Fixture.ps1'))

    function Mirror-Base-To {
        # Run Reset-Fixture with -SkipSvn to mirror base/ into TestRoot.
        param([string]$TestRoot)
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $outFile = [System.IO.Path]::Combine([System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-reset-out-$stamp.txt")
        try {
            # `2>&1` 在 cmd.exe shell context 內,**不是** PS-level — cmd.exe 做 shell
            # 重導向,PS 看到的是 single stream,不會 trigger NativeCommandError。
            # -SvnRepo is required by Reset-Fixture's signature but unused under -SkipSvn; pass a
            # sandbox-relative throwaway path so no machine-local literal leaks into the tree.
            $unusedSvn = [System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'unused-svn')
            $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script:ResetScript`" -TestRoot `"$TestRoot`" -SvnRepo `"$unusedSvn`" -SkipSvn > `"$outFile`" 2>&1"
            & cmd.exe /c $cmdStr
            return $LASTEXITCODE
        } finally {
            if ([System.IO.File]::Exists($outFile)) { try { [System.IO.File]::Delete($outFile) } catch {} }
        }
    }

    function Compute-TrustHash {
        param([string]$InstallCmd, [string]$BuildCmd)
        $trustInput = "$InstallCmd|$BuildCmd"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($trustInput))
        } finally { $sha.Dispose() }
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    function Write-Utf8NoBom-Local {
        param([string]$Path, [string]$Content)
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $Content, $enc)
    }

    function Append-Utf8 {
        param([string]$Path, [string]$Content)
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, $Content, $enc)
    }

    # AE8: the sandbox may live under a spaced parent path, but the gate tokenizes install_command
    # on whitespace, so the sentinel redirect target must be space-free. Mint it under the system
    # drive root (always space-free + writable) instead of inside the spaced sandbox.
    function New-SpaceFreeSentinel {
        param([string]$Leaf = 'sentinel')
        $sysDrive = $env:SystemDrive
        if ([string]::IsNullOrWhiteSpace($sysDrive)) { $sysDrive = 'C:' }
        $dir = $sysDrive + '\tp-sentinel-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $null = New-Item -ItemType Directory -Path $dir -Force
        return [System.IO.Path]::Combine($dir, "$Leaf.txt")
    }

    function New-FrontendWithSentinel {
        param([string]$TestRoot, [string]$SentinelPath)
        $frontendDir = [System.IO.Path]::Combine($TestRoot, 'frontend')
        $null = New-Item -ItemType Directory -Path $frontendDir -Force
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')
        # `cmd /c type nul > <path>` creates an empty sentinel file. Path MUST be space-free (gate
        # tokenizes on whitespace — see New-SpaceFreeSentinel).
        $installCmd = "cmd /c type nul > $SentinelPath"
        $buildCmd   = ''
        $cfg = [System.IO.Path]::Combine($TestRoot, '.turbo-plugin', 'config.toml')
        Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"$installCmd`"`nbuild_command = `"$buildCmd`"`n"
        return [PSCustomObject]@{ InstallCmd = $installCmd; BuildCmd = $buildCmd }
    }

    $script:ScriptExists = [System.IO.File]::Exists($script:ScriptUnderTest)
}

Describe 'Compress-Content' {

    It 'script-under-test exists' {
        $script:ScriptExists | Should -BeTrue -Because "pack-content.ps1 expected at $script:ScriptUnderTest"
    }

    Context 'Case 1: no [frontend] section → "not configured" + exit 0' {
        BeforeAll {
            $sb1 = New-Sandbox -Tag 'pc-1'
            $script:sb1 = $sb1
            $testRoot = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
            $script:rc1 = Mirror-Base-To -TestRoot $testRoot
            $script:res1 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll { Remove-Sandbox -Dir $script:sb1 }

        It 'mirror exit 0' { $script:rc1 | Should -Be 0 }
        It 'no-frontend exit code 0' {
            $script:res1.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res1.Stdout)`nstderr:`n$($script:res1.Stderr)"
        }
        It 'no-frontend stdout contains "not configured"' {
            $script:res1.Stdout | Should -Match 'not configured'
        }
    }

    Context 'Case 2: [frontend].dir → missing dir → "does not exist" + exit non-zero' {
        BeforeAll {
            $sb2 = New-Sandbox -Tag 'pc-2'
            $script:sb2 = $sb2
            $testRoot = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $cfg = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
            Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./no-such-frontend-dir`"`n"
            $script:res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll { Remove-Sandbox -Dir $script:sb2 }

        It 'missing-dir exit != 0' { ($script:res2.ExitCode -ne 0) | Should -BeTrue }
        It 'missing-dir stderr contains "does not exist"' {
            $script:res2.Combined | Should -Match 'does not exist'
        }
    }

    Context 'Case 3: [frontend] configured + package.json present, no trust file → TRUST_REQUIRED' {
        BeforeAll {
            $sb3 = New-Sandbox -Tag 'pc-3'
            $script:sb3 = $sb3
            $testRoot = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $frontendDir = [System.IO.Path]::Combine($testRoot, 'frontend')
            $null = New-Item -ItemType Directory -Path $frontendDir -Force
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')
            $cfg = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
            Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"cmd /c echo install`"`nbuild_command = `"cmd /c echo build`"`n"
            $script:res3 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll { Remove-Sandbox -Dir $script:sb3 }

        It 'trust-required exit != 0' { ($script:res3.ExitCode -ne 0) | Should -BeTrue }
        It 'stdout contains TRUST_REQUIRED token' {
            $script:res3.Stdout | Should -Match 'TRUST_REQUIRED'
        }
    }

    Context 'Case 4: 中文 source body byte-preserve through pack (R18; dict #5.3)' {
        BeforeAll {
            $sb4 = New-Sandbox -Tag 'pc-4'
            $script:sb4 = $sb4
            $testRoot = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot

            # Frontend dir + package.json
            $frontendDir = [System.IO.Path]::Combine($testRoot, 'frontend')
            $null = New-Item -ItemType Directory -Path $frontendDir -Force
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')

            # 中文 source file with string literal #5.3
            $zh53     = '"中文錯誤訊息:檔案不存在"'
            $srcBody  = "namespace HelloApp {`r`n    public class Sample {`r`n        // 中文註解:確認 byte preserve`r`n        public string Get() { return $zh53; }`r`n    }`r`n}`r`n"
            $srcFile = [System.IO.Path]::Combine($frontendDir, 'Sample.cs')
            Write-Utf8NoBom-Local -Path $srcFile -Content $srcBody
            $script:srcBytes4 = [System.IO.File]::ReadAllBytes($srcFile)

            # bin/ dir for build output target
            $binDir = [System.IO.Path]::Combine($frontendDir, 'bin')
            $null = New-Item -ItemType Directory -Path $binDir -Force
            $script:dstFile4 = [System.IO.Path]::Combine($binDir, 'Sample.cs')

            # Pre-approve trust by writing pack-content-trust.local.toml with matching hash.
            $installCmd = 'cmd /c echo install-ok'
            # build_command:in PowerShell, Copy-Item preserves bytes verbatim. Token-split-safe form.
            $buildCmd   = "powershell -NoProfile -Command Copy-Item Sample.cs bin\Sample.cs -Force"
            $cfg = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
            Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"$installCmd`"`nbuild_command = `"$buildCmd`"`n"

            $hash = Compute-TrustHash -InstallCmd $installCmd -BuildCmd $buildCmd
            $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
            Write-Utf8NoBom-Local -Path $trustFile -Content "approved_hash = `"$hash`"`n"

            $script:res4 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll { Remove-Sandbox -Dir $script:sb4 }

        It 'happy-path exit 0' {
            $script:res4.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res4.Stdout)`nstderr:`n$($script:res4.Stderr)"
        }
        It 'bin/Sample.cs created by build_command' {
            [System.IO.File]::Exists($script:dstFile4) | Should -BeTrue
        }
        It 'bin/Sample.cs byte-equal to source (中文 byte-preserve)' {
            [System.IO.File]::Exists($script:dstFile4) | Should -BeTrue
            $actualBytes = [System.IO.File]::ReadAllBytes($script:dstFile4)
            $actualBytes.Length | Should -Be $script:srcBytes4.Length
            for ($i = 0; $i -lt $script:srcBytes4.Length; $i++) {
                $actualBytes[$i] | Should -Be $script:srcBytes4[$i] -Because "byte mismatch at offset $i"
            }
        }
    }

    # ─── Trust-gate side-effect cases (U4 / R4) ──────────────────────────────────
    # The real security property: install/build commands must clear the trust-hash gate BEFORE
    # they execute. To distinguish "blocked" from "ran" we point install_command at a command
    # that leaves an observable trace (sentinel file) and assert presence/absence of it.

    Context 'Case 5: unapproved install_command → blocked before execution (sentinel absent)' {
        BeforeAll {
            $sb5 = New-Sandbox -Tag 'pc-5'
            $script:sb5 = $sb5
            $testRoot = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-unapproved'
            $script:sentinel5 = $sentinel
            $null = New-FrontendWithSentinel -TestRoot $testRoot -SentinelPath $sentinel
            # No pack-content-trust.local.toml written → gate must reject.
            $script:res5 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll {
            Remove-Sandbox -Dir $script:sb5
            if ($script:sentinel5) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sentinel5)) }
        }

        It 'unapproved exit != 0' { ($script:res5.ExitCode -ne 0) | Should -BeTrue }
        It 'unapproved emits TRUST_REQUIRED' { $script:res5.Stdout | Should -Match 'TRUST_REQUIRED' }
        It 'unapproved: sentinel NOT created (command did not run)' {
            [System.IO.File]::Exists($script:sentinel5) | Should -BeFalse -Because "sentinel unexpectedly present at $script:sentinel5"
        }
    }

    Context 'Case 6: trust file present but hash does not match config → blocked (sentinel absent)' {
        BeforeAll {
            $sb6 = New-Sandbox -Tag 'pc-6'
            $script:sb6 = $sb6
            $testRoot = [System.IO.Path]::Combine($sb6, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-stale'
            $script:sentinel6 = $sentinel
            $null = New-FrontendWithSentinel -TestRoot $testRoot -SentinelPath $sentinel
            # Write a trust file whose approved_hash is for *different* (old) commands —
            # simulates "config edited after approval". Hash must therefore mismatch.
            $staleHash = Compute-TrustHash -InstallCmd 'cmd /c echo old-install' -BuildCmd 'cmd /c echo old-build'
            $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
            Write-Utf8NoBom-Local -Path $trustFile -Content "approved_hash = `"$staleHash`"`n"
            $script:res6 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll {
            Remove-Sandbox -Dir $script:sb6
            if ($script:sentinel6) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sentinel6)) }
        }

        It 'stale-hash exit != 0' { ($script:res6.ExitCode -ne 0) | Should -BeTrue }
        It 'stale-hash emits TRUST_REQUIRED' { $script:res6.Stdout | Should -Match 'TRUST_REQUIRED' }
        It 'stale-hash: sentinel NOT created (command did not run)' {
            [System.IO.File]::Exists($script:sentinel6) | Should -BeFalse -Because "sentinel unexpectedly present at $script:sentinel6"
        }
    }

    Context 'Case 7: approved hash matches config → command runs (sentinel present, control group)' {
        BeforeAll {
            $sb7 = New-Sandbox -Tag 'pc-7'
            $script:sb7 = $sb7
            $testRoot = [System.IO.Path]::Combine($sb7, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-approved'
            $script:sentinel7 = $sentinel
            $cmds = New-FrontendWithSentinel -TestRoot $testRoot -SentinelPath $sentinel
            # Write a trust file whose approved_hash matches the *actual* configured commands.
            $hash = Compute-TrustHash -InstallCmd $cmds.InstallCmd -BuildCmd $cmds.BuildCmd
            $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
            Write-Utf8NoBom-Local -Path $trustFile -Content "approved_hash = `"$hash`"`n"
            $script:res7 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @()
        }
        AfterAll {
            Remove-Sandbox -Dir $script:sb7
            if ($script:sentinel7) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sentinel7)) }
        }

        It 'approved exit 0' {
            $script:res7.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res7.Stdout)`nstderr:`n$($script:res7.Stderr)"
        }
        It 'approved: sentinel created (command ran — gate did not over-block)' {
            [System.IO.File]::Exists($script:sentinel7) | Should -BeTrue -Because "sentinel missing at $script:sentinel7; stdout:`n$($script:res7.Stdout)`nstderr:`n$($script:res7.Stderr)"
        }
    }
}
