# Remove-SvnFile.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Remove-SvnFile.ps1
#
# Contract: -Path <bridge-relative> [-Branch <name=main>]. Removes one path from the SVN side of a
# bridge. Pre-flight (before any svn delete) resolves the bridge, requires the path to exist +
# be svn-tracked, and classifies git-tracked vs not on the bridge:
#   git-TRACKED  -> RECONCILE: svn delete + `sync: svn r<rev>` commit + `Merge branch '<r>' into <b>`
#                  --no-ff (formats MIRROR Sync-FromSvn exactly);
#   git-UNTRACKED/-IGNORED -> NO reconcile (bridge git tree stays clean).
# Not svn-tracked / missing path / missing bridge -> fail loudly, zero side effects.
#
# Every svn scenario builds a real bridge via Initialize-GitSvnBridge (already tested), so all of
# these self-SKIP when svn is absent. The arg-validation case runs on plain git.
#
# KTD8 isolation: the test's OWN svn client calls (list/info) pass --config-dir <sandbox>/.svnconfig.
# The script-under-test's internal svn calls are out of the test's control (same stance as
# Initialize-GitSvnBridge.test).

# --- Discovery-time svn gate (evaluated BEFORE BeforeAll) -----------------------
$SvnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $SvnAvailable = ($LASTEXITCODE -eq 0)
} catch {
    $SvnAvailable = $false
}

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Remove-SvnFile.ps1')
    $script:InitScript      = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Initialize-GitSvnBridge.ps1')
    $script:BuildScript     = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-SvnCommit.ps1')
    $script:SubmitScript    = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Submit-SvnCommit.ps1')

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    # Fence child git so a not-yet-a-repo dir cannot escape upward into the real repo.
    $script:PrevCeiling = $env:GIT_CEILING_DIRECTORIES
    $script:SandboxBase = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '.sandbox', 'sandboxes'))
    $null = New-Item -ItemType Directory -Path $script:SandboxBase -Force
    $env:GIT_CEILING_DIRECTORIES = $script:SandboxBase

    function Get-WorktreesDir { param([string]$Root) [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees') }
    function Get-BridgePath {
        param([string]$Root, [string]$Branch = 'main')
        $dash = $Branch -replace '/', '-'
        [System.IO.Path]::Combine((Get-WorktreesDir -Root $Root), "remote-svn-$dash")
    }

    # svn list / info on a working copy, isolated via --config-dir (KTD8).
    function Svn-ListWc {
        param([string]$WcPath, [string]$ConfigDir)
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        try { $out = & svn list --config-dir $ConfigDir $WcPath 2>$null } finally { $ErrorActionPreference = $prev }
        return ($out | Out-String)
    }

    # Build a bridge whose SVN content is: .gitignore(*.log) + app.txt + foo.csproj.user (both
    # git-tracked) + debug.log (git-IGNORED via *.log) + any $ExtraFiles. Returns @{Root;Cfg;Bridge}
    # or $null if the svn pipeline / bridge build failed. Also lands the tp-setup skeleton gitignore
    # so main ignores the nested bridge container (else main is dirty and reconcile refuses).
    function New-BridgeWithFiles {
        param([string]$Sandbox, [hashtable]$ExtraFiles = @{})
        $root = [System.IO.Path]::Combine($Sandbox, 'test-turbo-plugin')
        $cfg  = [System.IO.Path]::Combine($Sandbox, '.svnconfig')
        $repo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($repo -replace '\\', '/')
        $seed = [System.IO.Path]::Combine($Sandbox, 'seed')
        $null = New-Item -ItemType Directory -Path $seed -Force
        $enc = New-Object Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, '.gitignore'), "*.log`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'app.txt'), "app`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'foo.csproj.user'), "prefs`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'debug.log'), "noise`n", $enc)
        foreach ($k in $ExtraFiles.Keys) {
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, $k), $ExtraFiles[$k], $enc)
        }
        & svn import $seed $uri -m seed --no-auto-props --config-dir $cfg 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }

        $null = New-Item -ItemType Directory -Path $root -Force
        $null = Run-Git -Cwd $root -GitArgs @('init', '-b', 'main')
        $null = Run-Git -Cwd $root -GitArgs @('config', 'user.email', 'test@turbo-plugin')
        $null = Run-Git -Cwd $root -GitArgs @('config', 'user.name',  'turbo-plugin-test')

        $res = Invoke-PsScript -ScriptPath $script:InitScript -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
        if ($res.ExitCode -ne 0) { return $null }

        # tp-setup skeleton gitignore (so main ignores the nested bridge container).
        $gi = [System.IO.Path]::Combine($root, '.gitignore')
        [System.IO.File]::AppendAllText($gi, ".turbo-plugin/worktrees/`n.svn/`n", $enc)
        $null = Run-Git -Cwd $root -GitArgs @('add', '.gitignore')
        $null = Run-Git -Cwd $root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-m', 'chore: skeleton gitignore')

        return @{ Root = $root; Cfg = $cfg; Bridge = (Get-BridgePath -Root $root) }
    }

    # Caller precondition for Un-track A: stop git-tracking on main (keep the disk file) + ignore it.
    function Untrack-OnMain {
        param([string]$Root, [string]$RelPath)
        $null = Run-Git -Cwd $Root -GitArgs @('rm', '--cached', $RelPath)
        $enc = New-Object Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText([System.IO.Path]::Combine($Root, '.gitignore'), "$RelPath`n", $enc)
        $null = Run-Git -Cwd $Root -GitArgs @('add', '.gitignore')
        $null = Run-Git -Cwd $Root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-m', "chore: stop tracking $RelPath")
    }

    # Push main into the bridge (build + submit) to reach the NORMAL post-push state where
    # remote-svn/main is ahead of main by a benign `Merge branch 'main' into remote-svn/main`.
    # Returns $true on success.
    function Push-Main {
        param([string]$Root)
        $b = Invoke-PsScript -ScriptPath $script:BuildScript  -Cwd $Root -ScriptArgs @('-Branch', 'main')
        if ($b.ExitCode -ne 0) { return $false }
        $s = Invoke-PsScript -ScriptPath $script:SubmitScript -Cwd $Root -ScriptArgs @('-Branch', 'main', '-Title', 'sync main to svn')
        return ($s.ExitCode -eq 0)
    }
}

AfterAll {
    if ($null -eq $script:PrevCeiling) {
        Remove-Item Env:\GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue
    } else {
        $env:GIT_CEILING_DIRECTORIES = $script:PrevCeiling
    }
}

Describe 'Remove-SvnFile' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Case 1: missing -Path -> required-arg error (no svn needed)' {
        It 'exits non-zero and complains -Path is required' {
            $sb = New-Sandbox -Tag 'rmsvn-1'
            try {
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $sb -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match '-Path'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 2: Inconsistency B (git-ignored path) -> no-reconcile' {
        It 'removes it from SVN, leaves the bridge clean and remote-svn/main with NO new commit' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-2'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }

                $revBefore = Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('rev-parse', 'remote-svn/main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'debug.log')
                $res.ExitCode | Should -Be 0

                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -Not -Match 'debug\.log'
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
                $revAfter = Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('rev-parse', 'remote-svn/main')
                $revAfter | Should -BeExactly $revBefore
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 3: Un-track A (git-tracked path) -> reconcile with pull-identical commit formats' {
        It 'removes from SVN, sync+merge formats match Sync-FromSvn, main keeps the disk file untracked' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-3'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }

                # caller precondition on main: git rm --cached + ignore + commit (keep disk file).
                Untrack-OnMain -Root $ctx.Root -RelPath 'foo.csproj.user'
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'foo.csproj.user')
                $res.ExitCode | Should -Be 0

                # gone from SVN.
                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -Not -Match 'foo\.csproj\.user'
                # remote-svn/main tip is a canonical sync commit; main tip is the canonical merge.
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('log', '-1', '--pretty=%s', 'remote-svn/main')) | Should -Match '^sync: svn r\d+$'
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('log', '-1', '--pretty=%s')) | Should -BeExactly "Merge branch 'remote-svn/main' into main"
                # Every non-merge remote-svn/main commit is bridge-managed: a classic 'sync: svn r<N>'
                # reconcile/boundary commit, or a per-revision replay MARKED by refs/tp/svn/<N>
                # (U7 made the first import per-revision). A stray bare commit matches neither.
                $markedShas = @((Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('for-each-ref', '--format=%(objectname)', 'refs/tp/svn/*')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $shas = @((Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('log', '--no-merges', '--pretty=%H', 'remote-svn/main')) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                foreach ($sha in $shas) {
                    $subj = Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('show', '-s', '--format=%s', $sha)
                    if ($subj -match '^sync: svn r\d+$') { continue }
                    ($markedShas -contains $sha) | Should -BeTrue -Because "unexpected remote-svn/main commit subject: '$subj'"
                }
                # main keeps the disk file but no longer tracks it.
                [System.IO.File]::Exists([System.IO.Path]::Combine($ctx.Root, 'foo.csproj.user')) | Should -BeTrue
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('ls-files', 'foo.csproj.user')) | Should -BeNullOrEmpty
                # bridge clean.
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 4: pre-flight rejects a path not present in the bridge' {
        It 'exits non-zero, does not touch SVN' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-4'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }
                $listBefore = Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'nope.txt')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'not found in bridge'

                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -BeExactly $listBefore
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 5: pre-flight rejects an unversioned (not svn-tracked) path' {
        It 'exits non-zero with the not-svn-tracked wording, no side effects' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-5'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }
                # a brand-new *.log file in the bridge: on disk, git-IGNORED (via *.log, so the bridge
                # porcelain stays clean and we reach the svn check), but NOT under svn control (svn '?').
                $enc = New-Object Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($ctx.Bridge, 'extra.log'), "loose`n", $enc)

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'extra.log')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'not tracked by SVN'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 6: non-ASCII (CJK) filename reconciles + removes cleanly' {
        It 'removes a git-tracked CJK-named file from SVN via UTF-8 commit' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-6'
            try {
                # CJK name built from code points so THIS test file stays pure-ASCII (no BOM needed).
                $cjk = ([string][char]0x6E2C) + ([string][char]0x8A66) + '.txt'   # U+6E2C U+8A66 = a CJK word

                # A host whose ANSI codepage has no bytes for these characters cannot pass the name
                # to svn.exe as argv at all -- see the note on Test-AnsiCodepageCanHold. Say which
                # codepage, so this reads as "cannot be tested here", not "quietly not tested".
                if (-not (Test-AnsiCodepageCanHold -Text $cjk)) {
                    Set-ItResult -Skipped -Because "the host ANSI codepage ($(Get-AnsiCodepageName)) cannot represent this filename"
                    return
                }

                $ctx = New-BridgeWithFiles -Sandbox $sb -ExtraFiles @{ $cjk = "cjk`n" }
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }

                Untrack-OnMain -Root $ctx.Root -RelPath $cjk
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', $cjk)
                $res.ExitCode | Should -Be 0
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('log', '-1', '--pretty=%s', 'remote-svn/main')) | Should -Match '^sync: svn r\d+$'
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 7: reconcile pre-flight refuses a DIRTY main worktree BEFORE the irreversible svn delete' {
        It 'refuses on dirty main, leaves SVN untouched (nothing changed)' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-7'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }
                # untrack the target on main (isolate the dirty condition), then dirty an UNRELATED tracked file.
                Untrack-OnMain -Root $ctx.Root -RelPath 'foo.csproj.user'
                $enc = New-Object Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($ctx.Root, 'app.txt'), "locally modified`n", $enc)
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('status', '--porcelain')) | Should -Not -BeNullOrEmpty

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'foo.csproj.user')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'uncommitted changes'
                # svn delete did NOT happen -- file still in SVN, bridge unchanged.
                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -Match 'foo\.csproj\.user'
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 8: data-safety -- refuses when main still tracks the path (caller skipped git rm --cached)' {
        It 'refuses so the reconcile merge cannot delete the kept-local file; SVN + disk untouched' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-8'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }
                # DO NOT Untrack-OnMain: main still tracks foo.csproj.user (the contract violation).
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'foo.csproj.user')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'still git-tracked in the main worktree'
                # nothing deleted: still in SVN, still on disk in main.
                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -Match 'foo\.csproj\.user'
                [System.IO.File]::Exists([System.IO.Path]::Combine($ctx.Root, 'foo.csproj.user')) | Should -BeTrue
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 9: regression -- Un-track A reconciles in the NORMAL post-push state' {
        # After a push, remote-svn/main is ahead of main by a benign `Merge branch 'main' into
        # remote-svn/main` commit. Before the `--no-merges` guard fix, the unmerged-sync guard
        # false-fired on that merge and refused.
        It 'no false unmerged-sync refusal; removes from SVN and reconciles cleanly' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-9'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }
                if (-not (Push-Main -Root $ctx.Root)) { Set-ItResult -Skipped -Because 'could not push main to reach post-push state'; return }
                # Confirm post-push: remote-svn/main ahead by exactly one commit, and it is a MERGE.
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'main..remote-svn/main')).Trim() | Should -Be '1'
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', '--no-merges', 'main..remote-svn/main')).Trim() | Should -Be '0'

                Untrack-OnMain -Root $ctx.Root -RelPath 'foo.csproj.user'
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'foo.csproj.user')
                $res.Combined | Should -Not -Match 'unmerged sync'
                $res.ExitCode | Should -Be 0
                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -Not -Match 'foo\.csproj\.user'
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('log', '-1', '--pretty=%s', 'remote-svn/main')) | Should -Match '^sync: svn r\d+$'
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('log', '-1', '--pretty=%s')) | Should -BeExactly "Merge branch 'remote-svn/main' into main"
                [System.IO.File]::Exists([System.IO.Path]::Combine($ctx.Root, 'foo.csproj.user')) | Should -BeTrue
                (Run-Git-Capture -Cwd $ctx.Bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 10: a GENUINE orphaned sync (non-merge sync ahead) is still refused' {
        # The --no-merges guard must not weaken protection: a real interrupted pull leaves a
        # non-merge `sync:` commit ahead of main, and Remove-SvnFile must still refuse.
        It 'refuses on a non-merge sync ahead; SVN untouched' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'rmsvn-10'
            try {
                $ctx = New-BridgeWithFiles -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build bridge'; return }
                # Simulate an interrupted pull: a non-merge sync commit on remote-svn/main not merged to main.
                $null = Run-Git -Cwd $ctx.Bridge -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'sync: svn r777')
                Untrack-OnMain -Root $ctx.Root -RelPath 'foo.csproj.user'
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Path', 'foo.csproj.user')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'unmerged sync'
                (Svn-ListWc -WcPath $ctx.Bridge -ConfigDir $ctx.Cfg) | Should -Match 'foo\.csproj\.user'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }
}
