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
        # -PubxmlNodes injects arbitrary extra elements into the profile's PropertyGroup, which is
        # what the issue #51 cases need: a VS-generated FileSystem profile carries LastUsed* and
        # often no Configuration/Platform at all.
        param([string]$Purpose, [int]$PubxmlCount = 1, [switch]$WithConfigInPubxml, [string]$PubxmlNodes = '')
        $sb = New-Sandbox $Purpose
        [System.IO.File]::WriteAllText((Join-Path $sb 'HelloApp.csproj'), $script:MinimalCsproj, (New-Object System.Text.UTF8Encoding($false)))
        $profilesDir = Join-Path $sb 'Properties\PublishProfiles'
        $null = New-Item -ItemType Directory -Path $profilesDir -Force
        $cfgNode = if ($WithConfigInPubxml) { '<Configuration>Release</Configuration>' } else { '' }
        for ($i = 1; $i -le $PubxmlCount; $i++) {
            $name = if ($PubxmlCount -eq 1) { 'FolderProfile' } else { "Profile$i" }
            $pubxml = "<Project><PropertyGroup><WebPublishMethod>FileSystem</WebPublishMethod>$cfgNode$PubxmlNodes<PublishUrl>bin\app.publish\</PublishUrl></PropertyGroup></Project>"
            [System.IO.File]::WriteAllText((Join-Path $profilesDir "$name.pubxml"), $pubxml, (New-Object System.Text.UTF8Encoding($false)))
        }
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

    Context 'U4: arg construction (stub MSBuild) — configuration read from pubxml, .sln rejected' {
        BeforeAll {
            $script:sbpOmit = New-PublishArgFixture 'publish-arg-omit'
            $script:rpOmit = Invoke-Script -WorkDir $script:sbpOmit
            $script:sbpRel = New-PublishArgFixture 'publish-arg-rel'
            $script:rpRel = Invoke-Script -WorkDir $script:sbpRel -ExtraArgs @('-Configuration', 'Release')
            # pubxml carries <Configuration>Release</Configuration>, agent supplies nothing.
            $script:sbpPub = New-PublishArgFixture 'publish-arg-pubxmlcfg' -WithConfigInPubxml
            $script:rpPub = Invoke-Script -WorkDir $script:sbpPub
            # Same pubxml, but the agent explicitly asks for Debug -- the agent must win.
            $script:sbpOverride = New-PublishArgFixture 'publish-arg-override' -WithConfigInPubxml
            $script:rpOverride = Invoke-Script -WorkDir $script:sbpOverride -ExtraArgs @('-Configuration', 'Debug')
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
            Remove-Sandbox $script:sbpPub; Remove-Sandbox $script:sbpOverride
            Remove-Sandbox $script:sbpMulti; Remove-Sandbox $script:sbpSln
        }

        It 'omits /p:Configuration when neither the agent nor the pubxml names one' {
            $script:rpOmit.Exit | Should -Be 0
            ($script:rpOmit.Stdout + "`n" + $script:rpOmit.Stderr) | Should -Not -Match '/p:Configuration'
        }
        It 'passes /p:Configuration=Release when -Configuration given' {
            $script:rpRel.Stdout | Should -Match '/p:Configuration=Release'
        }
        It 'reads <Configuration> out of the pubxml when the agent gave none (real-machine: omitting published Debug)' {
            $script:rpPub.Exit | Should -Be 0
            $script:rpPub.Stdout | Should -Match '/p:Configuration=Release'
        }
        It 'an explicit -Configuration beats the pubxml' {
            $script:rpOverride.Exit | Should -Be 0
            $script:rpOverride.Stdout | Should -Match '/p:Configuration=Debug'
            $script:rpOverride.Stdout | Should -Not -Match '/p:Configuration=Release'
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
        # Issue #63: the marker used to tell the agent to keep the path line BARE. A bare Windows
        # path in a markdown-rendered reply silently loses one separator per hidden directory
        # ('\.claude' -> '.claude'), because '\' + ASCII punctuation is a markdown escape. The
        # instruction the agent reads has to ask for a fenced code block instead.
        It 'PUBLISH_OUTPUT tells the agent to relay inside a fenced code block, not bare (#63)' {
            $marker = @($script:rpOmit.Stdout -split "`r?`n" | Where-Object { $_ -match '^PUBLISH_OUTPUT' })[0]
            $marker | Should -Match 'fenced code block'
            $marker | Should -Not -Match '(?i)bare'
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

        # Publish BUILDS (/p:DeployOnBuild=true) and the SKILL never requires a prior build, so a
        # fresh clone can hit publish first -- it needs restore in its own right, not by borrowing
        # Build-Web's. Same switch-form requirement as Build-Web (see that script's comment).
        It 'passes /restore as the switch (publish builds, so it needs restore too)' {
            $script:rpOmit.Stdout | Should -Match '/restore'
            $script:rpOmit.Stdout | Should -Not -Match '/t:Restore'
        }
        It 'passes /p:RestorePackagesConfig=true (without it NuGet ignores packages.config)' {
            $script:rpOmit.Stdout | Should -Match '/p:RestorePackagesConfig=true'
        }
        # SolutionDir anchors the packages.config `<HintPath>..\packages\...` convention. Publish
        # only ever takes a csproj, so without this the anchor would differ from Build-Web's.
        # Asserted up to the following arg so a path containing spaces cannot loosen the match.
        It 'passes /p:SolutionDir with the trailing separator $(SolutionDir) expects' {
            $script:rpOmit.Stdout | Should -Match '/p:SolutionDir=.*\\ /p:DeployOnBuild=true'
        }
        # Anchored on DeployOnBuild, not on either restore flag: this It exists to prove the args are
        # echoed at all, so it must not also go red when a restore flag changes -- one red, one cause.
        It 'echoes the full MSBuild command line (agents diagnose failures from stdout)' {
            $script:rpOmit.Stdout | Should -Match 'MSBuild args:.*/p:DeployOnBuild=true'
        }
    }

    # In a mono repo each sub-project owns its own .sln and its own packages\, so anchoring
    # SolutionDir on the repo root restored into <repo>\packages while every <HintPath>..\packages\
    # pointed at <repo>\proj-1\packages -- publish failed on a project that BUILT fine, and MSBuild
    # blamed a missing NuGet package (issue #132).
    #
    # This Context is end-to-end on purpose. Common.test.ps1 proves Resolve-SolutionDir itself; only
    # a run of the real script proves Publish-Web CALLS it, and reverting that one line is exactly
    # how the bug would come back.
    Context 'issue #132 - SolutionDir anchors on the sub-project solution, not the repo root' {
        BeforeAll {
            $script:sbMono = New-Sandbox 'publish-mono-solutiondir'
            $webDir = [System.IO.Path]::Combine($script:sbMono, 'proj-1', 'src', 'Web')
            $null = New-Item -ItemType Directory -Path $webDir -Force
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText((Join-Path $webDir 'HelloApp.csproj'), $script:MinimalCsproj, $utf8)
            # A decoy solution at the repo root: the buggy answer and "the outermost .sln" are the
            # same directory here, so without it a walk that picked the wrong end would still pass.
            [System.IO.File]::WriteAllText((Join-Path $script:sbMono 'Everything.sln'), '', $utf8)
            [System.IO.File]::WriteAllText(([System.IO.Path]::Combine($script:sbMono, 'proj-1', 'App.sln')), '', $utf8)

            $profilesDir = [System.IO.Path]::Combine($webDir, 'Properties', 'PublishProfiles')
            $null = New-Item -ItemType Directory -Path $profilesDir -Force
            [System.IO.File]::WriteAllText((Join-Path $profilesDir 'FolderProfile.pubxml'),
                '<Project><PropertyGroup><WebPublishMethod>FileSystem</WebPublishMethod><Configuration>Release</Configuration><PublishUrl>bin\app.publish\</PublishUrl></PropertyGroup></Project>', $utf8)

            $tpDir = Join-Path $script:sbMono '.turbo-plugin'
            $null = New-Item -ItemType Directory -Path $tpDir -Force
            [System.IO.File]::WriteAllText((Join-Path $tpDir 'config.toml'),
                "[publish]`r`nproject = `"proj-1/src/Web/HelloApp.csproj`"`r`n", $utf8)
            [System.IO.File]::WriteAllText((Join-Path $tpDir 'config.local.toml'),
                "[tools]`r`nmsbuild_path = `"msbuild-stub.bat`"`r`n", $utf8)
            [System.IO.File]::WriteAllText((Join-Path $script:sbMono 'msbuild-stub.bat'),
                "@echo off`r`necho MSBUILD_ARGS: %*`r`n", $utf8)

            Push-Location -LiteralPath $script:sbMono
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                Invoke-GitSilent add -A
                & git -c commit.gpgsign=false commit -q -m init *>$null
            } finally { Pop-Location }

            $script:rpMono = Invoke-Script -WorkDir $script:sbMono
            $script:sbMonoProj1 = [System.IO.Path]::Combine($script:sbMono, 'proj-1')
        }
        AfterAll { Remove-Sandbox $script:sbMono }

        # Matched up to the following arg, so a sandbox path containing spaces cannot loosen it.
        It 'passes the sub-project solution directory as SolutionDir' {
            $script:rpMono.Stdout | Should -Match ('/p:SolutionDir=' + [regex]::Escape($script:sbMonoProj1) + '\\ /p:DeployOnBuild=true')
        }
        It 'does NOT pass the repo root (the regression)' {
            $script:rpMono.Stdout | Should -Not -Match ('/p:SolutionDir=' + [regex]::Escape($script:sbMono) + '\\ ')
        }
    }

    # A FileSystem profile generated by Visual Studio records the user's selection as
    # LastUsedBuildConfiguration / LastUsedPlatform and frequently carries no Configuration or
    # Platform element at all. Reading only the latter pair found nothing, so publish fell back to
    # the csproj default Debug|AnyCPU -- the opposite of what VS showed the user (issue #51).
    Context 'issue #51 - pubxml fallback reads the LastUsed* elements Visual Studio actually writes' {
        BeforeAll {
            # Exactly the shape VS emits: LastUsed* present, Configuration/Platform absent.
            $script:sbpLast = New-PublishArgFixture 'publish-lastused' -PubxmlNodes '<LastUsedBuildConfiguration>Release</LastUsedBuildConfiguration><LastUsedPlatform>x64</LastUsedPlatform>'
            $script:rpLast = Invoke-Script -WorkDir $script:sbpLast

            # Both spellings present: the explicit one is a deliberate setting, LastUsed* only
            # records whatever ran last, so Configuration/Platform must win.
            $script:sbpBoth = New-PublishArgFixture 'publish-both' -WithConfigInPubxml -PubxmlNodes '<LastUsedBuildConfiguration>Debug</LastUsedBuildConfiguration><Platform>x86</Platform><LastUsedPlatform>x64</LastUsedPlatform>'
            $script:rpBoth = Invoke-Script -WorkDir $script:sbpBoth

            # The agent's own value still beats everything in the file.
            $script:sbpCli = New-PublishArgFixture 'publish-cli' -PubxmlNodes '<LastUsedBuildConfiguration>Release</LastUsedBuildConfiguration><LastUsedPlatform>x64</LastUsedPlatform>'
            $script:rpCli = Invoke-Script -WorkDir $script:sbpCli -ExtraArgs @('-Configuration', 'Debug', '-Platform', 'AnyCPU')
        }
        AfterAll {
            Remove-Sandbox $script:sbpLast; Remove-Sandbox $script:sbpBoth; Remove-Sandbox $script:sbpCli
        }

        It 'takes Configuration from LastUsedBuildConfiguration when no Configuration element exists' {
            $script:rpLast.Exit | Should -Be 0
            $script:rpLast.Stdout | Should -Match '/p:Configuration=Release'
        }
        It 'takes Platform from LastUsedPlatform (previously never read at all)' {
            $script:rpLast.Stdout | Should -Match '/p:Platform=x64'
        }
        It 'an explicit Configuration/Platform element beats the LastUsed* pair' {
            $script:rpBoth.Exit | Should -Be 0
            $script:rpBoth.Stdout | Should -Match '/p:Configuration=Release'
            $script:rpBoth.Stdout | Should -Not -Match '/p:Configuration=Debug'
            $script:rpBoth.Stdout | Should -Match '/p:Platform=x86'
            $script:rpBoth.Stdout | Should -Not -Match '/p:Platform=x64'
        }
        It 'the agent-supplied values still beat everything in the pubxml' {
            $script:rpCli.Stdout | Should -Match '/p:Configuration=Debug'
            $script:rpCli.Stdout | Should -Match '/p:Platform=AnyCPU'
        }
    }

    # issue #45: publish had no way to pass one extra MSBuild property, so the only workaround for
    # anything the script does not model was to abandon the plugin and hand-run MSBuild.
    Context 'issue #45 - extra MSBuild properties can be passed through' {
        BeforeAll {
            $script:sbpProp = New-PublishArgFixture 'publish-prop'
            # The motivating case: the 32-bit aspnet_compiler cannot load x64-only assemblies.
            $script:rpProp = Invoke-Script -WorkDir $script:sbpProp -ExtraArgs @('-MsBuildProperty', 'AspnetCompilerPath=$(MSBuildFrameworkToolsPath64)')

            $script:sbpMulti2 = New-PublishArgFixture 'publish-prop-multi'
            $script:rpMulti2 = Invoke-Script -WorkDir $script:sbpMulti2 -ExtraArgs @('-MsBuildProperty', 'A=1,B=2')

            # Appended last, so a passthrough overrides what the script computed. Both values end
            # up on the command line; MSBuild takes the final one, which is the documented contract.
            $script:sbpOver = New-PublishArgFixture 'publish-prop-override' -WithConfigInPubxml
            $script:rpOver = Invoke-Script -WorkDir $script:sbpOver -ExtraArgs @('-MsBuildProperty', 'Configuration=Debug')

            $script:sbpBad = New-PublishArgFixture 'publish-prop-bad'
            $script:rpBad = Invoke-Script -WorkDir $script:sbpBad -ExtraArgs @('-MsBuildProperty', 'AspnetCompilerPath')
            $script:rpBadCombined = $script:rpBad.Stdout + "`n" + $script:rpBad.Stderr
        }
        AfterAll {
            Remove-Sandbox $script:sbpProp; Remove-Sandbox $script:sbpMulti2
            Remove-Sandbox $script:sbpOver; Remove-Sandbox $script:sbpBad
        }

        It 'passes a single property through as /p:Name=Value' {
            $script:rpProp.Exit | Should -Be 0
            $script:rpProp.Stdout | Should -Match ([regex]::Escape('/p:AspnetCompilerPath=$(MSBuildFrameworkToolsPath64)'))
        }
        It 'accepts several properties comma-separated (the form the .sh delegate can carry)' {
            $script:rpMulti2.Exit | Should -Be 0
            $script:rpMulti2.Stdout | Should -Match '/p:A=1'
            $script:rpMulti2.Stdout | Should -Match '/p:B=2'
        }
        It 'appends after the computed args so the caller wins on a collision' {
            $script:rpOver.Exit | Should -Be 0
            # The script's own value appears first, the passthrough last -- MSBuild honours the last.
            $script:rpOver.Stdout | Should -Match '/p:Configuration=Release.*/p:Configuration=Debug'
        }
        # Without validation this reaches MSBuild as a bare argument, where it is read as a PROJECT
        # FILE to build -- the error then talks about a missing project and never names the property.
        It 'rejects an entry with no = instead of letting MSBuild misread it as a project file' {
            $script:rpBad.Exit | Should -Not -Be 0
            $script:rpBadCombined | Should -Match 'AspnetCompilerPath'
            $script:rpBadCombined | Should -Match '(?i)Name=Value'
        }
        It 'the failed run never reached MSBuild' {
            $script:rpBadCombined | Should -Not -Match 'MSBUILD_ARGS'
        }
    }

    Context 'Case 4: real MSBuild publish (deferred to Phase 2 SKILL)' {
        It 'case4: real publish deferred' -Skip {
            # Real MSBuild publish deferred to Phase 2 SKILL manual testing.
        }
    }
}
