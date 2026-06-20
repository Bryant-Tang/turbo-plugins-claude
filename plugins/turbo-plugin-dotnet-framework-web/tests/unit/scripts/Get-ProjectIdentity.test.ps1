# Get-ProjectIdentity.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework-web/scripts/Get-ProjectIdentity.ps1
#
# Cases:
#   1. Happy: 標準 .csproj + git common-dir 下,output 含 PROJECT/IDENTITY_HASH/SITE_NAME，
#      且 IDENTITY_HASH 為 8-char hex (Get-ProjectIdentityHash 截前 8)。
#   2. SKILL entry path: 由 PowerShell -File <script.ps1> CLI 觸發 (與 SKILL 的標準入口路徑一致);
#      hash 與 case 1 一致 (R2(e) 一致性)。
#   3. 中文 path (字典 #1.5):workspace 路徑含中文「中文資料夾/sub-層」→ hash 計算不 crash,
#      ≠ ASCII fixture hash,結尾 8 hex。

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    $script:PluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:PluginRoot, 'scripts', 'Get-ProjectIdentity.ps1')
    $script:ScriptExists = [System.IO.File]::Exists($script:ScriptUnderTest)

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
    $script:minimalCsproj = @'
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
        [System.IO.File]::WriteAllText($csprojPath, $script:minimalCsproj, (New-Object System.Text.UTF8Encoding($false)))
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
                $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ScriptUnderTest 2>$null
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

    # ─── Build fixtures ──────────────────────────────────────────────────────
    # Case 1/2 share an ASCII sandbox; case 3 uses a 中文 path sandbox.
    $script:sb1 = New-Sandbox 'cpi-happy'
    New-GitRepoFixture -Dir $script:sb1
    $script:r1 = Invoke-Script -WorkDir $script:sb1

    $script:hash1 = $null
    if ($script:r1.Stdout -match 'IDENTITY_HASH=([0-9a-f]{8})') { $script:hash1 = $Matches[1] }

    # Case 2: re-invoke under the SAME workdir (canonical SKILL CLI invocation pattern)
    $script:r2 = Invoke-Script -WorkDir $script:sb1
    $script:hash2 = $null
    if ($script:r2.Stdout -match 'IDENTITY_HASH=([0-9a-f]{8})') { $script:hash2 = $Matches[1] }

    # Case 3: 中文 path (字典 #1.5 「中文資料夾/sub-層」一段)
    $script:sb2 = New-Sandbox 'cpi-zh'
    $zhSub = [System.IO.Path]::Combine($script:sb2, '中文資料夾')
    $null = New-Item -ItemType Directory -Path $zhSub -Force
    New-GitRepoFixture -Dir $zhSub
    $script:r3 = Invoke-Script -WorkDir $zhSub
    $script:hash3 = $null
    if ($script:r3.Stdout -match 'IDENTITY_HASH=([0-9a-f]{8})') { $script:hash3 = $Matches[1] }
}

AfterAll {
    Remove-Sandbox $script:sb1
    Remove-Sandbox $script:sb2
}

Describe 'Get-ProjectIdentity' {

    It 'script-under-test exists' {
        $script:ScriptExists | Should -BeTrue -Because "expected at $script:ScriptUnderTest"
    }

    Context 'Case 1: happy path — ASCII workspace' {
        It 'happy exit 0' { $script:r1.Exit | Should -Be 0 }
        It 'stdout has PROJECT line' { $script:r1.Stdout | Should -Match 'PROJECT=' }
        It 'IDENTITY_HASH is 8-hex' { $script:r1.Stdout | Should -Match 'IDENTITY_HASH=[0-9a-f]{8}\b' }
        It 'SITE_NAME format <stem>-<hash>' { $script:r1.Stdout | Should -Match 'SITE_NAME=HelloApp-[0-9a-f]{8}' }
    }

    Context 'Case 2: SKILL entry path — same script via canonical SKILL CLI invocation' {
        It 'SKILL-entry exit 0' { $script:r2.Exit | Should -Be 0 }
        It 'SKILL-entry hash matches direct invocation (R2(e) consistency)' {
            $script:hash2 | Should -Be $script:hash1
        }
    }

    Context 'Case 3: 中文 path (字典 #1.5)' {
        It '中文 path exit 0' { $script:r3.Exit | Should -Be 0 }
        It '中文 path IDENTITY_HASH 8-hex' { $script:r3.Stdout | Should -Match 'IDENTITY_HASH=[0-9a-f]{8}\b' }
        It '中文 path hash differs from ASCII fixture' { ($script:hash3 -ne $script:hash1) | Should -BeTrue }
    }
}
