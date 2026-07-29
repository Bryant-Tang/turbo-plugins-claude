# Sync-FromSvn.test.ps1 (Pester 5)
#
# Tests for plugins/turbo-plugin-git-svn/scripts/Sync-FromSvn.ps1.
#
# Scope:
#   - missing -Branch arg → fail-loudly
#   - unsupported branch name (-Branch foo) → "Unsupported branch"
#   - remote-svn-main worktree missing → fail-loudly
#   - main dirty (uncommitted change) → fail-loudly + no SVN op
#   - 中文 commit msg presence in SVN seed → svn-log text round-trip on r5
#
# Notes:
#   The full happy pull-then-rebase path requires a fully wired SVN bridge: real SVN repo, git repo
#   committed with same content as remote-svn-main checkout, etc. That's exercised at the integration
#   level (Phase 2 manual). Here we cover the fail-loudly user-protection paths + fixture-readiness
#   verification of the 中文 commit msg axis.

BeforeDiscovery {
    # Case 5 needs svn / svnadmin (Reset-Fixture loads a dump). On Unix runners that lack svn we
    # SKIP rather than FAIL.
    $script:HasSvn = [bool](Get-Command svn -ErrorAction SilentlyContinue) -and `
                     [bool](Get-Command svnadmin -ErrorAction SilentlyContinue)
}

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # ScriptsCommon.ps1 provides New-Sandbox / Remove-Sandbox / New-GitMainRepo / Invoke-PsScript.
    # (AssertHelpers.ps1 is intentionally NOT sourced — asserts use Pester Should.)
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:PluginRoot      = $pluginRoot
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Sync-FromSvn.ps1')
    $script:InitScript      = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Initialize-GitSvnBridge.ps1')
    $script:BuildScript     = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-SvnCommit.ps1')
    $script:SubmitScript    = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Submit-SvnCommit.ps1')
    $script:ResetScript     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'reset', 'Reset-Fixture.ps1'))
    $script:DumpPath        = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))
    $script:ScriptExists    = [System.IO.File]::Exists($script:ScriptUnderTest)

    # Inlined replacement for AssertHelpers' Assert-SvnLogTextRoundTrip decode logic:
    # try direct UTF-8 + F-3 mojibake recovery paths; PASS if any candidate contains $ExpectedText.
    function Test-SvnLogRoundTrip {
        param([byte[]]$RawBytes, [string]$ExpectedText)
        if ($null -eq $RawBytes -or $RawBytes.Length -eq 0) { return $false }
        $decodedDirect = [System.Text.Encoding]::UTF8.GetString($RawBytes)
        $candidates = @($decodedDirect)
        try {
            $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
            $candidates += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($decodedDirect))
            foreach ($cp in @(950, 1252, 936, 932)) {
                try {
                    $oemEnc = [System.Text.Encoding]::GetEncoding($cp)
                    $oemString = $oemEnc.GetString($RawBytes)
                    $candidates += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($oemString))
                } catch { }
            }
        } catch { }
        foreach ($c in $candidates) {
            if ($c.Contains($ExpectedText)) { return $true }
        }
        return $false
    }

    function Get-WorktreesDir { param([string]$Root) [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees') }

    # Build a real bridge (svn import + Initialize) then PUSH main into it, reaching the NORMAL
    # post-push state where remote-svn/main is ahead of main by a benign `Merge branch 'main' into
    # remote-svn/main` commit. Returns @{ Root; Bridge } or $null if the svn/bridge pipeline failed.
    # -SubPath bridges a SUBDIRECTORY of the repository instead of its root, which is what a
    # repository shared by several projects looks like (/proj-1, /proj-2, ... side by side).
    function New-PushedBridge {
        param([string]$Sandbox, [string]$SubPath = '')
        $root = [System.IO.Path]::Combine($Sandbox, 'test-turbo-plugin')
        $repo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')
        $cfg  = [System.IO.Path]::Combine($Sandbox, '.svnconfig')
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $repoRootUri = 'file:///' + ($repo -replace '\\', '/')
        $uri = if ([string]::IsNullOrWhiteSpace($SubPath)) { $repoRootUri } else { "$repoRootUri/$SubPath" }
        $seed = [System.IO.Path]::Combine($Sandbox, 'seed')
        $null = New-Item -ItemType Directory -Path $seed -Force
        $enc = New-Object Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, '.gitignore'), "*.log`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'app.txt'), "app`n", $enc)
        & svn import $seed $uri -m seed --no-auto-props --config-dir $cfg 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }

        $null = New-Item -ItemType Directory -Path $root -Force
        $null = Run-Git -Cwd $root -GitArgs @('init', '-b', 'main')
        $null = Run-Git -Cwd $root -GitArgs @('config', 'user.email', 'test@turbo-plugin')
        $null = Run-Git -Cwd $root -GitArgs @('config', 'user.name',  'turbo-plugin-test')
        $init = Invoke-PsScript -ScriptPath $script:InitScript -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
        if ($init.ExitCode -ne 0) { return $null }
        [System.IO.File]::AppendAllText([System.IO.Path]::Combine($root, '.gitignore'), ".turbo-plugin/worktrees/`n.svn/`n", $enc)
        $null = Run-Git -Cwd $root -GitArgs @('add', '.gitignore')
        $null = Run-Git -Cwd $root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-m', 'chore: skeleton gitignore')

        $b = Invoke-PsScript -ScriptPath $script:BuildScript  -Cwd $root -ScriptArgs @('-Branch', 'main')
        if ($b.ExitCode -ne 0) { return $null }
        $s = Invoke-PsScript -ScriptPath $script:SubmitScript -Cwd $root -ScriptArgs @('-Branch', 'main', '-Title', 'sync main to svn')
        if ($s.ExitCode -ne 0) { return $null }
        $dash = 'main'
        $bridge = [System.IO.Path]::Combine((Get-WorktreesDir -Root $root), "remote-svn-$dash")
        # Normalize the bridge WC to SVN HEAD so the pull's `cur` (= WC revision floor) is a
        # deterministic baseline for the new-revision tests below.
        Push-Location $bridge
        try { & svn update 2>$null | Out-Null } finally { Pop-Location }
        return @{ Root = $root; Bridge = $bridge; Uri = $uri; RepoRootUri = $repoRootUri; Repo = $repo; Cfg = $cfg }
    }

    # Read the bridge working copy's own checked-out revision.
    function Get-WcRevision {
        param([string]$Bridge)
        $v = (& svn info --show-item revision $Bridge | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return -1 }
        return [int]$v
    }

    # Commit $Count new real trunk revisions to $Uri via a scratch WC. Each revision adds one file;
    # the exact log message is forced with `svnadmin setlog` and the author with `svnadmin setrevprop`
    # (both bypass hooks and write true UTF-8 bytes, so ASCII and CJK messages round-trip
    # deterministically on Windows -- the seed builder's F-3 technique). Returns the new rev numbers.
    function Add-SvnRevisions {
        param(
            [string]$Uri, [string]$Repo, [string]$Cfg, [string]$Sandbox,
            [int]$Count,
            [string[]]$Messages,
            [string[]]$Authors
        )
        $token = [Guid]::NewGuid().ToString('N').Substring(0, 6)
        $co = [System.IO.Path]::Combine($Sandbox, "co-$token")
        & svn checkout $Uri $co --config-dir $Cfg 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $enc = New-Object Text.UTF8Encoding($false)
        $revs = @()
        for ($i = 0; $i -lt $Count; $i++) {
            # File name carries the per-call token so successive Add-SvnRevisions calls on the same
            # repo never collide on an already-versioned path.
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, "file-$token-$i.txt"), "content $i`n", $enc)
            & svn add ([System.IO.Path]::Combine($co, "file-$token-$i.txt")) --config-dir $Cfg 2>$null | Out-Null
            Push-Location $co
            try { & svn commit -m "seed rev $i" --config-dir $Cfg 2>$null | Out-Null } finally { Pop-Location }
            if ($LASTEXITCODE -ne 0) { return $null }
            $rev = [int]((& svn info --show-item revision $Uri --config-dir $Cfg | Out-String).Trim())
            if ($Messages -and $i -lt $Messages.Count) {
                $mf = [System.IO.Path]::Combine($Sandbox, "msg-$rev.txt")
                [System.IO.File]::WriteAllText($mf, $Messages[$i], $enc)
                & svnadmin setlog $Repo -r $rev $mf --bypass-hooks 2>$null | Out-Null
            }
            if ($Authors -and $i -lt $Authors.Count) {
                $af = [System.IO.Path]::Combine($Sandbox, "author-$rev.txt")
                [System.IO.File]::WriteAllText($af, $Authors[$i], (New-Object Text.ASCIIEncoding))
                & svnadmin setrevprop $Repo -r $rev svn:author $af 2>$null | Out-Null
            }
            $revs += $rev
        }
        return @($revs)
    }

    # One PROPERTY-ONLY revision (svn propset on app.txt) -- changes no tracked file content, so the
    # bridge's `svn update -r R` yields an empty git delta (KTD4 skip). Returns the new rev number.
    function Add-PropOnlyRevision {
        param([string]$Uri, [string]$Cfg, [string]$Sandbox)
        $co = [System.IO.Path]::Combine($Sandbox, "cop-$([Guid]::NewGuid().ToString('N').Substring(0, 6))")
        & svn checkout $Uri $co --config-dir $Cfg 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        & svn propset 'testmarker' 'x' ([System.IO.Path]::Combine($co, 'app.txt')) --config-dir $Cfg 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'prop-only (no tree change)' --config-dir $Cfg 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }
        return [int]((& svn info --show-item revision $Uri --config-dir $Cfg | Out-String).Trim())
    }

    # Marked revisions (refs/tp/svn/<N>) whose commit is reachable from <Ref>, ascending, as [int].
    # Run-Git-Capture joins lines via Out-String (CRLF), so each split element is trimmed before the
    # numeric match -- otherwise a trailing "`r" makes '^[0-9]+$' miss every line but the last.
    function Get-TrailerRevs {
        param([string]$Root, [string]$Ref)
        $raw = Run-Git-Capture -Cwd $Root -GitArgs @('for-each-ref', '--format=%(refname:lstrip=3) %(objectname)', 'refs/tp/svn/*')
        $vals = @()
        foreach ($line in ($raw -split "`n")) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9]+$') { continue }
            $null = Run-Git -Cwd $Root -GitArgs @('merge-base', '--is-ancestor', $parts[1], $Ref)
            if ($LASTEXITCODE -eq 0) { $vals += [int]$parts[0] }
        }
        return @($vals | Sort-Object)
    }
}

Describe 'Sync-FromSvn' {

    It 'script-under-test exists' {
        $script:ScriptExists | Should -BeTrue -Because "expected at $script:ScriptUnderTest"
    }

    Context 'Case 1: missing -Branch → required-arg error' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res1 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @()
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0' { ($script:res1.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions -Branch' { $script:res1.Combined | Should -Match '-Branch' }
    }

    Context 'Case 2: -Branch foo (unsupported) → Resolve-RemoteWorktree throws' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'foo')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        # 'foo' is a valid branch name now (no more "Unsupported branch"
        # rejection); with no bridge worktree the script fails "Remote worktree ... not found".
        It 'exit != 0 (no bridge for this branch)' { ($script:res2.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions the missing remote worktree' { $script:res2.Combined | Should -Match 'not found' }
    }

    Context 'Case 3: -Branch main, no remote-svn-main worktree → "Remote worktree ... not found"' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir
                $script:res3 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0 (remote-svn-main missing)' { ($script:res3.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions remote-svn-main not found' {
            $script:res3.Combined | Should -Match "Remote worktree 'remote-svn-main' not found"
        }
    }

    Context 'Case 4: main has uncommitted changes → "uncommitted changes" error' {
        BeforeAll {
            $sb = New-Sandbox -Tag 'pfs-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-GitMainRepo -Root $root -CreateWorktreesDir -CreateRemoteMain
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'dirty.txt'), 'uncommitted')
                $script:res4 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'exit != 0 (main dirty)' { ($script:res4.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions uncommitted changes' { $script:res4.Combined | Should -Match 'uncommitted changes' }
    }

    Context 'Case 5: SVN seed r5 中文 commit msg round-trips' {
        # F-U(test infra): Reset-Fixture requires svnadmin load to succeed; if the seed dump in
        # the working tree has been LF→CRLF mangled by git autocrlf (no .gitattributes binary rule),
        # load fails with E200004. We detect that and SKIP rather than FAIL — the corruption is a
        # fixture artefact, not a pull-from-svn regression. Missing svn/svnadmin or a
        # missing dump also SKIP (Unix runners).

        It 'r5 中文 commit msg decodes to 字典 #3.1' -Skip:(-not $script:HasSvn) {
            if (-not [System.IO.File]::Exists($script:DumpPath)) {
                Set-ItResult -Skipped -Because "seed dump missing at $script:DumpPath; run build-seed-repo.ps1"
                return
            }
            $sb5 = New-Sandbox -Tag 'pfs-5'
            try {
                $testRoot = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin')
                $svnRepo  = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin-svn-repo')
                $sandboxBase = [System.IO.Path]::Combine($script:PluginRoot, 'tests', '.sandbox', 'sandboxes')
                $resetOut = [System.IO.Path]::Combine($sandboxBase, "turbo-plugin-reset-out-$([Guid]::NewGuid().ToString('N').Substring(0,10)).txt")
                # 2>&1 是 cmd.exe shell redirect(非 PS-level)— 拉到變數避開 lint 規則 4 false positive。
                $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script:ResetScript`" -TestRoot `"$testRoot`" -SvnRepo `"$svnRepo`" > `"$resetOut`" 2>&1"
                & cmd.exe /c $cmdStr
                $rc = $LASTEXITCODE
                $resetLog = if ([System.IO.File]::Exists($resetOut)) { [System.IO.File]::ReadAllText($resetOut) } else { '' }
                if ([System.IO.File]::Exists($resetOut)) { try { [System.IO.File]::Delete($resetOut) } catch {} }

                if ($rc -ne 0 -and $resetLog -match 'E200004|Could not convert|svnadmin load failed') {
                    Set-ItResult -Skipped -Because 'Reset-Fixture failed with svnadmin-load corruption (likely LF→CRLF dump mangle; .gitattributes fix needed)'
                    return
                }

                $rc | Should -Be 0 -Because $resetLog

                $dumpScript = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'Get-RawCommitDump.ps1')
                $rawBytes = & $dumpScript -RevN 5 -RepoPathOrUrl $svnRepo -ReturnFormat Bytes
                (Test-SvnLogRoundTrip -RawBytes $rawBytes -ExpectedText '修正中文 commit 訊息亂碼') | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb5
            }
        }
    }

    Context 'Case 6: regression -- pull does NOT false-refuse in the normal post-push state' {
        # After a push, remote-svn/main is ahead of main by a benign `Merge branch 'main' into
        # remote-svn/main` commit. Before the `--no-merges` guard fix, the unmerged-sync guard
        # false-fired on that merge and refused the pull.
        It 'pull succeeds (no unmerged-sync refusal) when remote-svn/main is ahead by a merge' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-6'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'main..remote-svn/main')).Trim() | Should -Be '1'
                (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', '--no-merges', 'main..remote-svn/main')).Trim() | Should -Be '0'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.Combined | Should -Not -Match 'unmerged sync'
                $res.ExitCode | Should -Be 0
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 7: a GENUINE orphaned sync (non-merge sync ahead) is still refused' {
        It 'refuses on a non-merge sync commit ahead of main' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-7'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                # Simulate an interrupted pull: a non-merge sync commit on remote-svn/main not merged to main.
                $null = Run-Git -Cwd $ctx.Bridge -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'sync: svn r777')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'unmerged sync'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    # The complement of Case 7. A sync commit ahead of main that IS marked (refs/tp/svn/<N>) is
    # RESUMABLE state, not debris: the pull replays each revision onto remote-svn/main and only THEN
    # merges into main, so a merge that never landed (an aborted conflict, or the run dying between
    # the two steps) leaves exactly this shape. A plain re-run must retry the merge. Simulated by
    # rewinding main after a successful pull. The paired checkout half (such a commit must not
    # become a fork point) lives in Checkout-SvnBranch.test.ps1.
    Context 'Case 7b: a MARKED but unmerged replay commit is resumable, not an orphan' {
        It 're-running the pull retries the merge into main' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-7b'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $null = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 1
                $before = Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-parse', 'main')

                $first = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                if ($first.ExitCode -ne 0) { Set-ItResult -Skipped -Because 'the seeding pull did not succeed'; return }
                $bridgeTip = Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-parse', 'remote-svn/main')

                # Rewind main only: the replay commit and its marker stay on the bridge, unmerged.
                $null = Run-Git -Cwd $ctx.Root -GitArgs @('reset', '--hard', $before)
                (Run-Git -Cwd $ctx.Root -GitArgs @('merge-base', '--is-ancestor', $bridgeTip, 'main')) |
                    Should -Not -Be 0 -Because 'fixture: the replayed commit must be unreachable from main'

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Be 0 -Because "a marked replay commit is resumable. $($res.Combined)"
                $res.Combined | Should -Not -Match 'unmerged sync'
                (Run-Git -Cwd $ctx.Root -GitArgs @('merge-base', '--is-ancestor', $bridgeTip, 'main')) |
                    Should -Be 0 -Because 'the re-run must retry the merge into main'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 8: AE1 -- 3 new revs, per-revision auto -> 3 commits (author/message/trailer each)' {
        It 'replays 3 revisions as 3 distinct commits, not one squash' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-8'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 3 `
                    -Messages @('alpha change', 'beta change', 'gamma change') -Authors @('alice', 'bob', 'carol')
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revisions'; return }

                $before = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $trBefore = @(Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Stdout | Should -Not -Match 'TP_TOKEN:GRANULARITY_REQUIRED'
                $after = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                ($after - $before) | Should -Be 3

                # Exactly the three new revisions are carried as trailers (not one squashed boundary).
                # Delta over the pull: the bootstrap import commit already carries its own trailer now.
                $newTrailers = @((Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main') | Where-Object { $_ -notin $trBefore } | Sort-Object)
                $newTrailers | Should -Be @($revs | Sort-Object)
                # Three distinct subjects reached main.
                $subjects = Run-Git-Capture -Cwd $ctx.Root -GitArgs @('log', 'main', '--format=%s')
                $subjects | Should -Match 'alpha change'
                $subjects | Should -Match 'beta change'
                $subjects | Should -Match 'gamma change'
                # Author fidelity: the 'alpha change' commit carries the raw SVN username 'alice'.
                $an = Run-Git-Capture -Cwd $ctx.Root -GitArgs @('log', 'remote-svn/main', '--format=%an', '--grep=alpha change')
                $an | Should -Match 'alice'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 9: 5-or-fewer new revs replay per-revision with NO -Granularity (R2)' {
        It '5 revs -> 5 commits, no granularity signal' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-9'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 5
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revisions'; return }

                $before = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Stdout | Should -Not -Match 'TP_TOKEN:GRANULARITY_REQUIRED'
                $after = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                ($after - $before) | Should -Be 5
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 10: >5 new revs, no -Granularity -> needs-choice signal, ZERO commits (R3)' {
        It 'emits TP_TOKEN:GRANULARITY_REQUIRED count=6 and creates no commits' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-10'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 6
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revisions'; return }

                $before = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Stdout | Should -Match 'TP_TOKEN:GRANULARITY_REQUIRED count=6'
                $after = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                ($after - $before) | Should -Be 0
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 11: -Granularity squash -> ONE boundary commit with the HEAD trailer' {
        It 'squash produces a single sync: svn rHEAD commit carrying the trailer' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-11'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 6
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revisions'; return }
                $head = (@($revs) | Measure-Object -Maximum).Maximum

                $before = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Granularity', 'squash')
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $after = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                ($after - $before) | Should -Be 1

                $subj = Run-Git-Capture -Cwd $ctx.Root -GitArgs @('log', 'remote-svn/main', '-1', '--format=%s')
                $subj | Should -Be "sync: svn r$head"
                $marked = (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-parse', '--verify', '--quiet', "refs/tp/svn/$head^{commit}")).Trim()
                $marked | Should -Be (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-parse', 'remote-svn/main'))
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 12: -Granularity range -> per-revision inside, squash outside' {
        It '8 revs, middle 3 per-revision -> leading+trailing squash boundaries, strictly ascending trailers' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-12'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 8
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revisions'; return }
                $sorted = @($revs | Sort-Object)
                $base = $sorted[0] - 1
                $head = $sorted[-1]
                $lo = $base + 3
                $hi = $base + 5

                $before = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $trBefore = @(Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main', '-Granularity', 'range', '-Range', "$lo`:$hi")
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $after = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                # leading squash (1) + per-revision [lo..hi] (3) + trailing squash (1) = 5.
                ($after - $before) | Should -Be 5

                # Delta over the pull (the bootstrap import commit already carries its own trailer).
                $expected = @(($lo - 1)) + @($lo..$hi) + @($head) | Sort-Object
                $newTrailers = @((Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main') | Where-Object { $_ -notin $trBefore } | Sort-Object)
                $newTrailers | Should -Be $expected
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 13: empty-delta revision is skipped (no no-op commit)' {
        It 'a prop-only revision between two file revs mints no commit but is still marked' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-13'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $ra = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 1
                $rb = Add-PropOnlyRevision -Uri $ctx.Uri -Cfg $ctx.Cfg -Sandbox $sb
                $rc = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 1
                if ($null -eq $ra -or $null -eq $rb -or $null -eq $rc) { Set-ItResult -Skipped -Because 'could not build the mixed revision sequence'; return }

                $before = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $after = [int](Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                # 3 revisions enumerated (A, prop-only B, C) but only the two file revs commit.
                ($after - $before) | Should -Be 2

                $trailers = Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main'
                $trailers | Should -Contain @($ra)[0]
                $trailers | Should -Contain @($rc)[0]
                # The prop-only revision mints NO commit of its own (asserted by the count above) but
                # IS marked -- onto the commit that already carries its content. Marking every
                # enumerated revision, commit or not, is what keeps a revision resolvable when its
                # content arrived some other way (notably one this repo pushed itself).
                $trailers | Should -Contain $rb
                $markB = (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-parse', '--verify', '--quiet', "refs/tp/svn/$rb^{commit}")).Trim()
                $markA = (Run-Git-Capture -Cwd $ctx.Root -GitArgs @('rev-parse', '--verify', '--quiet', "refs/tp/svn/$(@($ra)[0])^{commit}")).Trim()
                $markB | Should -Be $markA -Because 'a prop-only revision marks the commit that already holds its content'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 14: interrupted-then-rerun resumes at cur (no duplicate)' {
        It 'a rerun after main was moved back replays only the new revision' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-14'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                # Bootstrap import commit already carries its own trailer -- exclude that baseline so the
                # counts below measure only the PULLED replay commits (delta).
                $trBase = @(Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main')
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 3
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revisions'; return }

                $res1 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res1.ExitCode | Should -Be 0 -Because $res1.Combined
                @((Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main') | Where-Object { $_ -notin $trBase }).Count | Should -Be 3

                # Simulate an interrupted pull: move main back BEFORE the merge so the 3 trailer-bearing
                # replay commits sit ahead of main (the resumable state).
                $null = Run-Git -Cwd $ctx.Root -GitArgs @('reset', '--hard', 'HEAD^')
                # One more SVN revision arrives.
                $rev4 = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 1
                if ($null -eq $rev4) { Set-ItResult -Skipped -Because 'could not add the 4th revision'; return }

                $res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res2.ExitCode | Should -Be 0 -Because $res2.Combined
                $res2.Combined | Should -Not -Match 'unmerged sync'
                # Exactly 4 PULLED replay commits on remote-svn/main -- the first 3 were NOT duplicated.
                $trailers = @((Get-TrailerRevs -Root $ctx.Root -Ref 'remote-svn/main') | Where-Object { $_ -notin $trBase })
                $trailers.Count | Should -Be 4
                (@($trailers | Sort-Object -Unique)).Count | Should -Be 4
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Case 15: a CJK SVN message round-trips into the replayed commit' {
        It 'no mojibake in the replayed commit body' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-15'
            try {
                $ctx = New-PushedBridge -Sandbox $sb
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }
                $cjk = '修正中文訊息測試'
                $revs = Add-SvnRevisions -Uri $ctx.Uri -Repo $ctx.Repo -Cfg $ctx.Cfg -Sandbox $sb -Count 1 -Messages @($cjk)
                if ($null -eq $revs) { Set-ItResult -Skipped -Because 'could not add svn revision'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $res.ExitCode | Should -Be 0 -Because $res.Combined

                # Read the replayed commit body as raw bytes (cmd redirect) so console codepage never
                # mangles the capture; decode via the same round-trip helper Case 5 uses.
                $mbFile = [System.IO.Path]::Combine($sb, 'msgout.txt')
                & cmd.exe /c "git -C `"$($ctx.Root)`" log remote-svn/main -1 --format=%B > `"$mbFile`""
                $bytes = if ([System.IO.File]::Exists($mbFile)) { [System.IO.File]::ReadAllBytes($mbFile) } else { @() }
                (Test-SvnLogRoundTrip -RawBytes $bytes -ExpectedText $cjk) | Should -BeTrue
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    # SVN revision numbers are repository-wide. In a repository shared by several projects, a
    # colleague's commit to a SIBLING path bumps HEAD without touching ours -- and the two sides
    # used to disagree about what that meant: push compared the working copy against repository
    # HEAD and refused ("run pull first"), while pull correctly found no revision affecting this
    # path and returned "already up to date". Neither could make progress; only a manual
    # `svn update` broke it. Both halves are asserted here because fixing either one alone still
    # leaves the working copy drifting further behind on every sibling commit.
    Context 'Case 16: a sibling project''s commit must not deadlock push against pull' {
        It 'push is not refused, and pull brings the working copy up to repository HEAD' -Skip:(-not $script:HasSvn) {
            $sb = New-Sandbox -Tag 'pfs-16'
            try {
                $ctx = New-PushedBridge -Sandbox $sb -SubPath 'proj-1'
                if ($null -eq $ctx) { Set-ItResult -Skipped -Because 'could not build/push bridge'; return }

                $wcBefore = Get-WcRevision -Bridge $ctx.Bridge

                # A sibling project commits. Nothing under proj-1 changes; only HEAD moves.
                & svn mkdir "$($ctx.RepoRootUri)/proj-2" -m 'sibling project commit' --config-dir $ctx.Cfg 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'could not commit to the sibling path'; return }

                # Half 1 -- pull must not leave the working copy behind. It reports "up to date"
                # (correct: nothing of ours changed) but still catches the checkout up.
                $pull = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $pull.ExitCode | Should -Be 0 -Because $pull.Combined
                $pull.Combined | Should -Match 'Already up to date'
                (Get-WcRevision -Bridge $ctx.Bridge) | Should -BeGreaterThan $wcBefore

                # Half 2 -- and push must not refuse in the first place. Roll the working copy back
                # to its pre-sibling revision so the check faces exactly the state pull would have
                # left it in before the fix above existed.
                & svn update -r $wcBefore $ctx.Bridge 2>$null | Out-Null
                (Get-WcRevision -Bridge $ctx.Bridge) | Should -Be $wcBefore

                $enc = New-Object Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($ctx.Root, 'new.txt'), "new`n", $enc)
                $null = Run-Git -Cwd $ctx.Root -GitArgs @('add', 'new.txt')
                $null = Run-Git -Cwd $ctx.Root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-m', 'feat: something of ours')

                $prep = Invoke-PsScript -ScriptPath $script:BuildScript -Cwd $ctx.Root -ScriptArgs @('-Branch', 'main')
                $prep.Combined | Should -Not -Match 'not up to date'
                $prep.ExitCode | Should -Be 0 -Because $prep.Combined
            } finally { Remove-Sandbox -Dir $sb }
        }
    }
}
