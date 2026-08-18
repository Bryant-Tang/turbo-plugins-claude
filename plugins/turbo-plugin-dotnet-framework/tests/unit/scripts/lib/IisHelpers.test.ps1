# IisHelpers.test.ps1 (Pester 5)
#
# Library: plugins/turbo-plugin-dotnet-framework/scripts/lib/IisHelpers.ps1
# Behavior: 此 file 主要是 library (dot-source) — 它本身不直接被執行。本測試在 child
#   powershell 中 dot-source 它並直接 call Resolve-IisSettings，verify 該 function 行為。
#
# Cases:
#   1. Happy: fixture (HelloApp.csproj + .turbo-plugin/applicationhost.config) → 回傳 hashtable
#      properties: IisUrl=http://localhost:5000/, IisPort=5000, IisExpressPath 存在,
#      ApplicationhostConfigFile 路徑正確, IisConfigSiteName, IdentityHash。
#   2. Missing .turbo-plugin/applicationhost.config: 仍會回傳 (apphost target 是 canonical 路徑,
#      即使檔不存在);ApplicationhostConfigFile 必須是 fixture-root/.turbo-plugin/applicationhost.config。
#   3. 中文 path:workspace 路徑含中文 → 仍正確解析 IisUrl。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1')
    $script:CommonPs1 = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Common.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    # ── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ──
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
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "turbo-plugin-test-$Purpose-$guid")
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

    $script:baseCsproj = @'
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

    function New-Fixture {
        param([string]$Dir, [switch]$WithApphost)
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($Dir, 'HelloApp.csproj'),
            $script:baseCsproj,
            (New-Object System.Text.UTF8Encoding($false)))
        $tpDir = [System.IO.Path]::Combine($Dir, '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tpDir -Force
        if ($WithApphost) {
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($tpDir, 'applicationhost.config'),
                '<configuration><system.applicationHost><sites><site name="HelloApp-deadbeef" id="1"><bindings><binding protocol="http" bindingInformation="*:5000:localhost" /></bindings></site></sites></system.applicationHost></configuration>',
                (New-Object System.Text.UTF8Encoding($false)))
        }
        Push-Location -LiteralPath $Dir
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'init'
        } finally { Pop-Location }
    }

    # Helper: run IisHelpers via PowerShell child process, returning a structured snapshot.
    # Why a child process and not dot-source: the script is library-only; we dot-source it inline
    # AND call Resolve-IisSettings inline, with cwd = the fixture workspace.
    function Invoke-ResolveAsChild {
        # ProjectArg: explicit target passed to Resolve-IisSettings (no auto-detect anymore).
        # Default 'HelloApp.csproj' matches the single-csproj fixtures; pass '' to exercise the
        # no-target error path, or a .sln name to exercise the .sln-rejection path.
        param([string]$WorkDir, [string]$ProjectArg = 'HelloApp.csproj')
        $oldLoc = Get-Location
        try {
            Set-Location -LiteralPath $WorkDir
            $resolveCall = if ([string]::IsNullOrWhiteSpace($ProjectArg)) {
                'Resolve-IisSettings'
            } else {
                "Resolve-IisSettings -Project '$ProjectArg'"
            }
            $cmd = @"
. '$($script:CommonPs1)'
. '$($script:ScriptUnderTest)'
try {
    `$s = $resolveCall
    Write-Output "IisUrl=`$(`$s.IisUrl)"
    Write-Output "IisPort=`$(`$s.IisPort)"
    Write-Output "IisExpressPath=`$(`$s.IisExpressPath)"
    Write-Output "ApplicationhostConfigFile=`$(`$s.ApplicationhostConfigFile)"
    Write-Output "IisConfigSiteName=`$(`$s.IisConfigSiteName)"
    Write-Output "IdentityHash=`$(`$s.IdentityHash)"
} catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@
            $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>$null
                $exit = $LASTEXITCODE
            } catch {
                $stdout = @($_.Exception.Message); $exit = 99
            } finally {
                $ErrorActionPreference = $savedEap
            }
            return @{ Stdout = ($stdout -join "`n"); Exit = $exit }
        } finally { Set-Location -LiteralPath $oldLoc }
    }
}

Describe 'IisHelpers Resolve-IisSettings' {

    Context 'Case 1: happy' {
        BeforeAll {
            $script:sb1 = New-Sandbox 'ris-happy'
            New-Fixture -Dir $script:sb1 -WithApphost
            $script:r1 = Invoke-ResolveAsChild -WorkDir $script:sb1
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'happy exits 0' { $script:r1.Exit | Should -Be 0 }
        It 'IisUrl is http://localhost:5000/' { $script:r1.Stdout | Should -Match 'IisUrl=http://localhost:5000/' }
        It 'IisPort is 5000' { $script:r1.Stdout | Should -Match 'IisPort=5000' }
        It 'IisExpressPath nonempty (iisexpress.exe)' { $script:r1.Stdout | Should -Match 'IisExpressPath=.+iisexpress\.exe' }
        It 'ApplicationhostConfigFile 路徑 ok' { $script:r1.Stdout | Should -Match '\.turbo-plugin[/\\]applicationhost\.config' }
        It 'IisConfigSiteName format' { $script:r1.Stdout | Should -Match 'IisConfigSiteName=HelloApp-[0-9a-f]{8}' }
        It 'IdentityHash 8-hex' { $script:r1.Stdout | Should -Match 'IdentityHash=[0-9a-f]{8}' }
    }

    Context 'Case 2: missing apphost still resolves' {
        BeforeAll {
            $script:sb2 = New-Sandbox 'ris-noapphost'
            New-Fixture -Dir $script:sb2  # no -WithApphost
            $script:r2 = Invoke-ResolveAsChild -WorkDir $script:sb2
        }
        AfterAll { Remove-Sandbox $script:sb2 }

        # Resolve-IisSettings 本身不檢查 apphost 是否存在(那是 start-iis 才檢);應仍能 return
        It 'missing apphost still exits 0' { $script:r2.Exit | Should -Be 0 }
        It 'ApplicationhostConfigFile 仍指向 canonical 路徑' { $script:r2.Stdout | Should -Match '\.turbo-plugin[/\\]applicationhost\.config' }
    }

    Context 'Case 3: chinese path' {
        BeforeAll {
            $script:sb3 = New-Sandbox 'ris-zh'
            $zhSub = [System.IO.Path]::Combine($script:sb3, '路徑', '含中文')
            $null = New-Item -ItemType Directory -Path $zhSub -Force
            New-Fixture -Dir $zhSub -WithApphost
            $script:r3 = Invoke-ResolveAsChild -WorkDir $zhSub
        }
        AfterAll { Remove-Sandbox $script:sb3 }

        It '中文 path exits 0' { $script:r3.Exit | Should -Be 0 }
        It '中文 path IisUrl 解析正確' { $script:r3.Stdout | Should -Match 'IisUrl=http://localhost:5000/' }
    }

    Context 'Case 4: .sln target is rejected (run/stop need a csproj)' {
        BeforeAll {
            $script:sb4 = New-Sandbox 'ris-sln'
            New-Fixture -Dir $script:sb4 -WithApphost
            # Add a .sln next to the csproj; passing it as the target must be rejected.
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($script:sb4, 'HelloApp.sln'),
                '', (New-Object System.Text.UTF8Encoding($false)))
            $script:r4 = Invoke-ResolveAsChild -WorkDir $script:sb4 -ProjectArg 'HelloApp.sln'
        }
        AfterAll { Remove-Sandbox $script:sb4 }

        It '.sln target exits != 0' { ($script:r4.Exit -ne 0) | Should -BeTrue }
    }

    Context 'Case 5: no target resolvable (no -Project, no config) errors' {
        BeforeAll {
            $script:sb5 = New-Sandbox 'ris-notarget'
            New-Fixture -Dir $script:sb5 -WithApphost
            $script:r5 = Invoke-ResolveAsChild -WorkDir $script:sb5 -ProjectArg ''
        }
        AfterAll { Remove-Sandbox $script:sb5 }

        It 'no-target exits != 0 (no auto-detect)' { ($script:r5.Exit -ne 0) | Should -BeTrue }
    }
}

# ── Remove-PerLaunchTempFile ────────────────────────────────────────────────────────────
#
# 這支 helper 存在的理由是一個實機抓到的競態:`Stop-Process -Force` 只是**送出**終止要求就返回,
# 被殺的 IIS Express 還握著 Start-Iis 重導向出去的 .out.log / .err.log。緊接著刪檔就會撞上
# 「檔案正由另一個處理序使用」——實測長相是「.config 刪掉了、兩個 .log 留著」,於是一次乾淨的
# 停止之後,清理工具照樣宣告有殘骸,使用者分不出那是殘留還是真的還在跑。
#
# 這裡直接 dot-source library 本體來測(不像上面那個 Describe 走 child powershell),因為要驗的
# 是「鎖住的檔案會不會重試到成功」——鎖必須由測試自己持有並在中途放掉,那需要同一個行程裡的
# FileStream 與一個真的持鎖的背景 job。
#
# 函式本體現在住在 **Common.ps1**,不在 IisHelpers.ps1 —— console 啟動器也要用同一套重試,而它
# 沒理由為此載入 IIS helpers。測試留在這個檔案是因為 IisHelpers.ps1 會 dot-source Common.ps1,
# 拿得到;搬檔只是製造沒必要的風險。
Describe 'Remove-PerLaunchTempFile (Common.ps1, reached via IisHelpers dot-source)' {

    BeforeAll {
        # IisHelpers.ps1 自己會 dot-source Common.ps1 → Core.ps1;放在 Describe 的 BeforeAll 裡
        # dot-source,讓它帶進來的 StrictMode / EAP 只作用在這個 scope,不影響上面的 Describe。
        . $script:ScriptUnderTest
        $script:tmpDir = New-Sandbox 'rpltf'
    }
    AfterAll { Remove-Sandbox $script:tmpDir }

    Context 'Case 6: 沒被鎖住的檔 → 刪掉' {
        BeforeAll {
            $script:f6 = [System.IO.Path]::Combine($script:tmpDir, 'turbo-plugin-iis-deadbeef.out.log')
            [System.IO.File]::WriteAllText($script:f6, 'x')
            $script:r6 = Remove-PerLaunchTempFile -Path $script:f6
        }

        It 'case6: 回報已移除' { $script:r6.Removed | Should -BeTrue }
        It 'case6: 沒有錯誤訊息' { $script:r6.Error | Should -BeNullOrEmpty }
        It 'case6: 檔案真的不在了' { (Test-Path -LiteralPath $script:f6) | Should -BeFalse }
    }

    Context 'Case 7: 檔案本來就不存在 → 算成功,不是錯誤' {
        BeforeAll {
            $script:f7 = [System.IO.Path]::Combine($script:tmpDir, 'turbo-plugin-iis-deadbeef.err.log')
            $script:r7 = Remove-PerLaunchTempFile -Path $script:f7
        }

        It 'case7: 回報已移除(冪等)' { $script:r7.Removed | Should -BeTrue }
        It 'case7: 沒有錯誤訊息' { $script:r7.Error | Should -BeNullOrEmpty }
    }

    Context 'Case 8: 鎖在中途被放掉 → 重試會等到' {
        BeforeAll {
            $script:f8 = [System.IO.Path]::Combine($script:tmpDir, 'turbo-plugin-iis-cafebabe.out.log')
            $script:sentinel8 = [System.IO.Path]::Combine($script:tmpDir, 'locked.flag')
            [System.IO.File]::WriteAllText($script:f8, 'held')

            # 背景 job 持鎖 1.5 秒後放掉。拿到鎖之後寫一個 sentinel 檔通知測試——不要用「測試自己
            # 試開看看」來偵測,那會跟 job 的開檔互搶,反而可能讓 job 開不成、整個 case 失去意義。
            $script:job8 = Start-Job -ScriptBlock {
                param($path, $flag, $holdMs)
                $fs = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
                [System.IO.File]::WriteAllText($flag, 'locked')
                Start-Sleep -Milliseconds $holdMs
                $fs.Close(); $fs.Dispose()
            } -ArgumentList $script:f8, $script:sentinel8, 1500

            $deadline = (Get-Date).AddSeconds(60)
            while ((-not (Test-Path -LiteralPath $script:sentinel8)) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 50
            }
            $script:lockObserved8 = Test-Path -LiteralPath $script:sentinel8

            # 預算 10 秒,遠大於 1.5 秒的持鎖時間。
            $script:r8 = Remove-PerLaunchTempFile -Path $script:f8 -RetryCount 100 -RetryDelayMilliseconds 100
        }
        AfterAll {
            if ($script:job8) {
                Wait-Job -Job $script:job8 -Timeout 30 | Out-Null
                Remove-Job -Job $script:job8 -Force -ErrorAction SilentlyContinue
            }
        }

        It 'case8: 鎖真的被持有過(沒有的話這個 case 什麼都沒證明)' { $script:lockObserved8 | Should -BeTrue }
        It 'case8: 撐過暫時的鎖之後刪掉了' { $script:r8.Removed | Should -BeTrue }
        It 'case8: 檔案真的不在了' { (Test-Path -LiteralPath $script:f8) | Should -BeFalse }
    }

    Context 'Case 9: 鎖比重試預算久 → 誠實回報,不丟例外' {
        BeforeAll {
            $script:f9 = [System.IO.Path]::Combine($script:tmpDir, 'turbo-plugin-iis-cafebabe.err.log')
            [System.IO.File]::WriteAllText($script:f9, 'held')
            $script:fs9 = [System.IO.File]::Open($script:f9, 'Open', 'ReadWrite', 'None')
            $script:threw9 = $false
            try {
                $script:r9 = Remove-PerLaunchTempFile -Path $script:f9 -RetryCount 2 -RetryDelayMilliseconds 50
            } catch {
                $script:threw9 = $true
                $script:r9 = $null
            }
        }
        AfterAll {
            if ($script:fs9) { $script:fs9.Close(); $script:fs9.Dispose() }
            Remove-Item -LiteralPath $script:f9 -Force -ErrorAction SilentlyContinue
        }

        It 'case9: 不丟例外(呼叫端自己決定要多大聲)' { $script:threw9 | Should -BeFalse }
        It 'case9: 回報沒移除' { $script:r9.Removed | Should -BeFalse }
        It 'case9: 帶著失敗原因' { $script:r9.Error | Should -Not -BeNullOrEmpty }
        It 'case9: 檔案還在' { (Test-Path -LiteralPath $script:f9) | Should -BeTrue }
    }

    # 這個形狀曾經讓整個 helper 失效:暫存路徑的「使用者設定檔」那一段是 8.3 短別名
    # (C:\Users\MELWU~1\AppData\Local\Temp\...)。只要環境的 TMP / TEMP 是短形式,
    # GetTempPath() 就會回這種路徑。
    #
    # Remove-Item -LiteralPath 仍然會套用 PowerShell 自己的路徑解析,對一個明明存在的檔案回
    #   An object at the specified path C:\Users\MELWU~1 does not exist
    # 而且那是 argument-transformation 例外,-ErrorAction 抑制不了 —— 包在 catch { } 的呼叫端
    # 因此是靜默洩漏,這支 helper 則是耗完整個重試迴圈才回報一句自相矛盾的訊息。
    #
    # 實測過的邊界:**只有設定檔那一段**會觸發。路徑其它位置的 8.3 別名(例如
    # C:\Users\Mel Wu\AppData\Local\Temp\TPLONG~1\f.txt)完全正常,單純含 `~` 的目錄名也正常。
    # 所以這個案例刻意用機器自己的短路徑,而不是自己合成一個含 `~` 的路徑 —— 合成的那種
    # 不會重現,測了等於沒測。
    Context 'Case 10: 8.3 短檔名的設定檔路徑 → 仍然刪得掉' {
        It 'case10: 刪得掉,而且回報已移除' {
            $shortTemp = $env:TEMP
            if ([string]::IsNullOrWhiteSpace($shortTemp) -or $shortTemp -notmatch '~') {
                Set-ItResult -Skipped -Because 'this host has no 8.3 short form for the profile path'
                return
            }
            $f10 = [System.IO.Path]::Combine($shortTemp, 'turbo-plugin-iis-short83.out.log')
            [System.IO.File]::WriteAllText($f10, 'x')
            try {
                $r10 = Remove-PerLaunchTempFile -Path $f10
                $r10.Removed | Should -BeTrue -Because "the file at $f10 must be removable"
                $r10.Error | Should -BeNullOrEmpty
                [System.IO.File]::Exists($f10) | Should -BeFalse
            } finally {
                if ([System.IO.File]::Exists($f10)) { [System.IO.File]::Delete($f10) }
            }
        }
    }
}
