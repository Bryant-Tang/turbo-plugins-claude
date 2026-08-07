# Build-Web.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework/scripts/Build-Web.ps1
# Behavior: 找 csproj → 找 MSBuild → 跑 msbuild /restore /t:Build → 跑 pack-content.ps1
#
# 注意:此 script **沒有** 自己的 [iis] enabled gate(by design;見 commit 84e944a)。
#   SKILL.md 是 gatekeeper。本測試 deviation 標記。
#
# Cases:
#   1. Missing csproj: workspace 無 csproj → exit ≠ 0,訊息提及 .csproj
#   2. SKILL entry consistency: 再呼叫 missing-csproj case → 一致
#   3. [iis] enabled = false consistency (deviation): script-level 沒 gate,但因 fixture 沒 csproj
#      會先撞 missing-csproj error → 走 csproj 訊息;documented deviation。
#   4. Real build happy (smoke): 不在 phase 1 跑(MSBuild restoration 太慢、會碰網路);
#      此 case 標 SKIP — Phase 2 SKILL 測試會 cover full build。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-Web.ps1')
    $script:PluginRoot = $pluginRoot

    # ─── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ───
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

    function New-Sandbox { param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine([System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-test-$Purpose-$guid")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }
    function Remove-Sandbox { param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try {
            if ([System.IO.Directory]::Exists($Dir)) {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($Dir, '*', [System.IO.SearchOption]::AllDirectories)) {
                    try {
                        $fa = [System.IO.File]::GetAttributes($f)
                        if ($fa -band [System.IO.FileAttributes]::ReadOnly) {
                            [System.IO.File]::SetAttributes($f, $fa -band (-bnot [System.IO.FileAttributes]::ReadOnly))
                        }
                    } catch { }
                }
                [System.IO.Directory]::Delete($Dir, $true)
            }
        } catch { }
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

    # csproj with the conditional Debug default (models a real .NET Framework web csproj):
    # the executor must OMIT /p:Configuration so this <Configuration Condition> default wins,
    # rather than forcing Debug (the pre-U3 bug that diverged from VS).
    $script:CsprojConditional = @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <Configuration Condition=" '$(Configuration)' == '' ">Debug</Configuration>
    <Platform Condition=" '$(Platform)' == '' ">AnyCPU</Platform>
    <ProjectGuid>{00000000-1111-2222-3333-444444444444}</ProjectGuid>
    <OutputType>Library</OutputType>
    <RootNamespace>HelloApp</RootNamespace>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
'@

    # Stub MSBuild: a .bat that echoes its args ("MSBUILD_ARGS: ...") and exits 0, so arg
    # construction is asserted WITHOUT running real MSBuild. Build-Web's Find-MSBuild reads
    # [tools].msbuild_path (config.local.toml); we point it at the stub. New-BuildArgFixture
    # builds a git sandbox + csproj (+ optional .sln) + the stub + config.
    function New-BuildArgFixture {
        param([string]$Purpose, [string]$ConfigToml = '', [switch]$WithSolution)
        $sb = New-Sandbox $Purpose
        [System.IO.File]::WriteAllText((Join-Path $sb 'HelloApp.csproj'), $script:CsprojConditional, (New-Object System.Text.UTF8Encoding($false)))
        if ($WithSolution) {
            [System.IO.File]::WriteAllText((Join-Path $sb 'HelloApp.sln'), '', (New-Object System.Text.UTF8Encoding($false)))
        }
        $tpDir = Join-Path $sb '.turbo-plugin'
        $null = New-Item -ItemType Directory -Path $tpDir -Force
        if (-not [string]::IsNullOrWhiteSpace($ConfigToml)) {
            [System.IO.File]::WriteAllText((Join-Path $tpDir 'config.toml'), $ConfigToml, (New-Object System.Text.UTF8Encoding($false)))
        }
        # Stub MSBuild + point [tools].msbuild_path at it via config.local.toml.
        [System.IO.File]::WriteAllText((Join-Path $sb 'msbuild-stub.bat'), "@echo off`r`necho MSBUILD_ARGS: %*`r`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $tpDir 'config.local.toml'), "[tools]`r`nmsbuild_path = `"msbuild-stub.bat`"`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Push-Location -LiteralPath $sb
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            & git -c commit.gpgsign=false commit -q -m init *>$null
        } finally { Pop-Location }
        return $sb
    }

    # ─── Build fixtures for case 1/2 (shared sandbox sb1) and case 3 (sb2) ───
    $script:sb1 = New-Sandbox 'build-nocsproj'
    Push-Location -LiteralPath $script:sb1
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        [System.IO.File]::WriteAllText((Join-Path $script:sb1 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }

    $script:sb2 = New-Sandbox 'build-iisfalse'
    $tpDir = [System.IO.Path]::Combine($script:sb2, '.turbo-plugin')
    $null = New-Item -ItemType Directory -Path $tpDir -Force
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($tpDir, 'config.toml'),
        "[iis]`nenabled = false`n",
        (New-Object System.Text.UTF8Encoding($false)))
    Push-Location -LiteralPath $script:sb2
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }
}

AfterAll {
    Remove-Sandbox $script:sb1
    Remove-Sandbox $script:sb2
}

Describe 'Build-Web' {

    Context 'Case 1: missing csproj' {
        BeforeAll { $script:r1 = Invoke-Script -WorkDir $script:sb1 }

        It 'missing csproj exit != 0' { ($script:r1.Exit -ne 0) | Should -BeTrue }
        It '訊息提及 .csproj' {
            ($script:r1.Stdout + "`n" + $script:r1.Stderr) | Should -Match '\.csproj'
        }
    }

    Context 'Case 2: SKILL entry re-invoke missing-csproj' {
        BeforeAll { $script:r2 = Invoke-Script -WorkDir $script:sb1 }

        It 'SKILL-entry exit != 0' { ($script:r2.Exit -ne 0) | Should -BeTrue }
    }

    Context 'Case 3: [iis]=false on sandbox with config.toml — script has no gate (deviation)' {
        # Behavior: script will fail at csproj-finding (same as case 1) because no csproj exists.
        # Documented deviation: SKILL-level gate not exercised here; Phase 2 SKILL covers it.
        BeforeAll { $script:r3 = Invoke-Script -WorkDir $script:sb2 }

        It '[iis]=false no script-level gate → exits with csproj error' {
            # Script has no [iis] gate; goes to csproj-finder which throws.
            ($script:r3.Exit -ne 0) | Should -BeTrue
        }
        It 'stderr present (no IIS gate at script level)' {
            # Either .csproj error or some other; not asserting IIS 已停用 here (script doesn't gate)
            (($script:r3.Stdout + "`n" + $script:r3.Stderr).Length -gt 0) | Should -BeTrue
        }
    }

    Context 'U3: arg construction (stub MSBuild) — omit config when unspecified, .sln SolutionDir' {
        BeforeAll {
            $script:sbRel = New-BuildArgFixture 'build-arg-release'
            $script:rRel = Invoke-Script -WorkDir $script:sbRel -ExtraArgs @('-Project', 'HelloApp.csproj', '-Configuration', 'Release')

            $script:sbOmit = New-BuildArgFixture 'build-arg-omit'
            $script:rOmit = Invoke-Script -WorkDir $script:sbOmit -ExtraArgs @('-Project', 'HelloApp.csproj')

            $script:sbCfg = New-BuildArgFixture 'build-arg-cfg' -ConfigToml "[build]`r`nproject = `"HelloApp.csproj`"`r`nconfiguration = `"Release`"`r`n"
            $script:rCfg = Invoke-Script -WorkDir $script:sbCfg

            $script:sbSln = New-BuildArgFixture 'build-arg-sln' -WithSolution
            $script:rSln = Invoke-Script -WorkDir $script:sbSln -ExtraArgs @('-Project', 'HelloApp.sln')
        }
        AfterAll {
            Remove-Sandbox $script:sbRel; Remove-Sandbox $script:sbOmit
            Remove-Sandbox $script:sbCfg; Remove-Sandbox $script:sbSln
        }

        It 'passes /p:Configuration=Release when -Configuration given' {
            $script:rRel.Stdout | Should -Match '/p:Configuration=Release'
        }
        It 'OMITS /p:Configuration when no value (core VS-alignment regression)' {
            ($script:rOmit.Stdout + "`n" + $script:rOmit.Stderr) | Should -Not -Match '/p:Configuration'
        }
        It 'OMITS /p:Platform when no value' {
            ($script:rOmit.Stdout + "`n" + $script:rOmit.Stderr) | Should -Not -Match '/p:Platform'
        }
        It 'uses [build].configuration from config when no CLI (memory = explicit choice)' {
            $script:rCfg.Stdout | Should -Match '/p:Configuration=Release'
        }
        It '.sln target: builds the .sln with /p:SolutionDir from the .sln dir (trailing separator)' {
            $script:rSln.Stdout | Should -Match 'HelloApp\.sln'
            $script:rSln.Stdout | Should -Match ('/p:SolutionDir=' + [regex]::Escape($script:sbSln))
            # SolutionDir ends with a path separator (the $(SolutionDir) convention).
            $script:rSln.Stdout | Should -Match ([regex]::Escape($script:sbSln) + '\\')
        }
        It 'prints BUILD_OUTPUT template with the resolved target (糾錯閘)' {
            $script:rOmit.Exit | Should -Be 0
            $script:rOmit.Stdout | Should -Match 'BUILD_OUTPUT'
            $script:rOmit.Stdout | Should -Match 'Target:.*HelloApp\.csproj'
        }
        It 'BUILD_OUTPUT marks unspecified configuration as MSBuild-decided (not Debug)' {
            $script:rOmit.Stdout | Should -Match 'Configuration:.*MSBuild'
            $script:rOmit.Stdout | Should -Not -Match 'Configuration: Debug'
        }

        # The two restore flags carry the whole packages.config story, and nothing else in this
        # suite touches them: before these Its existed, deleting either one left every test green
        # while silently breaking every packages.config project. /restore must also stay the SWITCH
        # (not a /t:Restore;Build target list) or post-restore .targets imports never bind.
        It 'passes /restore as the switch (so the project is re-evaluated after restore)' {
            $script:rOmit.Stdout | Should -Match '/restore'
            $script:rOmit.Stdout | Should -Not -Match '/t:Restore'
        }
        It 'passes /p:RestorePackagesConfig=true (without it NuGet ignores packages.config)' {
            $script:rOmit.Stdout | Should -Match '/p:RestorePackagesConfig=true'
        }
        # Anchored on SolutionDir, not on either restore flag: this It exists to prove the args are
        # echoed at all, so it must not also go red when a restore flag changes -- one red, one cause.
        It 'echoes the full MSBuild command line (agents diagnose failures from stdout)' {
            $script:rOmit.Stdout | Should -Match 'MSBuild args:.*/p:SolutionDir='
        }
    }

    # -RepoRoot names the project outright. The scenario this exists for: a session opened at a
    # root that holds several sibling projects, where the cwd is not any of them.
    Context 'U8: -RepoRoot targets a project other than the current directory' {
        BeforeAll {
            # Two independent project sandboxes. Only $sbTarget carries a csproj + stub MSBuild;
            # $sbElsewhere is a bare directory standing in for "wherever the session happens to be".
            $script:sbTarget = New-BuildArgFixture 'build-reporoot-target'
            $script:sbElsewhere = New-Sandbox 'build-reporoot-cwd'
            $script:rTargeted = Invoke-Script -WorkDir $script:sbElsewhere -ExtraArgs @('-RepoRoot', $script:sbTarget, '-Project', 'HelloApp.csproj')
            # Same call WITHOUT -RepoRoot: proves the pass above is doing the work, not the cwd.
            $script:rUntargeted = Invoke-Script -WorkDir $script:sbElsewhere -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:rBadRoot = Invoke-Script -WorkDir $script:sbTarget -ExtraArgs @('-RepoRoot', (Join-Path $script:sbTarget 'no-such-dir'))
            $script:rBadRootCombined = $script:rBadRoot.Stdout + "`n" + $script:rBadRoot.Stderr
        }
        AfterAll { Remove-Sandbox $script:sbTarget; Remove-Sandbox $script:sbElsewhere }

        It 'acts on the named project, not the current directory' {
            $script:rTargeted.Exit | Should -Be 0
            $script:rTargeted.Stdout | Should -Match ([regex]::Escape($script:sbTarget))
            $script:rTargeted.Stdout | Should -Match 'Target:.*HelloApp\.csproj'
        }
        It 'the same call without -RepoRoot fails (so the case above is not passing by accident)' {
            ($script:rUntargeted.Exit -ne 0) | Should -BeTrue
        }
        It 'a -RepoRoot that does not exist fails loudly naming the argument, before MSBuild' {
            ($script:rBadRoot.Exit -ne 0) | Should -BeTrue
            $script:rBadRootCombined | Should -Match '(?i)repo root not found'
            $script:rBadRootCombined | Should -Not -Match 'MSBUILD_ARGS'
        }
        It 'leaves nothing behind when -RepoRoot is bad' {
            (Test-Path -LiteralPath (Join-Path $script:sbTarget 'no-such-dir')) | Should -BeFalse
        }
    }

    Context 'Case 4: real-build happy (smoke)' {
        It 'real MSBuild build deferred to SKILL-level test (too heavy + network for unit scope)' -Skip {
            # Phase 2 SKILL territory — intentionally skipped at unit scope.
        }
    }
}
