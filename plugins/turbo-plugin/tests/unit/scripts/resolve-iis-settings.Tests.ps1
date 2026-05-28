# resolve-iis-settings.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/resolve-iis-settings.ps1
# Behavior: 此 file 主要是 library (dot-source) — 它本身不直接被執行;但仍可 `powershell -File ...`
#   呼叫,結果應只是 dot-source 帶來的 function 定義(無 stdout 輸出)。
#
# 由於 resolve-iis-settings.ps1 不是 main script 而是 library:本測試 dot-source 它並直接 call
# `Resolve-IisSettings`,verify 該 function 的行為。
#
# Cases:
#   1. Happy: fixture (HelloApp.csproj + .turbo-plugin/applicationhost.config) → 回傳 hashtable
#      properties: IisUrl=http://localhost:5000/, IisPort=5000, IisExpressPath 存在, ApplicationhostConfigFile 路徑正確
#   2. Missing .turbo-plugin/applicationhost.config: 仍會回傳 (apphost target 是 canonical 路徑,即使檔不存在);
#      但 ApplicationhostConfigFile 必須是 fixture-root/.turbo-plugin/applicationhost.config
#   3. 中文 path (字典 #1.1 「路徑/含中文」一段):workspace 路徑含中文 → 仍正確解析 IisUrl

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'Assert-Helpers.ps1')
. $LibPath
Reset-Counters


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

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'resolve-iis-settings.ps1')
$commonPs1 = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'common.ps1')

function New-Sandbox { param([string]$Purpose)
    $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-$Purpose-$guid")
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

$baseCsproj = @'
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
        $baseCsproj,
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

# Helper: run resolve-iis-settings via PowerShell child process, returning a structured snapshot.
# Why a child process and not dot-source: parent and child have to set strict-mode + share workspace,
# but the script itself is library-only. We dot-source it inline AND call Resolve-IisSettings inline.
function Invoke-ResolveAsChild {
    param([string]$WorkDir)
    $oldLoc = Get-Location
    try {
        Set-Location -LiteralPath $WorkDir
        $cmd = @"
. '$commonPs1'
. '$ScriptUnderTest'
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

$sb1 = $null
$sb2 = $null
$sb3 = $null

try {
    # Case 1: happy
    $sb1 = New-Sandbox 'ris-happy'
    New-Fixture -Dir $sb1 -WithApphost
    $r1 = Invoke-ResolveAsChild -WorkDir $sb1
    Assert-Equal -Name 'case1: happy exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: IisUrl=http://localhost:5000/' `
                 -Pattern 'IisUrl=http://localhost:5000/' -InputText $r1.Stdout
    Assert-Match -Name 'case1: IisPort=5000' -Pattern 'IisPort=5000' -InputText $r1.Stdout
    Assert-Match -Name 'case1: IisExpressPath nonempty' -Pattern 'IisExpressPath=.+iisexpress\.exe' -InputText $r1.Stdout
    Assert-Match -Name 'case1: ApplicationhostConfigFile 路徑 ok' `
                 -Pattern '\.turbo-plugin[/\\]applicationhost\.config' -InputText $r1.Stdout
    Assert-Match -Name 'case1: IisConfigSiteName format' -Pattern 'IisConfigSiteName=HelloApp-[0-9a-f]{8}' -InputText $r1.Stdout
    Assert-Match -Name 'case1: IdentityHash 8-hex' -Pattern 'IdentityHash=[0-9a-f]{8}' -InputText $r1.Stdout

    # Case 2: missing apphost (file 不存在但 path 仍應計算出)
    $sb2 = New-Sandbox 'ris-noapphost'
    New-Fixture -Dir $sb2  # no -WithApphost
    $r2 = Invoke-ResolveAsChild -WorkDir $sb2
    # Resolve-IisSettings 本身不檢查 apphost 是否存在(那是 start-iis 才檢);應仍能 return
    Assert-Equal -Name 'case2: missing apphost still exits 0' -Expected 0 -Actual $r2.Exit
    Assert-Match -Name 'case2: ApplicationhostConfigFile 仍指向 canonical 路徑' `
                 -Pattern '\.turbo-plugin[/\\]applicationhost\.config' -InputText $r2.Stdout

    # Case 3: 中文 path (字典 #1.1 「路徑/含中文」)
    $sb3 = New-Sandbox 'ris-zh'
    $zhSub = [System.IO.Path]::Combine($sb3, '路徑', '含中文')
    $null = New-Item -ItemType Directory -Path $zhSub -Force
    New-Fixture -Dir $zhSub -WithApphost
    $r3 = Invoke-ResolveAsChild -WorkDir $zhSub
    Assert-Equal -Name 'case3: 中文 path exit 0' -Expected 0 -Actual $r3.Exit
    Assert-Match -Name 'case3: 中文 path IisUrl 解析正確' `
                 -Pattern 'IisUrl=http://localhost:5000/' -InputText $r3.Stdout
}
finally {
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2
    Remove-Sandbox $sb3
}

Write-Output ''
Write-Output "resolve-iis-settings.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
