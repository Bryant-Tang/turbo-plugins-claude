# Merge-MainIntoBranches.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Merge-MainIntoBranches.ps1
#
# New contract: [-Branch <name>] is [string[]].
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

    # Under EAP=Stop, a `2>` redirection on a native command makes PS 5.1 wrap ANY stderr output as
    # a TERMINATING NativeCommandError -- `2>$null` does not prevent it (measured). git writes to
    # stderr on a perfectly healthy repo whose owner differs from the caller ("detected dubious
    # ownership": CI images, containers, a clone made under another account). The rollback
    # `git merge --abort` used to be written that way, so on those machines the throw landed BEFORE
    # the abort: the conflicted merge stayed in progress, the remaining branches were never
    # attempted, and the original branch was never restored (issue #128; the same shape was
    # reproduced on Request-Merge.ps1 in #127).
    #
    # The shim warns on EVERY git call. It started out warning only on `--abort`, because this
    # script's own reads still captured with `2>$null` and would have failed first, leaving the case
    # measuring them rather than the rollback. Those reads now go through Read-Git too, so the
    # narrowing is gone -- which makes this the end-to-end version: the whole call chain, shared
    # library included, has to survive a git that warns on every single invocation.
    # (Request-Merge.test.ps1 was widened the same way after #123 fixed Core.ps1.)
    # Numbered 5b rather than 7: this is Case 5's scenario re-run against a git that warns, so it
    # belongs next to it -- and appending it as 7 would have left the file reading 1,2,3,4,5,7,6.
    Context 'Case 5b (issue #128): a git that warns on stderr must not skip the conflict rollback' {
        It 'aborts the merge, keeps going, and restores the original branch' {
            $sb = New-Sandbox -Tag 'mmb-5b'
            $shimDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'tp-shim-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $savedPath = $env:PATH
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root

                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'base' -Msg 'feat: add shared'
                # Named so the CONFLICTING branch sorts FIRST: `git branch --format` lists
                # alphabetically, so with the clean branch first a rollback that killed the loop
                # would still leave it merged and the case would pass while broken.
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'aaa-conflict')
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'zzz-clean')

                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'aaa-conflict')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'branch-version' -Msg 'feat: branch edits shared'

                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'main')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'main-version' -Msg 'feat: main edits shared'
                $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'zzz-clean')

                $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
                $null = New-Item -ItemType Directory -Path $shimDir -Force
                [System.IO.File]::WriteAllLines(
                    [System.IO.Path]::Combine($shimDir, 'git.cmd'),
                    @(
                        '@echo off',
                        'echo warning: detected dubious ownership in repository 1>&2',
                        ('"' + $realGit + '" %*')
                    ),
                    [System.Text.Encoding]::ASCII)

                $env:PATH = $shimDir + ';' + $savedPath

                # Precondition: prove the shim actually resolves before trusting anything this case
                # concludes -- a shim that never loads produces a pass that means nothing. Both a
                # read and the rollback command are probed, since the point is that EVERY call warns.
                $probeErr = [System.IO.Path]::Combine($shimDir, 'probe.err')
                & cmd.exe /c "git --version 2> `"$probeErr`"" | Out-Null
                [System.IO.File]::ReadAllText($probeErr) | Should -Match 'dubious ownership'
                & cmd.exe /c "git merge --abort 2> `"$probeErr`"" | Out-Null
                [System.IO.File]::ReadAllText($probeErr) | Should -Match 'dubious ownership'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()

                # STATE, not messages: printing the right thing while leaving the tree wedged is the
                # failure this case exists to catch, and it prints the right thing either way.
                [System.IO.File]::Exists([System.IO.Path]::Combine($root, '.git', 'MERGE_HEAD')) | Should -BeFalse
                (Run-Git-Capture -Cwd $root -GitArgs @('status', '--porcelain')) | Should -Be ''
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')) | Should -Be 'zzz-clean'

                # The loop survived the conflicting branch and reached the one after it.
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'zzz-clean'))    | Should -Be 0
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'aaa-conflict')) | Should -Not -Be 0

                $res.ExitCode | Should -Be 1
                $res.Stdout | Should -Match '(?m)^CONFLICT aaa-conflict\b'
            } finally {
                $env:PATH = $savedPath
                Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
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
                # The status read now goes through Read-Git (issue #128), so the script's own
                # $LASTEXITCODE guard is what fires here -- it is no longer a fallback behind a
                # NativeCommandError thrown by the `2>` redirect before the guard could run. The
                # assertion below already accepted both wordings, so it stayed green across that
                # change; this note replaces the old one, which described the opposite mechanism.
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, '.git', 'index'), 'garbage-not-a-git-index')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
                $res.ExitCode | Should -Not -Be 0
                # Failed at the status/index stage, not elsewhere. Both wordings stay accepted:
                # the guard's message is the expected one now, and git's own fatal ('index file')
                # would still be correct evidence of the same stage failing.
                $res.Combined | Should -Match 'index file|git status --porcelain failed'
                $res.Stdout   | Should -Not -Match 'Merged cleanly'  # never reached a successful merge
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
