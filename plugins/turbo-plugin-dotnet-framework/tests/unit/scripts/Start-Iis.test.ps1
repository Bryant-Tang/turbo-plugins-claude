# Start-Iis.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework/scripts/Start-Iis.ps1
# Behavior:
#   - Defensive layer:.turbo-plugin/config.toml [iis] enabled = false → throw with bilingual msg
#   - Else:resolve IIS settings → render temp apphost.config (placeholder substitution) → launch
#     iisexpress.exe → wait for port LISTENING。
#
# Cases:
#   1. [iis] enabled = false canonical (CRITICAL — canonical disabled fixture case):
#      改 fixture 的 config.toml 為 enabled = false → 跑 script → exit ≠ 0,stderr 含「IIS 已停用」;
#      最後還原 config.toml 為 enabled = true。
#   2. 沒有 applicationhost.config → 第一次執行就自己產生(lazy bootstrap),不要求先跑別的指令
#   3. Missing csproj: workspace 無 csproj → throws .csproj 訊息
#   4. SKILL entry path (disabled fixture):用同樣的 [iis] enabled=false fixture 再呼叫一次 →
#      行為一致
#   5. 站台命名 / 啟動視窗的 regression lock(原始碼層)
#   6. 設定檔已存在但缺這個專案的站台 → 補上該站台,不動同檔內別的站台
#
# 不跑「真正啟動 IIS Express + port LISTENING」happy case:會 spawn 真實 process 污染 OS state。
#   Cases 2 / 6 需要走到產生設定檔之後,所以把 iis_express_path 指向一個「不是真正可執行檔」的檔案:
#   設定那一段完整跑完,最後在啟動那一步失敗 — 測試套件從頭到尾不會啟動任何 IIS Express。

BeforeAll {
    $script:pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'Start-Iis.ps1')
    $script:SandboxBase = [System.IO.Path]::Combine($script:pluginRoot, 'tests', '.sandbox', 'sandboxes')
    # Get-ProjectIdentityHash: lets the lazy-bootstrap sandboxes delete the exact per-launch temp
    # files their (deliberately failed) launch left in %TEMP%, instead of globbing for them.
    # Find-IisExpressPath: locates the applicationhost.config template those sandboxes need.
    . ([System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'lib', 'Common.ps1'))
    . ([System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1'))

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

    # Where IIS Express keeps the applicationhost.config template we generate from. Empty when IIS
    # Express is not installed, which makes the lazy-bootstrap contexts skip instead of fail.
    $script:IisTemplate = ''
    try {
        $probe = Find-IisExpressPath -RepoRoot ''
        $cand = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($probe), 'AppServer', 'applicationhost.config')
        if (Test-Path -LiteralPath $cand -PathType Leaf) { $script:IisTemplate = $cand }
    } catch {
        $script:IisTemplate = ''
    }

    # A throwaway repo for the lazy-bootstrap cases: one csproj, [iis] enabled, and an
    # iis_express_path pointing at a file that is NOT a real Win32 image -- but with a REAL
    # applicationhost.config template beside it under AppServer/, exactly where the production code
    # looks. So the whole configuration path (including generating from the genuine template) runs
    # for real, and only the launch step fails -- which is what makes this assertable without the
    # test suite ever spawning an IIS Express process.
    function New-LazySandbox {
        param([string]$Tag, [string]$Port = '51789')
        $enc = New-Object System.Text.UTF8Encoding($false)
        $root = [System.IO.Path]::Combine($script:SandboxBase, "turbo-plugin-test-lazy-$Tag-$([Guid]::NewGuid().ToString('N').Substring(0,8))")
        $null = New-Item -ItemType Directory -Path $root -Force
        $tp = [System.IO.Path]::Combine($root, '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tp -Force
        $appServer = [System.IO.Path]::Combine($root, 'AppServer')
        $null = New-Item -ItemType Directory -Path $appServer -Force
        Copy-Item -LiteralPath $script:IisTemplate -Destination ([System.IO.Path]::Combine($appServer, 'applicationhost.config')) -Force

        $csproj = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>HelloApp</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
    <IISUrl>http://localhost:$Port/</IISUrl>
  </PropertyGroup>
</Project>
"@
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'HelloApp.csproj'), $csproj, $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($tp, 'config.toml'), "[iis]`nenabled = true`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'not-really-iisexpress.exe'), 'not an executable', $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($tp, 'config.local.toml'),
            "[tools]`niis_express_path = `"not-really-iisexpress.exe`"`n", $enc)

        Push-Location -LiteralPath $root
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'lazy fixture'
        } finally { Pop-Location }
        return $root
    }

    function Remove-LazySandbox {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        # The launch attempt renders a per-launch temp config before it fails. Delete exactly that
        # file -- computed from the sandbox's own identity hash, never globbed -- so the suite
        # leaves nothing in %TEMP% and cannot touch a real project's temp config.
        try {
            $hash = Get-ProjectIdentityHash -RepoPath $Dir -CsprojRelPath 'HelloApp.csproj'
            foreach ($ext in @('config', 'out.log', 'err.log')) {
                $temp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-plugin-iis-$hash.$ext")
                if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
            }
        } catch { }
        try { if ([System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::Delete($Dir, $true) } } catch { }
    }

    function Get-SiteNode {
        param([string]$ConfigPath, [string]$SiteName)
        if (-not [System.IO.File]::Exists($ConfigPath)) { return $null }
        $x = New-Object System.Xml.XmlDocument
        $x.Load($ConfigPath)
        foreach ($n in @($x.SelectNodes('/configuration/system.applicationHost/sites/site'))) {
            if ($n.GetAttribute('name') -ieq $SiteName) { return $n }
        }
        return $null
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

    # Lazy bootstrap. A project nobody ever "set up" must just run: everything the <site> needs is
    # already in the csproj, and Visual Studio behaves the same way (its config appears on the first
    # run, not at install time). Demanding a separate setup command here was a dead end -- the old
    # error told users to copy a file out of Visual Studio, which is what this plugin exists to
    # avoid.
    Context 'Case 2: 沒有 applicationhost.config → 第一次執行就自己產生' {
        BeforeAll {
            if ([string]::IsNullOrWhiteSpace($script:IisTemplate)) { return }
            $script:lazy2 = New-LazySandbox -Tag 'gen'
            $script:apphost2 = [System.IO.Path]::Combine($script:lazy2, '.turbo-plugin', 'applicationhost.config')
            $script:r2 = Invoke-Script -WorkDir $script:lazy2 -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:combined2 = $script:r2.Stdout + "`n" + $script:r2.Stderr
            $script:site2 = Get-SiteNode -ConfigPath $script:apphost2 -SiteName 'HelloApp'
        }
        AfterAll { if (-not [string]::IsNullOrWhiteSpace($script:IisTemplate)) { Remove-LazySandbox -Dir $script:lazy2 } }

        BeforeEach {
            if ([string]::IsNullOrWhiteSpace($script:IisTemplate)) {
                Set-ItResult -Skipped -Because '這台機器沒有安裝 IIS Express,拿不到它自帶的設定檔範本'
            }
        }

        It 'case2: 設定檔被產生出來' {
            [System.IO.File]::Exists($script:apphost2) | Should -BeTrue -Because $script:combined2
        }
        It 'case2: 站台以專案名命名(canonical 形狀,可進版控)' {
            $script:site2 | Should -Not -BeNullOrEmpty
            $script:site2.SelectSingleNode('application/virtualDirectory').GetAttribute('physicalPath') |
                Should -Be '__TURBO_PLUGIN_PHYSICAL_PATH__'
        }
        # No angle brackets in the name: Pester treats <...> as a data-driven placeholder and tries
        # to expand it as a variable, which under StrictMode throws instead of rendering empty.
        It 'case2: binding 取自 csproj 的 IISUrl 元素' {
            $script:site2.SelectSingleNode('bindings/binding').GetAttribute('bindingInformation') |
                Should -Be '*:51789:localhost'
        }
        It 'case2: 有告知使用者設定檔是這次產生的' {
            $script:r2.Stdout | Should -Match 'applicationhost\.config'
        }
        It 'case2: 不再叫使用者先去跑別的設定指令' {
            $script:combined2 | Should -Not -Match 'tp-setup'
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
    #   3. IIS Express was started with Start-Process -NoNewWindow, which hands the server every
    #      inheritable handle this process holds -- including the agent harness's output pipe, so
    #      the tool call never ended and the session UI hung (issue #82).
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

        # Measured on Windows 11 + IIS Express 10 against a VALID config: -WindowStyle (either
        # Hidden or Minimized) forces UseShellExecute=$true, and IIS Express then exits with code 0
        # before binding the port -- it wants stdin it can read.
        It 'case5: 不用 -WindowStyle 啟動(那會讓 IIS Express 立刻 exit 0)' {
            $script:startIisCode | Should -Not -Match '-WindowStyle'
        }

        # issue #82. -NoNewWindow was the previous answer and it is now a REGRESSION, not a fix:
        # UseShellExecute=$false makes CreateProcess pass bInheritHandles=TRUE, so the long-lived
        # iisexpress.exe also receives the write end of the pipe the agent harness handed this
        # powershell.exe. The launcher exits, the server keeps that end open, the reader never sees
        # EOF, and the harness's tool call never returns.
        #
        # Measured directly, launcher started with a real stdout pipe and then allowed to exit:
        #   Start-Process -NoNewWindow -> launcher exited, pipe NEVER reached EOF
        #   Win32_Process.Create       -> launcher exited, pipe reached EOF immediately
        # Source-level assertions on purpose, like the rest of this Context: actually launching IIS
        # Express depends on the machine, but neither defect may silently come back.
        It 'case5: 不用 Start-Process 啟動(子行程會繼承呼叫端的 pipe,工具呼叫就永遠不結束)' {
            $script:startIisCode | Should -Not -Match '-NoNewWindow'
            $script:startIisCode | Should -Not -Match 'Start-Process'
        }
        It 'case5: 用 Win32_Process.Create 啟動,而且帶 CREATE_NEW_CONSOLE' {
            # WMI 服務建立行程,所以什麼都不會從這裡繼承過去。
            $script:startIisCode | Should -Match 'Win32_Process'
            # 沒有自己的 console,IIS Express 找不到可用的 stdin,會直接 exit 0 不綁 port。
            $script:startIisCode | Should -Match 'CreateFlags'
            $script:startIisCode | Should -Match 'ShowWindow'
        }
        It 'case5: 仍然保留 stdout / stderr 重導向(啟動失敗的原因只留在那裡)' {
            # Win32_Process.Create 本身不支援重導向,所以命令列走 cmd 包一層;拿掉這層等於
            # 讓「設定檔被 IIS Express 拒收」這個最常見的失敗變成只有一句 timeout。
            $script:startIisCode | Should -Match '/s /c'
            $script:startIisCode | Should -Match ([regex]::Escape('2>"{4}"'))
        }
        It 'case5: 回報的是 iisexpress 的 PID,不是外層 shell 的' {
            # Win32_Process.Create 回傳的是 cmd.exe 的 PID;stop / orphan / 提前結束偵測要的都是
            # 底下那個 iisexpress.exe。
            $script:startIisCode | Should -Match 'Wait-IisExpressProcess'
        }
        It 'case5: 啟動參數自己加引號(%TEMP% 路徑常含空白)' {
            # 引號是字面寫在命令列格式字串裡的:'"{0}" "/config:{1}" "/site:{2}" ...'。
            # (PowerShell 的跳脫字元是反引號不是反斜線,所以這裡用 [regex]::Escape 避開引號地獄。)
            $script:startIisCode | Should -Match ([regex]::Escape('"/config:{1}"'))
            $script:startIisCode | Should -Match ([regex]::Escape('"/site:{2}"'))
        }
        It 'case5: 啟動失敗時把 IIS Express 自己的訊息讀回來' {
            # 舊訊息指向一個正常安裝根本不存在的 TraceLogFiles 目錄,等於什麼都沒說。
            # 比對去掉註解的版本:註解裡刻意寫著被淘汰的做法,整檔比對會打到那段說明本身。
            $script:startIisCode | Should -Match 'Get-IisLaunchLogTail'
            $script:startIisCode | Should -Not -Match 'TraceLogFiles'
        }
        It 'case5: canonical 站台以專案名查找(CanonicalSiteName)' {
            $script:startIisCode | Should -Match 'CanonicalSiteName'
        }
        It 'case5: 啟動前把 temp 設定檔的站台改名為帶 hash 的執行期名稱' {
            $script:startIisCode | Should -Match 'Rename-ApplicationhostSite'
        }
        It 'case5: 站台缺漏的訊息不再指向「開 VS 後重跑 setup」這條死路' {
            # Naming Visual Studio as the ORIGIN of the site name is fine and useful; what must
            # never come back is instructing the user to open VS and re-run a setup command as the
            # FIX, because re-copying from VS could never produce the name the old code demanded.
            $script:startIisText | Should -Not -Match '請先用 Visual Studio 開'
        }
        It 'case5: 執行路徑上不再把使用者推去跑另一個設定指令' {
            $script:startIisCode | Should -Not -Match 'tp-setup'
        }
    }

    # A repo can hold more than one web project, and a config generated for the first one knows
    # nothing about the second. Appending is the only correct move: rebuilding the file from the
    # template would silently drop the sibling projects' sites.
    Context 'Case 6: 設定檔已存在但缺這個專案的站台 → 補上,不動同檔內別的站台' {
        BeforeAll {
            if ([string]::IsNullOrWhiteSpace($script:IisTemplate)) { return }
            $script:lazy6 = New-LazySandbox -Tag 'append'
            $script:apphost6 = [System.IO.Path]::Combine($script:lazy6, '.turbo-plugin', 'applicationhost.config')
            $seed = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.applicationHost>
    <sites>
      <site name="SomebodyElse" id="1">
        <application path="/" applicationPool="Clr4IntegratedAppPool">
          <virtualDirectory path="/" physicalPath="__TURBO_PLUGIN_PHYSICAL_PATH__" />
        </application>
        <bindings>
          <binding protocol="http" bindingInformation="*:5999:localhost" />
        </bindings>
      </site>
    </sites>
  </system.applicationHost>
</configuration>
'@
            [System.IO.File]::WriteAllText($script:apphost6, $seed, (New-Object System.Text.UTF8Encoding($false)))
            $script:r6 = Invoke-Script -WorkDir $script:lazy6 -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:combined6 = "$($script:r6.Stdout)`n$($script:r6.Stderr)"
        }
        AfterAll { if (-not [string]::IsNullOrWhiteSpace($script:IisTemplate)) { Remove-LazySandbox -Dir $script:lazy6 } }

        BeforeEach {
            if ([string]::IsNullOrWhiteSpace($script:IisTemplate)) {
                Set-ItResult -Skipped -Because '這台機器沒有安裝 IIS Express,拿不到它自帶的設定檔範本'
            }
        }

        It 'case6: 補上以專案名命名的站台' {
            (Get-SiteNode -ConfigPath $script:apphost6 -SiteName 'HelloApp') |
                Should -Not -BeNullOrEmpty -Because $script:combined6
        }
        It 'case6: 原本就在檔案裡的別的站台原封不動' {
            $other = Get-SiteNode -ConfigPath $script:apphost6 -SiteName 'SomebodyElse'
            $other | Should -Not -BeNullOrEmpty
            $other.SelectSingleNode('bindings/binding').GetAttribute('bindingInformation') | Should -Be '*:5999:localhost'
        }
        It 'case6: 兩個站台的 id 不重複(重複會讓 IIS Express 整份設定拒收)' {
            $a = (Get-SiteNode -ConfigPath $script:apphost6 -SiteName 'HelloApp').GetAttribute('id')
            $b = (Get-SiteNode -ConfigPath $script:apphost6 -SiteName 'SomebodyElse').GetAttribute('id')
            $a | Should -Not -Be $b
        }
        It 'case6: 訊息不再指向「開 VS 後重跑 setup」這條死路' {
            $script:combined6 | Should -Not -Match '請先用 Visual Studio 開'
        }
    }
}
