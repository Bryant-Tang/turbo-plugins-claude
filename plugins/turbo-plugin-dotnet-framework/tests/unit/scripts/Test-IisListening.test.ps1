# Test-IisListening.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework/scripts/Test-IisListening.ps1
# Behavior: 由 Resolve-IisSettings 取 port,然後 netstat -ano 篩出 ":<port>" + LISTENING 行;
#   無 listening 則 exit 1 + 寫對應訊息 stdout。
#
# Cases:
#   1. Not listening: fresh fixture port 5000,沒有 IIS Express 跑 → exit 1,stdout 含
#      「No listening socket found for IISUrl port: 5000」(或同 port 已被 OS 用但非 LISTENING)
#   2. SKILL entry re-invoke: 第二次跑結果應一致
#   3. Missing csproj error: workspace 無 csproj → exit 1,訊息含 .csproj
#
# 為什麼沒有「listening happy」case:啟動真實 IIS Express 屬於 start-iis 整合測試,
#   且每跑一次都污染 OS state。本 case 只驗證 not-listening / error 行為,夠用。

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:PluginRoot      = $pluginRoot
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Test-IisListening.ps1')

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
        $dir = [System.IO.Path]::Combine([System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-test-$Purpose-$guid")
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

    # Pick a high port unlikely to be in use → not listening case
    $script:Port = 51928
    $script:CsprojWithCustomPort = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <ProjectGuid>{00000000-1111-2222-3333-444444444444}</ProjectGuid>
    <OutputType>Library</OutputType>
    <RootNamespace>HelloApp</RootNamespace>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
  <ProjectExtensions>
    <VisualStudio>
      <FlavorProperties GUID="{349c5851-65df-11da-9384-00065b846f21}">
        <WebProjectProperties>
          <IISUrl>http://localhost:$($script:Port)/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
"@

    function New-Fixture {
        param([string]$Dir, [string]$Csproj = $script:CsprojWithCustomPort)
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($Dir, 'HelloApp.csproj'),
            $Csproj,
            (New-Object System.Text.UTF8Encoding($false)))
        # Explicit target via config (no auto-detect): Test-IisListening → Resolve-IisSettings
        # reads [run].project, falling back to [build].project. Script is invoked with no -Project.
        $tpDir = [System.IO.Path]::Combine($Dir, '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tpDir -Force
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($tpDir, 'config.toml'),
            "[build]`r`nproject = `"HelloApp.csproj`"`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
        Push-Location -LiteralPath $Dir
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'init'
        } finally { Pop-Location }
    }

    function Invoke-Script {
        param([string]$WorkDir)
        $oldLoc = Get-Location
        try {
            Set-Location -LiteralPath $WorkDir
            $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ScriptUnderTest 2>$null
            } catch {
                $stdout = @($_.Exception.Message)
            } finally {
                $ErrorActionPreference = $savedEap
            }
            $exit = $LASTEXITCODE
            return @{ Stdout = ($stdout -join "`n"); Exit = $exit }
        } finally { Set-Location -LiteralPath $oldLoc }
    }
}

Describe 'Test-IisListening' {

    Context 'Case 1 & 2: not listening + SKILL-entry re-invoke (same fixture)' {
        BeforeAll {
            $script:sb1 = New-Sandbox 'cil-notlisten'
            New-Fixture -Dir $script:sb1
            $script:r1 = Invoke-Script -WorkDir $script:sb1
            $script:r2 = Invoke-Script -WorkDir $script:sb1
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'case1: not-listening exit 1' { $script:r1.Exit | Should -Be 1 }
        It 'case1: stdout 提及 port' { $script:r1.Stdout | Should -Match "port: $($script:Port)" }
        It 'case2: SKILL-entry exit 1' { $script:r2.Exit | Should -Be 1 }
        It 'case2: stdout 一致' { $script:r2.Stdout | Should -Match "port: $($script:Port)" }
    }

    Context 'Case 3: missing csproj' {
        BeforeAll {
            $script:sb2 = New-Sandbox 'cil-nocsproj'
            Push-Location -LiteralPath $script:sb2
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                [System.IO.File]::WriteAllText((Join-Path $script:sb2 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'init'
            } finally { Pop-Location }
            $script:r3 = Invoke-Script -WorkDir $script:sb2
        }
        AfterAll { Remove-Sandbox $script:sb2 }

        It 'missing csproj exit ≠ 0' { ($script:r3.Exit -ne 0) | Should -BeTrue }
    }
}
