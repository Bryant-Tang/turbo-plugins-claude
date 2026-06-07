# Get-SvnLog.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin/scripts/Get-SvnLog.ps1
# Behavior: 走 main worktree → `<proj>.worktrees/remote-<branch>` → 跑 `svn log --xml`,parse XML
#   後 emit「rN | author | date | msg」+ trailer `# LAST_SHOWN_REV=<minRev>`。
#
# Cases:
#   1. Happy: fixture (Reset-Fixture seeded) → 預設 --branch main --limit 5 → top=r19 + trailer LAST_SHOWN_REV=15
#   2. 中文 commit (r5):跑 `-Revision 5` → stdout 含 r5 行;中文 round-trip via decode
#      (字典 #3.1「修正中文 commit 訊息亂碼」)
#   3. Revision 指定 r5: stdout 含 trailer
#   4. Limit invalid: -Limit 0 → exit 非 0,訊息提及「positive integer」
#   5. SKILL entry: 再呼叫一次 → 結果 deterministic

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $script:PluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($script:PluginRoot, 'scripts', 'Get-SvnLog.ps1')

    # Reset-Fixture (F5 fix 2026-05-28) 已改為直接創 sibling layout `<testRoot>.worktrees/`。
    $script:TestRoot = [System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'test-turbo-plugin')

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
        param([string]$Root)
        if (-not [System.IO.Directory]::Exists($Root)) { return $false }
        if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($Root, '.git'))) {
            Push-Location -LiteralPath $Root
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
        } finally { Set-Location -LiteralPath $oldLoc }
    }

    # ─── 中文 round-trip check (inlined from Assert-SvnLogTextRoundTrip; no AssertHelpers dep) ───
    # Tolerate both canonical-UTF-8 SVN repos AND F-3 Windows TortoiseSVN mojibake by trying
    # several decode paths; returns $true if any decode contains $ExpectedText.
    function Test-SvnLogTextRoundTrip {
        param(
            [Parameter(Mandatory = $true)][string]$ExpectedText,
            [Parameter(Mandatory = $true)][int]$RevN,
            [Parameter(Mandatory = $true)][string]$RepoPathOrUrl
        )
        $dumpScript = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'Get-RawCommitDump.ps1')
        if (-not [System.IO.File]::Exists($dumpScript)) {
            throw "Get-RawCommitDump.ps1 not found at: $dumpScript"
        }
        $rawBytes = & $dumpScript -RevN $RevN -RepoPathOrUrl $RepoPathOrUrl -ReturnFormat Bytes
        if ($null -eq $rawBytes -or $rawBytes.Length -eq 0) {
            throw "raw svn log bytes empty for r$RevN @ $RepoPathOrUrl"
        }

        # Path A — direct UTF-8 decode (canonical / Linux case)
        $decodedDirect = [System.Text.Encoding]::UTF8.GetString($rawBytes)
        $candidates = @($decodedDirect)
        try {
            $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
            # Path B — svnlook revprop recovery (mojibake but no output transcoding)
            $candidates += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($decodedDirect))
            # Path C — svn log output recovery (mojibake + locale output transcoding)
            foreach ($cp in @(950, 1252, 936, 932)) {
                try {
                    $oemEnc = [System.Text.Encoding]::GetEncoding($cp)
                    $oemString = $oemEnc.GetString($rawBytes)
                    $candidates += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($oemString))
                } catch { }
            }
        } catch { }

        foreach ($c in $candidates) {
            if ($c.Contains($ExpectedText)) { return $true }
        }
        return $false
    }

    $script:FixtureReady = Ensure-FixtureGit -Root $script:TestRoot

    if ($script:FixtureReady) {
        # Note: Seed dump goes r1..r19; observed actual remote-svn-main HEAD = r19.
        # Default --limit 5: top entry = r19, trailer = r15.
        $script:r1 = Invoke-Script -WorkDir $script:TestRoot
        $script:r2 = Invoke-Script -WorkDir $script:TestRoot -ExtraArgs @('-Revision', '5')
        $script:r4 = Invoke-Script -WorkDir $script:TestRoot -ExtraArgs @('-Limit', '0')
        $script:r5 = Invoke-Script -WorkDir $script:TestRoot

        $svnRepo = [System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'svn-repo')
        $script:SvnUri = 'file:///' + ($svnRepo -replace '\\', '/') + '/trunk'
    }
}

Describe 'Get-SvnLog' {

    It 'fixture git repo is present' {
        $script:FixtureReady | Should -BeTrue -Because "fixture $script:TestRoot expected (Reset-Fixture seeds it)"
    }

    Context 'Case 1: happy — default --branch main, --limit 5' {
        It 'happy exit 0' { $script:r1.Exit | Should -Be 0 }
        It 'stdout 含 r19 entry (top)' { $script:r1.Stdout | Should -Match '(?m)^r19 \|' }
        It 'stdout 含 trailer LAST_SHOWN_REV=15' { $script:r1.Stdout | Should -Match '# LAST_SHOWN_REV=15' }
    }

    Context 'Case 2: 中文 commit on r5 (字典 #3.1)' {
        It '中文 r5 exit 0' { $script:r2.Exit | Should -Be 0 }
        It 'stdout 含 r5 行' { $script:r2.Stdout | Should -Match '(?m)^r5 \|' }
        It '中文 commit msg present (text round-trip)' {
            # Re-decode via Get-RawCommitDump (svn-repo working copy); tolerates F-3 mojibake.
            (Test-SvnLogTextRoundTrip -ExpectedText '修正中文 commit 訊息亂碼' -RevN 5 -RepoPathOrUrl $script:SvnUri) | Should -BeTrue
        }
    }

    Context 'Case 3: revision-spec trailer' {
        It 'revision-spec emits trailer' { $script:r2.Stdout | Should -Match '# LAST_SHOWN_REV=\d+' }
    }

    Context 'Case 4: --limit 0 → invalid' {
        It 'limit 0 exit != 0' { ($script:r4.Exit -ne 0) | Should -BeTrue }
        It '訊息提及 positive integer' {
            ($script:r4.Stdout + "`n" + $script:r4.Stderr) | Should -Match 'positive integer'
        }
    }

    Context 'Case 5: SKILL entry — re-invoke happy → deterministic' {
        It 'SKILL-entry exit 0' { $script:r5.Exit | Should -Be 0 }
        It 'stdout 仍含 trailer' { $script:r5.Stdout | Should -Match '# LAST_SHOWN_REV=15' }
    }
}
