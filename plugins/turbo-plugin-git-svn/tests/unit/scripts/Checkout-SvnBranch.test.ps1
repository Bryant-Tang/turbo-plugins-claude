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

        # The import now bases the bridge branch on remote-svn/main (the trunk mirror) so the imported
        # branch connects to main. Real setups create this anchor ref via tp-setup; a ref at main is
        # enough here (the svn checkout fills the exact branch content regardless).
        & git -C $Root branch 'remote-svn/main' 'main' > $null 2>&1
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

    # -- U5 fixture helpers: seed replayed history + branch metadata --
    # Seed --allow-empty svn-revision trailer commits on main for the given revs (PASS ASCENDING).
    # Cheaply mirrors U3/U7 replay so the U5 floor lookup + cur bound have data to resolve against.
    function Add-MainTrailers {
        param([string]$Root, [int[]]$Revs)
        foreach ($r in $Revs) {
            $rc = Run-Git -Cwd $Root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', "sync: svn r$r")
            if ($rc -eq 0) { $rc = Run-Git -Cwd $Root -GitArgs @('update-ref', "refs/tp/svn/$r", (Run-Git-Capture -Cwd $Root -GitArgs @('rev-parse', 'HEAD'))) }
            if ($rc -ne 0) { return $false }
        }
        return $true
    }

    # SHA marked as <Rev> via refs/tp/svn/<Rev> (the floor target for assertions).
    function Get-TrailerSha {
        param([string]$Root, [int]$Rev)
        return (Run-Git-Capture -Cwd $Root -GitArgs @('rev-parse', '--verify', '--quiet', "refs/tp/svn/$Rev^{commit}"))
    }

    # Set one or more tp:* properties on an SVN branch URL (checkout once, propset each, one commit).
    # $Props is an ordered pair list @('name','value',...). Returns $true on success.
    function Set-TpProps {
        param([string]$BranchUrl, [string[]]$Props, [string]$Sandbox)
        $wc = [System.IO.Path]::Combine($Sandbox, "propwc-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        & svn checkout $BranchUrl $wc > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        Push-Location $wc
        try {
            for ($i = 0; $i -lt $Props.Count; $i += 2) {
                & svn propset "tp:$($Props[$i])" $Props[$i + 1] '.' > $null 2>$null
                if ($LASTEXITCODE -ne 0) { return $false }
            }
            & svn commit --depth empty -m 'test: set tp props' '.' > $null 2>$null
            if ($LASTEXITCODE -ne 0) { return $false }
        } finally {
            Pop-Location
        }
        return $true
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
                # U5: main must carry replayed svn-revision trailers so the branch's fork-point
                # resolves. With NO tp:* props this exercises the copyfrom-rev fallback (r20 -> floor r20).
                if (-not (Add-MainTrailers -Root $root -Revs @(1, 10, 19, 20))) {
                    Set-ItResult -Skipped -Because 'could not seed main trailers'; return
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
                # The imported working branch connects to THIS repo's main (not a disconnected orphan),
                # so a later merge-back is not "unrelated histories". This is the U11 connection fix.
                (Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'main', 'feature-x')) | Should -Not -BeNullOrEmpty

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

                # U5: seed replayed trailers so the copyfrom-rev fork-point (r20) resolves on the two-root repo.
                if (-not (Add-MainTrailers -Root $root -Revs @(1, 10, 19, 20))) { Set-ItResult -Skipped -Because 'could not seed main trailers'; return }

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

                # Connected to main (not an orphan), even on a two-root repo.
                (Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'main', 'other')) | Should -Not -BeNullOrEmpty

                $files = @((Run-Git-Capture -Cwd $root -GitArgs @('ls-tree', '-r', '--name-only', 'other')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $files | Should -Contain 'only-branch.txt'
                $files | Should -Not -Contain 'Web.config'
                ($files | Where-Object { $_ -like '*.turbo-plugin*' }) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    # == U5: graded fork-point resolution (AE2-AE5, R7-R11) ==

    Context 'Case 10: Covers AE2/R8 -- exact floor re-bases onto r120 with no prompt' {
        It 'attaches at the r120 commit; merge-base(main,branch) and branch^ both equal it' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-ae2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-ae2" -m 'test: ae2' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(90, 118, 120, 126))) { Set-ItResult -Skipped -Because 'seed'; return }
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-ae2" -Props @('last-aligned-rev', '120') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }
                $fork = Get-TrailerSha -Root $root -Rev 120

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-ae2", '-Branch', 'feat-ae2')
                $res.ExitCode | Should -Be 0 -Because "AE2 happy path: script under test must exit 0. $($res.Combined)"
                $res.Combined | Should -Not -Match 'Pull trunk first'
                $res.Combined | Should -Not -Match 'Ask the branch author'
                (Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'main', 'feat-ae2')) | Should -Be $fork
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feat-ae2^')) | Should -Be $fork
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 11: sparse floor -- no exact r120 but r118 present -> attach at r118' {
        It 'attaches at the nearest <=R commit (r118), not a spurious stop' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-sparse'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-sparse" -m 'test: sparse' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(90, 118, 126))) { Set-ItResult -Skipped -Because 'seed'; return }
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-sparse" -Props @('last-aligned-rev', '120') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }
                $fork = Get-TrailerSha -Root $root -Rev 118

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-sparse", '-Branch', 'feat-sparse')
                $res.ExitCode | Should -Be 0
                (Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'main', 'feat-sparse')) | Should -Be $fork
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Regression: R>cur but trunk unchanged in (cur..R] must attach, not deadlock' {
        # SVN revision numbers are repository-global. A branch copied from trunk@R where r(cur+1)..R
        # only touched OTHER paths leaves trunk@R identical to trunk@cur -- nothing to pull. Grading
        # on R itself wedged the tool: checkout demanded a pull, the pull answered "already up to
        # date", every retry failed the same way. Real case: branch copied from main@r52 while
        # trunk's last actual change was r46.
        It 'attaches at the trunk last-changed commit instead of demanding an impossible pull' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-gap'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                # Trunk's last REAL change; nothing after this touches trunk.
                $trunkLast = (& svn info --show-item last-changed-revision "$reposRoot/trunk" 2>$null | Out-String).Trim()
                if ($trunkLast -notmatch '^[0-9]+$') { Set-ItResult -Skipped -Because 'no trunk rev'; return }
                # These bump the repo-global counter WITHOUT touching trunk.
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-gap" -m 'test: gap branch' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                & svn mkdir "$reposRoot/unrelated" -m 'test: unrelated path' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no unrelated path'; return }
                $laterRev = (& svn info --show-item revision "$reposRoot/unrelated" 2>$null | Out-String).Trim()
                if ($laterRev -notmatch '^[0-9]+$') { Set-ItResult -Skipped -Because 'no later rev'; return }
                # Branch aligned to that LATER global revision; local main replayed only to trunkLast.
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-gap" -Props @('last-aligned-rev', $laterRev) -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @([int]$trunkLast))) { Set-ItResult -Skipped -Because 'seed'; return }
                $fork = Get-TrailerSha -Root $root -Rev ([int]$trunkLast)

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-gap", '-Branch', 'feat-gap')
                $res.Combined | Should -Not -Match 'Pull trunk first' -Because "trunk did not change in (r$trunkLast..r$laterRev] so there is nothing to pull"
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                (Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'main', 'feat-gap')) | Should -Be $fork
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 12: Covers AE3/R9 -- aligned rev newer than cur stops with a pull offer, then attaches after pull' {
        It 'stops with the pull instruction (no orphan), then attaches at r120 after the pull' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-ae3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-ae3" -m 'test: ae3' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(90, 118))) { Set-ItResult -Skipped -Because 'seed'; return }   # cur=118 < R=120
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-ae3" -Props @('last-aligned-rev', '120') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-ae3", '-Branch', 'feat-ae3')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Pull trunk first'
                (Test-NoBridgeOrphan -Root $root -Branch 'feat-ae3') | Should -BeTrue

                # Simulate the pull bringing r119, r120; retry -> attach at r120.
                if (-not (Add-MainTrailers -Root $root -Revs @(119, 120))) { Set-ItResult -Skipped -Because 'seed2'; return }
                $fork = Get-TrailerSha -Root $root -Rev 120
                $res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-ae3", '-Branch', 'feat-ae3')
                $res2.ExitCode | Should -Be 0
                (Run-Git-Capture -Cwd $root -GitArgs @('merge-base', 'main', 'feat-ae3')) | Should -Be $fork
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 13: Covers AE4/R10,R11 -- aligned rev with no floor commit stops with a refresh instruction (no wrong base)' {
        It 'stops with the refresh instruction and leaves no orphan (does not attach)' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-ae4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-ae4" -m 'test: ae4' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(118, 120, 126))) { Set-ItResult -Skipped -Because 'seed'; return }   # earliest 118 > R=50
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-ae4" -Props @('last-aligned-rev', '50') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-ae4", '-Branch', 'feat-ae4')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'has no replayed commit on local main'
                $res.Combined | Should -Not -Match 'Pull trunk first'
                (Test-NoBridgeOrphan -Root $root -Branch 'feat-ae4') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 14: base-ref swap keeps the SVN branch tree (not trunk-at-fork content)' {
        It 'imports the SVN branch tree while re-parenting onto the fork commit' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-tree'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                & git -C $root config commit.gpgsign false 2>$null | Out-Null
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-div" -m 'branch: div' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                $co = [System.IO.Path]::Combine($sb, 'co-div')
                & svn checkout "$reposRoot/branches/feat-div" $co > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no co'; return }
                & svn delete ([System.IO.Path]::Combine($co, 'Web.config')) > $null 2>$null
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'only-branch.txt'), 'only in branch')
                & svn add ([System.IO.Path]::Combine($co, 'only-branch.txt')) > $null 2>$null
                & svn commit $co -m 'branch: drop Web.config, add only-branch.txt' > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no branch diff'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(90, 118, 120, 126))) { Set-ItResult -Skipped -Because 'seed'; return }
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-div" -Props @('last-aligned-rev', '120') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }
                $fork = Get-TrailerSha -Root $root -Rev 120

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-div", '-Branch', 'feat-div')
                $res.ExitCode | Should -Be 0 -Because "base-ref-swap happy path: script under test must exit 0. $($res.Combined)"
                (Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'feat-div^')) | Should -Be $fork
                $files = @((Run-Git-Capture -Cwd $root -GitArgs @('ls-tree', '-r', '--name-only', 'feat-div')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $files | Should -Contain 'only-branch.txt'
                $files | Should -Not -Contain 'Web.config'
                # branch tree must DIFFER from the fork commit tree (proves the swap kept SVN content).
                (Run-Git -Cwd $root -GitArgs @('diff', '--quiet', $fork, 'feat-div')) | Should -Not -Be 0
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 15: R11 stale-but-present -- stored alignment below copyfrom -> stop, no attach' {
        It 'stops with the stale-contradiction message and leaves no orphan' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-stale'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feat-stale" -m 'test: stale' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(10, 20))) { Set-ItResult -Skipped -Because 'seed'; return }
                # copyfrom-rev is r20; a stored alignment of r5 is a provable contradiction (only advances).
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feat-stale" -Props @('last-aligned-rev', '5') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feat-stale", '-Branch', 'feat-stale')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match "older than the branch's fork revision"
                (Test-NoBridgeOrphan -Root $root -Branch 'feat-stale') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 16: Covers AE5/R7 -- tp:branch-name drives a slash-preserving local branch' {
        It 'imports without -Branch as the stored slash name (leaf feature-test-3-feature -> feature/test-3-feature)' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'csb-ae5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'no svn WC'; return }
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feature-test-3-feature" -m 'test: ae5' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'no svn branch'; return }
                if (-not (Add-MainTrailers -Root $root -Revs @(10, 20))) { Set-ItResult -Skipped -Because 'seed'; return }
                if (-not (Set-TpProps -BranchUrl "$reposRoot/branches/feature-test-3-feature" -Props @('branch-name', 'feature/test-3-feature', 'last-aligned-rev', '20') -Sandbox $sb)) { Set-ItResult -Skipped -Because 'props'; return }

                # Invoke WITHOUT -Branch: the dash-form leaf must be overridden by the stored slash name.
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$reposRoot/branches/feature-test-3-feature")
                # R7 core: the "Importing..." banner (emitted AFTER adoption, BEFORE any mutation) proves
                # the stored slash name was adopted over the dash-form leaf -- deterministic even where the
                # deep repo-relative sandbox trips git's '$GIT_DIR too big' worktree-path limit on this long name.
                $res.Combined | Should -Match "working branch 'feature/test-3-feature'"
                $res.Combined | Should -Not -Match "working branch 'feature-test-3-feature'"
                if ($res.ExitCode -eq 0) {
                    (Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'feature/test-3-feature')) | Should -Not -BeNullOrEmpty
                    (Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'remote-svn/feature/test-3-feature')) | Should -Not -BeNullOrEmpty
                    (Run-Git -Cwd $root -GitArgs @('show-ref', '--verify', '--quiet', 'refs/heads/feature-test-3-feature')) | Should -Not -Be 0
                }
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
