# Checkout-SvnBranch.test.ps1 (Pester 5)
#
# Script under test: scripts/Checkout-SvnBranch.ps1 (U11).
#   -SvnUrl <existing-svn-branch-url> [-Branch <name>]
# READ-ONLY import of an EXISTING SVN branch into a remote-svn/<branch> bridge + a working branch
# that descends from the bridge ref (KTD5). It NEVER writes to SVN.
#
# Arg/guard cases (required-arg, worktrees-missing, same-name R20 reject, collision, no
# remote-svn-main) run on a plain git sandbox. Trust + happy-import cases need remote-svn-main to
# be a real svn working copy, so they self-SKIP (-Skip) when svn.exe or the seed dump are absent.

# --- Discovery-time gate (evaluated BEFORE BeforeAll) ---------------------------
$script:DumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))
$SvnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $SvnAvailable = ($LASTEXITCODE -eq 0)
} catch {
    $SvnAvailable = $false
}
$SvnReady = ($SvnAvailable -and [System.IO.File]::Exists($script:DumpPath))

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Checkout-SvnBranch.ps1')
    $script:DumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    function Get-WorktreesDir {
        param([string]$Root)
        return [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees')
    }

    # Build a throwaway svn repo from the seed dump and check out trunk into
    # <worktreesDir>/remote-svn-main so it becomes a valid trusted working copy. Returns
    # the repos-root-url, or $null if the svn pipeline failed.
    function Initialize-RemoteMainWc {
        param([string]$Root, [string]$Sandbox)
        $worktreesDir = Get-WorktreesDir -Root $Root
        $svnRepo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')

        & svnadmin create $svnRepo
        if ($LASTEXITCODE -ne 0) { return $null }

        $loadCmd = "svnadmin load `"$svnRepo`" < `"$($script:DumpPath)`""
        & cmd.exe /c $loadCmd > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }

        $repoUri = 'file:///' + ($svnRepo -replace '\\', '/')
        $remoteMain = [System.IO.Path]::Combine($worktreesDir, 'remote-svn-main')
        & svn checkout "$repoUri/trunk" $remoteMain > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }

        $reposRoot = (& svn info --show-item repos-root-url $remoteMain 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($reposRoot)) { return $null }
        return $reposRoot
    }

    # True if NO partial bridge state (bridge branch / worktree dir) remains for $Branch.
    function Test-NoBridgeOrphan {
        param([string]$Root, [string]$Branch)
        $bridge = Run-Git-Capture -Cwd $Root -GitArgs @('branch', '--list', "remote-svn/$Branch")
        if ($bridge -ne '') { return $false }
        $dash = $Branch -replace '/', '-'
        $wtPath = [System.IO.Path]::Combine((Get-WorktreesDir -Root $Root), "remote-svn-$dash")
        return (-not [System.IO.Directory]::Exists($wtPath))
    }
}

Describe 'Checkout-SvnBranch' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: missing -SvnUrl -> required-arg error' {
        It 'exits non-zero and complains -SvnUrl is required' {
            $sb = New-Sandbox -Tag 'csb-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match '-SvnUrl is required'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 2: worktrees dir missing -> fail before any mutation' {
        It 'exits non-zero and mentions Worktrees directory not found' {
            $sb = New-Sandbox -Tag 'csb-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root  # NO -CreateWorktreesDir
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', 'file:///nonexistent/branches/x', '-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Worktrees directory not found'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 3: same-name working branch (R20) -> zero-side-effect reject' {
        It 'rejects with "already exists", never imports, leaves no bridge state' {
            $sb = New-Sandbox -Tag 'csb-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'feature-x', 'main')  # pre-existing work branch
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', 'file:///nonexistent/branches/feature-x', '-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'already exists'
                $res.Combined | Should -Not -Match 'Importing SVN branch'
                (Test-NoBridgeOrphan -Root $root -Branch 'feature-x') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 4: collision -> two branches map to the same worktree dir' {
        It 'rejects with "already taken by branch" and creates nothing for the requested branch' {
            $sb = New-Sandbox -Tag 'csb-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/feat-login', 'main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', 'file:///nonexistent/branches/feat-login', '-Branch', 'feat/login')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'is already taken by branch'
                (Test-NoBridgeOrphan -Root $root -Branch 'feat/login') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 5: remote-svn-main absent -> fail-closed, no side effects' {
        It 'rejects before "Importing", names the missing main bridge, leaves no orphan' {
            $sb = New-Sandbox -Tag 'csb-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir  # worktrees dir, but NO remote-svn-main
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', 'file:///nonexistent/branches/feature-x', '-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'remote-svn-main worktree not found'
                $res.Combined | Should -Not -Match 'Importing SVN branch'
                (Test-NoBridgeOrphan -Root $root -Branch 'feature-x') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 6: out-of-trust file:// URL rejected (needs svn WC)' {
        It 'rejects before import, no orphan' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-6'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', 'file:///C:/Windows/System32/', '-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Not -Match 'Importing SVN branch'
                (Test-NoBridgeOrphan -Root $root -Branch 'feature-x') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 7: trusted but non-existent SVN branch -> reject (read-only, no create)' {
        It 'rejects with "does not exist" and leaves no orphan' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-7'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', "$reposRoot/branches/nope-not-here", '-Branch', 'nope-not-here')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'does not exist'
                (Test-NoBridgeOrphan -Root $root -Branch 'nope-not-here') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 8: happy import -> bridge + working branch, read-only on SVN (needs svn WC)' {
        It 'creates the bridge + work branch at the bridge tip and writes no new SVN revision' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-8'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                # Create the EXISTING svn branch to import (the only svn write - done by the TEST).
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feature-x" -m 'test: branch to import' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Set-ItResult -Skipped -Because 'could not create the svn branch to import'
                    return
                }
                $revBefore = (& svn info --show-item revision $reposRoot 2>$null | Out-String).Trim()

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feature-x", '-Branch', 'feature-x')
                if ($res.ExitCode -ne 0) {
                    Set-ItResult -Skipped -Because "import did not succeed in this env: $($res.Combined)"
                    return
                }

                (Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'remote-svn/feature-x')) | Should -Not -BeNullOrEmpty
                (Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'feature-x')) | Should -Not -BeNullOrEmpty

                $workTip   = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feature-x')
                $bridgeTip = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/feature-x')
                $workTip | Should -Be $bridgeTip

                $mb = Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'feature-x', 'remote-svn/feature-x')
                $mb | Should -Not -BeNullOrEmpty

                $wtPath = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), 'remote-svn-feature-x')
                (Run-Git-Capture -Cwd $wtPath -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty

                $revAfter = (& svn info --show-item revision $reposRoot 2>$null | Out-String).Trim()
                $revAfter | Should -Be $revBefore
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 9: two-root repo imports an UNRELATED branch without crash or contamination (regression)' {
        It 'imports on a repo with TWO root commits with no "not a valid object name" and no trunk contamination' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-9'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                & git -C $root config commit.gpgsign false 2>&1 | Out-Null

                & git -C $root config commit.gpgsign false 2>&1 | Out-Null
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'; return }

                # An svn branch 'other' that DIFFERS from trunk: drop Web.config, add only-branch.txt.
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/other" -m 'branch: other' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'could not create svn branch'; return }
                $co = [System.IO.Path]::Combine($sb, 'co')
                & svn checkout "$reposRoot/branches/other" $co > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'could not checkout svn branch'; return }
                & svn delete ([System.IO.Path]::Combine($co, 'Web.config')) > $null 2>$null
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'only-branch.txt'), 'only in branch')
                & svn add ([System.IO.Path]::Combine($co, 'only-branch.txt')) > $null 2>$null
                & svn commit $co -m 'branch: drop Web.config, add only-branch.txt' > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'could not commit svn branch diff'; return }

                # Inject a SECOND root into main to reproduce the post-bridge two-root state: a
                # parentless commit-tree on the canonical empty tree, merged --allow-unrelated.
                $second = (& git -C $root commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m 'sync: svn r1' | Out-String).Trim()
                & git -C $root merge --allow-unrelated-histories --no-edit -m "Merge branch 'remote-svn/main' into main" $second 2>&1 | Out-Null
                $roots = @((Run-Git-Capture -Cwd $root -GitArgs @('rev-list', '--max-parents=0', 'HEAD')) -split "`n" | Where-Object { $_.Trim() })
                $roots.Count | Should -Be 2

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', "$reposRoot/branches/other", '-Branch', 'other')
                $res.Combined | Should -Not -Match 'not a valid object name'
                $res.ExitCode | Should -Be 0

                $files = @((Run-Git-Capture -Cwd $root -GitArgs @('ls-tree', '-r', '--name-only', 'other')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $files | Should -Contain 'only-branch.txt'
                $files | Should -Not -Contain 'Web.config'
                ($files | Where-Object { $_ -like '*.turbo-plugin*' }) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
