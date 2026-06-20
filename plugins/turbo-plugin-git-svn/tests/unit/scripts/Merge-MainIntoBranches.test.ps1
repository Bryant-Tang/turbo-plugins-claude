# Merge-MainIntoBranches.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Merge-MainIntoBranches.ps1
#
# New contract (v0.5.0): [-Branch <name>] is [string[]].
#   - No -Branch  -> target = EVERY local branch except 'main' and 'remote-svn/*'.
#   - -Branch X,Y -> target = exactly X,Y. A name that is missing OR excluded
#     (main / remote-svn/*) is reported "SKIP <b> (not found / excluded)" and skipped,
#     never aborting the whole run.
# Preserved behaviour: dirty-main guard; per-branch `git merge --abort` + "CONFLICT <b>"
# marker on conflict (others still merge); original branch restored; Summary; conflict -> exit 1.
#
# Git-only -- no SVN -- so every case runs green. "spirit" preserved from the old
# Merge-MainIntoAll: happy (targets get main tip), exclude (main + remote-svn/* never touched),
# conflict (aborted clean, others merge, original branch restored). NEW: explicit subset run
# (-Branch list) + SKIP-on-missing/excluded.

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Merge-MainIntoBranches.ps1')

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    # Commit a file on the currently-checked-out branch.
    function Add-CommitFile {
        param([string]$Root, [string]$Name, [string]$Content, [string]$Msg)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, $Name), $Content)
        $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
        $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', $Msg)
    }

    # main advanced by 1 commit; two targets (test-x, feature-y) forked BEFORE it (behind main);
    # a remote-svn/main bridge branch that must NOT be touched.
    function New-MergeFixture {
        param([string]$Root)
        New-GitMainRepo -Root $Root
        $null = Run-Git -Cwd $Root -GitArgs @('branch', 'test-x')
        $null = Run-Git -Cwd $Root -GitArgs @('branch', 'feature-y')
        $null = Run-Git -Cwd $Root -GitArgs @('branch', 'remote-svn/main')
        Add-CommitFile -Root $Root -Name 'main-only.txt' -Content 'main tip' -Msg 'feat: main advances'
    }
}

Describe 'Merge-MainIntoBranches' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: happy (no -Branch) -- all eligible targets get main tip; main & remote-svn untouched' {
        It 'exits 0; both targets contain main tip; main & remote-svn/main unchanged' {
            $sb = New-Sandbox -Tag 'mmb-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-MergeFixture -Root $root

                $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
                $remoteBefore = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/main')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
                $res.ExitCode | Should -Be 0

                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'test-x'))   | Should -Be 0
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'feature-y')) | Should -Be 0

                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main'))            | Should -Be $mainSha
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/main')) | Should -Be $remoteBefore

                $res.Stdout | Should -Match 'Merged cleanly:'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 2: exclude -- main & remote-svn/* never appear as merge targets' {
        It 'no "OK main" / "OK remote-svn/*"; test-x & feature-y are merged' {
            $sb = New-Sandbox -Tag 'mmb-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-MergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/test-1')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
                $res.ExitCode | Should -Be 0

                $res.Stdout | Should -Not -Match '(?m)^OK main\b'
                $res.Stdout | Should -Not -Match '(?m)^OK remote-svn/'
                $res.Stdout | Should -Match '(?m)^OK test-x\b'
                $res.Stdout | Should -Match '(?m)^OK feature-y\b'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 3: subset (-Branch list) -- only named branches merged' {
        It 'merges only test-x; feature-y is left behind main' {
            $sb = New-Sandbox -Tag 'mmb-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-MergeFixture -Root $root
                $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'test-x')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match '(?m)^OK test-x\b'

                # test-x merged; feature-y (NOT named) still behind main.
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'test-x'))   | Should -Be 0
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'feature-y')) | Should -Not -Be 0
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 4: missing / excluded -Branch -> SKIP (not found / excluded), run does not abort' {
        # NOTE on arg passing: a multi-element [string[]] cannot be supplied through the test
        # harness's child `powershell.exe -File` invocation (that mode binds an array only from a
        # single unquoted comma token, which the helper's per-arg quoting collapses to one element).
        # So we assert the SKIP-and-don't-abort behaviour with single-element runs: each invalid
        # name is SKIPped and the script ends gracefully (exit 0, "No branches to merge into.")
        # rather than throwing. The "valid targets still merge" half is covered by Cases 1 & 3.
        It 'SKIPs a non-existent branch and exits 0 without aborting' {
            $sb = New-Sandbox -Tag 'mmb-4a'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-MergeFixture -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'no-such')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match '(?m)^SKIP no-such \(not found / excluded\)'
                $res.Stdout | Should -Match 'No branches to merge into\.'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'SKIPs an excluded remote-svn/* branch and exits 0 without touching it' {
            $sb = New-Sandbox -Tag 'mmb-4b'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-MergeFixture -Root $root
                $remoteBefore = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'remote-svn/main')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match '(?m)^SKIP remote-svn/main \(not found / excluded\)'
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/main')) | Should -Be $remoteBefore
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 5: conflict -- aborted clean; non-conflicting branch merges; original restored' {
        It 'exit 1; CONFLICT marker; clean-branch merged; worktree clean; original branch restored' {
            $sb = New-Sandbox -Tag 'mmb-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root

                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'base' -Msg 'feat: add shared'
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'clean-branch')
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'conflict-branch')

                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'conflict-branch')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'branch-version' -Msg 'feat: branch edits shared'

                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'main')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'main-version' -Msg 'feat: main edits shared'
                $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'clean-branch')
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')) | Should -Be 'clean-branch'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
                $res.ExitCode | Should -Be 1

                $res.Stdout | Should -Match '(?m)^CONFLICT conflict-branch\b'
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'conflict-branch')) | Should -Not -Be 0
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'clean-branch'))    | Should -Be 0

                (Run-Git-Capture -Cwd $root -GitArgs @('status', '--porcelain')) | Should -Be ''
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')) | Should -Be 'clean-branch'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 6: git status failure (corrupt index) -> fail-loud, does not merge' {
        It 'exits non-zero on a status failure and never proceeds to a clean merge' {
            $sb = New-Sandbox -Tag 'mmb-6'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-MergeFixture -Root $root
                # Corrupt the index so `git status --porcelain` fails. Get-MainWorktree (runs first,
                # uses rev-parse, does not read the index) still succeeds, so this hits the
                # dirty-check stage. Safety contract: the script fails loud and does NOT silently
                # treat the tree as clean and merge.
                # NOTE: on PS 5.1 with EAP=Stop, 2>$null does NOT prevent the NativeCommandError
                # when git writes to stderr (empirically verified), so the corrupt-index failure
                # surfaces git's own fatal ("...index file...") at the status call here; the
                # script's $LASTEXITCODE guard is the fallback for a silent non-zero exit. Hence
                # we assert the index/status failure text, not the guard's message.
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, '.git', 'index'), 'garbage-not-a-git-index')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
                $res.ExitCode | Should -Not -Be 0
                # Failed at the status/index stage, not elsewhere. Accept EITHER git's native
                # fatal (the EAP=Stop path -- 'index file') OR the script's own guard message
                # (the rare silent-exit path) -- precise without coupling to one git version's wording.
                $res.Combined | Should -Match 'index file|git status --porcelain failed'
                $res.Stdout   | Should -Not -Match 'Merged cleanly'  # never reached a successful merge
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
