# Replay-Primitives.test.ps1 (Pester 5)
#
# Unit coverage for the U1 per-revision SVN replay primitives in scripts/lib/Common.ps1:
#   - Get-SvnRevisions      parse `svn log --xml` -> ascending { Rev; Author; Date; Message }
#   - Invoke-SvnReplayCommit  one SVN revision -> one git commit (author/date/trailer, skips)
#   - Get-SvnFloorCommit    newest `main` commit whose svn-revision trailer value is <= R
#
# svn is NEVER invoked: enumeration is fed a SYNTHETIC `svn log --xml` string, and replay/floor
# run against a throwaway git repo under $TestDrive. So every case runs on every host (no SKIP).
#
# This file is intentionally pure ASCII: the CJK sample is built from Unicode code points
# ([char]0xXXXX) so the .ps1 needs no UTF-8 BOM to survive PS 5.1 on a CP950 console.

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $script:PluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    . ([System.IO.Path]::Combine($script:PluginRoot, 'scripts', 'lib', 'Common.ps1'))

    # git may warn on stderr; Common.ps1 pins EAP=Stop, so wrap fixture git calls to soften it.
    function Invoke-GitQuiet {
        $a = $args
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & git @a 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $old }
    }
    function Get-GitOut {
        $a = $args
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $o = $null
        try { $o = & git @a 2>$null } catch { $o = $null } finally { $ErrorActionPreference = $old }
        return ((@($o) -join "`n").Trim())
    }

    function New-ScratchRepo {
        param([Parameter(Mandatory = $true)][string]$Base)
        $repo = [System.IO.Path]::Combine($Base, [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $repo
        Invoke-GitQuiet -C $repo init -q -b main
        if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($repo, '.git'))) {
            Invoke-GitQuiet -C $repo init -q
            Invoke-GitQuiet -C $repo checkout -q -b main
        }
        Invoke-GitQuiet -C $repo config user.email 'test@turbo.invalid'
        Invoke-GitQuiet -C $repo config user.name 'Turbo Test'
        Invoke-GitQuiet -C $repo config core.autocrlf false
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'seed.txt')) -Value 'seed'
        Invoke-GitQuiet -C $repo add -A
        Invoke-GitQuiet -C $repo -c commit.gpgsign=false commit -q -m 'seed'
        return $repo
    }
    function Commit-WithTrailer {
        param([string]$Repo, [string]$File, [string]$Content, [string]$Subject, [int]$Rev)
        Set-Content -LiteralPath ([System.IO.Path]::Combine($Repo, $File)) -Value $Content
        Invoke-GitQuiet -C $Repo add -A
        Invoke-GitQuiet -C $Repo -c commit.gpgsign=false commit -q -m $Subject -m ("svn-revision: " + $Rev)
    }

    # CJK sample built from code points (keeps this file ASCII): U+4FEE U+6B63 U+4E2D U+6587 U+8A0A U+606F
    $script:Cjk = -join ([char]0x4FEE, [char]0x6B63, [char]0x4E2D, [char]0x6587, [char]0x8A0A, [char]0x606F)

    # Synthetic `svn log --xml` (descending, as svn emits): r7 entities / r5 CJK / r3 multi-line.
    $script:SampleXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry revision="7"><author>alice</author><date>2026-05-26T12:00:00.000000Z</date><msg>fix &lt;tag&gt; &amp; done</msg></logentry>
<logentry revision="5"><author>carol</author><date>2026-05-22T00:00:00.000000Z</date><msg>$($script:Cjk)</msg></logentry>
<logentry revision="3"><author>bob</author><date>2026-05-20T09:00:00.000000Z</date><msg>line one
line two</msg></logentry>
</log>
"@
}

Describe 'Get-SvnRevisions' {
    It 'enumerates three revisions in ascending order' {
        $revs = Get-SvnRevisions -LogXml $script:SampleXml
        $revs.Count | Should -Be 3
        $revs[0].Rev | Should -Be 3
        $revs[1].Rev | Should -Be 5
        $revs[2].Rev | Should -Be 7
        $revs[0].Author | Should -Be 'bob'
        $revs[2].Date | Should -Be '2026-05-26T12:00:00.000000Z'
    }
    It 'decodes XML entities in the message' {
        $revs = Get-SvnRevisions -LogXml $script:SampleXml
        ($revs | Where-Object { $_.Rev -eq 7 }).Message | Should -Be 'fix <tag> & done'
    }
    It 'round-trips a CJK message with no mojibake' {
        $revs = Get-SvnRevisions -LogXml $script:SampleXml
        ($revs | Where-Object { $_.Rev -eq 5 }).Message | Should -Be $script:Cjk
    }
    It 'preserves a multi-line message' {
        $revs = Get-SvnRevisions -LogXml $script:SampleXml
        $lines = ($revs | Where-Object { $_.Rev -eq 3 }).Message -split "`n"
        $lines[0] | Should -Be 'line one'
        $lines[1] | Should -Be 'line two'
    }
    It 'returns an empty array for a log document with no entries' {
        $revs = Get-SvnRevisions -LogXml '<?xml version="1.0"?><log></log>'
        @($revs).Count | Should -Be 0
    }
}

Describe 'Invoke-SvnReplayCommit' {
    It 'commits with the raw username as author name, an empty author email, the SVN author-date, and the svn-revision trailer' {
        $repo = New-ScratchRepo -Base $TestDrive
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'f7.txt')) -Value 'feature'
        $result = Invoke-SvnReplayCommit -RepoDir $repo -Rev 7 -Author 'alice' -Date '2026-05-26T12:00:00.000000Z' -Message 'add feature'
        $result | Should -Match '^COMMIT:'
        (Get-GitOut -C $repo log -1 --format='%an') | Should -Be 'alice'
        (Get-GitOut -C $repo log -1 --format='%ae') | Should -Be ''
        (Get-GitOut -C $repo log -1 --format='%aI') | Should -Match '^2026-05-26T12:00:00'
        (Get-GitOut -C $repo log -1 --format='%(trailers:key=svn-revision,valueonly)') | Should -Be '7'
        (Get-GitOut -C $repo log -1 --format='%s') | Should -Be 'add feature'
    }
    It 'commits a CJK message without mojibake' {
        $repo = New-ScratchRepo -Base $TestDrive
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'c.txt')) -Value 'cjk'
        $null = Invoke-SvnReplayCommit -RepoDir $repo -Rev 5 -Author 'carol' -Date '2026-05-22T00:00:00.000000Z' -Message $script:Cjk
        (Get-GitOut -C $repo log -1 --format='%s') | Should -Be $script:Cjk
    }
    It "keeps a '#'-leading message line (cleanup=whitespace, not strip)" {
        $repo = New-ScratchRepo -Base $TestDrive
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'h.txt')) -Value 'x'
        $null = Invoke-SvnReplayCommit -RepoDir $repo -Rev 8 -Author 'bob' -Date '2026-05-27T00:00:00.000000Z' -Message "#42 hotfix`nbody"
        # Assert on the raw body (%B): the '#42 hotfix' line must survive (default 'strip' cleanup
        # would delete a '#' commentary line). %s is NOT used because git's subject collapses a
        # no-blank-line paragraph onto one line.
        (Get-GitOut -C $repo log -1 --format='%B') | Should -Match '#42 hotfix'
    }
    It 'signals SKIP:empty and mints no commit on an empty delta' {
        $repo = New-ScratchRepo -Base $TestDrive
        $before = [int](Get-GitOut -C $repo rev-list --count HEAD)
        $result = Invoke-SvnReplayCommit -RepoDir $repo -Rev 9 -Author 'bob' -Date '2026-05-28T00:00:00.000000Z' -Message 'no change'
        $result | Should -Be 'SKIP:empty'
        [int](Get-GitOut -C $repo rev-list --count HEAD) | Should -Be $before
    }
    It 'signals SKIP:idempotent and mints no duplicate when the trailer already exists' {
        $repo = New-ScratchRepo -Base $TestDrive
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'r11.txt')) -Value 'one'
        $null = Invoke-SvnReplayCommit -RepoDir $repo -Rev 11 -Author 'carol' -Date '2026-05-29T00:00:00.000000Z' -Message 'rev eleven'
        $before = [int](Get-GitOut -C $repo rev-list --count HEAD)
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'r11.txt')) -Value 'changed'
        $result = Invoke-SvnReplayCommit -RepoDir $repo -Rev 11 -Author 'carol' -Date '2026-05-29T00:00:00.000000Z' -Message 'rev eleven again'
        $result | Should -Be 'SKIP:idempotent'
        [int](Get-GitOut -C $repo rev-list --count HEAD) | Should -Be $before
    }

    It 'defangs a trailer-lookalike line in the message so the trailer scans are not fooled' {
        # A crafted/accidental `svn-revision: <N>` line in the message BODY must not fool the
        # trailer scans (max-trailer / idempotency). Only the tool's own appended trailer is real.
        $repo = New-ScratchRepo -Base $TestDrive
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'r5.txt')) -Value 'one'
        $null = Invoke-SvnReplayCommit -RepoDir $repo -Rev 5 -Author 'dave' -Date '2026-05-25T00:00:00.000000Z' -Message "legit work`nsvn-revision: 999"
        # The lookalike 999 must not be counted; the real trailer is r5.
        Get-SvnMaxTrailerRev -RepoDir $repo -Ref 'main' | Should -Be 5
        # A genuinely new r999 must still replay (the earlier lookalike must not mask it as present).
        Set-Content -LiteralPath ([System.IO.Path]::Combine($repo, 'r999.txt')) -Value 'two'
        $out2 = Invoke-SvnReplayCommit -RepoDir $repo -Rev 999 -Author 'dave' -Date '2026-05-30T00:00:00.000000Z' -Message 'real 999'
        $out2 | Should -Match '^COMMIT:'
        Get-SvnMaxTrailerRev -RepoDir $repo -Ref 'main' | Should -Be 999
    }
}

Describe 'Get-SvnFloorCommit' {
    It 'returns the nearest commit <= R when there is no exact match' {
        $repo = New-ScratchRepo -Base $TestDrive
        Commit-WithTrailer -Repo $repo -File 'a.txt' -Content 'aa' -Subject 'trunk five' -Rev 5
        Commit-WithTrailer -Repo $repo -File 'b.txt' -Content 'bb' -Subject 'trunk ten' -Rev 10
        $sha5 = Get-GitOut -C $repo log --grep='^svn-revision: 5$' -E --format='%H' main
        $sha10 = Get-GitOut -C $repo log --grep='^svn-revision: 10$' -E --format='%H' main
        (Get-SvnFloorCommit -RepoDir $repo -TargetRev 7)  | Should -Be $sha5
        (Get-SvnFloorCommit -RepoDir $repo -TargetRev 10) | Should -Be $sha10
        (Get-SvnFloorCommit -RepoDir $repo -TargetRev 20) | Should -Be $sha10
    }
    It 'returns $null when no commit <= R exists' {
        $repo = New-ScratchRepo -Base $TestDrive
        Commit-WithTrailer -Repo $repo -File 'a.txt' -Content 'aa' -Subject 'trunk five' -Rev 5
        Get-SvnFloorCommit -RepoDir $repo -TargetRev 3 | Should -BeNullOrEmpty
    }
    It 'throws (fails loud) when the chosen value is carried by two commits' {
        $repo = New-ScratchRepo -Base $TestDrive
        Commit-WithTrailer -Repo $repo -File 'a.txt' -Content 'aa' -Subject 'dup one' -Rev 4
        Commit-WithTrailer -Repo $repo -File 'b.txt' -Content 'bb' -Subject 'dup two' -Rev 4
        { Get-SvnFloorCommit -RepoDir $repo -TargetRev 6 } | Should -Throw -ExpectedMessage '*ambiguous*'
    }
    It 'is scoped to main and ignores a trailer that lives only off-main' {
        $repo = New-ScratchRepo -Base $TestDrive
        Commit-WithTrailer -Repo $repo -File 'a.txt' -Content 'aa' -Subject 'trunk five' -Rev 5
        Invoke-GitQuiet -C $repo checkout -q -b side
        Commit-WithTrailer -Repo $repo -File 'side.txt' -Content 'ss' -Subject 'side ninety-nine' -Rev 99
        Invoke-GitQuiet -C $repo checkout -q main
        $sha5 = Get-GitOut -C $repo log --grep='^svn-revision: 5$' -E --format='%H' main
        (Get-SvnFloorCommit -RepoDir $repo -TargetRev 99) | Should -Be $sha5
    }
}
