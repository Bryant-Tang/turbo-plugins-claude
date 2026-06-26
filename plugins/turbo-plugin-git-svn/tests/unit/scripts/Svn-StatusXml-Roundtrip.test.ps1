# Svn-StatusXml-Roundtrip.test.ps1 (Pester 5)
#
# Regression coverage for the non-ASCII (Chinese) filename push-to-svn bug, PS side.
#
# Root cause (forensic): Build/Submit-SvnCommit.ps1 captured `svn status` text and re-passed
# the parsed path as argv to `svn add/commit`. PowerShell encodes native-command ARGV using
# [Console]::OutputEncoding; on zh-TW Windows the on-disk + `svn status` bytes are the system
# ANSI codepage (Big5), so unless OutputEncoding matches, the re-passed path mismatches the
# file on disk -> "not under version control".
#
# Fix: scope [Console]::OutputEncoding to the system ANSI codepage around the svn region, so
# `svn status` decodes correctly AND the argv re-encode matches the on-disk filename. (The PS
# side deliberately does NOT use `svn status --xml`: UTF-8 XML output would need
# OutputEncoding=UTF8, which would then mis-encode the ANSI commit argv.)
#
# Two layers:
#   1. Structural guard (always runs): the scripts still perform the ANSI OutputEncoding swap.
#   2. Behavioral round-trip (SKIPs without svn/svnadmin): drives a live svn working copy that
#      holds a Chinese-named file through the script's exact technique (ANSI OutputEncoding +
#      `svn status` parse + re-pass to `svn add`/`svn commit`). On a zh-TW (Big5) runner this
#      FAILS without the ANSI swap and PASSES with it; on a UTF-8 runner it passes either way.

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:BuildScript  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-SvnCommit.ps1')
    $script:SubmitScript = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Submit-SvnCommit.ps1')
    $script:HasSvn = [bool](Get-Command svn -ErrorAction SilentlyContinue) -and `
                     [bool](Get-Command svnadmin -ErrorAction SilentlyContinue)

    # Chinese filename built from explicit code points so THIS source file stays pure ASCII
    # (no BOM dependency): the .txt name is U+6E2C U+8A66 U+4E2D U+6587 U+6A94 U+540D
    # DO NOT replace these code points with literal CJK characters: this file has no BOM and must
    # stay pure ASCII, or PS 5.1 on a CP950 console will mojibake and fail to parse the test.
    $script:ZhName = -join @(
        [char]0x6E2C, [char]0x8A66, [char]0x4E2D, [char]0x6587, [char]0x6A94, [char]0x540D
    ) + '.txt'
}

Describe 'Svn non-ASCII filename encoding' {

    Context 'Structural: scripts swap Console.OutputEncoding to the system ANSI codepage' {
        It 'Build-SvnCommit.ps1 sets OutputEncoding to the ANSI codepage' {
            (Get-Content -LiteralPath $script:BuildScript -Raw) |
                Should -Match 'OutputEncoding\s*=\s*\$tpAnsiEnc'
            (Get-Content -LiteralPath $script:BuildScript -Raw) | Should -Match 'ANSICodePage'
        }
        It 'Submit-SvnCommit.ps1 sets OutputEncoding to the ANSI codepage' {
            # Assert the actual assignment, not just the substring (which also appears in comments).
            (Get-Content -LiteralPath $script:SubmitScript -Raw) |
                Should -Match 'OutputEncoding\s*=\s*\[System\.Text\.Encoding\]::GetEncoding'
            (Get-Content -LiteralPath $script:SubmitScript -Raw) | Should -Match 'ANSICodePage'
        }
    }

    Context 'Behavioral: a Chinese filename round-trips through real svn under the ANSI technique' {
        It 'captured path re-passes to svn add/commit successfully' {
            if (-not $script:HasSvn) {
                Set-ItResult -Skipped -Because 'svn/svnadmin not available on this runner'
                return
            }
            $sb = New-Sandbox -Tag 'ssx'
            $prevEnc = [Console]::OutputEncoding
            try {
                $repo = [System.IO.Path]::Combine($sb, 'repo')
                $wc   = [System.IO.Path]::Combine($sb, 'wc')
                # ScriptsCommon sets EAP=Stop; under it a native exe writing stderr throws
                # NativeCommandError even with 2>$null. Wrap svn setup so an unusable svn yields a
                # graceful SKIP, not an uncaught failure.
                try {
                    & svnadmin create $repo 2>$null | Out-Null
                    $uri = 'file:///' + ($repo -replace '\\', '/')
                    & svn checkout $uri $wc 2>$null | Out-Null
                } catch {
                    Set-ItResult -Skipped -Because "svn/svnadmin setup failed: $($_.Exception.Message)"
                    return
                }
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'svn checkout returned non-zero'; return }

                [System.IO.File]::WriteAllText(
                    [System.IO.Path]::Combine($wc, $script:ZhName), 'hi',
                    (New-Object System.Text.UTF8Encoding($false)))

                # Apply the script's exact technique: ANSI OutputEncoding around the svn region.
                $ansi = [System.Text.Encoding]::GetEncoding(
                    [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
                [Console]::OutputEncoding = $ansi

                Push-Location $wc
                try {
                    $captured = $null
                    foreach ($line in (& svn status)) {
                        if ($line -match '^\?\s+(.+)$') { $captured = $Matches[1].Trim() }
                    }
                    $captured | Should -Not -BeNullOrEmpty
                    # The captured Unicode path must equal the original (decode round-trip).
                    $captured | Should -Be $script:ZhName

                    & svn add --parents -- $captured
                    $LASTEXITCODE | Should -Be 0
                    & svn commit --encoding UTF-8 -m 'add nonascii' -- $captured
                    $LASTEXITCODE | Should -Be 0

                    # After commit nothing should remain unversioned (re-pass round-trip worked).
                    $stillUnversioned = @(& svn status | Where-Object { $_ -match '^\?' })
                    $stillUnversioned.Count | Should -Be 0
                } finally {
                    Pop-Location
                }
            } finally {
                [Console]::OutputEncoding = $prevEnc
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
