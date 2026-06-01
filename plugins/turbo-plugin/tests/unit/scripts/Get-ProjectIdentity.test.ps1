# compute-project-identity.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/Get-ProjectIdentity.ps1
#
# Cases:
#   1. Happy: 標準 .csproj + git common-dir 下,output 含 PROJECT/IDENTITY_HASH/SITE_NAME，
#      且 IDENTITY_HASH 為 8-char hex (Get-ProjectIdentityHash 截前 8)。
#   2. SKILL entry path: 由 PowerShell -File <script.ps1> CLI 觸發 (與 SKILL 的標準入口路徑一致);
#      hash 與 case 1 一致 (R2(e) 一致性)。
#   3. 中文 path (字典 #1.5):workspace 路徑含中文「中文資料夾/sub-層」→ hash 計算不 crash,
#      ≠ ASCII fixture hash,結尾 8 hex。
#
# 規定:
#   - hand-rolled Assert-* via AssertHelpers.ps1 dot-source
#   - 不修改 plugins/turbo-plugin/scripts/...
#   - 沙盒目錄走 C:\Turbo\test-turbo-plugin\sandboxes\turbo-plugin-test-<purpose>-<guid>;避免 %TEMP% 的 PS 5.1 8.3 short-name 問題
#   - 用後 try/finally 清掉沙盒;ReadOnly attr 清掉再 Delete

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Locate helpers + script under test ─────────────────────────────────────

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
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Get-ProjectIdentity.ps1')
if (-not [System.IO.File]::Exists($ScriptUnderTest)) {
    Write-Output "  [FAIL] script-under-test not found: $ScriptUnderTest"
    exit 1
}

# ─── Sandbox setup ──────────────────────────────────────────────────────────

function New-Sandbox {
    param([string]$Purpose)
    $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine('C:\Turbo\test-turbo-plugin\sandboxes', "turbo-plugin-test-$Purpose-$guid")
    $null = New-Item -ItemType Directory -Path $dir -Force
    return $dir
}

function Remove-Sandbox {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        if ([System.IO.Directory]::Exists($Dir)) {
            # ReadOnly attr clear (git pack files / SVN format files)
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
    } catch {
        Write-Output "  (cleanup warn) Remove-Sandbox $Dir : $($_.Exception.Message)"
    }
}

# Minimal csproj content for a fixture (.NET Framework web app shape — enough for Find-SingleCsproj)
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
    param(
        [string]$Dir,
        [string]$CsprojName = 'HelloApp.csproj'
    )
    $csprojPath = [System.IO.Path]::Combine($Dir, $CsprojName)
    [System.IO.File]::WriteAllText($csprojPath, $minimalCsproj, (New-Object System.Text.UTF8Encoding($false)))
    # git init + first commit so common-dir is stable
    Push-Location -LiteralPath $Dir
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        Invoke-GitSilent add -A
        Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture init'
    } finally {
        Pop-Location
    }
}

function Invoke-Script {
    param(
        [string]$WorkDir,
        [hashtable]$EnvVars
    )
    $oldLoc = Get-Location
    $savedEnv = @{}
    if ($null -ne $EnvVars) {
        foreach ($k in $EnvVars.Keys) {
            $savedEnv[$k] = [System.Environment]::GetEnvironmentVariable($k, 'Process')
            [System.Environment]::SetEnvironmentVariable($k, [string]$EnvVars[$k], 'Process')
        }
    }
    try {
        Set-Location -LiteralPath $WorkDir
        $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptUnderTest 2>$null
            $exit = $LASTEXITCODE
        } catch {
            $out = @($_.Exception.Message); $exit = 99
        } finally {
            $ErrorActionPreference = $savedEap
        }
        return @{ Stdout = ($out -join "`n"); Exit = $exit }
    } finally {
        Set-Location -LiteralPath $oldLoc
        if ($null -ne $EnvVars) {
            foreach ($k in $savedEnv.Keys) {
                [System.Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process')
            }
        }
    }
}

# ─── Cases ──────────────────────────────────────────────────────────────────

$sb1 = $null
$sb2 = $null

try {
    # Case 1: happy path — ASCII workspace
    $sb1 = New-Sandbox 'cpi-happy'
    New-GitRepoFixture -Dir $sb1
    $r1 = Invoke-Script -WorkDir $sb1
    Assert-Equal -Name 'case1: happy exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: stdout has PROJECT line' -Pattern 'PROJECT=' -InputText $r1.Stdout
    Assert-Match -Name 'case1: IDENTITY_HASH is 8-hex' -Pattern 'IDENTITY_HASH=[0-9a-f]{8}\b' -InputText $r1.Stdout
    Assert-Match -Name 'case1: SITE_NAME format <stem>-<hash>' -Pattern 'SITE_NAME=HelloApp-[0-9a-f]{8}' -InputText $r1.Stdout

    # Extract hash for case 2
    $hash1 = $null
    if ($r1.Stdout -match 'IDENTITY_HASH=([0-9a-f]{8})') { $hash1 = $Matches[1] }

    # Case 2: SKILL entry path — same script via the canonical SKILL CLI invocation pattern.
    # turbo-plugin scripts do not consume env vars (config-driven design); SKILL entry =
    # the `powershell -NoProfile -ExecutionPolicy Bypass -File <ps1>` form already used in case 1.
    # We re-invoke under the SAME workdir and assert hash deterministically equal — R2(e) consistency.
    $r2 = Invoke-Script -WorkDir $sb1
    Assert-Equal -Name 'case2: SKILL-entry exit 0' -Expected 0 -Actual $r2.Exit
    $hash2 = $null
    if ($r2.Stdout -match 'IDENTITY_HASH=([0-9a-f]{8})') { $hash2 = $Matches[1] }
    Assert-Equal -Name 'case2: SKILL-entry hash matches direct invocation' -Expected $hash1 -Actual $hash2

    # Case 3: 中文 path (字典 #1.5 「中文資料夾/sub-層」一段)
    $sb2 = New-Sandbox 'cpi-zh'
    $zhSub = [System.IO.Path]::Combine($sb2, '中文資料夾')
    $null = New-Item -ItemType Directory -Path $zhSub -Force
    New-GitRepoFixture -Dir $zhSub
    $r3 = Invoke-Script -WorkDir $zhSub
    Assert-Equal -Name 'case3: 中文 path exit 0' -Expected 0 -Actual $r3.Exit
    Assert-Match -Name 'case3: 中文 path IDENTITY_HASH 8-hex' -Pattern 'IDENTITY_HASH=[0-9a-f]{8}\b' -InputText $r3.Stdout
    $hash3 = $null
    if ($r3.Stdout -match 'IDENTITY_HASH=([0-9a-f]{8})') { $hash3 = $Matches[1] }
    Assert-True -Name 'case3: 中文 path hash differs from ASCII fixture' -Condition ($hash3 -ne $hash1)
}
finally {
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2
}

# ─── Summary ────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output "compute-project-identity.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    Write-Output 'Failures:'
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
