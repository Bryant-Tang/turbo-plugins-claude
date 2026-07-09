# Initialize-GitSvnBridge.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Initialize-GitSvnBridge.ps1
#
# Contract: -SvnUrl <url> [-Branch <name=main>]. First-bridge bootstrap that bridges the
# CURRENT repo to an SVN URL and merges the SVN content into the current branch. Two-arm
# flow on "has root commit":
#   case (a) no HEAD  -> seed an empty root commit, then bridge + merge (unrelated histories);
#   case (b) has HEAD -> bridge + merge into the current branch (can conflict on overlap).
# Pre-bridge guards: scheme allowlist (^(https?|svn|file)://) and a git-identity check that
# emits TP_TOKEN:IDENTITY_REQUIRED. A merge conflict emits TP_TOKEN:MERGE_CONFLICT (no abort,
# no rollback). A mid-run failure AFTER the bridge worktree exists rolls back the local git side.
#
# svn-gated cases (anything that drives a real svn checkout/commit) self-SKIP when svn.exe or
# the seed dump are absent. Arg/identity/url-validation cases run on plain git.
#
# KTD8 isolation (stricter than New-RemoteBridge.test): every svn CLIENT call this test makes
# (propget / info) passes --config-dir <sandbox>/.svnconfig so the real %APPDATA%\Subversion is
# never touched. svnadmin create/load take no --config-dir (they read no global state). The
# script-under-test's own internal svn calls are out of the test's control.

# --- Discovery-time svn gate (evaluated BEFORE BeforeAll) -----------------------
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
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Initialize-GitSvnBridge.ps1')
    $script:DumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

    # Shared test helpers (New-Sandbox / Remove-Sandbox / Run-Git / Run-Git-Capture / Invoke-PsScript).
    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    # CRITICAL isolation: the gitignored sandbox lives INSIDE this plugin's own git repo, so a test
    # dir that is not yet its own repo (scenario 6's pre-init state) would let the script's
    # `git rev-parse` / worktree / clean escape UPWARD into the real repo. Fence every child git
    # invocation at the sandbox base so it can never traverse above it. Each scenario still git-inits
    # its own $root, so the fence only blocks the dangerous upward escape.
    $script:PrevCeiling = $env:GIT_CEILING_DIRECTORIES
    $script:SandboxBase = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '.sandbox', 'sandboxes'))
    $null = New-Item -ItemType Directory -Path $script:SandboxBase -Force
    $env:GIT_CEILING_DIRECTORIES = $script:SandboxBase

    # Runtime svn-availability flag (the file-scope $SvnAvailable used by -Skip: is only in scope at
    # DISCOVERY; an It body that branches on svn at RUN time needs this script-scoped copy).
    $script:SvnAvailableRt = $false
    try {
        $null = (& svn --version --quiet 2>$null)
        $script:SvnAvailableRt = ($LASTEXITCODE -eq 0)
    } catch {
        $script:SvnAvailableRt = $false
    }

    function Get-WorktreesDir {
        param([string]$Root)
        return [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees')
    }

    function Get-BridgePath {
        param([string]$Root, [string]$Branch = 'main')
        $dash = $Branch -replace '/', '-'
        return [System.IO.Path]::Combine((Get-WorktreesDir -Root $Root), "remote-svn-$dash")
    }

    # Create an SVN repo under the sandbox. -Load seeds it from the r1-r20 dump (trunk + branches);
    # without -Load it is an empty rev-0 repo. svnadmin takes NO --config-dir. Returns the file:///
    # URI (repos root), or $null if the svn pipeline failed.
    function New-SvnRepo {
        param([string]$Sandbox, [string]$Name = 'svnrepo', [switch]$Load)
        $repo = [System.IO.Path]::Combine($Sandbox, $Name)
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($Load) {
            $loadCmd = "svnadmin load `"$repo`" < `"$($script:DumpPath)`""
            & cmd.exe /c $loadCmd > $null 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
        }
        return ('file:///' + ($repo -replace '\\', '/'))
    }

    # case (a) fixture: a git repo with identity but NO root commit (no HEAD) and no .gitignore.
    function New-CaseARepo {
        param([string]$Root)
        $null = New-Item -ItemType Directory -Path $Root -Force
        $null = Run-Git -Cwd $Root -GitArgs @('init', '-b', 'main')
        $null = Run-Git -Cwd $Root -GitArgs @('config', 'user.email', 'test@turbo-plugin')
        $null = Run-Git -Cwd $Root -GitArgs @('config', 'user.name',  'turbo-plugin-test')
    }

    # case (b) fixture: a git repo with identity + committed files (from -Files name->content).
    # Deliberately commits NO .gitignore so the bridge's own .gitignore (.svn/) merges without an
    # add/add conflict -- conflicts in these tests come only from the seeded overlap file.
    function New-CaseBRepo {
        param([string]$Root, [hashtable]$Files)
        $null = New-Item -ItemType Directory -Path $Root -Force
        $null = Run-Git -Cwd $Root -GitArgs @('init', '-b', 'main')
        $null = Run-Git -Cwd $Root -GitArgs @('config', 'user.email', 'test@turbo-plugin')
        $null = Run-Git -Cwd $Root -GitArgs @('config', 'user.name',  'turbo-plugin-test')
        foreach ($k in $Files.Keys) {
            $p = [System.IO.Path]::Combine($Root, $k)
            $dir = [System.IO.Path]::GetDirectoryName($p)
            if (-not [System.IO.Directory]::Exists($dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            [System.IO.File]::WriteAllText($p, $Files[$k])
        }
        $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
        $null = Run-Git -Cwd $Root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-m', 'initial')
    }

    # svn propget svn:ignore on a working copy, isolated via --config-dir (KTD8).
    function Get-SvnIgnore {
        param([string]$WcPath, [string]$ConfigDir)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $out = & svn propget --config-dir $ConfigDir svn:ignore $WcPath 2>$null
        } finally {
            $ErrorActionPreference = $prev
        }
        return ($out | Out-String).Trim()
    }

    function Get-BridgeBranchCount {
        param([string]$Root)
        $raw = Run-Git-Capture -Cwd $Root -GitArgs @('branch', '--list', 'remote-svn/main')
        if ([string]::IsNullOrWhiteSpace($raw)) { return 0 }
        return @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }).Count
    }

    # The steady-state pull script (U7 scenario: a follow-up pull must find nothing new).
    $script:SyncScript = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Sync-FromSvn.ps1')

    # Build a small svn repo with -Total revisions at the ROOT (import=r1 + (Total-1) file commits).
    # Returns the file:/// URI (root), or $null on failure. Client calls isolated via -ConfigDir.
    function New-SmallSvnRepo {
        param([string]$Sandbox, [string]$Name = 'svnrepo', [int]$Total = 3, [string]$ConfigDir)
        $repo = [System.IO.Path]::Combine($Sandbox, $Name)
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($repo -replace '\\', '/')
        $seed = [System.IO.Path]::Combine($Sandbox, "seed-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        $null = New-Item -ItemType Directory -Path $seed -Force
        $enc = New-Object Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'app.txt'), "app`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, '.gitignore'), "*.log`n", $enc)
        & svn import $seed $uri -m 'import 1' --no-auto-props --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($Total -gt 1) {
            $co = [System.IO.Path]::Combine($Sandbox, "co-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
            & svn checkout $uri $co --config-dir $ConfigDir 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
            for ($n = 2; $n -le $Total; $n++) {
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, "file$n.txt"), "content $n`n", $enc)
                & svn add ([System.IO.Path]::Combine($co, "file$n.txt")) --config-dir $ConfigDir 2>$null | Out-Null
                Push-Location $co
                try { & svn commit -m "change $n" --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
                if ($LASTEXITCODE -ne 0) { return $null }
            }
        }
        return $uri
    }

    # Count trailer-bearing replay commits on remote-svn/main (numeric svn-revision trailers).
    function Get-BridgeTrailerCount {
        param([string]$Root)
        $raw = Run-Git-Capture -Cwd $Root -GitArgs @('log', 'remote-svn/main', '--format=%(trailers:key=svn-revision,valueonly)')
        return @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' }).Count
    }
}

AfterAll {
    if ($null -eq $script:PrevCeiling) {
        Remove-Item Env:\GIT_CEILING_DIRECTORIES -ErrorAction SilentlyContinue
    } else {
        $env:GIT_CEILING_DIRECTORIES = $script:PrevCeiling
    }
}

Describe 'Initialize-GitSvnBridge' {

    It 'script-under-test exists' {
        [System.IO.File]::Exists($script:ScriptUnderTest) | Should -BeTrue
    }

    Context 'Scenario 1: case (a) + EMPTY svn -> clean connect, empty main' {
        It 'connects, main carries no project files, bridge clean, svn:ignore=.git' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SvnRepo -Sandbox $sb
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build empty svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'SVN bridge connected\.'

                # remote-svn/main branch exists (exactly one).
                (Get-BridgeBranchCount -Root $root) | Should -Be 1

                $bridge = Get-BridgePath -Root $root
                # bridge worktree is clean.
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
                # svn:ignore on the bridge WC is exactly .git.
                (Get-SvnIgnore -WcPath $bridge -ConfigDir $cfg) | Should -BeExactly '.git'

                # main is empty: only the merged .gitignore, no SVN project files.
                $mainFiles = Run-Git-Capture -Cwd $root -GitArgs @('ls-files')
                $mainFiles | Should -BeExactly '.gitignore'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 2: case (a) + NON-EMPTY svn (/trunk) -> svn content lands on main' {
        It 'connects, main has the svn content, bridge clean, .svn ignored + untracked' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'igsb-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseARepo -Root $root
                $uri = New-SvnRepo -Sandbox $sb -Load
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build seeded svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$uri/trunk", '-Granularity', 'squash')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'SVN bridge connected\.'

                # squash => exactly ONE replay commit on remote-svn/main (single lump).
                [int](Run-Git-Capture -Cwd $root -GitArgs @('rev-list', '--count', 'remote-svn/main')) | Should -Be 1

                # main carries the imported svn content.
                $mainFiles = Run-Git-Capture -Cwd $root -GitArgs @('ls-files')
                $mainFiles | Should -Match 'README\.txt'

                $bridge = Get-BridgePath -Root $root
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty

                # bridge .gitignore contains .svn/
                $gi = [System.IO.Path]::Combine($bridge, '.gitignore')
                [System.IO.File]::Exists($gi) | Should -BeTrue
                @([System.IO.File]::ReadAllLines($gi) | Where-Object { $_.Trim() -eq '.svn/' }).Count | Should -BeGreaterThan 0

                # .svn metadata is NOT tracked by git in the bridge.
                $bridgeFiles = Run-Git-Capture -Cwd $bridge -GitArgs @('ls-files')
                $bridgeFiles | Should -Not -Match '(^|\n)\.svn'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 3: case (b) + overlapping svn content (different) -> MERGE_CONFLICT' {
        It 'emits TP_TOKEN:MERGE_CONFLICT, exits non-zero, leaves the merge in progress' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'igsb-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                # README.txt exists in trunk; seed a DIFFERENT README.txt on the git side -> add/add conflict.
                New-CaseBRepo -Root $root -Files @{ 'README.txt' = "GIT-SIDE README - intentional conflict`n" }
                $uri = New-SvnRepo -Sandbox $sb -Load
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build seeded svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$uri/trunk", '-Granularity', 'squash')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'TP_TOKEN:MERGE_CONFLICT'
                $res.Combined | Should -Match 'README\.txt'

                # Conflict left in place (NOT aborted): MERGE_HEAD present in the main worktree.
                [System.IO.File]::Exists([System.IO.Path]::Combine($root, '.git', 'MERGE_HEAD')) | Should -BeTrue
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 4: case (b) + NON-overlapping svn content -> clean merge of both sides' {
        It 'connects, main has both the original and the svn files' -Skip:(-not $SvnReady) {
            $sb = New-Sandbox -Tag 'igsb-4'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseBRepo -Root $root -Files @{ 'original.txt' = "original git-only file`n" }
                $uri = New-SvnRepo -Sandbox $sb -Load
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build seeded svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$uri/trunk", '-Granularity', 'squash')
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'SVN bridge connected\.'

                $mainFiles = Run-Git-Capture -Cwd $root -GitArgs @('ls-files')
                $mainFiles | Should -Match 'original\.txt'
                $mainFiles | Should -Match 'README\.txt'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 5: case (b) + EMPTY svn -> no-op merge, original content intact' {
        It 'connects, original file unchanged, bridge clean' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseBRepo -Root $root -Files @{ 'original.txt' = "keep me intact`n" }
                $uri = New-SvnRepo -Sandbox $sb
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build empty svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'SVN bridge connected\.'

                # original content intact.
                $orig = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($root, 'original.txt'))
                $orig | Should -Match 'keep me intact'
                (Run-Git-Capture -Cwd $root -GitArgs @('ls-files')) | Should -Match 'original\.txt'

                $bridge = Get-BridgePath -Root $root
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 6: git identity gate, then a clean re-run' {
        It 'emits TP_TOKEN:IDENTITY_REQUIRED (no bridge), then succeeds once identity is set' {
            $sb = New-Sandbox -Tag 'igsb-6'
            $prevG = $env:GIT_CONFIG_GLOBAL
            $prevS = $env:GIT_CONFIG_SYSTEM
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $null = New-Item -ItemType Directory -Path $root -Force   # NOT a git repo yet (script git-inits it)

                # Hide any ambient git identity: empty global + system config files.
                $emptyG = [System.IO.Path]::Combine($sb, 'empty-global.gitconfig')
                $emptyS = [System.IO.Path]::Combine($sb, 'empty-system.gitconfig')
                [System.IO.File]::WriteAllText($emptyG, '')
                [System.IO.File]::WriteAllText($emptyS, '')
                $env:GIT_CONFIG_GLOBAL = $emptyG
                $env:GIT_CONFIG_SYSTEM = $emptyS

                $repo = [System.IO.Path]::Combine($sb, 'svnrepo')
                $uri  = 'file:///' + ($repo -replace '\\', '/')

                # --- no identity -> TP_TOKEN:IDENTITY_REQUIRED, exit 1, .git created, no bridge. ---
                $res1 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res1.ExitCode | Should -Be 1
                $res1.Stdout | Should -Match 'TP_TOKEN:IDENTITY_REQUIRED'
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, '.git')) | Should -BeTrue
                (Get-BridgeBranchCount -Root $root) | Should -Be 0

                # The re-run drives a real svn checkout/commit -> svn-gated.
                if (-not $script:SvnAvailableRt) { return }
                $null = New-SvnRepo -Sandbox $sb
                # Set LOCAL identity (writes to .git/config, unaffected by the empty global).
                $null = Run-Git -Cwd $root -GitArgs @('config', 'user.email', 'test@turbo-plugin')
                $null = Run-Git -Cwd $root -GitArgs @('config', 'user.name',  'turbo-plugin-test')

                $res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res2.ExitCode | Should -Be 0
                $res2.Stdout | Should -Match 'SVN bridge connected\.'
                # exactly one remote-svn/main (no duplicate / no "already exists" failure).
                (Get-BridgeBranchCount -Root $root) | Should -Be 1
            } finally {
                $env:GIT_CONFIG_GLOBAL = $prevG
                $env:GIT_CONFIG_SYSTEM = $prevS
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 7: invalid SVN URL -> rejected before any side effect' {
        It 'exits non-zero with the invalid-URL wording and creates no bridge' {
            $sb = New-Sandbox -Tag 'igsb-7'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseARepo -Root $root
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', 'not-a-url')
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match "Invalid SVN URL 'not-a-url'"
                # nothing created.
                [System.IO.Directory]::Exists((Get-BridgePath -Root $root)) | Should -BeFalse
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 8: unreachable (scheme-valid) SVN URL -> fail, no residue' {
        It 'on an unreachable URL leaves no bridge branch + no worktree dir' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-8'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseBRepo -Root $root -Files @{ 'original.txt' = "git-only`n" }
                # A scheme-valid file:// URL pointing at a non-existent repo -> passes URL validation,
                # passes git init/identity/case-split, then the U7 early granularity probe (svn info on
                # the URL, BEFORE the worktree exists) fails -> clean exit, nothing created.
                $bogus = [System.IO.Path]::Combine($sb, 'no-such-repo')
                $bogusUri = 'file:///' + ($bogus -replace '\\', '/')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $bogusUri)
                $res.ExitCode | Should -Not -Be 0

                # rollback removed both the bridge branch and the bridge worktree dir.
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
                [System.IO.Directory]::Exists((Get-BridgePath -Root $root)) | Should -BeFalse
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 9 (U7): 5-or-fewer-revision URL -> per-revision auto import (trailer-greppable, not a lump)' {
        It 'replays each revision as its own trailer-bearing commit; svn:ignore=.git and .svn untracked' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-9'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SmallSvnRepo -Sandbox $sb -Total 3 -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the small svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Stdout | Should -Match 'SVN bridge connected\.'
                # No granularity prompt on a <=5 import (replays per-revision silently).
                $res.Stdout | Should -Not -Match 'TP_TOKEN:GRANULARITY_REQUIRED'
                # 3 revisions -> 3 trailer-bearing replay commits (NOT one squashed lump).
                (Get-BridgeTrailerCount -Root $root) | Should -Be 3

                # Setup invariants: svn:ignore is exactly .git; the .svn metadata dir is not git-tracked.
                $bridge = Get-BridgePath -Root $root
                (Get-SvnIgnore -WcPath $bridge -ConfigDir $cfg) | Should -BeExactly '.git'
                (Run-Git-Capture -Cwd $bridge -GitArgs @('ls-files')) | Should -Not -Match '(^|\n)\.svn'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 10 (U7): >5-revision URL, no -Granularity -> prompt token, ZERO residue' {
        It 'emits TP_TOKEN:GRANULARITY_REQUIRED and creates no bridge' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-10'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SmallSvnRepo -Sandbox $sb -Total 7 -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the small svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Stdout | Should -Match 'TP_TOKEN:GRANULARITY_REQUIRED count=7'
                # Residue-free: nothing created, so a re-run with a choice is clean.
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
                [System.IO.Directory]::Exists((Get-BridgePath -Root $root)) | Should -BeFalse
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 11 (U7): >5-revision URL + -Granularity per-revision -> N replay commits' {
        It 'per-revision imports all 7 revisions as 7 trailer-bearing commits' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-11'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SmallSvnRepo -Sandbox $sb -Total 7 -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the small svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri, '-Granularity', 'per-revision')
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Stdout | Should -Match 'SVN bridge connected\.'
                (Get-BridgeTrailerCount -Root $root) | Should -Be 7
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 12 (U7): after bootstrap, a subsequent tp-pull-from-svn finds nothing new' {
        It 'the follow-up pull is a no-op (cur = HEAD, no double-import)' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-12'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SmallSvnRepo -Sandbox $sb -Total 3 -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the small svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0 -Because $res.Combined

                # Skeleton .gitignore (as tp-setup writes post-bootstrap) so the nested bridge worktree
                # dir does not show as untracked and trip the pull's main-dirty guard.
                $enc = New-Object Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, '.gitignore'), "/.turbo-plugin/worktrees/`n.svn/`n*.log`n", $enc)
                $null = Run-Git -Cwd $root -GitArgs @('add', '.gitignore')
                $null = Run-Git -Cwd $root -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-m', 'chore: skeleton gitignore')

                $before = [int](Run-Git-Capture -Cwd $root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                $pull = Invoke-PsScript -ScriptPath $script:SyncScript -Cwd $root -ScriptArgs @('-Branch', 'main')
                $pull.ExitCode | Should -Be 0 -Because $pull.Combined
                $pull.Stdout | Should -Match 'Already up to date'
                $after = [int](Run-Git-Capture -Cwd $root -GitArgs @('rev-list', '--count', 'remote-svn/main'))
                ($after - $before) | Should -Be 0
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
