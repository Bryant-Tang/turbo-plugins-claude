# Remove-OrphanIis.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework-web/scripts/Remove-OrphanIis.ps1
# Behavior: 找與 current site name 不同 hash 的 stale iisexpress 進程 + 沒人在用的 temp apphost 檔。
#   無 orphan → exit 0 + echo「No orphan...」。
#
# 注意:此 script **沒有** 自己的 [iis] enabled gate(只 SKILL.md 有;見 commit 84e944a)。
#   因此本 case 文檔記為 deviation:我們改 assert script behavior when called directly with
#   [iis]=false → 因為 script 本身沒 gate,行為與 [iis]=true 一致(exit 0 + No orphan)。
#   這是「SKILL is the gatekeeper」設計;在 Phase 2 SKILL 測試會 cover SKILL-level gate。
#
# Cases:
#   1. No orphan: fresh fixture (no orphan process) → exit 0,stdout 含「No orphan IIS Express」
#   2. SKILL entry re-invoke: 一致 (no-orphan)
#   3. [iis] enabled = false (script does NOT have script-level gate — by design):
#      script 仍 exit 0 + No orphan;此 case 文件 deviation,SKILL-level gate test 在 Phase 2 cover
#   R5. regex-metacharacter 誤殺防護: Test-OrphanSiteNameMatch escape 生效

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Remove-OrphanIis.ps1')

    # Dot-source the production IIS helpers so we call the *real* Test-OrphanSiteNameMatch
    # (which builds the same $stemPattern Remove-OrphanIis.ps1 uses). This guarantees that if
    # anyone removes [regex]::Escape from production, the metacharacter cases below go red.
    . ([System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1'))

    $script:testRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'test-turbo-plugin')
    $script:cfgPath = [System.IO.Path]::Combine($script:testRoot, '.turbo-plugin', 'config.toml')
    $script:SandboxBase = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

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
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m init
            } finally { Pop-Location }
        }
        return $true
    }

    function Set-IisEnabled {
        param([bool]$Enabled)
        if (-not [System.IO.File]::Exists($script:cfgPath)) { throw "cfg not found: $($script:cfgPath)" }
        $text = [System.IO.File]::ReadAllText($script:cfgPath, [System.Text.Encoding]::UTF8)
        $valueLine = if ($Enabled) { 'enabled = true' } else { 'enabled = false' }
        $patched = [regex]::Replace($text, '(?m)^enabled\s*=\s*(true|false)\s*$', $valueLine)
        [System.IO.File]::WriteAllText($script:cfgPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Is some OTHER iisexpress already running a site the fixture's scoped orphan detection would
    # claim? The fixture's csproj stem is HelloApp, and the scoped matcher accepts
    # ^HelloApp-<8hex>$ with a hash different from the fixture's -- so a developer's own HelloApp
    # instance IS a match, and the script would correctly report it as an orphan. That is a real
    # machine-state collision no sandbox can remove (WMI is machine-wide), so the affected cases
    # SKIP loudly instead of failing on someone else's running server.
    function Test-ForeignHelloAppIisRunning {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'iisexpress.exe'" -ErrorAction SilentlyContinue)
        } catch {
            $procs = @()
        } finally {
            $ErrorActionPreference = $prev
        }
        foreach ($p in $procs) {
            if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
            if ($p.CommandLine -match '/site:(HelloApp-[0-9a-f]{8})') { return $true }
        }
        return $false
    }

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
        # Give the script under test its OWN empty %TEMP%. It scans GetTempPath() for stale
        # turbo-plugin-iis-<hash>.{config,out.log,err.log} sets, so with the real temp dir the
        # assertions below depend on whatever any earlier IIS Express run happened to leave on this
        # machine -- a leftover from a developer's own /tp-run turned these cases red once already.
        # GetTempPath() reads TMP then TEMP, so both must be set; Start-Process inherits this
        # process's environment block, so setting them here is what reaches the child.
        $isoTemp = [System.IO.Path]::Combine($script:SandboxBase, "iis-temp-$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
        $null = New-Item -ItemType Directory -Path $isoTemp -Force
        $prevTemp = $env:TEMP
        $prevTmp = $env:TMP
        try {
            # Quote -File (and any spaced ExtraArg) so a spaced repo/parent path (AE8) survives
            # Start-Process's naive space-join of -ArgumentList.
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) + @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $env:TEMP = $isoTemp
            $env:TMP = $isoTemp
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList $argList -WorkingDirectory $WorkDir `
                -RedirectStandardOutput $tmpStdout -RedirectStandardError $tmpStderr `
                -NoNewWindow -PassThru -Wait
            $env:TEMP = $prevTemp
            $env:TMP = $prevTmp
            $stdout = if (Test-Path -LiteralPath $tmpStdout -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStdout, [System.Text.Encoding]::UTF8) } else { '' }
            $stderr = if (Test-Path -LiteralPath $tmpStderr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStderr, [System.Text.Encoding]::UTF8) } else { '' }
            return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode }
        } finally {
            $env:TEMP = $prevTemp
            $env:TMP = $prevTmp
            foreach ($t in @($tmpStdout, $tmpStderr)) {
                if (Test-Path -LiteralPath $t -PathType Leaf) {
                    try { [System.IO.File]::Delete($t) } catch { }
                }
            }
            try { [System.IO.Directory]::Delete($isoTemp, $true) } catch { }
        }
    }

    # Called at the top of each machine-state-dependent It. Makes the skip visible in the log so
    # this regression guard cannot silently vanish on a machine that happens to be running a
    # HelloApp instance.
    function Skip-IfForeignIis {
        if ($script:ForeignIis) {
            Write-Warning 'Remove-OrphanIis no-orphan cases skipped: an iisexpress running a HelloApp-<hash> site is already on this machine, so "no orphan" cannot hold. Stop it (or run /tp-cleanup-orphan-iis) to exercise these.'
            Set-ItResult -Skipped -Because 'a foreign HelloApp IIS Express instance is running'
        }
    }

    $script:FixtureReady = Ensure-FixtureGit
}

Describe 'Remove-OrphanIis' {

    Context 'No-orphan behavior + SKILL re-invoke + [iis]=false deviation' {
        BeforeAll {
            # The %TEMP% half of "no orphan" is isolated inside Invoke-Script. The PROCESS half
            # cannot be: the script scans machine-wide WMI, and the fixture's csproj stem
            # (HelloApp) is a plausible real project name, so a developer's own running
            # HelloApp-<hash> would legitimately be reported. Detect that and SKIP loudly.
            $script:ForeignIis = Test-ForeignHelloAppIisRunning
            if ($script:FixtureReady -and -not $script:ForeignIis) {
                $script:r1 = Invoke-Script -WorkDir $script:testRoot
                $script:r2 = Invoke-Script -WorkDir $script:testRoot
                # Case 3: [iis] enabled = false — script has NO script-level gate.
                # Documented deviation: SKILL.md guards [iis]=false; script proceeds normally.
                Set-IisEnabled -Enabled $false
                try {
                    $script:r3 = Invoke-Script -WorkDir $script:testRoot
                } finally {
                    Set-IisEnabled -Enabled $true
                }
            }
        }

        It 'setup: fixture present' { $script:FixtureReady | Should -BeTrue }

        It 'case1: no-orphan exit 0' { Skip-IfForeignIis; $script:r1.Exit | Should -Be 0 }
        It 'case1: stdout 含 No orphan IIS Express' { Skip-IfForeignIis; $script:r1.Stdout | Should -Match 'No orphan IIS Express' }

        It 'case2: SKILL-entry no-orphan exit 0' { Skip-IfForeignIis; $script:r2.Exit | Should -Be 0 }
        It 'case2: 訊息一致' { Skip-IfForeignIis; $script:r2.Stdout | Should -Match 'No orphan IIS Express' }

        # By design: script-level still runs (SKILL is the gatekeeper). exit 0 + No orphan.
        It 'case3 (deviation): script-level no [iis] gate — still exits 0' { Skip-IfForeignIis; $script:r3.Exit | Should -Be 0 }
        It 'case3: 訊息仍是 No orphan' { Skip-IfForeignIis; $script:r3.Stdout | Should -Match 'No orphan IIS Express' }
    }

    # ─── R5: regex-metacharacter 誤殺防護 (canonical 斷言) ───────────────────────
    # Remove-OrphanIis 比對 running iisexpress.exe 的 /site:<name> 命令列,
    # 用 "^<csprojStem>-<8hex>$" pattern。stem 須被當 literal (regex-escape),否則含
    # metachar 的 stem (如 My.Test) 會誤 match 別的站台 (如 MyXTest-deadbeef) → 把不該
    # 清的站台當 orphan 殺掉。以下證明 escape 生效。
    Context 'R5: regex-metacharacter escape 防誤殺' {
        # near-miss: stem 當 literal 不該 match (escape 生效);若 escape 被拿掉則會誤 match。
        # 對照組: <stem>-<8hex> self-site 一定要 match,證明不是「全部都不 match」才過。
        $metacharCases = @(
            @{ Char = '.';  Stem = 'My.Test';  NearMiss = 'MyXTest-deadbeef' }
            @{ Char = '+';  Stem = 'Sva+b';    NearMiss = 'Svaab-deadbeef' }
            @{ Char = '[';  Stem = 'App[0-9]'; NearMiss = 'App5-deadbeef' }
            @{ Char = ']';  Stem = 'A[BC]D';   NearMiss = 'ABD-deadbeef' }
            @{ Char = '(';  Stem = '(App)';    NearMiss = 'App-deadbeef' }
            @{ Char = ')';  Stem = '(Foo)Bar'; NearMiss = 'FooBar-deadbeef' }
            @{ Char = '{';  Stem = 'Ap{1,2}';  NearMiss = 'App-deadbeef' }
            @{ Char = '}';  Stem = 'a{2}b';    NearMiss = 'aab-deadbeef' }
            @{ Char = '^';  Stem = '^App';     NearMiss = 'XApp-deadbeef' }
            @{ Char = '$';  Stem = 'App$X';    NearMiss = 'App-deadbeefX' }
        )

        It "metachar '<Char>': near-miss '<NearMiss>' NOT matched (literal stem '<Stem>')" -TestCases $metacharCases {
            param($Char, $Stem, $NearMiss)
            (Test-OrphanSiteNameMatch -CsprojStem $Stem -SiteName $NearMiss) | Should -BeFalse
        }

        It "metachar '<Char>': self-site '<Stem>-deadbeef' DOES match" -TestCases $metacharCases {
            param($Char, $Stem, $NearMiss)
            $selfSite = "$Stem-deadbeef"
            (Test-OrphanSiteNameMatch -CsprojStem $Stem -SiteName $selfSite) | Should -BeTrue
        }

        It 'control: real orphan HelloApp-0badf00d matches stem HelloApp' {
            (Test-OrphanSiteNameMatch -CsprojStem 'HelloApp' -SiteName 'HelloApp-0badf00d') | Should -BeTrue
        }
        It 'control: unrelated OtherApp-0badf00d does NOT match stem HelloApp' {
            (Test-OrphanSiteNameMatch -CsprojStem 'HelloApp' -SiteName 'OtherApp-0badf00d') | Should -BeFalse
        }
        It 'control: non-hex hash does NOT match' {
            (Test-OrphanSiteNameMatch -CsprojStem 'HelloApp' -SiteName 'HelloApp-zzzzzzzz') | Should -BeFalse
        }
    }

    # ─── KTD8: no-project path uses the GENERIC turbo-plugin family pattern ──────
    # When no current project is resolvable, cleanup can't pin a single stem; it matches the
    # generic "<stem>-<8 hex>" family via Test-TurboPluginSiteName. The 8-hex suffix keeps
    # non-turbo-plugin IIS Express sites out of the match.
    Context 'KTD8: Test-TurboPluginSiteName generic family match' {
        $genericCases = @(
            @{ Site = 'HelloApp-deadbeef'; Expect = $true }
            @{ Site = 'My.App-cafe1234';   Expect = $true }
            @{ Site = 'Anything-0badf00d'; Expect = $true }
            @{ Site = 'nohash';            Expect = $false }
            @{ Site = 'HelloApp-zzzzzzzz'; Expect = $false }
            @{ Site = 'Foo-deadbee';       Expect = $false }
            @{ Site = 'Foo-deadbeef0';     Expect = $false }
        )

        It "generic site '<Site>' match = <Expect>" -TestCases $genericCases {
            param($Site, $Expect)
            (Test-TurboPluginSiteName -SiteName $Site) | Should -Be $Expect
        }
    }

    # ─── KTD8: no-project -RemoveAll is refused (live-site protection) ───────────
    # After auto-detect removal, a no-project invocation can't identify the live site to
    # exclude, so blanket -RemoveAll would risk killing it. The script refuses and points the
    # user to -Project (scoped) or -RemoveSite (specific). With -Project the behavior is unchanged.
    Context 'KTD8: no-project -RemoveAll refused' {
        BeforeAll {
            $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
            $script:noProjSandbox = [System.IO.Path]::Combine($script:SandboxBase, "turbo-plugin-test-roi-noproj-$guid")
            $null = New-Item -ItemType Directory -Path $script:noProjSandbox -Force
            Push-Location -LiteralPath $script:noProjSandbox
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                [System.IO.File]::WriteAllText((Join-Path $script:noProjSandbox 'README.txt'), 'no project', (New-Object System.Text.UTF8Encoding($false)))
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m init
            } finally { Pop-Location }
            $script:roiNoProj = Invoke-Script -WorkDir $script:noProjSandbox -ExtraArgs @('-RemoveAll')
            $script:roiNoProjCombined = $script:roiNoProj.Stdout + "`n" + $script:roiNoProj.Stderr
        }
        AfterAll {
            try { [System.IO.Directory]::Delete($script:noProjSandbox, $true) } catch { }
        }

        It 'no-project -RemoveAll exits != 0' { ($script:roiNoProj.Exit -ne 0) | Should -BeTrue }
        It 'no-project -RemoveAll refuses blanket removal' {
            $script:roiNoProjCombined | Should -Match 'Refusing -RemoveAll without a project'
        }
    }
}
