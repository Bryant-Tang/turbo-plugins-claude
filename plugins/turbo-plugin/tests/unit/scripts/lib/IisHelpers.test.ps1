# IisHelpers.test.ps1 (Pester 5)
#
# Library: plugins/turbo-plugin/scripts/lib/IisHelpers.ps1
# Behavior: 此 file 主要是 library (dot-source) — 它本身不直接被執行。本測試在 child
#   powershell 中 dot-source 它並直接 call Resolve-IisSettings，verify 該 function 行為。
#
# Cases:
#   1. Happy: fixture (HelloApp.csproj + .turbo-plugin/applicationhost.config) → 回傳 hashtable
#      properties: IisUrl=http://localhost:5000/, IisPort=5000, IisExpressPath 存在,
#      ApplicationhostConfigFile 路徑正確, IisConfigSiteName, IdentityHash。
#   2. Missing .turbo-plugin/applicationhost.config: 仍會回傳 (apphost target 是 canonical 路徑,
#      即使檔不存在);ApplicationhostConfigFile 必須是 fixture-root/.turbo-plugin/applicationhost.config。
#   3. 中文 path:workspace 路徑含中文 → 仍正確解析 IisUrl。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1')
    $script:CommonPs1 = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Common.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    # ── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ──
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

    function New-Sandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "turbo-plugin-test-$Purpose-$guid")
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

    $script:baseCsproj = @'
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
          <IISUrl>http://localhost:5000/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
'@

    function New-Fixture {
        param([string]$Dir, [switch]$WithApphost)
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($Dir, 'HelloApp.csproj'),
            $script:baseCsproj,
            (New-Object System.Text.UTF8Encoding($false)))
        $tpDir = [System.IO.Path]::Combine($Dir, '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tpDir -Force
        if ($WithApphost) {
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($tpDir, 'applicationhost.config'),
                '<configuration><system.applicationHost><sites><site name="HelloApp-deadbeef" id="1"><bindings><binding protocol="http" bindingInformation="*:5000:localhost" /></bindings></site></sites></system.applicationHost></configuration>',
                (New-Object System.Text.UTF8Encoding($false)))
        }
        Push-Location -LiteralPath $Dir
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'init'
        } finally { Pop-Location }
    }

    # Helper: run IisHelpers via PowerShell child process, returning a structured snapshot.
    # Why a child process and not dot-source: the script is library-only; we dot-source it inline
    # AND call Resolve-IisSettings inline, with cwd = the fixture workspace.
    function Invoke-ResolveAsChild {
        param([string]$WorkDir)
        $oldLoc = Get-Location
        try {
            Set-Location -LiteralPath $WorkDir
            $cmd = @"
. '$($script:CommonPs1)'
. '$($script:ScriptUnderTest)'
try {
    `$s = Resolve-IisSettings
    Write-Output "IisUrl=`$(`$s.IisUrl)"
    Write-Output "IisPort=`$(`$s.IisPort)"
    Write-Output "IisExpressPath=`$(`$s.IisExpressPath)"
    Write-Output "ApplicationhostConfigFile=`$(`$s.ApplicationhostConfigFile)"
    Write-Output "IisConfigSiteName=`$(`$s.IisConfigSiteName)"
    Write-Output "IdentityHash=`$(`$s.IdentityHash)"
} catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@
            $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>$null
                $exit = $LASTEXITCODE
            } catch {
                $stdout = @($_.Exception.Message); $exit = 99
            } finally {
                $ErrorActionPreference = $savedEap
            }
            return @{ Stdout = ($stdout -join "`n"); Exit = $exit }
        } finally { Set-Location -LiteralPath $oldLoc }
    }
}

Describe 'IisHelpers Resolve-IisSettings' {

    Context 'Case 1: happy' {
        BeforeAll {
            $script:sb1 = New-Sandbox 'ris-happy'
            New-Fixture -Dir $script:sb1 -WithApphost
            $script:r1 = Invoke-ResolveAsChild -WorkDir $script:sb1
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'happy exits 0' { $script:r1.Exit | Should -Be 0 }
        It 'IisUrl is http://localhost:5000/' { $script:r1.Stdout | Should -Match 'IisUrl=http://localhost:5000/' }
        It 'IisPort is 5000' { $script:r1.Stdout | Should -Match 'IisPort=5000' }
        It 'IisExpressPath nonempty (iisexpress.exe)' { $script:r1.Stdout | Should -Match 'IisExpressPath=.+iisexpress\.exe' }
        It 'ApplicationhostConfigFile 路徑 ok' { $script:r1.Stdout | Should -Match '\.turbo-plugin[/\\]applicationhost\.config' }
        It 'IisConfigSiteName format' { $script:r1.Stdout | Should -Match 'IisConfigSiteName=HelloApp-[0-9a-f]{8}' }
        It 'IdentityHash 8-hex' { $script:r1.Stdout | Should -Match 'IdentityHash=[0-9a-f]{8}' }
    }

    Context 'Case 2: missing apphost still resolves' {
        BeforeAll {
            $script:sb2 = New-Sandbox 'ris-noapphost'
            New-Fixture -Dir $script:sb2  # no -WithApphost
            $script:r2 = Invoke-ResolveAsChild -WorkDir $script:sb2
        }
        AfterAll { Remove-Sandbox $script:sb2 }

        # Resolve-IisSettings 本身不檢查 apphost 是否存在(那是 start-iis 才檢);應仍能 return
        It 'missing apphost still exits 0' { $script:r2.Exit | Should -Be 0 }
        It 'ApplicationhostConfigFile 仍指向 canonical 路徑' { $script:r2.Stdout | Should -Match '\.turbo-plugin[/\\]applicationhost\.config' }
    }

    Context 'Case 3: chinese path' {
        BeforeAll {
            $script:sb3 = New-Sandbox 'ris-zh'
            $zhSub = [System.IO.Path]::Combine($script:sb3, '路徑', '含中文')
            $null = New-Item -ItemType Directory -Path $zhSub -Force
            New-Fixture -Dir $zhSub -WithApphost
            $script:r3 = Invoke-ResolveAsChild -WorkDir $zhSub
        }
        AfterAll { Remove-Sandbox $script:sb3 }

        It '中文 path exits 0' { $script:r3.Exit | Should -Be 0 }
        It '中文 path IisUrl 解析正確' { $script:r3.Stdout | Should -Match 'IisUrl=http://localhost:5000/' }
    }
}
