# Build-Web.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework-web/scripts/Build-Web.ps1
# Behavior: 找 csproj → 找 MSBuild → 跑 msbuild /restore /t:Build → 跑 pack-content.ps1
#
# 注意:此 script **沒有** 自己的 [iis] enabled gate(by design;見 commit 84e944a)。
#   SKILL.md 是 gatekeeper。本測試 deviation 標記。
#
# Cases:
#   1. Missing csproj: workspace 無 csproj → exit ≠ 0,訊息提及 .csproj
#   2. SKILL entry consistency: 再呼叫 missing-csproj case → 一致
#   3. [iis] enabled = false consistency (deviation): script-level 沒 gate,但因 fixture 沒 csproj
#      會先撞 missing-csproj error → 走 csproj 訊息;documented deviation。
#   4. Real build happy (smoke): 不在 phase 1 跑(MSBuild restoration 太慢、會碰網路);
#      此 case 標 SKIP — Phase 2 SKILL 測試會 cover full build。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-Web.ps1')
    $script:PluginRoot = $pluginRoot

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

    function New-Sandbox { param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine([System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-test-$Purpose-$guid")
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
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) + @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
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

    # ─── Build fixtures for case 1/2 (shared sandbox sb1) and case 3 (sb2) ───
    $script:sb1 = New-Sandbox 'build-nocsproj'
    Push-Location -LiteralPath $script:sb1
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        [System.IO.File]::WriteAllText((Join-Path $script:sb1 'README.txt'), 'no csproj', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }

    $script:sb2 = New-Sandbox 'build-iisfalse'
    $tpDir = [System.IO.Path]::Combine($script:sb2, '.turbo-plugin')
    $null = New-Item -ItemType Directory -Path $tpDir -Force
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($tpDir, 'config.toml'),
        "[iis]`nenabled = false`n",
        (New-Object System.Text.UTF8Encoding($false)))
    Push-Location -LiteralPath $script:sb2
    try {
        Invoke-GitSilent init -q
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }
}

AfterAll {
    Remove-Sandbox $script:sb1
    Remove-Sandbox $script:sb2
}

Describe 'Build-Web' {

    Context 'Case 1: missing csproj' {
        BeforeAll { $script:r1 = Invoke-Script -WorkDir $script:sb1 }

        It 'missing csproj exit != 0' { ($script:r1.Exit -ne 0) | Should -BeTrue }
        It '訊息提及 .csproj' {
            ($script:r1.Stdout + "`n" + $script:r1.Stderr) | Should -Match '\.csproj'
        }
    }

    Context 'Case 2: SKILL entry re-invoke missing-csproj' {
        BeforeAll { $script:r2 = Invoke-Script -WorkDir $script:sb1 }

        It 'SKILL-entry exit != 0' { ($script:r2.Exit -ne 0) | Should -BeTrue }
    }

    Context 'Case 3: [iis]=false on sandbox with config.toml — script has no gate (deviation)' {
        # Behavior: script will fail at csproj-finding (same as case 1) because no csproj exists.
        # Documented deviation: SKILL-level gate not exercised here; Phase 2 SKILL covers it.
        BeforeAll { $script:r3 = Invoke-Script -WorkDir $script:sb2 }

        It '[iis]=false no script-level gate → exits with csproj error' {
            # Script has no [iis] gate; goes to csproj-finder which throws.
            ($script:r3.Exit -ne 0) | Should -BeTrue
        }
        It 'stderr present (no IIS gate at script level)' {
            # Either .csproj error or some other; not asserting IIS 已停用 here (script doesn't gate)
            (($script:r3.Stdout + "`n" + $script:r3.Stderr).Length -gt 0) | Should -BeTrue
        }
    }

    Context 'Case 4: real-build happy (smoke)' {
        It 'real MSBuild build deferred to SKILL-level test (too heavy + network for unit scope)' -Skip {
            # Phase 2 SKILL territory — intentionally skipped at unit scope.
        }
    }
}
