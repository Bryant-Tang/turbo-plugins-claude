# Test-EncodingSupport.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Test-EncodingSupport.ps1
# Behavior: emits PS_VERSION / ANSI_CODEPAGE / OEM_CODEPAGE / ARGV_SAFE_FOR_UNICODE /
#   RECOMMENDATION tokens; non-UTF-8 ANSI also prints a WARNING + (a)(b)(c) guidance.

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Test-EncodingSupport.ps1')

    function Invoke-Script {
        $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ScriptUnderTest 2>$null
            $exit = $LASTEXITCODE
        } catch {
            $stdout = @($_.Exception.Message); $exit = 99
        } finally {
            $ErrorActionPreference = $savedEap
        }
        return @{ Stdout = ($stdout -join "`n"); Exit = $exit }
    }

    function Get-Tokens {
        param([string]$Text)
        return ((($Text -split "`r?`n") | Where-Object {
            $_ -match '^(PS_VERSION|ANSI_CODEPAGE|OEM_CODEPAGE|ARGV_SAFE_FOR_UNICODE|RECOMMENDATION)='
        }) -join "`n")
    }
}

Describe 'Test-EncodingSupport' {

    Context 'Case 1: tokens present' {
        BeforeAll { $script:r1 = Invoke-Script }

        It 'exits 0' { $script:r1.Exit | Should -Be 0 }
        It 'emits PS_VERSION token' { $script:r1.Stdout | Should -Match 'PS_VERSION=\d+\.\d+' }
        It 'emits ANSI_CODEPAGE token' { $script:r1.Stdout | Should -Match 'ANSI_CODEPAGE=' }
        It 'emits OEM_CODEPAGE token' { $script:r1.Stdout | Should -Match 'OEM_CODEPAGE=' }
        It 'emits ARGV_SAFE_FOR_UNICODE token' { $script:r1.Stdout | Should -Match 'ARGV_SAFE_FOR_UNICODE=(True|False)' }
        It 'emits RECOMMENDATION token' { $script:r1.Stdout | Should -Match 'RECOMMENDATION=(OK|UPGRADE_PS7_OR_ENABLE_WIN10_UTF8)' }
    }

    Context 'Case 2: deterministic across runs' {
        It 'tokens are deterministic across two invocations' {
            $a = Invoke-Script
            $b = Invoke-Script
            $b.Exit | Should -Be 0
            (Get-Tokens $b.Stdout) | Should -Be (Get-Tokens $a.Stdout)
        }
    }
}
