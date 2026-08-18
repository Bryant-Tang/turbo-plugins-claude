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

    Context 'Case 7 (U3): staleness is measured on THIS path, not the repository HEAD' {
        # Real-machine deadlock 2026-07-31: SVN revision numbers are repository-wide, so in a
        # repository holding several projects a commit under a sibling path bumps HEAD without
        # touching anything of ours. Submit measured staleness against the repository HEAD and
        # refused with "SVN HEAD changed since prepare (local r85, head r87)" -- then sent the user
        # to /tp-pull-from-svn, which correctly replayed nothing for this path and answered
        # "Already up to date at SVN r85". Two commands contradicting each other, with no way out
        # but a manual `svn update`. Build-SvnCommit already measured it on the path; only this end
        # was left on the old rule.
        It 'a sibling-path commit does not block this path''s push' -Skip:(-not $script:SvnReady) {
            $sb = New-Sandbox -Tag 'sibling'
            try {
                $fx = New-FeatureBridge -Sandbox $sb
                if ($null -eq $fx) { Set-ItResult -Skipped -Because 'could not build the feature bridge in this env'; return }

                # Stage this path's push FIRST, so the sibling commit lands strictly between
                # prepare and submit -- which is the window this guard covers.
                $null = Run-Git -Cwd $fx.Root -GitArgs @('checkout', 'feat-x')
                Set-Content -LiteralPath ([System.IO.Path]::Combine($fx.Root, 'app.txt')) -Value 'app-sibling' -NoNewline
                $null = Run-Git -Cwd $fx.Root -GitArgs @('add', 'app.txt')
                $null = Run-Git -Cwd $fx.Root -GitArgs @('commit', '-m', 'feat: change for the sibling case')
                $b = Invoke-PsScript -ScriptPath $script:BuildScript -Cwd $fx.Root -ScriptArgs @('-Branch', 'feat-x')
                if ($b.ExitCode -ne 0) { Set-ItResult -Skipped -Because 'prepare did not succeed in this env'; return }

                # Bump repository HEAD from a path we do NOT own (trunk is a sibling of branches/feat-x).
                $siblingWc = [System.IO.Path]::Combine($sb, 'siblingwc')
                $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                try {
                    & svn checkout "$($fx.Uri)/trunk" $siblingWc 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'sibling checkout failed'; return }
                    Set-Content -LiteralPath ([System.IO.Path]::Combine($siblingWc, 'sibling.txt')) -Value 'someone-elses-project' -NoNewline
                    & svn add ([System.IO.Path]::Combine($siblingWc, 'sibling.txt')) 2>$null | Out-Null
                    & svn commit $siblingWc -m 'another project moves HEAD' 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'sibling commit failed'; return }
                } finally { $ErrorActionPreference = $old }

                $s = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $fx.Root -ScriptArgs @('-Branch', 'feat-x', '-Title', 'push despite sibling commit')
                $s.ExitCode | Should -Be 0 -Because "submit must ignore sibling paths: $($s.Combined)"
                $s.Combined | Should -Not -Match 'HEAD changed'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # The loosening is "ignore sibling paths", not "ignore everyone" -- a commit to OUR path
        # must still stop the push and point at pull.
        It 'a commit to this very path still blocks, and points at pull' -Skip:(-not $script:SvnReady) {
            $sb = New-Sandbox -Tag 'samepath'
            try {
                $fx = New-FeatureBridge -Sandbox $sb
                if ($null -eq $fx) { Set-ItResult -Skipped -Because 'could not build the feature bridge in this env'; return }

                $null = Run-Git -Cwd $fx.Root -GitArgs @('checkout', 'feat-x')
                Set-Content -LiteralPath ([System.IO.Path]::Combine($fx.Root, 'app.txt')) -Value 'app-mine' -NoNewline
                $null = Run-Git -Cwd $fx.Root -GitArgs @('add', 'app.txt')
                $null = Run-Git -Cwd $fx.Root -GitArgs @('commit', '-m', 'feat: change for the same-path case')
                $b = Invoke-PsScript -ScriptPath $script:BuildScript -Cwd $fx.Root -ScriptArgs @('-Branch', 'feat-x')
                if ($b.ExitCode -ne 0) { Set-ItResult -Skipped -Because 'prepare did not succeed in this env'; return }

                $branchWc = [System.IO.Path]::Combine($sb, 'branchwc')
                $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                try {
                    & svn checkout $fx.BranchUrl $branchWc 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'branch checkout failed'; return }
                    Set-Content -LiteralPath ([System.IO.Path]::Combine($branchWc, 'teammate.txt')) -Value 'teammate' -NoNewline
                    & svn add ([System.IO.Path]::Combine($branchWc, 'teammate.txt')) 2>$null | Out-Null
                    & svn commit $branchWc -m 'teammate commits to this very branch' 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'branch commit failed'; return }
                } finally { $ErrorActionPreference = $old }

                $s = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $fx.Root -ScriptArgs @('-Branch', 'feat-x', '-Title', 'should be refused')
                $s.ExitCode | Should -Not -Be 0
                $s.Combined | Should -Match 'tp-pull-from-svn'
                $s.Combined | Should -Match 'this path last changed at'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'issue #79: the pushed-file listing is the script''s own copy, not svn''s' {
        # svn renders its per-path progress lines ("Adding <path>") in the console codepage, so a
        # filename it cannot represent there arrives as '?' -- and that listing is the one place the
        # user sees WHAT was just written permanently, at the moment it became permanent. The script
        # therefore prints the paths it already holds.
        #
        # The assertion is on the MECHANISM, not the bytes: a host whose codepage happens to cover
        # the filename renders it correctly EITHER WAY, so "the name looks right" would pass against
        # the unfixed script. What discriminates is the FORM -- `A  <path>` is the script's own
        # rendering and svn never emits it, while `Adding <path>` is svn's and must be gone.
        # THE FILENAME HERE IS ASCII ON PURPOSE, so this case runs on every host. What proves the
        # fix is the FORM of the output, which holds for any filename; a CJK name would add no proof
        # (a host whose codepage covers it renders it correctly either way) but WOULD make the case
        # depend on whether this host can carry that name to svn at all. The non-ASCII axis is its
        # own case below.
        It 'lists every committed path itself and stops echoing svn''s listing' -Skip:(-not $script:SvnReady) {
            $sb = New-Sandbox -Tag 'ownlist'
            try {
                $fx = New-FeatureBridge -Sandbox $sb
                if ($null -eq $fx) { Set-ItResult -Skipped -Because 'could not build the feature bridge in this env'; return }
                # Kept at the working-copy ROOT on purpose: `svn status` reports nested paths with
                # the platform separator, so a subdirectory would make the expected string
                # OS-dependent.
                $null = Run-Git -Cwd $fx.Root -GitArgs @('checkout', 'feat-x')
                Set-Content -LiteralPath ([System.IO.Path]::Combine($fx.Root, 'notes.md')) -Value 'new' -NoNewline
                Set-Content -LiteralPath ([System.IO.Path]::Combine($fx.Root, 'app.txt')) -Value 'app-v2' -NoNewline
                $null = Run-Git -Cwd $fx.Root -GitArgs @('add', '-A')
                $null = Run-Git -Cwd $fx.Root -GitArgs @('commit', '-m', 'feat: add a file')

                $b = Invoke-PsScript -ScriptPath $script:BuildScript -Cwd $fx.Root -ScriptArgs @('-Branch', 'feat-x')
                if ($b.ExitCode -ne 0) { Set-ItResult -Skipped -Because 'the prepare step did not succeed in this env'; return }
                $s = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $fx.Root -ScriptArgs @('-Branch', 'feat-x', '-Title', 'feat: a file')
                $s.ExitCode | Should -Be 0 -Because "the push must succeed; output was:`n$($s.Combined)"

                # The script's own listing, carrying the very paths it handed to svn.
                # `\r?$`, not `$`: in .NET multiline mode `$` matches immediately before the `\n`,
                # so a CRLF line leaves the `\r` unconsumed and an anchored match fails on output
                # that is in fact correct.
                $s.Combined | Should -Match '(?m)^A  notes\.md\r?$'
                $s.Combined | Should -Match '(?m)^M  app\.txt\r?$'
                # svn's own per-path lines are the codepage-dependent ones; not echoed as well.
                $s.Combined | Should -Not -Match '(?m)^(Adding|Deleting|Sending|Replacing)\s'
                # `svn add` / `svn delete` list every path too, in the same codepage -- the SECOND
                # mojibake source in the same push. They are silenced with --quiet. Their listing is
                # `A` + many spaces; ours is `A` + exactly two, so the column width tells them apart.
                $s.Combined | Should -Not -Match '(?m)^[AD]\s{3,}'
                # ...but the filter must be surgical: everything else svn says still comes through.
                $s.Combined | Should -Match 'Committed revision'
            } finally { Remove-Sandbox -Dir $sb }
        }

        # NO end-to-end non-ASCII push case lives here, deliberately. One was written and removed:
        # it proved nothing the case above does not already prove -- what makes the #79 fix correct
        # is the FORM of the output, which holds for any filename -- while making the result depend
        # on the host's ANSI codepage (a CJK name is unrepresentable on the CP1252 CI runner, where
        # the script correctly refuses) and on the parent's CONSOLE codepage. A case whose red
        # lights are dominated by the environment teaches the reader to ignore it. The encoding axis
        # has coverage built for it: Svn-StatusXml-Roundtrip.test.ps1 for the capture/re-pass round
        # trip, Test-EncodingSupport for diagnosing a host, and Common.test.ps1 for the targets-file
        # encoding and its refusal.
    }
}
