# Reset-BranchToMain.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Reset-BranchToMain.ps1
#
# New contract: -Branch <name> [-DiffOnly] (no -N / test-<n>). Resets ANY local
# branch to main's tip. Emits LOSE / GAIN / FILES_LOST_AFTER_PUSH preview tokens; with
# -DiffOnly it exits after the preview without mutating. Early-exits with
# "<branch> already equals main. Nothing to reset." when there is nothing to do.
# Errors: "Missing required argument: -Branch <name>", "Branch '...' does not exist.",
# "Branch 'main' does not exist.", remote worktree not found, dirty main/remote refusal.
#
# Preserved "spirit" from the old Reset-RemoteTest: happy path (branch ahead -> reset to
# main HEAD) + dirty-refusal. Generalized to an arbitrary branch name (feature-x), plus new
# cases for the new contract: -Branch required, non-existent branch, -DiffOnly no-mutate,
# already-equal early-exit. Git-only -- no svn required, so every case can run green.

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Reset-BranchToMain.ps1')

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    # Add the remote-svn/<Branch> bridge worktree. Returns the `git worktree add` exit code so
    # callers can SKIP when it fails for an ENVIRONMENT reason (e.g. git-on-Windows
    # "'$GIT_DIR' too big" on very deeply nested sandbox paths) rather than reporting a false
    # FAIL. On a normal-depth CI checkout this succeeds and the case runs for real.
    function Add-BridgeWorktree {
        param([string]$Root, [string]$Branch)
        $wtDir = [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees')
        $null = New-Item -ItemType Directory -Path $wtDir -Force
        $dash = $Branch -replace '/', '-'
        $remoteWtDir = [System.IO.Path]::Combine($wtDir, "remote-svn-$dash")
        $null = Run-Git -Cwd $Root -GitArgs @('branch', "remote-svn/$Branch", 'main')
        return (Run-Git -Cwd $Root -GitArgs @('worktree', 'add', $remoteWtDir, "remote-svn/$Branch"))
    }

    # main has 1 commit; <Branch> = main + 1 extra; remote-svn/<Branch> bridge worktree linked.
    # Returns the bridge `git worktree add` exit code (0 = ready).
    function New-RepoWithBranchAhead {
        param([string]$Root, [string]$Branch = 'feature-x')
        New-GitMainRepo -Root $Root
        $null = Run-Git -Cwd $Root -GitArgs @('branch', $Branch)
        $null = Run-Git -Cwd $Root -GitArgs @('checkout', $Branch)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, "$Branch-only.txt"), "$Branch specific")
        $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
        $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', "feat: $Branch-only change")
        $null = Run-Git -Cwd $Root -GitArgs @('checkout', 'main')
        return (Add-BridgeWorktree -Root $Root -Branch $Branch)
    }

    # main + <Branch> identical (no divergence); bridge worktree linked.
    # Returns the bridge `git worktree add` exit code (0 = ready).
    function New-RepoBranchEqualMain {
        param([string]$Root, [string]$Branch = 'feature-x')
        New-GitMainRepo -Root $Root
        $null = Run-Git -Cwd $Root -GitArgs @('branch', $Branch)  # forked at main tip, no extra commit
        return (Add-BridgeWorktree -Root $Root -Branch $Branch)
    }
}

Describe 'Reset-BranchToMain' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: missing -Branch -> required-arg error' {
        It 'exits non-zero with "Missing required argument: -Branch"' {
            $sb = New-Sandbox -Tag 'rbm-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-RepoWithBranchAhead -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Missing required argument: -Branch'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 2: non-existent branch -> error' {
        It 'exits non-zero with "Branch ... does not exist."' {
            $sb = New-Sandbox -Tag 'rbm-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-RepoWithBranchAhead -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'no-such-branch')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match "Branch 'no-such-branch' does not exist\."
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 3: happy -- branch ahead -> reset to main HEAD' {
        It 'exits 0, emits LOSE, and the branch SHA equals main SHA afterward' {
            $sb = New-Sandbox -Tag 'rbm-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $wtRc = New-RepoWithBranchAhead -Root $root -Branch 'feature-x'
                if ($wtRc -ne 0) {
                    Set-ItResult -Skipped -Because "git worktree add failed in fixture (env path-length quirk, rc=$wtRc)"
                    return
                }

                $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
                $branchSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feature-x')
                $branchSha | Should -Not -Be $mainSha

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match '(?m)^LOSE'

                $mainSha2 = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
                $branchSha2 = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feature-x')
                $branchSha2 | Should -Be $mainSha2
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 4: -DiffOnly -> preview only, no mutation' {
        It 'emits preview tokens, exits 0, and leaves the branch SHA unchanged' {
            $sb = New-Sandbox -Tag 'rbm-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $wtRc = New-RepoWithBranchAhead -Root $root -Branch 'feature-x'
                if ($wtRc -ne 0) {
                    Set-ItResult -Skipped -Because "git worktree add failed in fixture (env path-length quirk, rc=$wtRc)"
                    return
                }

                $branchShaBefore = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feature-x')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-DiffOnly')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match '(?m)^LOSE'
                $res.Stdout | Should -Match '(?m)^GAIN'
                $res.Stdout | Should -Match '(?m)^FILES_LOST_AFTER_PUSH'

                # No mutation: the branch tip must be unchanged.
                $branchShaAfter = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feature-x')
                $branchShaAfter | Should -Be $branchShaBefore
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 5: branch already equals main -> early exit' {
        It 'exits 0 with "already equals main. Nothing to reset."' {
            $sb = New-Sandbox -Tag 'rbm-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $wtRc = New-RepoBranchEqualMain -Root $root -Branch 'feature-x'
                if ($wtRc -ne 0) {
                    Set-ItResult -Skipped -Because "git worktree add failed in fixture (env path-length quirk, rc=$wtRc)"
                    return
                }
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'already equals main\. Nothing to reset\.'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 6: dirty main worktree -> refuse' {
        It 'exits non-zero with "uncommitted changes"' {
            $sb = New-Sandbox -Tag 'rbm-6'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $wtRc = New-RepoWithBranchAhead -Root $root -Branch 'feature-x'
                if ($wtRc -ne 0) {
                    Set-ItResult -Skipped -Because "git worktree add failed in fixture (env path-length quirk, rc=$wtRc)"
                    return
                }
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'dirty.txt'), 'uncommitted')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'uncommitted'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
