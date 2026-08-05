# New-ApphostConfig.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-dotnet-framework/scripts/New-ApphostConfig.ps1
#
# Contract: -Project <csproj> [-Force]. Generates .turbo-plugin/applicationhost.config from the
# shipped template plus a <site> synthesised from the csproj's IIS settings, so a project can be
# set up without ever opening Visual Studio.
#
# The generated site must be in CANONICAL shape -- plain project name, physicalPath placeholder --
# because that is what Start-Iis looks up and what makes the file safe to commit and share. The
# identity-hashed name and the real path belong to the per-launch temp copy only.
#
# No IIS Express, no Visual Studio and no network are needed: every case builds a throwaway git
# repo with a hand-written csproj and asserts on the XML that comes out.

BeforeAll {
    $script:pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'New-ApphostConfig.ps1')
    $script:SandboxBase = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($script:pluginRoot, 'tests', '.sandbox', 'sandboxes'))
    $null = New-Item -ItemType Directory -Path $script:SandboxBase -Force

    function Invoke-GitSilent {
        $allArgs = $args
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & git @allArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $oldEap }
    }

    # A throwaway repo holding one csproj. $CsprojBody is spliced into the <PropertyGroup> so each
    # case controls exactly which IIS elements exist.
    function New-ProjectSandbox {
        param([string]$Tag, [string]$IisElements, [string]$ProjectName = 'HelloApp')
        $root = [System.IO.Path]::Combine($script:SandboxBase, "tp-nac-$Tag-$([Guid]::NewGuid().ToString('N').Substring(0,8))")
        $null = New-Item -ItemType Directory -Path $root -Force
        $csproj = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>$ProjectName</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
$IisElements
  </PropertyGroup>
</Project>
"@
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($root, "$ProjectName.csproj"), $csproj,
            (New-Object System.Text.UTF8Encoding($false)))
        Push-Location -LiteralPath $root
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture'
        } finally { Pop-Location }
        return $root
    }

    function Remove-ProjectSandbox {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try { if ([System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::Delete($Dir, $true) } } catch { }
    }

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
        $tmpOut = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-nac-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpErr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-nac-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) +
                @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $WorkDir `
                -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -NoNewWindow -PassThru -Wait
            $stdout = if (Test-Path -LiteralPath $tmpOut -PathType Leaf) { [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8) } else { '' }
            $stderr = if (Test-Path -LiteralPath $tmpErr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpErr, [System.Text.Encoding]::UTF8) } else { '' }
            return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode; Combined = "$stdout`n$stderr" }
        } finally {
            foreach ($t in @($tmpOut, $tmpErr)) {
                if (Test-Path -LiteralPath $t -PathType Leaf) { try { [System.IO.File]::Delete($t) } catch { } }
            }
        }
    }

    function Get-GeneratedSite {
        param([string]$Root, [string]$SiteName = 'HelloApp')
        $path = [System.IO.Path]::Combine($Root, '.turbo-plugin', 'applicationhost.config')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $x = New-Object System.Xml.XmlDocument
        $x.Load($path)
        foreach ($node in @($x.SelectNodes('/configuration/system.applicationHost/sites/site'))) {
            if ($node.GetAttribute('name') -ieq $SiteName) { return $node }
        }
        return $null
    }
}

Describe 'New-ApphostConfig' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: http-only project generates a canonical-shaped site' {
        BeforeAll {
            $script:r1Root = New-ProjectSandbox -Tag 'http' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $script:r1 = Invoke-Script -WorkDir $script:r1Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r1Site = Get-GeneratedSite -Root $script:r1Root
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r1Root }

        It 'case1: exit 0' { $script:r1.Exit | Should -Be 0 -Because $script:r1.Combined }
        It 'case1: 站台以「專案名」命名(不是帶 hash 的執行期名)' {
            $script:r1Site | Should -Not -BeNullOrEmpty
            $script:r1Site.GetAttribute('name') | Should -Be 'HelloApp'
        }
        It 'case1: physicalPath 是佔位符,不含機器路徑' {
            $vd = $script:r1Site.SelectSingleNode('application/virtualDirectory')
            $vd.GetAttribute('physicalPath') | Should -Be '__TURBO_PLUGIN_PHYSICAL_PATH__'
        }
        It 'case1: http binding 取自 <IISUrl> 的 port' {
            $b = @($script:r1Site.SelectNodes('bindings/binding'))
            $b.Count | Should -Be 1
            $b[0].GetAttribute('protocol') | Should -Be 'http'
            $b[0].GetAttribute('bindingInformation') | Should -Be '*:5000:localhost'
        }
        It 'case1: 預設用 Integrated app pool' {
            $script:r1Site.SelectSingleNode('application').GetAttribute('applicationPool') | Should -Be 'Clr4IntegratedAppPool'
        }
    }

    Context 'Case 2: SSL port adds an https binding' {
        BeforeAll {
            $elements = "    <IISUrl>http://localhost:5000/</IISUrl>`n    <IISExpressSSLPort>44301</IISExpressSSLPort>"
            $script:r2Root = New-ProjectSandbox -Tag 'ssl' -IisElements $elements
            $script:r2 = Invoke-Script -WorkDir $script:r2Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r2Site = Get-GeneratedSite -Root $script:r2Root
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r2Root }

        It 'case2: exit 0' { $script:r2.Exit | Should -Be 0 -Because $script:r2.Combined }
        It 'case2: 產出 http + https 兩個 binding' {
            $b = @($script:r2Site.SelectNodes('bindings/binding'))
            $b.Count | Should -Be 2
            ($b | ForEach-Object { $_.GetAttribute('protocol') }) -join ',' | Should -Be 'http,https'
            $b[1].GetAttribute('bindingInformation') | Should -Be '*:44301:localhost'
        }
        It 'case2: 回報 https 位址' { $script:r2.Stdout | Should -Match 'https://localhost:44301' }
    }

    Context 'Case 3: classic pipeline selects the classic app pool' {
        BeforeAll {
            $elements = "    <IISUrl>http://localhost:5000/</IISUrl>`n    <IISExpressUseClassicPipelineMode>true</IISExpressUseClassicPipelineMode>"
            $script:r3Root = New-ProjectSandbox -Tag 'classic' -IisElements $elements
            $script:r3 = Invoke-Script -WorkDir $script:r3Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r3Site = Get-GeneratedSite -Root $script:r3Root
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r3Root }

        It 'case3: exit 0' { $script:r3.Exit | Should -Be 0 -Because $script:r3.Combined }
        It 'case3: 用 Clr4ClassicAppPool' {
            $script:r3Site.SelectSingleNode('application').GetAttribute('applicationPool') | Should -Be 'Clr4ClassicAppPool'
        }
    }

    Context 'Case 4: an existing canonical is left alone without -Force' {
        BeforeAll {
            $script:r4Root = New-ProjectSandbox -Tag 'exists' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $null = Invoke-Script -WorkDir $script:r4Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r4Path = [System.IO.Path]::Combine($script:r4Root, '.turbo-plugin', 'applicationhost.config')
            # Mark the file so any rewrite is detectable.
            $marked = [System.IO.File]::ReadAllText($script:r4Path, [System.Text.Encoding]::UTF8) + "`n<!-- sentinel -->"
            [System.IO.File]::WriteAllText($script:r4Path, $marked, (New-Object System.Text.UTF8Encoding($false)))
            $script:r4 = Invoke-Script -WorkDir $script:r4Root -ExtraArgs @('-Project', 'HelloApp.csproj')
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r4Root }

        It 'case4: exit 0' { $script:r4.Exit | Should -Be 0 -Because $script:r4.Combined }
        It 'case4: 既有檔案原封不動' {
            [System.IO.File]::ReadAllText($script:r4Path, [System.Text.Encoding]::UTF8) | Should -Match 'sentinel'
        }
        It 'case4: 回報「已存在,未變更」' { $script:r4.Stdout | Should -Match '已存在' }
    }

    # A repo with more than one web project shares ONE applicationhost.config, the way Visual
    # Studio's does. Regenerating the file from the template for each project would leave only the
    # last one standing, so the second project's site has to be appended to the first's.
    Context 'Case 6: a second project is appended to the same config' {
        BeforeAll {
            $script:r6Root = New-ProjectSandbox -Tag 'multi' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $second = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>AdminApp</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
    <IISUrl>http://localhost:5001/</IISUrl>
  </PropertyGroup>
</Project>
"@
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($script:r6Root, 'AdminApp.csproj'), $second,
                (New-Object System.Text.UTF8Encoding($false)))
            $null = Invoke-Script -WorkDir $script:r6Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r6 = Invoke-Script -WorkDir $script:r6Root -ExtraArgs @('-Project', 'AdminApp.csproj')
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r6Root }

        It 'case6: exit 0' { $script:r6.Exit | Should -Be 0 -Because $script:r6.Combined }
        It 'case6: 兩個專案的站台都在同一份設定檔裡' {
            (Get-GeneratedSite -Root $script:r6Root -SiteName 'HelloApp') | Should -Not -BeNullOrEmpty
            (Get-GeneratedSite -Root $script:r6Root -SiteName 'AdminApp') | Should -Not -BeNullOrEmpty
        }
        It 'case6: 先產生的站台保留自己的 binding' {
            (Get-GeneratedSite -Root $script:r6Root -SiteName 'HelloApp').SelectSingleNode('bindings/binding').GetAttribute('bindingInformation') |
                Should -Be '*:5000:localhost'
        }
        It 'case6: 兩個站台 id 不重複' {
            $a = (Get-GeneratedSite -Root $script:r6Root -SiteName 'HelloApp').GetAttribute('id')
            $b = (Get-GeneratedSite -Root $script:r6Root -SiteName 'AdminApp').GetAttribute('id')
            $a | Should -Not -Be $b
        }
        It 'case6: 回報是「補上站台」而不是「新建」' {
            $script:r6.Stdout | Should -Match '已補上'
        }
    }

    # -Force regenerates ONE project's site from its csproj. It must not take the sibling projects
    # with it -- the old implementation rebuilt the whole file from the template and did exactly that.
    Context 'Case 7: -Force rebuilds only the named site' {
        BeforeAll {
            $script:r7Root = New-ProjectSandbox -Tag 'force' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $null = Invoke-Script -WorkDir $script:r7Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            # Add a sibling site by hand, then force-regenerate HelloApp.
            $script:r7Path = [System.IO.Path]::Combine($script:r7Root, '.turbo-plugin', 'applicationhost.config')
            $text = [System.IO.File]::ReadAllText($script:r7Path, [System.Text.Encoding]::UTF8)
            $sibling = '<site name="Sibling" id="9"><application path="/" applicationPool="Clr4IntegratedAppPool"><virtualDirectory path="/" physicalPath="__TURBO_PLUGIN_PHYSICAL_PATH__" /></application><bindings><binding protocol="http" bindingInformation="*:5099:localhost" /></bindings></site>'
            [System.IO.File]::WriteAllText($script:r7Path, $text.Replace('</sites>', "$sibling</sites>"),
                (New-Object System.Text.UTF8Encoding($false)))
            $script:r7 = Invoke-Script -WorkDir $script:r7Root -ExtraArgs @('-Project', 'HelloApp.csproj', '-Force')
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r7Root }

        It 'case7: exit 0' { $script:r7.Exit | Should -Be 0 -Because $script:r7.Combined }
        It 'case7: 目標站台仍在' { (Get-GeneratedSite -Root $script:r7Root -SiteName 'HelloApp') | Should -Not -BeNullOrEmpty }
        It 'case7: 同檔案裡別的站台沒有被一起清掉' {
            (Get-GeneratedSite -Root $script:r7Root -SiteName 'Sibling') | Should -Not -BeNullOrEmpty
        }
    }

    # THE regression lock for this script. Everything else here asserts on the XML we wrote; this
    # asks IIS EXPRESS ITSELF whether it can load the result. The first shipped version generated a
    # ~40-line file that parsed fine as XML, satisfied every structural assertion, and was rejected
    # outright by IIS Express ("cannot read configuration section 'system.applicationHost' because
    # it is missing a section declaration") -- a real applicationhost.config carries ~1000 lines of
    # <configSections> plus the <system.webServer> module/handler tables.
    #
    # appcmd parses the config WITHOUT starting a server, so this stays hermetic: no process is
    # spawned, no port is bound, nothing on the machine changes.
    Context 'Case 8: IIS Express itself can load the generated config' {
        BeforeAll {
            $script:appcmd = ''
            try {
                . ([System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'lib', 'Common.ps1'))
                . ([System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1'))
                $exe = Find-IisExpressPath -RepoRoot ''
                $candidate = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($exe), 'appcmd.exe')
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:appcmd = $candidate }
            } catch {
                $script:appcmd = ''
            }

            $script:r8Root = ''
            if (-not [string]::IsNullOrWhiteSpace($script:appcmd)) {
                $elements = "    <IISUrl>http://localhost:5000/</IISUrl>`n    <IISExpressSSLPort>44301</IISExpressSSLPort>"
                $script:r8Root = New-ProjectSandbox -Tag 'appcmd' -IisElements $elements
                $script:r8 = Invoke-Script -WorkDir $script:r8Root -ExtraArgs @('-Project', 'HelloApp.csproj')
                $script:r8Cfg = [System.IO.Path]::Combine($script:r8Root, '.turbo-plugin', 'applicationhost.config')
                # appcmd's complaint (including the offending line number) is the whole value of
                # this case when it fails, so stderr must be kept -- but `2>&1` would fold it into
                # the output stream as ErrorRecords and make $LASTEXITCODE unreliable, which is the
                # one thing this case actually asserts on. Capture the two streams separately and
                # join them only for the failure message. EAP is pinned to Continue around the call
                # because a native exe writing to stderr throws under EAP=Stop even with a
                # redirection in place.
                $r8ErrFile = [System.IO.Path]::Combine($script:r8Root, 'appcmd-stderr.txt')
                $r8PrevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $r8Out = (& $script:appcmd list site /apphostconfig:"$($script:r8Cfg)" 2>$r8ErrFile | Out-String)
                    $script:r8AppcmdExit = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $r8PrevEap
                }
                $r8Err = if (Test-Path -LiteralPath $r8ErrFile -PathType Leaf) {
                    [System.IO.File]::ReadAllText($r8ErrFile)
                } else { '' }
                $script:r8Appcmd = ($r8Out + $r8Err)
            }
        }
        AfterAll { if (-not [string]::IsNullOrWhiteSpace($script:r8Root)) { Remove-ProjectSandbox -Dir $script:r8Root } }

        It 'case8: appcmd 能載入這份設定檔(exit 0)' {
            if ([string]::IsNullOrWhiteSpace($script:appcmd)) {
                Set-ItResult -Skipped -Because '這台機器沒有 IIS Express 的 appcmd.exe'
            }
            $script:r8AppcmdExit | Should -Be 0 -Because $script:r8Appcmd
        }
        It 'case8: appcmd 列得出這個專案的站台' {
            if ([string]::IsNullOrWhiteSpace($script:appcmd)) {
                Set-ItResult -Skipped -Because '這台機器沒有 IIS Express 的 appcmd.exe'
            }
            $script:r8Appcmd | Should -Match 'SITE "HelloApp"'
        }
        It 'case8: 內建的示範站台沒有被一起帶進來' {
            if ([string]::IsNullOrWhiteSpace($script:appcmd)) {
                Set-ItResult -Skipped -Because '這台機器沒有 IIS Express 的 appcmd.exe'
            }
            # IIS Express 的範本自帶一個 "Development Web Site"(:8080、指向空目錄)。它不該進到
            # 這個 repo 共享的設定檔裡,否則每個專案都莫名多一個站台、還占著 8080。
            $script:r8Appcmd | Should -Not -Match 'Development Web Site'
        }
        It 'case8: 設定檔含區段宣告(缺這段 IIS Express 會直接拒收)' {
            if ([string]::IsNullOrWhiteSpace($script:appcmd)) {
                Set-ItResult -Skipped -Because '這台機器沒有 IIS Express 的 appcmd.exe'
            }
            [System.IO.File]::ReadAllText($script:r8Cfg) | Should -Match '<configSections>'
        }
    }

    # The generated file is meant to be committed, and the run SKILL asks the user to do exactly
    # that. But it is ~1000 lines of IIS internals including <configProtectedData sessionKey="...">,
    # and a reader has no way to tell those keys are constants copied out of IIS Express's own
    # template. Observed for real (2026-08-04): a push flow stopped and warned the user about
    # "encryption keys produced by this machine" on a file with nothing machine-specific in it.
    # The explanation therefore lives in the artifact, where every reader hits it -- including tools
    # in other plugins that only ever see the file.
    Context 'Case 9: 產生的設定檔自帶「這確實可以進版控」的說明' {
        BeforeAll {
            $script:r9Root = New-ProjectSandbox -Tag 'note' -IisElements '    <IISUrl>http://localhost:5000/</IISUrl>'
            $script:r9 = Invoke-Script -WorkDir $script:r9Root -ExtraArgs @('-Project', 'HelloApp.csproj')
            $script:r9Path = [System.IO.Path]::Combine($script:r9Root, '.turbo-plugin', 'applicationhost.config')
            $script:r9Text = [System.IO.File]::ReadAllText($script:r9Path, [System.Text.Encoding]::UTF8)

            $script:r9Xml = New-Object System.Xml.XmlDocument
            $script:r9Xml.Load($script:r9Path)

            # 第二個專案接進同一份設定檔 —— 說明不該被複製第二份。
            $second = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>AdminApp</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
    <IISUrl>http://localhost:5001/</IISUrl>
  </PropertyGroup>
</Project>
"@
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($script:r9Root, 'AdminApp.csproj'), $second,
                (New-Object System.Text.UTF8Encoding($false)))
            $null = Invoke-Script -WorkDir $script:r9Root -ExtraArgs @('-Project', 'AdminApp.csproj')
            $script:r9TextAfter = [System.IO.File]::ReadAllText($script:r9Path, [System.Text.Encoding]::UTF8)
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r9Root }

        It 'case9: exit 0' { $script:r9.Exit | Should -Be 0 -Because $script:r9.Combined }

        It 'case9: 說明就在 <configuration> 的第一個子節點(讀的人第一眼會看到)' {
            $first = $script:r9Xml.DocumentElement.FirstChild
            $first.NodeType | Should -Be ([System.Xml.XmlNodeType]::Comment)
            $first.Value | Should -Match 'turbo-plugin:applicationhost'
        }

        # 這兩個字串是契約,不是文案。它們正是掃描工具會誤判的兩個東西:改寫說明時如果把它們
        # 拿掉,說明就不再回答讀者真正的疑問,而這個修正等於默默失效。
        It 'case9: 說明有交代 sessionKey 是原廠固定值' {
            $script:r9Xml.DocumentElement.FirstChild.Value | Should -Match 'sessionKey'
        }
        It 'case9: 說明有交代 physicalPath 是佔位符' {
            $script:r9Xml.DocumentElement.FirstChild.Value | Should -Match '__TURBO_PLUGIN_PHYSICAL_PATH__'
        }

        It 'case9: 說明只出現一次' {
            ([regex]::Matches($script:r9Text, 'turbo\-plugin:applicationhost')).Count | Should -Be 1
        }
        It 'case9: 補上第二個專案之後仍然只有一份說明' {
            ([regex]::Matches($script:r9TextAfter, 'turbo\-plugin:applicationhost')).Count | Should -Be 1
        }
        It 'case9: 加了說明之後檔案仍是合法 XML,站台照樣讀得出來' {
            $after = New-Object System.Xml.XmlDocument
            { $after.Load($script:r9Path) } | Should -Not -Throw
            @($after.SelectNodes('/configuration/system.applicationHost/sites/site')).Count | Should -Be 2
        }
    }

    Context 'Case 5: csproj without any IIS setting fails loudly' {
        BeforeAll {
            # Mirrors a project where VS kept the server settings in the gitignored .csproj.user.
            $script:r5Root = New-ProjectSandbox -Tag 'noiis' -IisElements '    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>'
            $script:r5 = Invoke-Script -WorkDir $script:r5Root -ExtraArgs @('-Project', 'HelloApp.csproj')
        }
        AfterAll { Remove-ProjectSandbox -Dir $script:r5Root }

        It 'case5: exit ≠ 0' { ($script:r5.Exit -ne 0) | Should -BeTrue }
        It 'case5: 訊息點名缺哪些元素' { $script:r5.Combined | Should -Match 'IISUrl' }
        It 'case5: 不產生半成品設定檔' {
            [System.IO.File]::Exists([System.IO.Path]::Combine($script:r5Root, '.turbo-plugin', 'applicationhost.config')) | Should -BeFalse
        }
    }
}
