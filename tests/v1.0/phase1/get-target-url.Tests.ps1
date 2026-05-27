# get-target-url.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/get-target-url.ps1
# Behavior: 從 csproj 的 <IISUrl> 解析 URL,Resolve-IisSettings 提供
#   IisUrl;script 直接 echo「IIS URL: <url>」。
#
# Cases:
#   1. Happy: 標準 fixture (IISUrl=http://localhost:5000/) → stdout 含 "IIS URL: http://localhost:5000/"
#   2. SKILL entry path: 重複呼叫 → 結果一致
#   3. missing csproj: workspace 無 .csproj → exit 非 0,stderr 含「No .csproj found」

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Assert-Helpers.ps1')
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

$repoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($repoRoot, 'plugins', 'turbo-plugin', 'scripts', 'get-target-url.ps1')

function New-Sandbox {
    param([string]$Purpose)
    $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-$Purpose-$guid")
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

$minimalCsproj = @'
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

function New-GitRepoFixture {
    param([string]$Dir)
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($Dir, 'HelloApp.csproj'),
        $minimalCsproj,
        (New-Object System.Text.UTF8Encoding($false)))
    Push-Location -LiteralPath $Dir
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        Invoke-GitSilent add -A
        Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture init'
    } finally { Pop-Location }
}

function Invoke-Script {
    param([string]$WorkDir)
    $oldLoc = Get-Location
    try {
        Set-Location -LiteralPath $WorkDir
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptUnderTest) `
                -WorkingDirectory $WorkDir `
                -RedirectStandardOutput $tmpStdout `
                -RedirectStandardError $tmpStderr `
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
    } finally {
        Set-Location -LiteralPath $oldLoc
    }
}

$sb1 = $null
$sb2 = $null

try {
    # Case 1: happy
    $sb1 = New-Sandbox 'gtu-happy'
    New-GitRepoFixture -Dir $sb1
    $r1 = Invoke-Script -WorkDir $sb1
    Assert-Equal -Name 'case1: happy exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: stdout 含 IIS URL: http://localhost:5000/' `
                 -Pattern 'IIS URL: http://localhost:5000/' -InputText $r1.Stdout

    # Case 2: SKILL entry (same workdir → same URL)
    $r2 = Invoke-Script -WorkDir $sb1
    Assert-Equal -Name 'case2: SKILL-entry exit 0' -Expected 0 -Actual $r2.Exit
    Assert-Match -Name 'case2: stdout IIS URL 一致' -Pattern 'IIS URL: http://localhost:5000/' -InputText $r2.Stdout

    # Case 3: missing csproj
    $sb2 = New-Sandbox 'gtu-nocsproj'
    Push-Location -LiteralPath $sb2
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        # Don't add csproj; commit empty repo state with one placeholder
        [System.IO.File]::WriteAllText((Join-Path $sb2 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture nocsproj'
    } finally { Pop-Location }
    $r3 = Invoke-Script -WorkDir $sb2
    Assert-True -Name 'case3: missing csproj exit ≠ 0' -Condition ($r3.Exit -ne 0)
    # Combined stdout+stderr search (PS write to either depending on host)
    $combined = $r3.Stdout + "`n" + $r3.Stderr
    Assert-Match -Name 'case3: 訊息提及 .csproj' -Pattern '\.csproj' -InputText $combined
}
finally {
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2
}

Write-Output ''
Write-Output "get-target-url.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
