# Request-Merge.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Request-Merge.ps1
#
# Contract (identical to the .sh sibling):
#   Request-Merge.ps1 -Branch <name> [-Base <name>] [-Merge] [-RepoRoot <path>]
#   Emits exactly ONE 'TP_TOKEN:' line. Precedence:
#     ERROR > BRANCH_IS_BASE > BRANCH_NOT_FOUND > BASE_NOT_FOUND > SOURCE_DIRTY
#           > MAIN_DIRTY > MAIN_DETACHED > BASE_ELSEWHERE > NOTHING_TO_MERGE
#           > READY (report) | MERGED / CONFLICT (-Merge)
#
# Every token above has a case here that actually produces it. A guard nothing can reach is a
# guard that will not be there when it is needed, and it looks identical to one that works.
#
# Git-only -- no SVN -- so every case runs green on both runners. This file is deliberately
# pure ASCII: a .ps1 carrying non-ASCII needs a UTF-8 BOM to survive PS 5.1 on a Big5 system
# codepage, and staying ASCII removes that dependency outright.

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Request-Merge.ps1')

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    function Add-CommitFile {
        param([string]$Root, [string]$Name, [string]$Content, [string]$Msg)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, $Name), $Content)
        $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
        $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', $Msg)
    }

    # main + a `feat` branch two commits ahead; main worktree left on `main`.
    function New-RequestMergeFixture {
        param([string]$Root)
        New-GitMainRepo -Root $Root
        $null = Run-Git -Cwd $Root -GitArgs @('checkout', '-b', 'feat')
        Add-CommitFile -Root $Root -Name 'b.txt' -Content 'b' -Msg 'feat: add b'
        Add-CommitFile -Root $Root -Name 'c.txt' -Content 'c' -Msg 'feat: add c'
        $null = Run-Git -Cwd $Root -GitArgs @('checkout', 'main')
    }

    # A peer worktree that silently failed to be created leaves an ordinary directory behind,
    # and every assertion downstream then passes for the wrong reason. Verified, not assumed.
    function Add-PeerWorktree {
        param([string]$Root, [string]$Path, [string]$Branch)
        $null = Run-Git -Cwd $Root -GitArgs @('worktree', 'add', $Path, $Branch)
        $marker = [System.IO.Path]::Combine($Path, '.git')
        if (-not (Test-Path -LiteralPath $marker)) {
            throw "fixture: '$Path' is not a linked worktree -- git worktree add failed silently"
        }
    }

    function Get-Token {
        param([string]$Text)
        $lines = @(($Text -replace "`r", '') -split "`n" | Where-Object { $_ -like 'TP_TOKEN:*' })
        if ($lines.Count -eq 0) { return '' }
        return $lines[0]
    }

    function Get-TokenCount {
        param([string]$Text)
        return @(($Text -replace "`r", '') -split "`n" | Where-Object { $_ -like 'TP_TOKEN:*' }).Count
    }
}

Describe 'Request-Merge' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: report mode is READY and changes nothing' {
        It 'emits one READY token and leaves main where it was' {
            $sb = New-Sandbox -Tag 'rqm-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $before = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')

                $res.ExitCode | Should -Be 0
                Get-TokenCount $res.Stdout | Should -Be 1
                # The main= path spelling is platform-dependent; pin the stable fields and only
                # require the path to be non-empty.
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:READY branch=feat base=main ahead=2 main=.'
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')) | Should -Be $before
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'lists the commit subjects and the diffstat' {
            $sb = New-Sandbox -Tag 'rqm-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                $res.Stdout | Should -Match 'feat: add b'
                $res.Stdout | Should -Match 'feat: add c'
                $res.Stdout | Should -Match 'ahead  : 2 commit'
                $res.Stdout | Should -Match 'behind : 0 commit'
                $res.Stdout | Should -Match '2 files changed'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 2: lookup failures' {
        It 'BRANCH_NOT_FOUND for an unknown branch' {
            $sb = New-Sandbox -Tag 'rqm-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'nope')
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:BRANCH_NOT_FOUND branch=nope'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'BASE_NOT_FOUND for an unknown base' {
            $sb = New-Sandbox -Tag 'rqm-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Base', 'nosuch')
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:BASE_NOT_FOUND base=nosuch'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'BRANCH_IS_BASE when source and target are the same' {
            $sb = New-Sandbox -Tag 'rqm-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:BRANCH_IS_BASE branch=main'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # As base it would merge work INTO the bridge; as branch it does tp-pull-from-svn's job
        # without any of its bookkeeping. Refused by name, so it holds even when the bridge exists.
        It 'BRIDGE_BRANCH when remote-svn/* is the base' {
            $sb = New-Sandbox -Tag 'rqm-20'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Base', 'remote-svn/main')
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:BRIDGE_BRANCH name=remote-svn/main'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'BRIDGE_BRANCH when remote-svn/* is the source' {
            $sb = New-Sandbox -Tag 'rqm-21'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'remote-svn/main')
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:BRIDGE_BRANCH name=remote-svn/main'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # The refusal must not swallow ordinary branches that merely start with similar text.
        It 'a branch merely NAMED like the bridge prefix is not refused' {
            $sb = New-Sandbox -Tag 'rqm-22'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn-ish', 'feat')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'remote-svn-ish')
                (Get-Token $res.Stdout) | Should -Not -Match '^TP_TOKEN:BRIDGE_BRANCH'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'a malformed ref name is a HARD, TOKENLESS error (anti-forge)' {
            $sb = New-Sandbox -Tag 'rqm-6'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'bad..name')
                $res.ExitCode | Should -Be 1
                Get-TokenCount $res.Combined | Should -Be 0
                $res.Combined | Should -Match 'not a valid branch name'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 3: state guards' {
        It 'MAIN_DIRTY when the main worktree has uncommitted changes' {
            $sb = New-Sandbox -Tag 'rqm-7'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'dirt.txt'), 'dirt')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:MAIN_DIRTY path=.'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # The guard this script exists for. The branch lives in a peer worktree with work that
        # was never committed: merging now would ship less than what was built, and the `remove`
        # that follows would delete the rest.
        It 'SOURCE_DIRTY when the branch worktree has uncommitted work' {
            $sb = New-Sandbox -Tag 'rqm-8'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $peer = [System.IO.Path]::Combine($sb, 'wt')
                Add-PeerWorktree -Root $root -Path $peer -Branch 'feat'
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($peer, 'pending.txt'), 'not committed')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:SOURCE_DIRTY path=.'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # Without this, the case above would pass just as happily if the guard fired always.
        It 'a CLEAN peer worktree still reports READY' {
            $sb = New-Sandbox -Tag 'rqm-9'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                Add-PeerWorktree -Root $root -Path ([System.IO.Path]::Combine($sb, 'wt')) -Branch 'feat'
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:READY '
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'MAIN_DETACHED when the main worktree is on a detached HEAD' {
            $sb = New-Sandbox -Tag 'rqm-10'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('checkout', '--detach')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:MAIN_DETACHED path=.'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'BASE_ELSEWHERE when base is checked out in another worktree' {
            $sb = New-Sandbox -Tag 'rqm-11'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('checkout', '-b', 'parked')
                Add-PeerWorktree -Root $root -Path ([System.IO.Path]::Combine($sb, 'wt')) -Branch 'main'
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:BASE_ELSEWHERE base=main path=.'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 4: the merge itself' {
        It 'merges, makes a real merge commit, and returns to the branch it started on' {
            $sb = New-Sandbox -Tag 'rqm-12'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $featSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feat')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')

                $res.ExitCode | Should -Be 0
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:MERGED branch=feat base=main commit=.'
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $featSha, 'main')) | Should -Be 0
                # "<sha> <p1> <p2>" => 3 fields for a merge. --no-ff is what makes this a merge
                # commit rather than a fast-forward, so this notices if --no-ff is ever dropped.
                $parents = Run-Git-Capture -Cwd $root -GitArgs @('rev-list', '--parents', '-n', '1', 'main')
                @($parents -split '\s+' | Where-Object { $_ -ne '' }).Count | Should -Be 3
                (Run-Git-Capture -Cwd $root -GitArgs @('symbolic-ref', '--short', 'HEAD')) | Should -Be 'main'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'restores a non-base original branch rather than leaving HEAD on base' {
            $sb = New-Sandbox -Tag 'rqm-13'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('checkout', '-b', 'parked')
                $null = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')
                (Run-Git-Capture -Cwd $root -GitArgs @('symbolic-ref', '--short', 'HEAD')) | Should -Be 'parked'
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', 'feat', 'main')) | Should -Be 0
            } finally { Remove-Sandbox -Dir $sb }
        }

        # The single-worktree everyday shape: you are standing ON the branch you want merged.
        # It exercises checkout-base -> merge -> checkout-back where "back" is the source branch
        # itself, which the 'parked' case above (a third, unrelated branch) does not reach.
        It 'merges while the main worktree is sitting on the source branch' {
            $sb = New-Sandbox -Tag 'rqm-19'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'feat')
                (Run-Git-Capture -Cwd $root -GitArgs @('symbolic-ref', '--short', 'HEAD')) | Should -Be 'feat'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')

                $res.ExitCode | Should -Be 0
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:MERGED branch=feat base=main commit=.'
                (Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', 'feat', 'main')) | Should -Be 0
                (Run-Git-Capture -Cwd $root -GitArgs @('symbolic-ref', '--short', 'HEAD')) | Should -Be 'feat'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'NOTHING_TO_MERGE once the branch is already in' {
            $sb = New-Sandbox -Tag 'rqm-14'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:NOTHING_TO_MERGE branch=feat base=main'
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'CONFLICT leaves base exactly as it was, with no merge state behind' {
            $sb = New-Sandbox -Tag 'rqm-15'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('checkout', '-b', 'clash', 'main')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'from-clash' -Msg 'clash side'
                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'main')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'from-main' -Msg 'main side'
                $before = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'clash', '-Merge')

                $res.ExitCode | Should -Be 1
                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:CONFLICT branch=clash base=main'
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')) | Should -Be $before
                (Test-Path -LiteralPath ([System.IO.Path]::Combine($root, '.git', 'MERGE_HEAD'))) | Should -BeFalse
                (Run-Git-Capture -Cwd $root -GitArgs @('symbolic-ref', '--short', 'HEAD')) | Should -Be 'main'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # The reason report and merge live in one script: the gate the user was shown and the
        # gate that admits the merge are the same code, so a report that has gone stale cannot
        # let a merge through.
        It '-Merge re-runs the guards and refuses on a report that has gone stale' {
            $sb = New-Sandbox -Tag 'rqm-16'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $peer = [System.IO.Path]::Combine($sb, 'wt')
                Add-PeerWorktree -Root $root -Path $peer -Branch 'feat'

                $first = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')
                (Get-Token $first.Stdout) | Should -Match '^TP_TOKEN:READY '

                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($peer, 'late.txt'), 'appeared later')
                $before = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:SOURCE_DIRTY '
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')) | Should -Be $before
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 5: routing hygiene' {
        It 'a -RepoRoot that does not exist routes as ERROR rather than crashing bare' {
            $sb = New-Sandbox -Tag 'rqm-17'
            try {
                $missing = [System.IO.Path]::Combine($sb, 'no-such-dir')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $sb -ScriptArgs @('-Branch', 'feat', '-RepoRoot', $missing)
                $res.ExitCode | Should -Be 1
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:ERROR reason=.'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # This one CANNOT use New-Sandbox. Sandboxes live under tests/.sandbox/, which is inside
        # this repository, so a directory created there is inside a git worktree by construction
        # -- the exact condition the case needs to negate. An earlier version of this test did
        # use New-Sandbox: the script then walked up, found the REAL repository, and answered
        # BRANCH_NOT_FOUND about it. Read-only, so nothing was harmed, but the case was testing
        # something else entirely while looking like it worked.
        It 'a working directory outside any repository routes as ERROR' {
            $outside = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'tp-rqm-out-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $outside -Force
            try {
                # Precondition: prove it really is outside a repository before trusting the verdict.
                $probe = Run-Git -Cwd $outside -GitArgs @('rev-parse', '--git-dir')
                $probe | Should -Not -Be 0

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $outside -ScriptArgs @('-Branch', 'feat')
                $res.ExitCode | Should -Be 1
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:ERROR reason=.'
            } finally {
                Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Under EAP=Stop a native git call whose output PowerShell CAPTURES is wrapped as a
        # terminating NativeCommandError the moment git writes ANYTHING to stderr -- and git
        # warns on stderr while still exiting 0 (`detected dubious ownership` is the everyday
        # instance: a repo owned by another user, the normal state in CI images and agent
        # containers). The requirement is not merely "say something" -- it is that this answers
        # exactly what request-merge.sh answers, because the two are supposed to be one tool
        # with two implementations. `Read-Git` drops EAP to Continue for the duration of each
        # read, which is what keeps a warning from pre-empting the exit-code check.
        #
        # The shim warns on EVERY call. It used to warn only for `worktree` subcommands, because
        # Probe-GitVersion and Get-MainWorktree in the shared Core.ps1 still captured git output
        # the old way and would have failed first, leaving the case measuring them rather than
        # this script. Core.ps1 goes through its own Read-Git as of issue #123, so the narrowing
        # is gone -- which makes this the end-to-end version of that fix: the whole call chain,
        # shared library included, has to survive a git that warns on every single invocation.
        It 'a git that warns on stderr still produces the normal answer, same as the .sh twin' {
            $sb = New-Sandbox -Tag 'rqm-23'
            $shimDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'tp-shim-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $savedPath = $env:PATH
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root

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

                # Precondition: prove the shim is doing exactly what the case assumes before
                # trusting anything it concludes. A shim that never resolves produces a pass
                # that means nothing.
                # stderr goes to a file rather than being folded in: this asks about stderr
                # specifically, and it keeps the lint's `2>&1`-on-a-native-exe rule satisfied
                # (the redirect here would be cmd's own, not PowerShell's, but the rule cannot
                # see that difference and there is no reason to make it guess).
                $probeErr = [System.IO.Path]::Combine($shimDir, 'probe.err')
                & cmd.exe /c "git --version 2> `"$probeErr`"" | Out-Null
                [System.IO.File]::ReadAllText($probeErr) | Should -Match 'dubious ownership'
                & cmd.exe /c "git worktree list 2> `"$probeErr`"" | Out-Null
                [System.IO.File]::ReadAllText($probeErr) | Should -Match 'dubious ownership'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')

                Get-TokenCount $res.Stdout | Should -Be 1
                (Get-Token $res.Stdout) | Should -Match '^TP_TOKEN:READY branch=feat base=main ahead=2 '
                $res.ExitCode | Should -Be 0
                # And the warning must not have leaked into the values either -- that is the
                # other half of the same bug, and it would surface as a dirty verdict.
                $res.Stdout | Should -Not -Match 'DIRTY'

                # The write path too, not just the report: it is the half where being wrong
                # costs something.
                $merged = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')
                (Get-Token $merged.Stdout) | Should -Match '^TP_TOKEN:MERGED branch=feat base=main commit=.'
                $merged.ExitCode | Should -Be 0
            } finally {
                $env:PATH = $savedPath
                Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Sandbox -Dir $sb
            }
        }

        # The recovery path is the one that must survive a noisy git most of all: `merge --abort`
        # was written as `2>$null | Out-Null`, which is a CAPTURE, so a warning threw straight
        # past the abort and left exactly the conflicted tree this script promises never to leave.
        It 'a git that warns on stderr still aborts a conflicted merge cleanly' {
            $sb = New-Sandbox -Tag 'rqm-24'
            $shimDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'tp-shim-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $savedPath = $env:PATH
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                $null = Run-Git -Cwd $root -GitArgs @('checkout', '-b', 'clash', 'main')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'from-clash' -Msg 'clash side'
                $null = Run-Git -Cwd $root -GitArgs @('checkout', 'main')
                Add-CommitFile -Root $root -Name 'shared.txt' -Content 'from-main' -Msg 'main side'
                $before = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

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
                $probeErr = [System.IO.Path]::Combine($shimDir, 'probe.err')
                & cmd.exe /c "git --version 2> `"$probeErr`"" | Out-Null
                [System.IO.File]::ReadAllText($probeErr) | Should -Match 'dubious ownership'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'clash', '-Merge')

                (Get-Token $res.Stdout) | Should -Be 'TP_TOKEN:CONFLICT branch=clash base=main'
                $res.ExitCode | Should -Be 1
                # The abort really happened: base unmoved, no half-finished merge state, and the
                # worktree back on the branch it started on.
                $env:PATH = $savedPath
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')) | Should -Be $before
                (Test-Path -LiteralPath ([System.IO.Path]::Combine($root, '.git', 'MERGE_HEAD'))) | Should -BeFalse
                (Run-Git-Capture -Cwd $root -GitArgs @('symbolic-ref', '--short', 'HEAD')) | Should -Be 'main'
            } finally {
                $env:PATH = $savedPath
                Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Sandbox -Dir $sb
            }
        }

        It 'emits exactly one token in every mode' {
            $sb = New-Sandbox -Tag 'rqm-18'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-RequestMergeFixture -Root $root
                Get-TokenCount (Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')).Stdout | Should -Be 1
                Get-TokenCount (Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'nope')).Stdout | Should -Be 1
                Get-TokenCount (Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat', '-Merge')).Stdout | Should -Be 1
                Get-TokenCount (Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feat')).Stdout | Should -Be 1
            } finally { Remove-Sandbox -Dir $sb }
        }
    }
}
