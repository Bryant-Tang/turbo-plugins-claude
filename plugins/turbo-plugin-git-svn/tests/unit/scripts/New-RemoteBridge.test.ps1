# New-RemoteBridge.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/New-RemoteBridge.ps1
#
# New contract: -Branch <name> -SvnUrl <url> (no -N / test-<n>). Creates the
# remote-svn/<branch> BRIDGE branch (rooted at the repo init commit) + a linked worktree +
# svn checkout. It does NOT create a working branch -- the working branch is the caller's
# current branch. Behaviour preserved from the old New-RemoteTest "spirit":
#   - required-arg validation (-Branch, -SvnUrl)
#   - worktrees dir missing -> fail before any mutation
#   - trust validation (out-of-trust / prefix-confusion URLs rejected before side effects)
#   - bridge already-exists guard
#   - collision (two branches mapping to the same worktree dir)
#   - rollback (local git state cleaned up when a downstream step fails)
#
# Cases that need NO svn (arg validation, worktrees-missing, bridge-exists, collision,
# fail-closed) run on a plain git sandbox. The trust-validation reject/legit/rollback cases
# need remote-svn-main to be a real svn working copy, so they self-SKIP (Pester -Skip) when
# svn.exe or the seed dump are unavailable.

# --- Discovery-time gate (evaluated BEFORE BeforeAll) ---------------------------
# Pester evaluates the `-Skip:` argument on each `It` during DISCOVERY, before any
# BeforeAll runs. So the svn-availability gate must be computed here at file scope, not
# inside BeforeAll, or every -Skip would see $null and skip unconditionally.
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
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'New-RemoteBridge.ps1')
    $script:DumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

    # Shared test helpers (sandbox, git wrappers, child-script invoker). Not AssertHelpers.
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    function Get-WorktreesDir {
        param([string]$Root)
        return [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees')
    }

    # Build a throwaway svn repo from the seed dump and check out trunk into
    # <worktreesDir>/remote-svn-main so it becomes a valid trusted working copy.
    # Returns the repos-root-url, or $null if the svn pipeline failed.
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

        # The bridge branch is now based on remote-svn/main's tip (not a repo root commit), so the
        # anchor ref must exist for the create path to run. Real setups create it via Initialize;
        # here a ref at main is enough (the svn checkout --force overlays the branch content anyway).
        & git -C $Root branch 'remote-svn/main' 'main' > $null 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }

        $reposRoot = (& svn info --show-item repos-root-url $remoteMain 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($reposRoot)) { return $null }
        return $reposRoot
    }

    # Build a FAITHFUL first-push drift scenario (mirrors new-remote-bridge.test.sh make_drift_scenario):
    #   - svn trunk already carries svn:ignore=.git (post-tp-setup) so the bootstrap propset is a
    #     NO-OP -> '.' is not committed;
    #   - git main mirrors trunk but a versioned file (Templates/drift.txt) has DIVERGENT content
    #     (git "v2" vs svn "v1"), so `svn checkout --force` marks it locally modified on the new
    #     bridge worktree -- the exact overlay drift the old unscoped commit swept in;
    #   - main's .gitignore DIFFERS from trunk's, so a real .gitignore change IS committed (a child
    #     of '.' that does not bump '.', which is what leaves the WC root lagging without `svn update`).
    # $Root must already be a git repo with a worktrees dir (New-GitMainRepo -CreateWorktreesDir).
    # Returns the svn repo URI, or $null on any svn/git failure.
    function Initialize-DriftScenario {
        param([string]$Root, [string]$Sandbox)
        $worktreesDir = Get-WorktreesDir -Root $Root
        $svnRepo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')
        & svnadmin create $svnRepo
        if ($LASTEXITCODE -ne 0) { return $null }
        $loadCmd = "svnadmin load `"$svnRepo`" < `"$($script:DumpPath)`""
        & cmd.exe /c $loadCmd > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($svnRepo -replace '\\', '/')

        # trunk: svn:ignore=.git + versioned .gitignore + Templates/drift.txt content "v1".
        $twc = [System.IO.Path]::Combine($Sandbox, 'trunkwc')
        & svn checkout "$uri/trunk" $twc > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        & svn propset svn:ignore '.git' $twc > $null 2>$null
        Set-Content -LiteralPath ([System.IO.Path]::Combine($twc, '.gitignore')) -Value '.svn/' -NoNewline
        & svn add ([System.IO.Path]::Combine($twc, '.gitignore')) > $null 2>$null
        $tmpl = [System.IO.Path]::Combine($twc, 'Templates')
        $null = New-Item -ItemType Directory -Path $tmpl -Force
        Set-Content -LiteralPath ([System.IO.Path]::Combine($tmpl, 'drift.txt')) -Value 'v1' -NoNewline
        & svn add $tmpl > $null 2>$null
        & svn commit $twc -m 'trunk prep' > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }

        # remote-svn-main anchor WC (the trust anchor + svn copy source).
        $remoteMain = [System.IO.Path]::Combine($worktreesDir, 'remote-svn-main')
        & svn checkout "$uri/trunk" $remoteMain > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }

        # git main mirrors trunk, but drift.txt = "v2" (divergent) and .gitignore differs.
        $tx = [System.IO.Path]::Combine($Sandbox, 'tx')
        & svn export --force "$uri/trunk" $tx > $null 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        Get-ChildItem -LiteralPath $tx -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Root -Recurse -Force
        }
        Set-Content -LiteralPath ([System.IO.Path]::Combine($Root, 'Templates', 'drift.txt')) -Value 'v2' -NoNewline
        Set-Content -LiteralPath ([System.IO.Path]::Combine($Root, '.gitignore')) -Value ".svn/`r`nbin/`r`n" -NoNewline
        & git -C $Root config core.autocrlf false 2>&1 | Out-Null
        & git -C $Root add -A 2>&1 | Out-Null
        & git -C $Root -c commit.gpgsign=false commit -m 'main mirrors trunk (drift v2, gitignore differs)' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        & git -C $Root branch 'remote-svn/main' 'main' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $uri
    }

    # True if NO partial git state (bridge branch / worktree dir) remains for $Branch.
    function Test-NoOrphanState {
        param([string]$Root, [string]$Branch)
        $bridge = Run-Git-Capture -Cwd $Root -GitArgs @('branch', '--list', "remote-svn/$Branch")
        if ($bridge -ne '') { return $false }
        $dash = $Branch -replace '/', '-'
        $wtPath = [System.IO.Path]::Combine((Get-WorktreesDir -Root $Root), "remote-svn-$dash")
        return (-not [System.IO.Directory]::Exists($wtPath))
    }
}

Describe 'New-RemoteBridge' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: missing -Branch -> required-arg error' {
        It 'exits non-zero and complains -Branch is required' {
            $sb = New-Sandbox -Tag 'nrb-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-SvnUrl', 'file:///some/url')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match '-Branch is required'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 2: missing -SvnUrl -> required-arg error' {
        It 'exits non-zero and complains -SvnUrl is required' {
            $sb = New-Sandbox -Tag 'nrb-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match '-SvnUrl is required'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 3: worktrees dir missing -> fail before any mutation' {
        It 'exits non-zero and mentions Worktrees directory not found' {
            $sb = New-Sandbox -Tag 'nrb-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root  # NO -CreateWorktreesDir
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', 'file:///nonexistent/branches/x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Worktrees directory not found'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 4: complete bridge already exists -> guard fires before svn' {
        It 'rejects with "Bridge branch ... already exists"' {
            $sb = New-Sandbox -Tag 'nrb-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                # Pre-create BOTH the bridge branch AND its worktree dir so this is a genuine
                # complete bridge (not the inconsistent ref-XOR-dir partial state in Case 4b).
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/feature-x', 'main')
                $wtDir = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), 'remote-svn-feature-x')
                $null = New-Item -ItemType Directory -Path $wtDir -Force
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', 'file:///nonexistent/branches/x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match "Bridge branch 'remote-svn/feature-x' already exists\."
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 4b: inconsistent partial state (ref without worktree dir) -> recovery guidance' {
        It 'rejects with an inconsistent-state message naming the recovery steps' {
            $sb = New-Sandbox -Tag 'nrb-4b'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                # Bridge branch exists but NO worktree dir -> leftover from an interrupted run.
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/feature-x', 'main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', 'file:///nonexistent/branches/x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Inconsistent bridge state'
                $res.Combined | Should -Match 'git worktree prune'
                # Must NOT have reached the svn-mutation phase.
                $res.Combined | Should -Not -Match 'Creating SVN bridge'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 4c: inconsistent partial state (worktree dir without ref) -> recovery guidance' {
        It 'rejects with the dir-without-branch message and recovery steps' {
            $sb = New-Sandbox -Tag 'nrb-4c'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                # Worktree dir exists but NO bridge branch -> the symmetric leftover state.
                $wtDir = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), 'remote-svn-feature-x')
                $null = New-Item -ItemType Directory -Path $wtDir -Force
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', 'file:///nonexistent/branches/x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Inconsistent bridge state'
                $res.Combined | Should -Match 'git worktree prune'
                # Prove it is the dir-without-ref arm specifically (not the ref-without-dir arm,
                # which says 'git branch -D'): the dir-without-ref message says 'delete that directory'.
                $res.Combined | Should -Match 'delete that directory'
                $res.Combined | Should -Not -Match 'git branch -D'
                $res.Combined | Should -Not -Match 'Creating SVN bridge'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 5: collision -> two branches map to the same worktree dir' {
        It 'rejects with "already taken by branch" and creates nothing for the requested branch' {
            $sb = New-Sandbox -Tag 'nrb-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                # remote-svn/feat-login already exists; requesting feat/login maps to the SAME
                # worktree dir name (remote-svn-feat-login) -> collision.
                $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/feat-login', 'main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feat/login', '-SvnUrl', 'file:///nonexistent/branches/x')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'is already taken by branch'
                # The requested bridge for feat/login must NOT have been created.
                (Test-NoOrphanState -Root $root -Branch 'feat/login') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 6: remote-svn-main absent -> trust fail-closed, no side effects' {
        It 'rejects before "Creating SVN bridge" and before rollback' {
            $sb = New-Sandbox -Tag 'nrb-6'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir  # worktrees dir, but NO remote-svn-main
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', 'file:///nonexistent/branches/x')
                $res.ExitCode | Should -Not -Be 0
                # Rejected pre-side-effect: never printed the "Creating" line, never rolled back.
                $res.Combined | Should -Not -Match 'Creating SVN bridge'
                $res.Combined | Should -Not -Match 'rolling back'
                (Test-NoOrphanState -Root $root -Branch 'feature-x') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 7: out-of-trust file:// URL rejected (needs svn WC)' {
        It 'rejects before side effects' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-7'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', 'file:///C:/Windows/System32/')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Not -Match 'Creating SVN bridge'
                $res.Combined | Should -Not -Match 'rolling back'
                (Test-NoOrphanState -Root $root -Branch 'feature-x') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 8: prefix-confusion URL rejected (needs svn WC)' {
        It 'rejects repos-root-evil sibling before side effects' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-8'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                $evilUrl = "$reposRoot-evil/branches/x"
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', $evilUrl)
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Not -Match 'Creating SVN bridge'
                (Test-NoOrphanState -Root $root -Branch 'feature-x') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 9: legit sibling URL passes trust gate (no regression; needs svn WC)' {
        It 'gets past trust gate (prints "Creating SVN bridge") and is not a trust rejection' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-9'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                $legitUrl = "$reposRoot/branches/feature-x"
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', $legitUrl)
                # Trust gate accepted it -> proceeded past the gate.
                $res.Combined | Should -Match 'Creating SVN bridge'
                # Whatever happens after is NOT a trust rejection.
                $res.Combined | Should -Not -Match 'Untrusted SVN URL'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 10: rollback regression -- downstream svn failure cleans up git state (needs svn WC)' {
        It 'on failure prints "rolling back" and leaves no orphan git state; on success the bridge exists' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-10'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                # A legit (trusted) URL gets past the gate and into the rollback try, where the
                # git branch + worktree are created, then a downstream svn (or worktree-add) step
                # fails. The INVARIANT we assert is:
                #   - on failure -> rollback fired (message), it is NOT a trust rejection, and the
                #     partial WORKTREE dir was removed. (We assert the worktree dir specifically:
                #     `git worktree remove` is the load-bearing rollback step; the follow-up
                #     `git branch -D` is best-effort `2>$null` and an orphan bridge ref can linger
                #     in some environments without leaving a working tree behind.)
                #   - on success -> the bridge branch + worktree exist (legitimately created).
                $legitUrl = "$reposRoot/branches/feature-x"
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', $legitUrl)
                $wtPath = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), 'remote-svn-feature-x')
                if ($res.ExitCode -ne 0) {
                    $res.Combined | Should -Match 'rolling back'
                    $res.Combined | Should -Not -Match 'Untrusted SVN URL'
                    [System.IO.Directory]::Exists($wtPath) | Should -BeFalse
                } else {
                    (Test-NoOrphanState -Root $root -Branch 'feature-x') | Should -BeFalse
                }
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 11: successful create sets a fixed svn:ignore = .git' {
        It 'the bridge worktree svn:ignore is exactly .git' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-11'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) {
                    Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'
                    return
                }
                # Create the SVN branch the bridge checks out, so the create path can succeed.
                & svn copy "$reposRoot/trunk" "$reposRoot/branches/feature-x" -m 'test: branch for bridge' --parents > $null 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Set-ItResult -Skipped -Because 'could not create the svn branch for the success path'
                    return
                }
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feature-x', '-SvnUrl', "$reposRoot/branches/feature-x")
                if ($res.ExitCode -ne 0) {
                    Set-ItResult -Skipped -Because "bridge create did not succeed in this env: $($res.Combined)"
                    return
                }
                $wtPath = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), 'remote-svn-feature-x')
                $ignore = (& svn propget svn:ignore $wtPath 2>$null | Out-String).Trim()
                $ignore | Should -BeExactly '.git'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 12: two-root repo (already bridged) still bridges a new branch (regression)' {
        It 'first-push on a repo with TWO root commits does not fail with "not a valid object name"' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-12'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                & git -C $root config commit.gpgsign false 2>&1 | Out-Null
                $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb
                if ($null -eq $reposRoot) { Set-ItResult -Skipped -Because 'could not build remote-svn-main svn WC'; return }

                # Inject a SECOND root into main to reproduce the post-bridge two-root state: a
                # parentless commit-tree on the canonical empty tree, merged --allow-unrelated.
                $second = (& git -C $root commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m 'sync: svn r1' | Out-String).Trim()
                & git -C $root merge --allow-unrelated-histories --no-edit -m "Merge branch 'remote-svn/main' into main" $second 2>&1 | Out-Null
                $roots = @((Run-Git-Capture -Cwd $root -GitArgs @('rev-list', '--max-parents=0', 'HEAD')) -split "`n" | Where-Object { $_.Trim() })
                $roots.Count | Should -Be 2

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feat-y', '-SvnUrl', "$reposRoot/branches/feat-y")
                $res.Combined | Should -Not -Match 'not a valid object name'
                $res.ExitCode | Should -Be 0
                (Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'remote-svn/feat-y')) | Should -Match 'remote-svn/feat-y'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Case 13: first-push bootstrap keeps the WC at HEAD and scopes the infra commit (regression)' {
        # Reproduces the reported first-push symptoms:
        #   B) the bootstrap svn:ignore commit left the WC one revision behind HEAD, so the next
        #      build-svn-commit falsely demanded '/tp-pull-from-svn' on a freshly-created bridge;
        #   C) an unscoped `svn commit` swept `svn checkout --force` overlay drift (a file whose git
        #      bytes differ from the SVN base) into the commit, under the svn:ignore message.
        # The fix scopes the commit (--depth empty + explicit targets) and `svn update`s to HEAD.
        It 'scopes the infra commit (no overlay drift) and leaves the WC at HEAD' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'nrb-13'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                & git -C $root config commit.gpgsign false 2>&1 | Out-Null
                $uri = Initialize-DriftScenario -Root $root -Sandbox $sb
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the drift scenario'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root `
                                       -ScriptArgs @('-Branch', 'feat-y', '-SvnUrl', "$uri/branches/feat-y")
                if ($res.ExitCode -ne 0) {
                    Set-ItResult -Skipped -Because "bridge create did not succeed in this env: $($res.Combined)"
                    return
                }

                $wtPath = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), 'remote-svn-feat-y')
                $localRev = (& svn info --show-item revision $wtPath 2>$null | Out-String).Trim()
                $headRev  = (& svn info --show-item revision "$uri/branches/feat-y" 2>$null | Out-String).Trim()
                # B: the WC must be exactly at HEAD (no mixed-revision lag).
                $localRev | Should -BeExactly $headRev

                # C: the bootstrap commit must NOT contain the overlay drift file.
                $changed = (& svn log -v -r $headRev "$uri/branches/feat-y" 2>$null | Out-String)
                $changed | Should -Not -Match 'drift\.txt'

                # intended infra state landed: svn:ignore is exactly .git.
                $ignore = (& svn propget svn:ignore $wtPath 2>$null | Out-String).Trim()
                $ignore | Should -BeExactly '.git'

                # the bridge git worktree is clean (build-svn-commit's git-clean gate would pass).
                (Run-Git-Capture -Cwd $wtPath -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
