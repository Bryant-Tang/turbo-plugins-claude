# New-ApphostConfig.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-dotnet-framework-web/scripts/New-ApphostConfig.ps1
#
# Contract: -Project <csproj> [-Force]. Generates .turbo-plugin/applicationhost.config from the
# shipped template plus a <site> synthesised from the csproj's IIS settings, so a project can be
# set up without ever opening Visual Studio.
#
# The generated site must be in CANONICAL shape -- plain project name, physicalPath placeholder --
# because that is what Start-Iis looks up and what makes the file safe to commit and share. The
# identity-hashed name and the real path belong to the per-launch temp copy only.
#
# No IIS Express, no Visual Studio and no network are needed: every case builds a throwaway git
# repo with a hand-written csproj and asserts on the XML that comes out.

BeforeAll {
    $script:pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'New-ApphostConfig.ps1')
    $script:SandboxBase = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($script:pluginRoot, 'tests', '.sandbox', 'sandboxes'))
    $null = New-Item -ItemType Directory -Path $script:SandboxBase -Force

    function Invoke-GitSilent {
        $allArgs = $args
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & git @allArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $oldEap }
    }

    # A throwaway repo holding one csproj. $CsprojBody is spliced into the <PropertyGroup> so each
    # case controls exactly which IIS elements exist.
    function New-ProjectSandbox {
        param([string]$Tag, [string]$IisElements, [string]$ProjectName = 'HelloApp')
        $root = [System.IO.Path]::Combine($script:SandboxBase, "tp-nac-$Tag-$([Guid]::NewGuid().ToString('N').Substring(0,8))")
        $null = New-Item -ItemType Directory -Path $root -Force
        $csproj = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>$ProjectName</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
$IisElements
  </PropertyGroup>
</Project>
"@
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($root, "$ProjectName.csproj"), $csproj,
            (New-Object System.Text.UTF8Encoding($false)))
        Push-Location -LiteralPath $root
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture'
        } finally { Pop-Location }
        return $root
    }

    function Remove-ProjectSandbox {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try { if ([System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::Delete($Dir, $true) } } catch { }
    }

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
        $tmpOut = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-nac-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpErr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-nac-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) +
                @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $WorkDir `
                -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -NoNewWindow -PassThru -Wait
            $stdout = if (Test-Path -LiteralPath $tmpOut -PathType Leaf) { [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8) } else { '' }
            $stderr = if (Test-Path -LiteralPath $tmpErr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpErr, [System.Text.Encoding]::UTF8) } else { '' }
            return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode; Combined = "$stdout`n$stderr" }
        } finally {
            foreach ($t in @($tmpOut, $tmpErr)) {
                if (Test-Path -LiteralPath $t -PathType Leaf) { try { [System.IO.File]::Delete($t) } catch { } }
            }
        }
    }

    function Get-GeneratedSite {
        param([string]$Root, [string]$SiteName = 'HelloApp')
        $path = [System.IO.Path]::Combine($Root, '.turbo-plugin', 'applicationhost.config')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $x = New-Object System.Xml.XmlDocument
        $x.Load($path)
        foreach ($node in @($x.SelectNodes('/configuration/system.applicationHost/sites/site'))) {
            if ($node.GetAttribute('name') -ieq $SiteName) { return $node }
        }
        return $null
    }
}

Describe 'New-ApphostConfig' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: http-only project generates a canonical-shaped site' {
        BeforeAll {
            $script:r1Root = New-ProjectSandbox -Tag 'http' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $script:r1 = Invoke-Script -WorkDir $script:r1Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r1Site = Get-GeneratedSite -Root $script:r1Root
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r1Root }

        It 'case1: exit 0' { $script:r1.Exit | Should -Be 0 -Because $script:r1.Combined }
        It 'case1: 站台以「專案名」命名(不是帶 hash 的執行期名)' {
            $script:r1Site | Should -Not -BeNullOrEmpty
            $script:r1Site.GetAttribute('name') | Should -Be 'HelloApp'
        }
        It 'case1: physicalPath 是佔位符,不含機器路徑' {
            $vd = $script:r1Site.SelectSingleNode('application/virtualDirectory')
            $vd.GetAttribute('physicalPath') | Should -Be '__TURBO_PLUGIN_PHYSICAL_PATH__'
        }
        It 'case1: http binding 取自 <IISUrl> 的 port' {
            $b = @($script:r1Site.SelectNodes('bindings/binding'))
            $b.Count | Should -Be 1
            $b[0].GetAttribute('protocol') | Should -Be 'http'
            $b[0].GetAttribute('bindingInformation') | Should -Be '*:5000:localhost'
        }
        It 'case1: 預設用 Integrated app pool' {
            $script:r1Site.SelectSingleNode('application').GetAttribute('applicationPool') | Should -Be 'Clr4IntegratedAppPool'
        }
    }

    Context 'Case 2: SSL port adds an https binding' {
        BeforeAll {
            $elements = "    <IISUrl>http://localhost:5000/</IISUrl>`n    <IISExpressSSLPort>44301</IISExpressSSLPort>"
            $script:r2Root = New-ProjectSandbox -Tag 'ssl' -IisElements $elements
            $script:r2 = Invoke-Script -WorkDir $script:r2Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r2Site = Get-GeneratedSite -Root $script:r2Root
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r2Root }

        It 'case2: exit 0' { $script:r2.Exit | Should -Be 0 -Because $script:r2.Combined }
        It 'case2: 產出 http + https 兩個 binding' {
            $b = @($script:r2Site.SelectNodes('bindings/binding'))
            $b.Count | Should -Be 2
            ($b | ForEach-Object { $_.GetAttribute('protocol') }) -join ',' | Should -Be 'http,https'
            $b[1].GetAttribute('bindingInformation') | Should -Be '*:44301:localhost'
        }
        It 'case2: 回報 https 位址' { $script:r2.Stdout | Should -Match 'https://localhost:44301' }
    }

    Context 'Case 3: classic pipeline selects the classic app pool' {
        BeforeAll {
            $elements = "    <IISUrl>http://localhost:5000/</IISUrl>`n    <IISExpressUseClassicPipelineMode>true</IISExpressUseClassicPipelineMode>"
            $script:r3Root = New-ProjectSandbox -Tag 'classic' -IisElements $elements
            $script:r3 = Invoke-Script -WorkDir $script:r3Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r3Site = Get-GeneratedSite -Root $script:r3Root
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r3Root }

        It 'case3: exit 0' { $script:r3.Exit | Should -Be 0 -Because $script:r3.Combined }
        It 'case3: 用 Clr4ClassicAppPool' {
            $script:r3Site.SelectSingleNode('application').GetAttribute('applicationPool') | Should -Be 'Clr4ClassicAppPool'
        }
    }

    Context 'Case 4: an existing canonical is left alone without -Force' {
        BeforeAll {
            $script:r4Root = New-ProjectSandbox -Tag 'exists' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $null = Invoke-Script -WorkDir $script:r4Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r4Path = [System.IO.Path]::Combine($script:r4Root, '.turbo-plugin', 'applicationhost.config')
            # Mark the file so any rewrite is detectable.
            $marked = [System.IO.File]::ReadAllText($script:r4Path, [System.Text.Encoding]::UTF8) + "`n<!-- sentinel -->"
            [System.IO.File]::WriteAllText($script:r4Path, $marked, (New-Object System.Text.UTF8Encoding($false)))
            $script:r4 = Invoke-Script -WorkDir $script:r4Root -ExtraArgs @('-Project', 'HelloApp.csproj')
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r4Root }

        It 'case4: exit 0' { $script:r4.Exit | Should -Be 0 -Because $script:r4.Combined }
        It 'case4: 既有檔案原封不動' {
            [System.IO.File]::ReadAllText($script:r4Path, [System.Text.Encoding]::UTF8) | Should -Match 'sentinel'
        }
        It 'case4: 回報「已存在,未變更」' { $script:r4.Stdout | Should -Match '已存在' }
    }

    Context 'Case 5: csproj without any IIS setting fails loudly' {
        BeforeAll {
            # Mirrors a project where VS kept the server settings in the gitignored .csproj.user.
            $script:r5Root = New-ProjectSandbox -Tag 'noiis' -IisElements '    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>'
            $script:r5 = Invoke-Script -WorkDir $script:r5Root -ExtraArgs @('-Project', 'HelloApp.csproj')
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r5Root }

        It 'case5: exit ≠ 0' { ($script:r5.Exit -ne 0) | Should -BeTrue }
        It 'case5: 訊息點名缺哪些元素' { $script:r5.Combined | Should -Match 'IISUrl' }
        It 'case5: 不產生半成品設定檔' {
            [System.IO.File]::Exists([System.IO.Path]::Combine($script:r5Root, '.turbo-plugin', 'applicationhost.config')) | Should -BeFalse
        }
    }
}
