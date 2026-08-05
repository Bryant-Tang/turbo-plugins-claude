# Tag-Release.test.ps1 (Pester 5)
#
# Tests for plugins/turbo-plugin-git-svn/scripts/Tag-Release.ps1.
#
# Scope (U9 plan):
#   - happy:           on a fixture repo with a remote-svn/test-1 branch, --branch test-1
#                      creates a tag test-1-release-<date>-001 pointing at remote-svn/test-1.
#                      (Covers AE1's tag part — tag points at remote-svn/<branch>.)
#   - serial increment: run twice same day → -001 then -002.
#   - ref naming:      tag points at remote-svn/test-<n>, NOT remote/test-<n>.
#   - arg validation:  missing -Branch → exit non-zero + stderr.
#
# Git-only (no SVN needed for the tag). Uses shared ScriptsCommon.ps1 helpers; no hardcoded paths.

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # ScriptsCommon.ps1 provides New-Sandbox / Remove-Sandbox / New-GitMainRepo / Invoke-PsScript /
    # Run-Git / Run-Git-Capture. (AssertHelpers.ps1 NOT sourced — asserts use Pester Should.)
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Tag-Release.ps1')
    $script:ScriptExists    = [System.IO.File]::Exists($script:ScriptUnderTest)
    $script:Today           = (Get-Date -Format 'yyyy-MM-dd')

    # Build a main repo + a remote-svn/test-N branch ref (tip = main + 1 extra commit).
    # The tag only needs the branch ref to exist; no linked worktree / SVN required.
    function New-RepoWithRemoteSvnTestBranch {
        param([string]$Root, [int]$N = 1)
        New-GitMainRepo -Root $Root
        $remoteBranch = "remote-svn/test-$N"
        $null = Run-Git -Cwd $Root -GitArgs @('checkout', '-b', $remoteBranch)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, "remote-svn-test-$N.txt"), "remote-svn/test-$N tip")
        $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
        $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', "feat: remote-svn/test-$N tip")
        $null = Run-Git -Cwd $Root -GitArgs @('checkout', 'main')
    }
}

Describe 'Tag-Release' {

    It 'script-under-test exists' {
        $script:ScriptExists | Should -BeTrue -Because "expected at $script:ScriptUnderTest"
    }

    Context 'Case 1: happy — --branch test-1 → tag test-1-release-DATE-001 == remote-svn/test-1' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'tagrel-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-RepoWithRemoteSvnTestBranch -Root $root -N 1
                $script:res1        = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
                $script:expectedTag = "test-1-release-$($script:Today)-001"
                $script:tagList1    = Run-Git-Capture -Cwd $root -GitArgs @('tag', '-l', $script:expectedTag)
                $script:tagSha1     = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', $script:expectedTag)
                $script:remoteSha1  = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/test-1')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'tag-release exit 0' {
            $script:res1.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res1.Stdout)`nstderr:`n$($script:res1.Stderr)"
        }
        It 'stdout reports created tag' {
            $script:res1.Stdout | Should -Match ([regex]::Escape("Created tag: $($script:expectedTag)"))
        }
        It 'tag exists' { $script:tagList1 | Should -Be $script:expectedTag }
        It 'tag SHA == remote-svn/test-1 SHA' { $script:tagSha1 | Should -Be $script:remoteSha1 }
    }

    Context 'Case 2: serial increment — two runs same day → -001 then -002' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'tagrel-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-RepoWithRemoteSvnTestBranch -Root $root -N 1
                $script:res2a = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
                $script:res2b = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'first run exit 0' { $script:res2a.ExitCode | Should -Be 0 -Because "stderr:`n$($script:res2a.Stderr)" }
        It 'first run -001' { $script:res2a.Stdout | Should -Match ([regex]::Escape("test-1-release-$($script:Today)-001")) }
        It 'second run exit 0' { $script:res2b.ExitCode | Should -Be 0 -Because "stderr:`n$($script:res2b.Stderr)" }
        It 'second run -002' { $script:res2b.Stdout | Should -Match ([regex]::Escape("test-1-release-$($script:Today)-002")) }
    }

    Context 'Case 3: ref naming — tag resolves to remote-svn/test-1, and remote/test-1 does not exist' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'tagrel-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-RepoWithRemoteSvnTestBranch -Root $root -N 1
                $script:res3      = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
                $tagName          = "test-1-release-$($script:Today)-001"
                $script:oldRefRc3 = Run-Git -Cwd $root -GitArgs @('rev-parse', '--verify', 'remote/test-1')
                $script:tagSha3   = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', $tagName)
                $script:remoteSha3 = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/test-1')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'tag-release exit 0' { $script:res3.ExitCode | Should -Be 0 -Because "stderr:`n$($script:res3.Stderr)" }
        It 'remote/test-1 does NOT exist (old naming absent)' { ($script:oldRefRc3 -ne 0) | Should -BeTrue }
        It 'tag points at remote-svn/test-1 (new naming)' { $script:tagSha3 | Should -Be $script:remoteSha3 }
    }

    Context 'Case 4: missing -Branch → exit non-zero + stderr mentions branch' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'tagrel-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-RepoWithRemoteSvnTestBranch -Root $root -N 1
                $script:res4 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'missing -Branch exits non-zero' { ($script:res4.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions Branch' { $script:res4.Combined | Should -Match '(?i)branch' }
    }
}
