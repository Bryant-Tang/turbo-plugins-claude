# Publish-Web.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework/scripts/Publish-Web.ps1
# Behavior: 找 csproj → 找 MSBuild → 找 .pubxml → pack-content → msbuild /p:DeployOnBuild=true
#
# 同 build-web,script **沒有** [iis] enabled gate。SKILL.md 是 gatekeeper。
#
# Cases:
#   1. Missing csproj: exit ≠ 0,訊息提及 .csproj
#   2. Missing pubxml (有 csproj, 沒有 .pubxml): exit ≠ 0,訊息提及 pubxml
#   3. SKILL entry consistency: re-invoke 行為一致
#   4. Real publish: SKIP (Phase 2 territory)

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Publish-Web.ps1')
    $script:SandboxBase = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

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

    function New-Sandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($script:SandboxBase, "turbo-plugin-test-$Purpose-$guid")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }

    function Remove-Sandbox {
        param([string]$Dir)
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

    $script:MinimalCsproj = @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <ProjectGuid>{00000000-1111-2222-3333-444444444444}</ProjectGuid>
    <OutputType>Library</OutputType>
    <RootNamespace>HelloApp</RootNamespace>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
</Project>
'@

    # Stub MSBuild (.bat echoing args) so publish arg construction is asserted without running
    # real MSBuild. New-PublishArgFixture builds a git sandbox + csproj + N pubxml + stub + config.
    function New-PublishArgFixture {
        param([string]$Purpose, [int]$PubxmlCount = 1, [switch]$WithConfigInPubxml)
        $sb = New-Sandbox $Purpose
        [System.IO.File]::WriteAllText((Join-Path $sb 'HelloApp.csproj'), $script:MinimalCsproj, (New-Object System.Text.UTF8Encoding($false)))
        $profilesDir = Join-Path $sb 'Properties\PublishProfiles'
        $null = New-Item -ItemType Directory -Path $profilesDir -Force
        $cfgNode = if ($WithConfigInPubxml) { '<Configuration>Release</Configuration>' } else { '' }
        for ($i = 1; $i -le $PubxmlCount; $i++) {
            $name = if ($PubxmlCount -eq 1) { 'FolderProfile' } else { "Profile$i" }
            $pubxml = "<Project><PropertyGroup><WebPublishMethod>FileSystem</WebPublishMethod>$cfgNode<PublishUrl>bin\app.publish\</PublishUrl></PropertyGroup></Project>"
            [System.IO.File]::WriteAllText((Join-Path $profilesDir "$name.pubxml"), $pubxml, (New-Object System.Text.UTF8Encoding($false)))
        }
        if ($WithConfigInPubxml) { } # placeholder to keep param meaningful
        $tpDir = Join-Path $sb '.turbo-plugin'
        $null = New-Item -ItemType Directory -Path $tpDir -Force
        [System.IO.File]::WriteAllText((Join-Path $tpDir 'config.toml'), "[publish]`r`nproject = `"HelloApp.csproj`"`r`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $tpDir 'config.local.toml'), "[tools]`r`nmsbuild_path = `"msbuild-stub.bat`"`r`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $sb 'msbuild-stub.bat'), "@echo off`r`necho MSBUILD_ARGS: %*`r`n", (New-Object System.Text.UTF8Encoding($false)))
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

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
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
    }
}

Describe 'Publish-Web' {

    Context 'Case 1: missing csproj → fail-loudly' {
        BeforeAll {
            $script:sb1 = New-Sandbox 'publish-nocsproj'
            Push-Location -LiteralPath $script:sb1
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                [System.IO.File]::WriteAllText((Join-Path $script:sb1 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m init
            } finally { Pop-Location }
            $script:r1 = Invoke-Script -WorkDir $script:sb1
            $script:combined1 = $script:r1.Stdout + "`n" + $script:r1.Stderr
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'case1: missing csproj exit ≠ 0' { ($script:r1.Exit -ne 0) | Should -BeTrue }
        It 'case1: 訊息提及 .csproj' { $script:combined1 | Should -Match '\.csproj' }
    }

    Context 'Case 2 & 3: missing pubxml (has csproj) + SKILL re-invoke consistency' {
        BeforeAll {
            $script:sb2 = New-Sandbox 'publish-nopubxml'
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($script:sb2, 'HelloApp.csproj'),
                $script:MinimalCsproj,
                (New-Object System.Text.UTF8Encoding($false)))
            # A stub MSBuild, even though this case never publishes. The script resolves MSBuild
            # BEFORE it looks for a pubxml, so on a machine without Visual Studio / Build Tools it
            # fails at the MSBuild step and never emits the missing-pubxml message this case is
            # about. Pointing at a stub makes the case assert what it claims to, independent of
            # whether the host happens to have MSBuild -- which the CI runner does not.
            $tpDir2 = Join-Path $script:sb2 '.turbo-plugin'
            $null = New-Item -ItemType Directory -Path $tpDir2 -Force
            [System.IO.File]::WriteAllText(
                (Join-Path $tpDir2 'config.local.toml'),
                "[tools]`r`nmsbuild_path = `"msbuild-stub.bat`"`r`n",
                (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText(
                (Join-Path $script:sb2 'msbuild-stub.bat'),
                "@echo off`r`necho MSBUILD_ARGS: %*`r`n",
                (New-Object System.Text.UTF8Encoding($false)))
            Push-Location -LiteralPath $script:sb2
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m init
            } finally { Pop-Location }
            # Explicit -Project (no auto-detect): reaches the pubxml-finding step so the
            # missing-pubxml error fires (the point of this case), not a "no target" error.
            $script:r2 = Invoke-Script -WorkDir $script:sb2 -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:combined2 = $script:r2.Stdout + "`n" + $script:r2.Stderr
            $script:r3 = Invoke-Script -WorkDir $script:sb2 -ExtraArgs @('-Project', 'HelloApp.csproj')
        }
        AfterAll { Remove-Sandbox $script:sb2 }

        It 'case2: missing pubxml exit ≠ 0' { ($script:r2.Exit -ne 0) | Should -BeTrue }
        It 'case2: 訊息提及 pubxml' { $script:combined2 | Should -Match '(?i)pubxml' }
        It 'case3: SKILL-entry exit ≠ 0' { ($script:r3.Exit -ne 0) | Should -BeTrue }
    }

    Context 'U4: arg construction (stub MSBuild) — pubxml governs config, .sln rejected' {
        BeforeAll {
            $script:sbpOmit = New-PublishArgFixture 'publish-arg-omit'
            $script:rpOmit = Invoke-Script -WorkDir $script:sbpOmit
            $script:sbpRel = New-PublishArgFixture 'publish-arg-rel'
            $script:rpRel = Invoke-Script -WorkDir $script:sbpRel -ExtraArgs @('-Configuration', 'Release')
            $script:sbpMulti = New-PublishArgFixture 'publish-arg-multi' -PubxmlCount 2
            $script:rpMulti = Invoke-Script -WorkDir $script:sbpMulti
            $script:rpMultiCombined = $script:rpMulti.Stdout + "`n" + $script:rpMulti.Stderr
            # .sln target rejected (publish needs a csproj). Reuse omit fixture's sandbox + a .sln.
            $script:sbpSln = New-PublishArgFixture 'publish-arg-sln'
            [System.IO.File]::WriteAllText((Join-Path $script:sbpSln 'HelloApp.sln'), '', (New-Object System.Text.UTF8Encoding($false)))
            $script:rpSln = Invoke-Script -WorkDir $script:sbpSln -ExtraArgs @('-Project', 'HelloApp.sln')
            $script:rpSlnCombined = $script:rpSln.Stdout + "`n" + $script:rpSln.Stderr
        }
        AfterAll {
            Remove-Sandbox $script:sbpOmit; Remove-Sandbox $script:sbpRel
            Remove-Sandbox $script:sbpMulti; Remove-Sandbox $script:sbpSln
        }

        It 'omits /p:Configuration when no value (pubxml governs)' {
            $script:rpOmit.Exit | Should -Be 0
            ($script:rpOmit.Stdout + "`n" + $script:rpOmit.Stderr) | Should -Not -Match '/p:Configuration'
        }
        It 'passes /p:Configuration=Release when -Configuration given' {
            $script:rpRel.Stdout | Should -Match '/p:Configuration=Release'
        }
        It 'still passes the publish profile args' {
            $script:rpOmit.Stdout | Should -Match '/p:PublishProfile=FolderProfile'
            $script:rpOmit.Stdout | Should -Match '/p:DeployOnBuild=true'
        }
        It 'preserves the PUBLISH_OUTPUT bare path + file:/// URL contract (no trailing punctuation)' {
            $script:rpOmit.Stdout | Should -Match 'PUBLISH_OUTPUT'
            $script:rpOmit.Stdout | Should -Match 'app\.publish'
            $script:rpOmit.Stdout | Should -Match 'file:///.*app\.publish'
            # file:/// line ends without trailing punctuation (stays clickable)
            ($script:rpOmit.Stdout -split "`r?`n" | Where-Object { $_ -match '^file:///' } | Select-Object -First 1) | Should -Match '[^.,;:]$'
        }
        It 'PUBLISH_OUTPUT includes the resolved Target line (糾錯閘, consistent with build/run/stop)' {
            ($script:rpOmit.Stdout -split "`r?`n" | Where-Object { $_ -match '^Target: ' } | Select-Object -First 1) | Should -Match 'HelloApp\.csproj'
        }
        It '>1 pubxml without -Pubxml errors (unchanged pubxml resolution)' {
            ($script:rpMulti.Exit -ne 0) | Should -BeTrue
            $script:rpMultiCombined | Should -Match '(?i)multiple .*pubxml'
        }
        It '.sln target is rejected (publish needs a csproj)' {
            ($script:rpSln.Exit -ne 0) | Should -BeTrue
            $script:rpSlnCombined | Should -Match '\.sln'
        }
    }

    Context 'Case 4: real MSBuild publish (deferred to Phase 2 SKILL)' {
        It 'case4: real publish deferred' -Skip {
            # Real MSBuild publish deferred to Phase 2 SKILL manual testing.
        }
    }
}
