# check-iis-listening.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/check-iis-listening.ps1
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
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'check-iis-listening.ps1')

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

# Pick a high port unlikely to be in use → not listening case
$port = 51928
$csprojWithCustomPort = @"
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
          <IISUrl>http://localhost:$port/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
"@

function New-Fixture {
    param([string]$Dir, [string]$Csproj = $csprojWithCustomPort)
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($Dir, 'HelloApp.csproj'),
        $Csproj,
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
            $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptUnderTest 2>$null
        } catch {
            $stdout = @($_.Exception.Message)
        } finally {
            $ErrorActionPreference = $savedEap
        }
        $exit = $LASTEXITCODE
        return @{ Stdout = ($stdout -join "`n"); Exit = $exit }
    } finally { Set-Location -LiteralPath $oldLoc }
}

$sb1 = $null
$sb2 = $null

try {
    # Case 1: not listening on chosen port
    $sb1 = New-Sandbox 'cil-notlisten'
    New-Fixture -Dir $sb1
    $r1 = Invoke-Script -WorkDir $sb1
    Assert-Equal -Name 'case1: not-listening exit 1' -Expected 1 -Actual $r1.Exit
    Assert-Match -Name 'case1: stdout 提及 port' -Pattern "port: $port" -InputText $r1.Stdout

    # Case 2: SKILL entry — same dir, second invocation. Behavior identical.
    $r2 = Invoke-Script -WorkDir $sb1
    Assert-Equal -Name 'case2: SKILL-entry exit 1' -Expected 1 -Actual $r2.Exit
    Assert-Match -Name 'case2: stdout 一致' -Pattern "port: $port" -InputText $r2.Stdout

    # Case 3: missing csproj
    $sb2 = New-Sandbox 'cil-nocsproj'
    Push-Location -LiteralPath $sb2
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        [System.IO.File]::WriteAllText((Join-Path $sb2 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'init'
    } finally { Pop-Location }
    $r3 = Invoke-Script -WorkDir $sb2
    Assert-True -Name 'case3: missing csproj exit ≠ 0' -Condition ($r3.Exit -ne 0)
}
finally {
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2
}

Write-Output ''
Write-Output "check-iis-listening.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
