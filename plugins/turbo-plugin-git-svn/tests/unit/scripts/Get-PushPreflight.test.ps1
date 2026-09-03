# Get-PushPreflight.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-git-svn/scripts/Get-PushPreflight.ps1
# Token contract: emits exactly ONE terminal token prefixed 'TP_TOKEN:'.
# Precedence: DETACHED_HEAD > BRANCH_MISMATCH_WARNING > BRIDGE_ABSENT > BRIDGE_PRESENT.
# These tests build their own minimal git sandboxes (no svn / no .turbo-plugin worktrees
# needed for the token-routing scenarios most worth pinning).

# Skip conditions must be resolved at DISCOVERY time (Pester 5): a flag set in BeforeAll
# is $null during discovery, which would skip everything.
BeforeDiscovery {
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Get-PushPreflight.ps1')
    $script:SandboxBase = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')
    $null = New-Item -ItemType Directory -Path $script:SandboxBase -Force

    function Invoke-GitSilent {
        param([string]$Dir)
        $rest = $args
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & git -C $Dir @rest 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $oldEap }
    }

    function New-GitRepo {
        # Fresh git repo on branch 'main' with one commit. Returns its path.
        $dir = [System.IO.Path]::Combine($script:SandboxBase, "pf-$([Guid]::NewGuid().ToString('N'))")
        $null = New-Item -ItemType Directory -Path $dir -Force
        Invoke-GitSilent $dir init -q -b main
        Invoke-GitSilent $dir config user.email 'test@example.invalid'
        Invoke-GitSilent $dir config user.name 'Test'
        Set-Content -LiteralPath ([System.IO.Path]::Combine($dir, 'a.txt')) -Value 'x'
        Invoke-GitSilent $dir add -A
        Invoke-GitSilent $dir -c commit.gpgsign=false commit -q -m 'init'
        return $dir
    }

    function Invoke-Preflight {
        param([string]$WorkDir, [string]$Branch, [string]$RepoRoot = '')
        $oldLoc = Get-Location
        try {
            Set-Location -LiteralPath $WorkDir
            $psArgs = @('-Branch', $Branch)
            if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $psArgs += @('-RepoRoot', $RepoRoot) }
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ScriptUnderTest @psArgs 2>$null
            $exit = $LASTEXITCODE
        } catch {
            $out = @($_.Exception.Message); $exit = 99
        } finally {
            Set-Location -LiteralPath $oldLoc
        }
        $text = ($out -join "`n")
        $tokenLines = @(($text -split "`r?`n") | Where-Object { $_ -like 'TP_TOKEN:*' })
        return @{
            Stdout     = $text
            Exit       = $exit
            Token      = ($tokenLines | Select-Object -First 1)
            TokenCount = $tokenLines.Count
        }
    }

    $script:hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
}

Describe 'Get-PushPreflight token contract' {

    Context 'detached / literal HEAD' {
        It 'rejects literal --branch HEAD with DETACHED_HEAD' -Skip:(-not $hasGit) {
            $repo = New-GitRepo
            $r = Invoke-Preflight -WorkDir $repo -Branch 'HEAD'
            $r.Token | Should -BeLike 'TP_TOKEN:DETACHED_HEAD*'
        }
    }

    Context 'anti-forge sanitization (sanitize before emitting any token)' {
        It 'rejects a branch with an embedded fake TP_TOKEN line, emits no token, exit 1' -Skip:(-not $hasGit) {
            $repo = New-GitRepo
            $r = Invoke-Preflight -WorkDir $repo -Branch "foo`nTP_TOKEN:BRIDGE_PRESENT requested=foo"
            $r.Exit | Should -Be 1
            $r.TokenCount | Should -Be 0
        }
        It 'rejects a path-traversal branch name, emits no token, exit 1' -Skip:(-not $hasGit) {
            $repo = New-GitRepo
            $r = Invoke-Preflight -WorkDir $repo -Branch 'a/../b'
            $r.Exit | Should -Be 1
            $r.TokenCount | Should -Be 0
        }
    }

    Context 'branch mismatch (current != requested) takes precedence over bridge state' {
        It 'emits BRANCH_MISMATCH_WARNING with current/requested payload' -Skip:(-not $hasGit) {
            $repo = New-GitRepo   # HEAD on main
            $r = Invoke-Preflight -WorkDir $repo -Branch 'feat-x'
            $r.Token | Should -BeLike 'TP_TOKEN:BRANCH_MISMATCH_WARNING*current=main*requested=feat-x*'
        }
        It 'emits exactly ONE TP_TOKEN line' -Skip:(-not $hasGit) {
            $repo = New-GitRepo
            $r = Invoke-Preflight -WorkDir $repo -Branch 'feat-x'
            $r.TokenCount | Should -Be 1
        }
    }

    Context 'issue #161 - the predicate is "checked out anywhere", not "the main worktree is on it"' {
        # The dead-end this fixes: developing a branch in its own worktree means the main
        # worktree CANNOT hold it (git forbids it), so the old form warned every time -- and
        # because mismatch outranks the bridge gate, first push could never be reached.
        It 'does NOT warn while a LINKED worktree holds the branch, and reaches the bridge gate' -Skip:(-not $hasGit) {
            $repo = New-GitRepo   # main worktree stays on main
            $wt = [System.IO.Path]::Combine($script:SandboxBase, "pfwt-$([Guid]::NewGuid().ToString('N').Substring(0,8))")
            Invoke-GitSilent $repo worktree add -q -b feat-x $wt

            # Guard the fixture: a silently failed `worktree add` leaves no worktree holding
            # feat-x, which is exactly the state the OLD code produced -- the case would then
            # pass for the wrong reason and assert nothing.
            (& git -C $wt rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'feat-x'

            # Run from INSIDE the linked worktree -- the situation from the report.
            $r = Invoke-Preflight -WorkDir $wt -Branch 'feat-x'
            $r.Token | Should -Not -BeLike 'TP_TOKEN:BRANCH_MISMATCH_WARNING*'
            $r.Token | Should -BeLike 'TP_TOKEN:BRIDGE_ABSENT*requested=feat-x*target=*'
            $r.TokenCount | Should -Be 1
        }

        # The sharp reverse. The mismatch case above uses a branch that does not exist at all,
        # so an implementation that merely asked "does this branch exist" would pass both and
        # still be wrong. The question is checkout, not existence.
        It 'still warns for a branch that EXISTS but no worktree holds' -Skip:(-not $hasGit) {
            $repo = New-GitRepo
            Invoke-GitSilent $repo branch feat-parked
            $r = Invoke-Preflight -WorkDir $repo -Branch 'feat-parked'
            $r.Token | Should -BeLike 'TP_TOKEN:BRANCH_MISMATCH_WARNING*current=main*requested=feat-parked*'
            $r.TokenCount | Should -Be 1
        }
    }

    Context 'bridge absent (current == requested, no bridge worktree)' {
        It 'emits BRIDGE_ABSENT carrying the resolved target' -Skip:(-not $hasGit) {
            $repo = New-GitRepo   # on main; no .turbo-plugin/worktrees
            $r = Invoke-Preflight -WorkDir $repo -Branch 'main'
            $r.Token | Should -BeLike 'TP_TOKEN:BRIDGE_ABSENT*requested=main*target=*'
        }
    }

    Context 'post-sanitization failure emits TP_TOKEN:ERROR (not tokenless, not a routing token)' {
        # A valid branch passes sanitization; running OUTSIDE any git repo makes Get-MainWorktree
        # throw AFTER $sanitized is set. The catch must emit exactly one TP_TOKEN:ERROR so the
        # SKILL (which routes only by TP_TOKEN: lines) is never handed an undocumented "exit 1,
        # no token". This is the PS<->sh parity path hardened.
        It 'emits a single TP_TOKEN:ERROR for a valid branch run outside a git repo' -Skip:(-not $hasGit) {
            $nonGit = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "pf-nongit-$([Guid]::NewGuid().ToString('N'))")
            $null = New-Item -ItemType Directory -Path $nonGit -Force
            try {
                # Hermetic guard: this scenario REQUIRES a dir outside any git repo so
                # Get-MainWorktree fails. If the temp root unusually sits under a repo, skip
                # rather than false-pass (we'd otherwise get a routing token, not ERROR).
                $inRepo = $false
                try { & git -C $nonGit rev-parse --git-dir 2>$null | Out-Null; $inRepo = ($LASTEXITCODE -eq 0) } catch { $inRepo = $false }
                if ($inRepo) {
                    # Make the skip visible in CI logs -- otherwise this regression guard could
                    # silently vanish (test green) if a runner's temp root sits under a repo.
                    Write-Warning 'TG-1 skipped: temp dir is inside a git repo; TP_TOKEN:ERROR regression is UNGUARDED this run.'
                    Set-ItResult -Skipped -Because 'temp dir is inside a git repo'; return
                }

                $r = Invoke-Preflight -WorkDir $nonGit -Branch 'feat-x'
                $r.Exit | Should -Be 1
                $r.Token | Should -BeLike 'TP_TOKEN:ERROR*'
                $r.TokenCount | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $nonGit -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context '-RepoRoot names the repository instead of inheriting the caller''s directory' {
        # Contrast with the Context above: the SAME non-repo working directory that yields
        # TP_TOKEN:ERROR without -RepoRoot must route normally once the repository is named.
        It 'routes on the named repo while cwd is outside any git repo' -Skip:(-not $hasGit) {
            $repo = New-GitRepo   # on main; no .turbo-plugin/worktrees
            $nonGit = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "pf-outside-$([Guid]::NewGuid().ToString('N'))")
            $null = New-Item -ItemType Directory -Path $nonGit -Force
            try {
                $inRepo = $false
                try { & git -C $nonGit rev-parse --git-dir 2>$null | Out-Null; $inRepo = ($LASTEXITCODE -eq 0) } catch { $inRepo = $false }
                if ($inRepo) {
                    Write-Warning '-RepoRoot test skipped: temp dir is inside a git repo, so cwd alone could produce the token.'
                    Set-ItResult -Skipped -Because 'temp dir is inside a git repo'; return
                }

                $r = Invoke-Preflight -WorkDir $nonGit -Branch 'main' -RepoRoot $repo
                $r.Token | Should -BeLike 'TP_TOKEN:BRIDGE_ABSENT*requested=main*target=*'
                $r.TokenCount | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $nonGit -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'a -RepoRoot that does not exist fails as TP_TOKEN:ERROR, not tokenless' -Skip:(-not $hasGit) {
            # Resolve-GitRoot throws before any git call; the script''s catch must still shape it
            # into the one token the SKILL routes on.
            $repo = New-GitRepo
            $absent = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "pf-absent-$([Guid]::NewGuid().ToString('N'))")
            $r = Invoke-Preflight -WorkDir $repo -Branch 'main' -RepoRoot $absent
            $r.Exit | Should -Be 1
            $r.Token | Should -BeLike 'TP_TOKEN:ERROR*'
            $r.TokenCount | Should -Be 1
        }
    }
}
