# Compress-Content.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework/scripts/Compress-Content.ps1
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
        # Run Reset-Fixture to mirror base/ into TestRoot (this plugin has no SVN concern).
        param([string]$TestRoot)
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $outFile = [System.IO.Path]::Combine([System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-reset-out-$stamp.txt")
        try {
            # `2>&1` here is the cmd.exe shell string's own redirection (NOT a PS-level `&`
            # redirection), so it does not trigger NativeCommandError.
            $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script:ResetScript`" -TestRoot `"$TestRoot`" > `"$outFile`" 2>&1"
            & cmd.exe /c $cmdStr
            return $LASTEXITCODE
        } finally {
            if ([System.IO.File]::Exists($outFile)) { try { [System.IO.File]::Delete($outFile) } catch {} }
        }
    }

    # -GroupKey mirrors the script: the bare [frontend] keeps the historical input verbatim so
    # approvals granted before groups existed still match, and a keyed group prefixes its key so
    # approving one project never authorises another.
    function Compute-TrustHash {
        param([string]$InstallCmd, [string]$BuildCmd, [string]$GroupKey = '')
        $trustInput = if ([string]::IsNullOrWhiteSpace($GroupKey)) { "$InstallCmd|$BuildCmd" } else { "$GroupKey|$InstallCmd|$BuildCmd" }
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

    # Two keyed [frontend] groups, one per project, each with its own frontend dir. Both groups
    # get the SAME install command on purpose in the isolation case; the caller decides.
    function New-KeyedFrontendProject {
        param([string]$TestRoot, [string]$ProjName, [string]$SentinelPath)
        $projDir = [System.IO.Path]::Combine($TestRoot, $ProjName)
        $frontendDir = [System.IO.Path]::Combine($projDir, 'frontend')
        $null = New-Item -ItemType Directory -Path $frontendDir -Force
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($projDir, "$ProjName.csproj"), '<Project/>')
        $installCmd = "cmd /c type nul > $SentinelPath"
        $cfg = [System.IO.Path]::Combine($TestRoot, '.turbo-plugin', 'config.toml')
        Append-Utf8 -Path $cfg -Content "`n[frontend.`"$ProjName`"]`ndir = `"./$ProjName/frontend`"`ninstall_command = `"$installCmd`"`nbuild_command = `"`"`n"
        return [PSCustomObject]@{
            Key         = $ProjName
            InstallCmd  = $installCmd
            BuildCmd    = ''
            ProjectFile = [System.IO.Path]::Combine($projDir, "$ProjName.csproj")
        }
    }

    # The hash the SCRIPT asks to have approved, harvested from its own TRUST_REQUIRED line.
    #
    # This is the oracle for every group-keyed case, and recomputing it with Compute-TrustHash
    # would NOT be: the test would then encode the same formula as the code, so removing the group
    # key from the hash changes both sides together and the case stays green. Measured, not
    # assumed -- that mutation was run and the mirrored version did not catch it. Harvesting is
    # also exactly what the SKILL does, so the case exercises the real approval path.
    #
    # The gate blocks before running anything, so harvesting has no side effects.
    function Get-EmittedTrustHash {
        param([string]$TestRoot, [string]$ProjectFile)
        $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $TestRoot -ScriptArgs @('-Project', $ProjectFile)
        $line = @($res.Stdout -split "`r?`n" | Where-Object { $_ -match '^TRUST_REQUIRED ' })[0]
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "fixture: expected TRUST_REQUIRED for '$ProjectFile' but got:`n$($res.Stdout)"
        }
        if ($line -notmatch 'hash=([0-9a-f]+)') {
            throw "fixture: TRUST_REQUIRED line carried no hash: $line"
        }
        return $Matches[1]
    }

    # Entries accumulate, one per approved command set -- [[approved]] is an array of tables, so
    # repeating it stays valid TOML (a repeated [approved] header would not).
    function Add-TrustEntry {
        param([string]$Path, [string]$GroupKey, [string]$Hash)
        Append-Utf8 -Path $Path -Content "`n[[approved]]`ngroup = `"$GroupKey`"`napproved_hash = `"$Hash`"`n"
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

    # Issue #61. Both hashed commands come from the VERSION-CONTROLLED config.toml, so every
    # worktree of a repo hashes identically -- re-approving per worktree bought no safety, it just
    # asked the user to nod at the same two commands again in each new worktree (the approval file
    # is gitignored, so a fresh worktree never has it).
    Context 'Case 8: a linked worktree honours the main worktree approval (#61)' {
        BeforeAll {
            $sb8 = New-Sandbox -Tag 'pc-8'
            $script:sb8 = $sb8
            $mainRoot = [System.IO.Path]::Combine($sb8, 'test-turbo-plugin')
            $script:mainRoot8 = $mainRoot
            $null = Mirror-Base-To -TestRoot $mainRoot
            $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-wt-inherit'
            $script:sentinel8 = $sentinel
            $cmds = New-FrontendWithSentinel -TestRoot $mainRoot -SentinelPath $sentinel

            # A real repo with a real linked worktree: the whole point is that the approval file is
            # gitignored and therefore absent from the new worktree.
            $script:git8 = $true
            $ea = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & git -C $mainRoot init -q -b main 2>$null | Out-Null
                & git -C $mainRoot config user.email 'test@turbo-plugin' 2>$null | Out-Null
                & git -C $mainRoot config user.name 'turbo-plugin-test' 2>$null | Out-Null
                & git -C $mainRoot add -A 2>$null | Out-Null
                & git -C $mainRoot -c commit.gpgsign=false commit -q -m init 2>$null | Out-Null
                $script:wt8 = [System.IO.Path]::Combine($sb8, 'linked-worktree')
                & git -C $mainRoot worktree add -q -b feat $script:wt8 2>$null | Out-Null
            } catch {
                $script:git8 = $false
            } finally {
                $ErrorActionPreference = $ea
            }
            if ($script:git8 -and -not (Test-Path -LiteralPath $script:wt8 -PathType Container)) { $script:git8 = $false }

            if ($script:git8) {
                # Approval recorded ONLY in the main worktree.
                $hash = Compute-TrustHash -InstallCmd $cmds.InstallCmd -BuildCmd $cmds.BuildCmd
                Write-Utf8NoBom-Local -Path ([System.IO.Path]::Combine($mainRoot, '.turbo-plugin', 'pack-content-trust.local.toml')) -Content "approved_hash = `"$hash`"`n"
                $script:res8 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $script:wt8 -ScriptArgs @()
            }
        }
        AfterAll {
            if ($script:git8 -and $script:wt8) {
                $ea = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { & git -C $script:mainRoot8 worktree remove --force $script:wt8 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $ea }
            }
            Remove-Sandbox -Dir $script:sb8
            if ($script:sentinel8) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sentinel8)) }
        }

        # Skip decided in the RUN phase, not via -Skip:. A -Skip: expression is evaluated at
        # DISCOVERY, when a flag set in BeforeAll is still $null -- the case would silently skip
        # itself and still report green.
        It 'runs without asking again (exit 0, no TRUST_REQUIRED)' {
            if (-not $script:git8) { Set-ItResult -Skipped -Because 'git worktree could not be created here'; return }
            $script:res8.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res8.Stdout)`nstderr:`n$($script:res8.Stderr)"
            $script:res8.Stdout | Should -Not -Match 'TRUST_REQUIRED'
        }

        It 'actually ran the command from the linked worktree (control: gate did not just pass silently)' {
            if (-not $script:git8) { Set-ItResult -Skipped -Because 'git worktree could not be created here'; return }
            [System.IO.File]::Exists($script:sentinel8) | Should -BeTrue -Because "sentinel missing at $script:sentinel8; stdout:`n$($script:res8.Stdout)"
        }
    }

    Context 'Case 9: an unapproved linked worktree is told to record approval in the MAIN worktree (#61)' {
        BeforeAll {
            $sb9 = New-Sandbox -Tag 'pc-9'
            $script:sb9 = $sb9
            $mainRoot = [System.IO.Path]::Combine($sb9, 'test-turbo-plugin')
            $script:mainRoot9 = $mainRoot
            $null = Mirror-Base-To -TestRoot $mainRoot
            $frontendDir = [System.IO.Path]::Combine($mainRoot, 'frontend')
            $null = New-Item -ItemType Directory -Path $frontendDir -Force
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')
            Append-Utf8 -Path ([System.IO.Path]::Combine($mainRoot, '.turbo-plugin', 'config.toml')) `
                -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"cmd /c echo install`"`nbuild_command = `"cmd /c echo build`"`n"

            $script:git9 = $true
            $ea = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & git -C $mainRoot init -q -b main 2>$null | Out-Null
                & git -C $mainRoot config user.email 'test@turbo-plugin' 2>$null | Out-Null
                & git -C $mainRoot config user.name 'turbo-plugin-test' 2>$null | Out-Null
                & git -C $mainRoot add -A 2>$null | Out-Null
                & git -C $mainRoot -c commit.gpgsign=false commit -q -m init 2>$null | Out-Null
                $script:wt9 = [System.IO.Path]::Combine($sb9, 'linked-worktree')
                & git -C $mainRoot worktree add -q -b feat $script:wt9 2>$null | Out-Null
            } catch {
                $script:git9 = $false
            } finally {
                $ErrorActionPreference = $ea
            }
            if ($script:git9 -and -not (Test-Path -LiteralPath $script:wt9 -PathType Container)) { $script:git9 = $false }
            if ($script:git9) {
                $script:res9 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $script:wt9 -ScriptArgs @()
            }
        }
        AfterAll {
            if ($script:git9 -and $script:wt9) {
                $ea = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { & git -C $script:mainRoot9 worktree remove --force $script:wt9 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $ea }
            }
            Remove-Sandbox -Dir $script:sb9
        }

        # Without this line the SKILL would write the approval into the worktree it happens to be
        # standing in, and the next worktree would ask all over again.
        It 'emits a TRUST_FILE line pointing at the main worktree' {
            if (-not $script:git9) { Set-ItResult -Skipped -Because 'git worktree could not be created here'; return }
            $script:res9.Stdout | Should -Match 'TRUST_REQUIRED'
            $line = @($script:res9.Stdout -split "`r?`n" | Where-Object { $_ -match '^TRUST_FILE ' })[0]
            $line | Should -Not -BeNullOrEmpty -Because "stdout:`n$($script:res9.Stdout)"
            $emitted = $line.Substring('TRUST_FILE '.Length).Trim()
            $expected = [System.IO.Path]::Combine($script:mainRoot9, '.turbo-plugin', 'pack-content-trust.local.toml')
            # Compare resolved forms: the sandbox path may reach the script via a different spelling.
            ([System.IO.Path]::GetFullPath($emitted)) | Should -Be ([System.IO.Path]::GetFullPath($expected))
        }
    }

    # ─── multi-project [frontend] groups (issue #125) ───────────────────────────
    # The bug being closed here was silent in both directions at once: the target project's
    # frontend never ran, and ANOTHER project's did -- successfully, in its own directory, so
    # nothing errored. Sentinels are what make "which one actually ran" observable; asserting on
    # stdout alone would pass for a script that printed the right thing and did the wrong thing.

    Context 'Case 10: -Project picks its own group, and only that group runs' {
        BeforeAll {
            $sb10 = New-Sandbox -Tag 'pc-10'
            $script:sb10 = $sb10
            $testRoot = [System.IO.Path]::Combine($sb10, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $script:sentA10 = New-SpaceFreeSentinel -Leaf 'sentinel-a'
            $script:sentB10 = New-SpaceFreeSentinel -Leaf 'sentinel-b'
            $a = New-KeyedFrontendProject -TestRoot $testRoot -ProjName 'proj-a' -SentinelPath $script:sentA10
            $b = New-KeyedFrontendProject -TestRoot $testRoot -ProjName 'proj-b' -SentinelPath $script:sentB10

            # BOTH approvals in one file: that also exercises the reader, which used to stop at the
            # first approved_hash and would therefore have compared proj-b's hash against proj-a's
            # entry forever. Hashes come from the script's own TRUST_REQUIRED line, not from a
            # recomputation here -- see Get-EmittedTrustHash.
            $hashA = Get-EmittedTrustHash -TestRoot $testRoot -ProjectFile $a.ProjectFile
            $hashB = Get-EmittedTrustHash -TestRoot $testRoot -ProjectFile $b.ProjectFile
            $script:distinct10 = ($hashA -ne $hashB)
            $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
            Write-Utf8NoBom-Local -Path $trustFile -Content "# approvals`n"
            # ORDER IS LOAD-BEARING: the entry for the project actually built (proj-a) is written
            # SECOND. With proj-a first, a reader that stops at the first approved_hash still
            # passes, and the "does not stop at the first" assertion below measures nothing --
            # measured, not assumed: that mutation was run and the first-entry version stayed green.
            Add-TrustEntry -Path $trustFile -GroupKey $b.Key -Hash $hashB
            Add-TrustEntry -Path $trustFile -GroupKey $a.Key -Hash $hashA

            $script:res10 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @('-Project', $a.ProjectFile)
        }
        AfterAll {
            Remove-Sandbox -Dir $script:sb10
            if ($script:sentA10) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sentA10)) }
            if ($script:sentB10) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sentB10)) }
        }

        It 'exits 0' {
            $script:res10.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res10.Stdout)`nstderr:`n$($script:res10.Stderr)"
        }
        It "runs the target project's frontend" {
            [System.IO.File]::Exists($script:sentA10) | Should -BeTrue -Because "stdout:`n$($script:res10.Stdout)"
        }
        It 'does NOT run the other project''s frontend' {
            [System.IO.File]::Exists($script:sentB10) | Should -BeFalse -Because 'that is exactly the silent mis-pack this change removes'
        }
        It 'both approvals in one file are honoured (reader does not stop at the first)' {
            $script:res10.Stdout | Should -Not -Match 'TRUST_REQUIRED'
        }
        It 'the two projects ask for DIFFERENT approvals despite living in one repo' {
            $script:distinct10 | Should -BeTrue -Because 'one approval must not cover another project'
        }
    }

    Context 'Case 11: approving one project does not authorise another with identical commands' {
        BeforeAll {
            $sb11 = New-Sandbox -Tag 'pc-11'
            $script:sb11 = $sb11
            $testRoot = [System.IO.Path]::Combine($sb11, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            # ONE sentinel, so both groups carry a byte-identical install_command. If the group key
            # were not part of the hash, approving proj-a would silently approve proj-b too -- and
            # the two are only identical today; proj-b's command is free to change tomorrow.
            $script:sent11 = New-SpaceFreeSentinel -Leaf 'sentinel-shared'
            $a = New-KeyedFrontendProject -TestRoot $testRoot -ProjName 'proj-a' -SentinelPath $script:sent11
            $b = New-KeyedFrontendProject -TestRoot $testRoot -ProjName 'proj-b' -SentinelPath $script:sent11
            $script:sameCmd11 = ($a.InstallCmd -eq $b.InstallCmd)

            # Record EXACTLY what a user approving proj-a would record: the hash the script itself
            # printed. Recomputing it here would make the case blind to the very thing it tests --
            # drop the group key from the hash and a mirrored fixture drops it too, so both sides
            # move together and nothing goes red.
            $hashA = Get-EmittedTrustHash -TestRoot $testRoot -ProjectFile $a.ProjectFile
            $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
            Write-Utf8NoBom-Local -Path $trustFile -Content "# approvals`n"
            Add-TrustEntry -Path $trustFile -GroupKey $a.Key -Hash $hashA

            $script:res11 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @('-Project', $b.ProjectFile)
        }
        AfterAll {
            Remove-Sandbox -Dir $script:sb11
            if ($script:sent11) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sent11)) }
        }

        It 'precondition: the two groups really do carry identical commands' {
            $script:sameCmd11 | Should -BeTrue -Because 'otherwise this case proves nothing about the key'
        }
        It 'still asks for approval' { $script:res11.Stdout | Should -Match 'TRUST_REQUIRED' }
        It 'names the group being approved' {
            $line = @($script:res11.Stdout -split "`r?`n" | Where-Object { $_ -match '^TRUST_GROUP ' })[0]
            $line | Should -Not -BeNullOrEmpty -Because "stdout:`n$($script:res11.Stdout)"
            $line.Substring('TRUST_GROUP '.Length).Trim() | Should -Be 'proj-b'
        }
        It 'nothing ran' {
            [System.IO.File]::Exists($script:sent11) | Should -BeFalse
        }
    }

    Context 'Case 12: a project no group names is reported as such, not as plain "not configured"' {
        BeforeAll {
            $sb12 = New-Sandbox -Tag 'pc-12'
            $script:sb12 = $sb12
            $testRoot = [System.IO.Path]::Combine($sb12, 'test-turbo-plugin')
            $null = Mirror-Base-To -TestRoot $testRoot
            $script:sent12 = New-SpaceFreeSentinel -Leaf 'sentinel-unmatched'
            $null = New-KeyedFrontendProject -TestRoot $testRoot -ProjName 'proj-a' -SentinelPath $script:sent12
            # proj-b exists as a project but has no group of its own.
            $projB = [System.IO.Path]::Combine($testRoot, 'proj-b')
            $null = New-Item -ItemType Directory -Path $projB -Force
            $bCsproj = [System.IO.Path]::Combine($projB, 'proj-b.csproj')
            [System.IO.File]::WriteAllText($bCsproj, '<Project/>')
            $script:res12 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $testRoot -ScriptArgs @('-Project', $bCsproj)
        }
        AfterAll {
            Remove-Sandbox -Dir $script:sb12
            if ($script:sent12) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($script:sent12)) }
        }

        It 'exits 0 (a project without a frontend is not an error)' { $script:res12.ExitCode | Should -Be 0 }
        It 'says no group names this project' {
            $script:res12.Stdout | Should -Match 'none names'
        }
        It 'does not fall back to another project''s group' {
            [System.IO.File]::Exists($script:sent12) | Should -BeFalse
        }
    }
}
