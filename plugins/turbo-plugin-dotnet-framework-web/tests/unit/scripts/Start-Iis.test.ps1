# Start-Iis.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework-web/scripts/Start-Iis.ps1
# Behavior:
#   - Defensive layer:.turbo-plugin/config.toml [iis] enabled = false → throw with bilingual msg
#   - Else:resolve IIS settings → render temp apphost.config (placeholder substitution) → launch
#     iisexpress.exe → wait for port LISTENING。
#
# Cases:
#   1. [iis] enabled = false canonical (CRITICAL — canonical disabled fixture case):
#      改 fixture 的 config.toml 為 enabled = false → 跑 script → exit ≠ 0,stderr 含「IIS 已停用」;
#      最後還原 config.toml 為 enabled = true。
#   2. Missing canonical applicationhost.config in fixture: 刪 fixture 的 apphost.config →
#      script throws「applicationhost.config does not exist」or「無法解析」(無 apphost → SKIP)
#   3. Missing csproj: workspace 無 csproj → throws .csproj 訊息
#   4. SKILL entry path (disabled fixture):用同樣的 [iis] enabled=false fixture 再呼叫一次 →
#      行為一致
#
# 不跑「真正啟動 IIS Express + port LISTENING」happy case:會 spawn 真實 process 污染 OS state。
#   Cases 1-3 走 gate / missing-file 路徑,不需要實際 iisexpress.exe。

BeforeAll {
    $script:pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'Start-Iis.ps1')
    $script:SandboxBase = [System.IO.Path]::Combine($script:pluginRoot, 'tests', '.sandbox', 'sandboxes')

    $script:testRoot = [System.IO.Path]::Combine($script:pluginRoot, 'tests', '.sandbox', 'test-turbo-plugin')
    $script:cfgPath = [System.IO.Path]::Combine($script:testRoot, '.turbo-plugin', 'config.toml')
    $script:apphostPath = [System.IO.Path]::Combine($script:testRoot, '.turbo-plugin', 'applicationhost.config')

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

    function Ensure-FixtureGit {
        if (-not [System.IO.Directory]::Exists($script:testRoot)) { return $false }
        if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:testRoot, '.git'))) {
            Push-Location -LiteralPath $script:testRoot
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture init'
            } finally { Pop-Location }
        }
        return $true
    }

    function Set-IisEnabled {
        param([bool]$Enabled)
        if (-not [System.IO.File]::Exists($script:cfgPath)) {
            throw "cfg not found: $($script:cfgPath)"
        }
        $text = [System.IO.File]::ReadAllText($script:cfgPath, [System.Text.Encoding]::UTF8)
        $valueLine = if ($Enabled) { 'enabled = true' } else { 'enabled = false' }
        # Replace existing 'enabled = true|false' under [iis] section
        $patched = [regex]::Replace($text, '(?m)^enabled\s*=\s*(true|false)\s*$', $valueLine)
        [System.IO.File]::WriteAllText($script:cfgPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
    }

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            # Quote -File (and any spaced ExtraArg) so a spaced repo/parent path (AE8) survives
            # Start-Process's naive space-join of -ArgumentList.
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) + @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList $argList `
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

    $script:FixtureReady = Ensure-FixtureGit
}

Describe 'Start-Iis' {

    Context 'Case 1 & 4: [iis] enabled = false canonical disabled fixture + SKILL re-invoke' {
        BeforeAll {
            if ($script:FixtureReady) {
                Set-IisEnabled -Enabled $false
                try {
                    $script:r1 = Invoke-Script -WorkDir $script:testRoot
                    $script:combined1 = $script:r1.Stdout + "`n" + $script:r1.Stderr
                    $script:r4 = Invoke-Script -WorkDir $script:testRoot
                    $script:combined4 = $script:r4.Stdout + "`n" + $script:r4.Stderr
                } finally {
                    Set-IisEnabled -Enabled $true  # restore so other tests don't see disabled state
                }
            }
        }

        It 'setup: fixture present' { $script:FixtureReady | Should -BeTrue }

        It 'case1: [iis] disabled exit ≠ 0' { ($script:r1.Exit -ne 0) | Should -BeTrue }
        It 'case1: stderr 含 IIS 已停用' { $script:combined1 | Should -Match 'IIS 已停用' }
        It 'case1: stderr 含 [iis] enabled = false 提示' { $script:combined1 | Should -Match '\[iis\].*enabled.*false' }

        It 'case4: SKILL-entry disabled exit ≠ 0' { ($script:r4.Exit -ne 0) | Should -BeTrue }
        It 'case4: 訊息一致' { $script:combined4 | Should -Match 'IIS 已停用' }
    }

    Context 'Case 2: missing canonical applicationhost.config' {
        BeforeAll {
            $script:apphostPresent = $script:FixtureReady -and [System.IO.File]::Exists($script:apphostPath)
            if ($script:apphostPresent) {
                $apphostBackup = [System.IO.File]::ReadAllBytes($script:apphostPath)
                try {
                    [System.IO.File]::Delete($script:apphostPath)
                    $script:r2 = Invoke-Script -WorkDir $script:testRoot
                    $script:combined2 = $script:r2.Stdout + "`n" + $script:r2.Stderr
                } finally {
                    [System.IO.File]::WriteAllBytes($script:apphostPath, $apphostBackup)
                }
            }
        }

        It 'case2: missing apphost exit ≠ 0' {
            if (-not $script:apphostPresent) { Set-ItResult -Skipped -Because 'no canonical apphost present in fixture (treated as N/A)' }
            ($script:r2.Exit -ne 0) | Should -BeTrue
        }
        It 'case2: 訊息提及 applicationhost' {
            if (-not $script:apphostPresent) { Set-ItResult -Skipped -Because 'no canonical apphost present in fixture (treated as N/A)' }
            $script:combined2 | Should -Match 'applicationhost'
        }
    }

    Context 'Case 3: missing csproj → fail-loudly' {
        BeforeAll {
            $sandboxGuid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
            $script:sandbox3 = [System.IO.Path]::Combine($script:SandboxBase, "turbo-plugin-test-startiis-$sandboxGuid")
            $null = New-Item -ItemType Directory -Path $script:sandbox3 -Force
            $tpDir = [System.IO.Path]::Combine($script:sandbox3, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $tpDir -Force
            # Need [iis] enabled = true so we get past the gate
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($tpDir, 'config.toml'),
                "[iis]`nenabled = true`n",
                (New-Object System.Text.UTF8Encoding($false)))
            Push-Location -LiteralPath $script:sandbox3
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m init
            } finally { Pop-Location }
            $script:r3 = Invoke-Script -WorkDir $script:sandbox3
            $script:combined3 = $script:r3.Stdout + "`n" + $script:r3.Stderr
        }
        AfterAll {
            try { [System.IO.Directory]::Delete($script:sandbox3, $true) } catch { }
        }

        It 'case3: no csproj exit ≠ 0' { ($script:r3.Exit -ne 0) | Should -BeTrue }
        It 'case3: 訊息提及 .csproj' { $script:combined3 | Should -Match '\.csproj' }
    }

    # Regression locks for the two defects that made /tp-run fail on every freshly set-up project:
    #   1. Start-Iis demanded the identity-hashed site name inside the SHARED canonical config -- a
    #      name Visual Studio never writes -- so the launch always failed, and the error told users
    #      to re-copy from VS, which could never produce that name. Canonical now carries the plain
    #      project name and the hash is applied to the per-launch temp copy only (the rename itself
    #      is covered behaviourally in ApplicationHostHelpers.test.ps1).
    #   2. IIS Express was started with -WindowStyle Hidden, which makes it exit immediately with
    #      code 0 before it ever binds the port.
    # These are source-level assertions deliberately: actually launching IIS Express depends on the
    # machine, but neither defect may silently return.
    Context 'Case 5: canonical site naming + launch window regression locks' {
        BeforeAll {
            $script:startIisText = [System.IO.File]::ReadAllText($script:ScriptUnderTest, [System.Text.Encoding]::UTF8)
            # Comment lines are stripped before asserting on what the script DOES: the comments
            # deliberately name the rejected approach ("NOT -WindowStyle Hidden, because ...") and
            # a naive whole-file match would flag the very note that documents the fix.
            $script:startIisCode = (($script:startIisText -split "`r?`n") |
                Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        }

        It 'case5: 不再以 -WindowStyle Hidden 啟動 IIS Express' {
            $script:startIisCode | Should -Not -Match '-WindowStyle\s+Hidden'
        }
        It 'case5: canonical 站台以專案名查找(CanonicalSiteName)' {
            $script:startIisCode | Should -Match 'CanonicalSiteName'
        }
        It 'case5: 啟動前把 temp 設定檔的站台改名為帶 hash 的執行期名稱' {
            $script:startIisCode | Should -Match 'Rename-ApplicationhostSite'
        }
        It 'case5: 站台缺漏的訊息不再指向「開 VS 後重跑 setup」這條死路' {
            # Naming Visual Studio as the ORIGIN of the site name is fine and useful; what must
            # never come back is instructing the user to open VS and re-run /tp-setup as the FIX,
            # because re-copying from VS could never produce the name the old code demanded.
            $script:startIisText | Should -Not -Match '請先用 Visual Studio 開'
        }
    }

    Context 'Case 6: canonical 缺專案站台時 fail loudly,且不指向 VS 死路' {
        BeforeAll {
            Set-IisEnabled -Enabled $true
            $script:apphostBackup6 = [System.IO.File]::ReadAllText($script:apphostPath, [System.Text.Encoding]::UTF8)
            # Rename the canonical site to something neither the plain nor the hashed name matches.
            $broken6 = $script:apphostBackup6.Replace('name="HelloApp"', 'name="SomethingElse"')
            [System.IO.File]::WriteAllText($script:apphostPath, $broken6, (New-Object System.Text.UTF8Encoding($false)))
            $script:r6 = Invoke-Script -WorkDir $script:testRoot -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:combined6 = "$($script:r6.Stdout)`n$($script:r6.Stderr)"
            [System.IO.File]::WriteAllText($script:apphostPath, $script:apphostBackup6, (New-Object System.Text.UTF8Encoding($false)))
        }

        It 'case6: exit ≠ 0' { ($script:r6.Exit -ne 0) | Should -BeTrue }
        It 'case6: 訊息點名缺的是以專案名命名的站台' { $script:combined6 | Should -Match 'HelloApp' }
        It 'case6: 訊息不再指向「開 VS 後重跑 setup」這條死路' {
            $script:combined6 | Should -Not -Match '請先用 Visual Studio 開'
        }
    }
}
