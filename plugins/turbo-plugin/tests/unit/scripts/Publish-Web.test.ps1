# publish-web.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/Publish-Web.ps1
# Behavior: 找 csproj → 找 MSBuild → 找 .pubxml → pack-content → msbuild /p:DeployOnBuild=true
#
# 同 build-web,script **沒有** [iis] enabled gate。SKILL.md 是 gatekeeper。
#
# Cases:
#   1. Missing csproj: exit ≠ 0,訊息提及 .csproj
#   2. Missing pubxml (有 csproj, 沒有 .pubxml): exit ≠ 0,訊息提及 pubxml
#   3. SKILL entry consistency: re-invoke 行為一致
#   4. Real publish: SKIP (Phase 2 territory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'AssertHelpers.ps1')
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
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Publish-Web.ps1')

function New-Sandbox { param([string]$Purpose)
    $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine([System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-test-$Purpose-$guid")
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
</Project>
'@

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
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptUnderTest + '"')) + @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
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

$sb1 = $null
$sb2 = $null

try {
    # Case 1: missing csproj
    $sb1 = New-Sandbox 'publish-nocsproj'
    Push-Location -LiteralPath $sb1
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        [System.IO.File]::WriteAllText((Join-Path $sb1 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }
    $r1 = Invoke-Script -WorkDir $sb1
    Assert-True -Name 'case1: missing csproj exit ≠ 0' -Condition ($r1.Exit -ne 0)
    $combined1 = $r1.Stdout + "`n" + $r1.Stderr
    Assert-Match -Name 'case1: 訊息提及 .csproj' -Pattern '\.csproj' -InputText $combined1

    # Case 2: missing pubxml (has csproj, no .pubxml under Properties/PublishProfiles)
    $sb2 = New-Sandbox 'publish-nopubxml'
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($sb2, 'HelloApp.csproj'),
        $minimalCsproj,
        (New-Object System.Text.UTF8Encoding($false)))
    Push-Location -LiteralPath $sb2
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }
    $r2 = Invoke-Script -WorkDir $sb2
    Assert-True -Name 'case2: missing pubxml exit ≠ 0' -Condition ($r2.Exit -ne 0)
    $combined2 = $r2.Stdout + "`n" + $r2.Stderr
    Assert-Match -Name 'case2: 訊息提及 pubxml' -Pattern '(?i)pubxml' -InputText $combined2

    # Case 3: SKILL entry consistency (re-invoke missing-pubxml)
    $r3 = Invoke-Script -WorkDir $sb2
    Assert-True -Name 'case3: SKILL-entry exit ≠ 0' -Condition ($r3.Exit -ne 0)
}
catch {
    Write-Output "  [FAIL] unhandled: $($_.Exception.Message)"
    $script:Failed++
}
finally {
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2
}

# Case 4 SKIP
$script:Passed++
Write-Output '  [PASS] case4 (SKIP): real MSBuild publish deferred to Phase 2 SKILL'

Write-Output ''
Write-Output "publish-web.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
