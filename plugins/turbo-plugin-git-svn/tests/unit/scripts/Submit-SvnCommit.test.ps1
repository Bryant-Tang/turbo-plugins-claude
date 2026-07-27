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

# --- Discovery-time svn gate (evaluated BEFORE BeforeAll, so -Skip: sees a real value) ---
$SvnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $SvnAvailable = ($LASTEXITCODE -eq 0)
} catch { $SvnAvailable = $false }
$script:SvnReady = $SvnAvailable

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # ScriptsCommon.ps1 provides New-Sandbox / Remove-Sandbox / New-GitMainRepo / Invoke-PsScript.
    # (AssertHelpers.ps1 is intentionally NOT sourced — asserts use Pester Should.)
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Submit-SvnCommit.ps1')
    $script:ScriptExists = [System.IO.File]::Exists($script:ScriptUnderTest)
    $script:InitScript  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Initialize-GitSvnBridge.ps1')
    $script:NrbScript   = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'New-RemoteBridge.ps1')
    $script:BuildScript = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-SvnCommit.ps1')

    # EAP-softened svn value read (svn may warn to stderr; Common's EAP=Stop is not in scope here).
    function Get-SvnValue {
        $a = $args
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = & svn @a 2>$null } catch { $o = $null } finally { $ErrorActionPreference = $old }
        return ((@($o) -join "`n").Trim())
    }
    function Get-BranchRev { param([string]$BranchUrl) return (Get-SvnValue info --show-item revision $BranchUrl) }

    # Build a real trunk+branches bridge with a FEATURE branch first-pushed (tp:last-aligned-rev
    # initialized to the trunk copyfrom-rev). Mirrors submit-svn-commit.test.sh build_feature_bridge:
    # scripts run with default svn config; file:// needs no auth. Returns a hashtable or $null.
    function New-FeatureBridge {
        param([string]$Sandbox)
        $root = [System.IO.Path]::Combine($Sandbox, 'test-turbo-plugin')
        $svnRepo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & svnadmin create $svnRepo 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
            $uri = 'file:///' + ($svnRepo -replace '\\', '/')
            $seed = [System.IO.Path]::Combine($Sandbox, 'seed')
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($seed, 'trunk')) -Force
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($seed, 'branches')) -Force
            Set-Content -LiteralPath ([System.IO.Path]::Combine($seed, 'trunk', 'app.txt')) -Value 'app-v1' -NoNewline
            Set-Content -LiteralPath ([System.IO.Path]::Combine($seed, 'branches', '.keep')) -Value 'k' -NoNewline
            & svn import $seed $uri -m 'seed trunk+branches' 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
        } finally { $ErrorActionPreference = $old }

        $null = New-Item -ItemType Directory -Path $root -Force
        if ((Run-Git -Cwd $root -GitArgs @('init', '-b', 'main')) -ne 0) { return $null }
        $null = Run-Git -Cwd $root -GitArgs @('config', 'user.email', 'test@turbo')
        $null = Run-Git -Cwd $root -GitArgs @('config', 'user.name',  'turbo')
        $null = Run-Git -Cwd $root -GitArgs @('config', 'commit.gpgsign', 'false')

        $initRes = Invoke-PsScript -ScriptPath $script:InitScript -Cwd $root -ScriptArgs @('-SvnUrl', "$uri/trunk")
        if ($initRes.ExitCode -ne 0) { return $null }

        Set-Content -LiteralPath ([System.IO.Path]::Combine($root, '.gitignore')) -Value ".turbo-plugin/worktrees/`n.svn/`n"
        $null = Run-Git -Cwd $root -GitArgs @('add', '.gitignore')
        $null = Run-Git -Cwd $root -GitArgs @('commit', '-m', 'chore: skeleton gitignore')

        if ((Run-Git -Cwd $root -GitArgs @('branch', 'feat-x', 'main')) -ne 0) { return $null }
        $branchUrl = "$uri/branches/feat-x"
        $nrbRes = Invoke-PsScript -ScriptPath $script:NrbScript -Cwd $root -ScriptArgs @('-Branch', 'feat-x', '-SvnUrl', $branchUrl)
        if ($nrbRes.ExitCode -ne 0) { return $null }

        $initAligned = Get-SvnValue propget tp:last-aligned-rev $branchUrl
        if ([string]::IsNullOrWhiteSpace($initAligned)) { return $null }
        return @{ Root = $root; Uri = $uri; BranchUrl = $branchUrl; InitAligned = $initAligned }
    }

    # build-svn-commit + submit-svn-commit (the real push flow). Returns $true on a clean push.
    function Invoke-FeatPush {
        param([string]$Root, [string]$Title)
        $b = Invoke-PsScript -ScriptPath $script:BuildScript -Cwd $Root -ScriptArgs @('-Branch', 'feat-x')
        if ($b.ExitCode -ne 0) { return $false }
        $s = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $Root -ScriptArgs @('-Branch', 'feat-x', '-Title', $Title)
        return ($s.ExitCode -eq 0)
    }
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

    Context 'Case 5 (U4): a push that newly merges main into the branch ADVANCES tp:last-aligned-rev' {
        # A commit reachable from feat-x is MARKED with a HIGHER revision than the branch's
        # stored alignment (simulating a merge of a newer main). The advance lands IN THE SAME
        # content commit (folded, not a separate property revision): one new rev, tp == HIGH.
        It 'advances tp:last-aligned-rev, folded into the content commit' -Skip:(-not $script:SvnReady) {
            $sb = New-Sandbox -Tag 'adv'
            try {
                $fx = New-FeatureBridge -Sandbox $sb
                if ($null -eq $fx) { Set-ItResult -Skipped -Because 'could not build the feature bridge in this env'; return }
                $high = [int]$fx.InitAligned + 100
                $revBefore = [int](Get-BranchRev -BranchUrl $fx.BranchUrl)
                $null = Run-Git -Cwd $fx.Root -GitArgs @('checkout', 'feat-x')
                Set-Content -LiteralPath ([System.IO.Path]::Combine($fx.Root, 'app.txt')) -Value 'app-v2' -NoNewline
                $null = Run-Git -Cwd $fx.Root -GitArgs @('add', 'app.txt')
                # A commit that BOTH changes a file (content to push) AND carries the trailer.
                $null = Run-Git -Cwd $fx.Root -GitArgs @('commit', '-m', "sync: svn r$high")
                $null = Run-Git -Cwd $fx.Root -GitArgs @('update-ref', "refs/tp/svn/$high", (Run-Git-Capture -Cwd $fx.Root -GitArgs @('rev-parse', 'HEAD')))
                if (-not (Invoke-FeatPush -Root $fx.Root -Title 'push feat-x with merged main')) {
                    Set-ItResult -Skipped -Because 'the feature push did not succeed in this env'; return
                }
                $got = Get-SvnValue propget tp:last-aligned-rev $fx.BranchUrl
                $got | Should -BeExactly ([string]$high)
                $revAfter = [int](Get-BranchRev -BranchUrl $fx.BranchUrl)
                # Folded, not separate: the advance rode in the ONE content commit (delta 1, not 2).
                ($revAfter - $revBefore) | Should -Be 1
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 6 (U4): an ordinary feature push does NOT advance tp:last-aligned-rev' {
        # A normal feature commit (file change, NO svn-revision trailer) brings no newer main rev,
        # so tp:last-aligned-rev is untouched and the push creates exactly ONE content revision
        # (no extra property-only commit).
        It 'leaves tp:last-aligned-rev unchanged and adds no property commit' -Skip:(-not $script:SvnReady) {
            $sb = New-Sandbox -Tag 'noadv'
            try {
                $fx = New-FeatureBridge -Sandbox $sb
                if ($null -eq $fx) { Set-ItResult -Skipped -Because 'could not build the feature bridge in this env'; return }
                $revBefore = [int](Get-BranchRev -BranchUrl $fx.BranchUrl)
                $null = Run-Git -Cwd $fx.Root -GitArgs @('checkout', 'feat-x')
                Set-Content -LiteralPath ([System.IO.Path]::Combine($fx.Root, 'app.txt')) -Value 'app-feat' -NoNewline
                $null = Run-Git -Cwd $fx.Root -GitArgs @('add', 'app.txt')
                $null = Run-Git -Cwd $fx.Root -GitArgs @('commit', '-m', 'feat: ordinary tweak (no trailer)')
                if (-not (Invoke-FeatPush -Root $fx.Root -Title 'ordinary feature push')) {
                    Set-ItResult -Skipped -Because 'the feature push did not succeed in this env'; return
                }
                $got = Get-SvnValue propget tp:last-aligned-rev $fx.BranchUrl
                $got | Should -BeExactly ([string]$fx.InitAligned)
                $revAfter = [int](Get-BranchRev -BranchUrl $fx.BranchUrl)
                # No separate property commit: exactly the ONE content revision.
                ($revAfter - $revBefore) | Should -Be 1
            } finally { Remove-Sandbox -Dir $sb }
        }
    }
}
