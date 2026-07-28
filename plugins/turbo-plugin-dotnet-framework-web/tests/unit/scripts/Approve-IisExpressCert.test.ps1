# Approve-IisExpressCert.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-dotnet-framework-web/scripts/Approve-IisExpressCert.ps1
#
# Contract: [-CheckOnly]. Adds the IIS Express development certificate to CurrentUser\Root so the
# browser stops warning on https://localhost -- the same thing Visual Studio's one-time prompt does.
#
# TESTS NEVER ADD OR REMOVE A CERTIFICATE. Trusting a certificate is a real change to the machine's
# security configuration, and the repo's tests are required to leave global state untouched. So
# only the read-only paths are exercised: -CheckOnly, the library predicates, and the guarantee
# that a check leaves the trusted-root store exactly as it found it. The write path is covered by
# the script's own read-back verification, not by mutating the developer's store here.
#
# Assertions adapt to the machine: a runner without IIS Express installed has no certificate at
# all, which is a legitimate state the script must report cleanly rather than crash on.

BeforeAll {
    $script:pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'Approve-IisExpressCert.ps1')

    . ([System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'lib', 'Common.ps1'))
    . ([System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1'))

    function Get-RootStoreCount {
        return @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction SilentlyContinue).Count
    }

    function Invoke-Script {
        param([string[]]$ExtraArgs = @())
        $tmpOut = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-cert-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpErr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-cert-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) + $ExtraArgs
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
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

    $script:HasDevCert = ($null -ne (Get-IisExpressDevCert))
}

Describe 'Approve-IisExpressCert' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: library predicates' {
        It 'case1: Get-IisExpressDevCert 不丟例外,有回傳就帶指紋' {
            $c = Get-IisExpressDevCert
            if ($null -ne $c) { $c.Thumbprint | Should -Not -BeNullOrEmpty }
            else { $true | Should -BeTrue }
        }

        # Regression: the lookup used to build its candidate list through an if-expression, which
        # unwraps a SINGLE-element array into a scalar; the following .Count read then threw under
        # StrictMode and the catch reported "no certificate found". A machine holding exactly one
        # IIS Express certificate -- the normal case -- hit it every time.
        It 'case1: 商店裡讀得到憑證時,查找函式就不能回傳 null(單元素拆包回歸)' {
            $raw = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -match 'IIS Express' })
            if ($raw.Count -gt 0) {
                Get-IisExpressDevCert | Should -Not -BeNullOrEmpty
            } else {
                Set-ItResult -Skipped -Because '這台機器沒有安裝 IIS Express 的開發憑證'
            }
        }

        It 'case1: 信任判斷比對指紋,不是比對主體名稱' {
            # CN=localhost is used by several unrelated dev certificates (ASP.NET Core ships one),
            # so a subject-based check would report the wrong certificate as trusted.
            $fake = [pscustomobject]@{ Thumbprint = '0000000000000000000000000000000000000000'; Subject = 'CN=localhost' }
            Test-IisExpressCertTrusted -Certificate $fake | Should -BeFalse
        }

        It 'case1: 傳入 null 回 false,不丟例外' {
            Test-IisExpressCertTrusted -Certificate $null | Should -BeFalse
        }
    }

    Context 'Case 2: -CheckOnly 是唯讀的' {
        BeforeAll {
            $script:beforeCount = Get-RootStoreCount
            $script:r2 = Invoke-Script -ExtraArgs @('-CheckOnly')
            $script:afterCount = Get-RootStoreCount
        }

        It 'case2: 信任清單筆數不變(沒有寫入任何東西)' {
            $script:afterCount | Should -Be $script:beforeCount
        }

        It 'case2: 有憑證時 exit 0 並印出結果區段' {
            if ($script:HasDevCert) {
                $script:r2.Exit | Should -Be 0 -Because $script:r2.Combined
                $script:r2.Stdout | Should -Match 'CERT_OUTPUT'
            } else {
                Set-ItResult -Skipped -Because '這台機器沒有 IIS Express 開發憑證'
            }
        }

        It 'case2: 沒有憑證時 fail loudly 並說明怎麼取得' {
            if ($script:HasDevCert) {
                Set-ItResult -Skipped -Because '這台機器有憑證,走的是另一條路徑'
            } else {
                $script:r2.Exit | Should -Not -Be 0
                $script:r2.Combined | Should -Match 'IIS Express'
            }
        }

        It 'case2: 尚未信任時吐出可供 SKILL 分支的 token' {
            $cert = Get-IisExpressDevCert
            if (($null -ne $cert) -and (-not (Test-IisExpressCertTrusted -Certificate $cert))) {
                $script:r2.Stdout | Should -Match 'TP_TOKEN:CERT_UNTRUSTED'
            } else {
                Set-ItResult -Skipped -Because '憑證不存在或已受信任,不該出現此 token'
            }
        }
    }
}
