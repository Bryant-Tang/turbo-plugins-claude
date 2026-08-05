# Get-TargetUrl.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework/scripts/Get-TargetUrl.ps1
# Behavior: 從 csproj 的 <IISUrl> 解析 URL,Resolve-IisSettings 提供
#   IisUrl;script 直接 echo「IIS URL: <url>」。
#
# Cases:
#   1. Happy: 標準 fixture (IISUrl=http://localhost:5000/) → stdout 含 "IIS URL: http://localhost:5000/"
#   2. SKILL entry path: 重複呼叫 → 結果一致
#   3. missing csproj: workspace 無 .csproj → exit 非 0,訊息提及 .csproj

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Get-TargetUrl.ps1')
    $script:SandboxBase = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

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
            $script:MinimalCsproj,
            (New-Object System.Text.UTF8Encoding($false)))
        # Explicit target via config (no auto-detect): Get-TargetUrl → Resolve-IisSettings reads
        # [run].project, falling back to [build].project. Script is invoked with no -Project.
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
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture init'
        } finally { Pop-Location }
    }

    function Invoke-Script {
        param([string]$WorkDir)
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            # Quote the -File path so a spaced repo/parent path (AE8) survives Start-Process's
            # naive space-join of -ArgumentList (otherwise powershell.exe parses only up to the
            # first space and drops into interactive banner mode).
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) `
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
    }
}

Describe 'Get-TargetUrl' {

    Context 'Case 1 & 2: happy fixture (IISUrl) + SKILL re-invoke consistency' {
        BeforeAll {
            $script:sb1 = New-Sandbox 'gtu-happy'
            New-GitRepoFixture -Dir $script:sb1
            $script:r1 = Invoke-Script -WorkDir $script:sb1
            $script:r2 = Invoke-Script -WorkDir $script:sb1
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'case1: happy exit 0' { $script:r1.Exit | Should -Be 0 }
        It 'case1: stdout 含 IIS URL: http://localhost:5000/' {
            $script:r1.Stdout | Should -Match 'IIS URL: http://localhost:5000/'
        }
        It 'case2: SKILL-entry exit 0' { $script:r2.Exit | Should -Be 0 }
        It 'case2: stdout IIS URL 一致' {
            $script:r2.Stdout | Should -Match 'IIS URL: http://localhost:5000/'
        }
    }

    Context 'Case 3: missing csproj → fail-loudly' {
        BeforeAll {
            $script:sb2 = New-Sandbox 'gtu-nocsproj'
            Push-Location -LiteralPath $script:sb2
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                # Don't add csproj; commit empty repo state with one placeholder
                [System.IO.File]::WriteAllText((Join-Path $script:sb2 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture nocsproj'
            } finally { Pop-Location }
            $script:r3 = Invoke-Script -WorkDir $script:sb2
            # Combined stdout+stderr search (PS write to either depending on host)
            $script:combined3 = $script:r3.Stdout + "`n" + $script:r3.Stderr
        }
        AfterAll { Remove-Sandbox $script:sb2 }

        It 'case3: missing csproj exit ≠ 0' { ($script:r3.Exit -ne 0) | Should -BeTrue }
        It 'case3: 訊息提及 .csproj' { $script:combined3 | Should -Match '\.csproj' }
    }
}
