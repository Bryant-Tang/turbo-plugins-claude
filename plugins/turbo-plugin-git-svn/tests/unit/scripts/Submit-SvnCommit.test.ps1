# Submit-SvnCommit.test.ps1 (Pester 5)
#
# Tests for plugins/turbo-plugin-git-svn/scripts/Submit-SvnCommit.ps1.
#
# Scope (--Message renamed to --Title; agent supplies only the title, body comes from the
# locked pin written by Build-SvnCommit):
#   - missing -Branch → required-arg error
#   - missing -Title → required-arg error
#   - valid branch name, no bridge → "Remote worktree ... not found"
#   - no prepared merge (no MERGE_HEAD) → "No pending merge ..." (中文 title input — verify the
#     script handles a 中文 -Title arg without parser/encoding crash before hitting the
#     precondition fail)

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # ScriptsCommon.ps1 provides New-Sandbox / Remove-Sandbox / New-GitMainRepo / Invoke-PsScript.
    # (AssertHelpers.ps1 is intentionally NOT sourced — asserts use Pester Should.)
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Submit-SvnCommit.ps1')
    $script:ScriptExists = [System.IO.File]::Exists($script:ScriptUnderTest)
}

Describe 'Submit-SvnCommit' {

    It 'script-under-test exists' {
        $script:ScriptExists | Should -BeTrue -Because "expected at $script:ScriptUnderTest"
    }

    Context 'Case 1: missing -Branch → required-arg error' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'ptsc-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res1 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0' { ($script:res1.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions -Branch required' { $script:res1.Combined | Should -Match '-Branch' }
    }

    Context 'Case 2: -Branch supplied but missing -Title → required-arg error' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'ptsc-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0' { ($script:res2.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions -Title required' { $script:res2.Combined | Should -Match '-Title' }
    }

    Context 'Case 2b: legacy -Message is now an unknown parameter (agent cannot pass a free message)' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'ptsc-2b'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res2b = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main', '-Message', 'free body')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        # CmdletBinding rejects the undeclared -Message parameter with a binding error (non-zero).
        It 'exit != 0 (param binding rejects -Message)' { ($script:res2b.ExitCode -ne 0) | Should -BeTrue }
    }

    Context 'Case 3: -Branch develop (valid name, no bridge) → "Remote worktree ... not found"' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'ptsc-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res3 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'develop', '-Title', 'irrelevant')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        # Any valid branch name is accepted now; 'develop' is a legal name
        # with no bridge worktree, so the script fails with "Remote worktree ... not found"
        # (the old "Unsupported branch" rejection no longer exists).
        It 'exit != 0' { ($script:res3.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions the missing remote worktree' { $script:res3.Combined | Should -Match 'not found' }
    }

    Context 'Case 4: -Branch main with remote-svn-main but no MERGE_HEAD → "No pending merge" (中文 -Title)' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'ptsc-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir -CreateRemoteMain
                $zhTitle = '修正中文 bug — push-commit precondition case'
                $script:res4 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main', '-Title', $zhTitle)
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0 (no MERGE_HEAD)' { ($script:res4.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions No pending merge' { $script:res4.Combined | Should -Match 'No pending merge' }
    }
}
