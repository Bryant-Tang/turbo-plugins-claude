# Sync-FromSvn.test.ps1 (Pester 5)
#
# Tests for plugins/turbo-plugin/scripts/Sync-FromSvn.ps1.
#
# Scope (U4 plan):
#   - missing -Branch arg → fail-loudly
#   - unsupported branch name (-Branch foo) → "Unsupported branch"
#   - remote-svn-main worktree missing → fail-loudly
#   - main dirty (uncommitted change) → fail-loudly + no SVN op
#   - 中文 commit msg presence in SVN seed → svn-log text round-trip on r5
#
# Notes:
#   The full happy pull-then-rebase path requires a fully wired SVN bridge: real SVN repo, git repo
#   committed with same content as remote-svn-main checkout, etc. That's exercised at the integration
#   level (Phase 2 manual). Here we cover the fail-loudly user-protection paths + fixture-readiness
#   verification of the 中文 commit msg axis.

BeforeDiscovery {
    # Case 5 needs svn / svnadmin (Reset-Fixture loads a dump). On Unix runners that lack svn we
    # SKIP rather than FAIL.
    $script:HasSvn = [bool](Get-Command svn -ErrorAction SilentlyContinue) -and `
                     [bool](Get-Command svnadmin -ErrorAction SilentlyContinue)
}

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # ScriptsCommon.ps1 provides New-Sandbox / Remove-Sandbox / New-GitMainRepo / Invoke-PsScript.
    # (AssertHelpers.ps1 is intentionally NOT sourced — asserts use Pester Should.)
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:PluginRoot      = $pluginRoot
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Sync-FromSvn.ps1')
    $script:ResetScript     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'reset', 'Reset-Fixture.ps1'))
    $script:DumpPath        = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))
    $script:ScriptExists    = [System.IO.File]::Exists($script:ScriptUnderTest)

    # Inlined replacement for AssertHelpers' Assert-SvnLogTextRoundTrip decode logic:
    # try direct UTF-8 + F-3 mojibake recovery paths; PASS if any candidate contains $ExpectedText.
    function Test-SvnLogRoundTrip {
        param([byte[]]$RawBytes, [string]$ExpectedText)
        if ($null -eq $RawBytes -or $RawBytes.Length -eq 0) { return $false }
        $decodedDirect = [System.Text.Encoding]::UTF8.GetString($RawBytes)
        $candidates = @($decodedDirect)
        try {
            $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
            $candidates += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($decodedDirect))
            foreach ($cp in @(950, 1252, 936, 932)) {
                try {
                    $oemEnc = [System.Text.Encoding]::GetEncoding($cp)
                    $oemString = $oemEnc.GetString($RawBytes)
                    $candidates += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($oemString))
                } catch { }
            }
        } catch { }
        foreach ($c in $candidates) {
            if ($c.Contains($ExpectedText)) { return $true }
        }
        return $false
    }
}

Describe 'Sync-FromSvn' {

    It 'script-under-test exists' {
        $script:ScriptExists | Should -BeTrue -Because "expected at $script:ScriptUnderTest"
    }

    Context 'Case 1: missing -Branch → required-arg error' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res1 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0' { ($script:res1.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions -Branch' { $script:res1.Combined | Should -Match '-Branch' }
    }

    Context 'Case 2: -Branch foo (unsupported) → Resolve-RemoteWorktree throws' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'foo')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        # v0.5.0 U7/U8: 'foo' is a valid branch name now (no more "Unsupported branch"
        # rejection); with no bridge worktree the script fails "Remote worktree ... not found".
        It 'exit != 0 (no bridge for this branch)' { ($script:res2.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions the missing remote worktree' { $script:res2.Combined | Should -Match 'not found' }
    }

    Context 'Case 3: -Branch main, no remote-svn-main worktree → "Remote worktree ... not found"' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res3 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0 (remote-svn-main missing)' { ($script:res3.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions remote-svn-main not found' {
            $script:res3.Combined | Should -Match "Remote worktree 'remote-svn-main' not found"
        }
    }

    Context 'Case 4: main has uncommitted changes → "uncommitted changes" error' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir -CreateRemoteMain
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'dirty.txt'), 'uncommitted')
                $script:res4 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0 (main dirty)' { ($script:res4.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions uncommitted changes' { $script:res4.Combined | Should -Match 'uncommitted changes' }
    }

    Context 'Case 5: SVN seed r5 中文 commit msg round-trips' {
        # F-U(test infra): Reset-Fixture requires svnadmin load to succeed; if the seed dump in
        # the working tree has been LF→CRLF mangled by git autocrlf (no .gitattributes binary rule),
        # load fails with E200004. We detect that and SKIP rather than FAIL — the corruption is a
        # U1 fixture artefact, not a U4 / pull-from-svn regression. Missing svn/svnadmin or a
        # missing dump also SKIP (Unix runners).

        It 'r5 中文 commit msg decodes to 字典 #3.1' -Skip:(-not $script:HasSvn) {
            if (-not [System.IO.File]::Exists($script:DumpPath)) {
                Set-ItResult -Skipped -Because "seed dump missing at $script:DumpPath; run build-seed-repo.ps1"
                return
            }
            $sb5 = New-Sandbox -Tag 'pfs-5'
            try {
                $testRoot = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin')
                $svnRepo  = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin-svn-repo')
                $sandboxBase = [System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes')
                $resetOut = [System.IO.Path]::Combine($sandboxBase, "turbo-plugin-reset-out-$([Guid]::NewGuid().ToString('N').Substring(0,10)).txt")
                # 2>&1 是 cmd.exe shell redirect(非 PS-level)— 拉到變數避開 lint 規則 4 false positive。
                $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script:ResetScript`" -TestRoot `"$testRoot`" -SvnRepo `"$svnRepo`" > `"$resetOut`" 2>&1"
                & cmd.exe /c $cmdStr
                $rc = $LASTEXITCODE
                $resetLog = if ([System.IO.File]::Exists($resetOut)) { [System.IO.File]::ReadAllText($resetOut) } else { '' }
                if ([System.IO.File]::Exists($resetOut)) { try { [System.IO.File]::Delete($resetOut) } catch {} }

                if ($rc -ne 0 -and $resetLog -match 'E200004|Could not convert|svnadmin load failed') {
                    Set-ItResult -Skipped -Because 'Reset-Fixture failed with svnadmin-load corruption (likely LF→CRLF dump mangle; U1 .gitattributes fix needed)'
                    return
                }

                $rc | Should -Be 0 -Because $resetLog

                $dumpScript = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'Get-RawCommitDump.ps1')
                $rawBytes = & $dumpScript -RevN 5 -RepoPathOrUrl $svnRepo -ReturnFormat Bytes
                (Test-SvnLogRoundTrip -RawBytes $rawBytes -ExpectedText '修正中文 commit 訊息亂碼') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb5
            }
        }
    }
}
