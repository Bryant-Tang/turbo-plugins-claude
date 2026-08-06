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
    $script:PluginRoot = $pluginRoot
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
    # Conflicts in these tests come only from a seeded overlap file. (Before U4 a .gitignore here
    # would ALSO have conflicted, because the bridge invented one of its own -- that is exactly the
    # defect, and 'Scenario 3b' below now pins the fixed behaviour.)
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

    # Does this URL resolve in the repository? Isolated via --config-dir (KTD8).
    function Test-SvnPathExists {
        param([string]$Url, [string]$ConfigDir)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            & svn info --config-dir $ConfigDir $Url 2>$null | Out-Null
            return ($LASTEXITCODE -eq 0)
        } finally {
            $ErrorActionPreference = $prev
        }
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

    # Build an svn repo that HAS HISTORY, plus a landing path that EXISTS BUT IS EMPTY. That is the
    # exact shape New-SvnPath produces: a brand-new project gets its trunk created inside a
    # repository several other projects already share, so the repo HEAD is well past r0 while the
    # path itself has never had a single file. Returns the URI OF THE EMPTY TRUNK, or $null.
    #
    # NOT the same as Scenario 1's empty repo: there HEAD is r0 and the import has no revisions to
    # consider at all; here the import walks real revisions and finds none of them touched this
    # path -- a different branch of the bootstrap, which left the bridge branch unborn (step 13 then
    # died on "not something we can merge", misreported as a conflict).
    function New-SvnRepoWithEmptyTrunk {
        param([string]$Sandbox, [string]$Name = 'svnrepo', [string]$ConfigDir)
        $repo = [System.IO.Path]::Combine($Sandbox, $Name)
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($repo -replace '\\', '/')
        & svn mkdir --parents -m 'layout' "$uri/other/trunk" "$uri/proj-new/trunk" --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $co = [System.IO.Path]::Combine($Sandbox, "co-other-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        & svn checkout "$uri/other/trunk" $co --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $enc = New-Object Text.UTF8Encoding($false)
        for ($n = 1; $n -le 3; $n++) {
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, "other$n.txt"), "other $n`n", $enc)
            & svn add ([System.IO.Path]::Combine($co, "other$n.txt")) --config-dir $ConfigDir 2>$null | Out-Null
            Push-Location $co
            try { & svn commit -m "other change $n" --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
            if ($LASTEXITCODE -ne 0) { return $null }
        }
        return "$uri/proj-new/trunk"
    }

    # Build an svn repo whose FIRST revision has NO .gitignore and where a LATER revision ADDS one.
    # This is the shape that used to deadlock a per-revision bootstrap: the bridge .gitignore was
    # written while the WC sat at r1, so the incoming add at r3 raised a tree conflict and svn sat on
    # its interactive prompt forever. Returns the file:/// URI, or $null on failure.
    function New-SvnRepoGitignoreAddedLater {
        param([string]$Sandbox, [string]$Name = 'svnrepo', [string]$ConfigDir)
        $repo = [System.IO.Path]::Combine($Sandbox, $Name)
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($repo -replace '\\', '/')
        $enc = New-Object Text.UTF8Encoding($false)
        $seed = [System.IO.Path]::Combine($Sandbox, "seedgi-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        $null = New-Item -ItemType Directory -Path $seed -Force
        # r1: deliberately NO .gitignore
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'app.txt'), "app`n", $enc)
        & svn import $seed $uri -m 'import 1' --no-auto-props --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $co = [System.IO.Path]::Combine($Sandbox, "cogi-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        & svn checkout $uri $co --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'file2.txt'), "two`n", $enc)
        & svn add ([System.IO.Path]::Combine($co, 'file2.txt')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'change 2' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }
        # r3: SVN adds its own .gitignore
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, '.gitignore'), "*.log`n", $enc)
        & svn add ([System.IO.Path]::Combine($co, '.gitignore')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'add gitignore' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }
        return $uri
    }

    # Build an svn repo where an ANCESTOR of the project path is renamed AFTER the project's first
    # revision -- the exact shape reported in issue #32:
    #   r1: mkdir /SRC/OLD/proj/trunk
    #   r2: first import under it
    #   r3: svn move /SRC/OLD -> /SRC/NEW        <- the ancestor rename
    #   r4: one more commit under the NEW name
    # Returns the CURRENT (post-rename) URL, which is what a user would hand to tp-setup. Importing
    # its history requires following the rename backwards; a checkout pinned at r2 binds to the OLD
    # path, and enumerating from there dies with E160013 naming a path the user never typed.
    function New-SvnRepoAncestorRenamed {
        param([string]$Sandbox, [string]$Name = 'svnrepo-renamed', [string]$ConfigDir)
        $repo = [System.IO.Path]::Combine($Sandbox, $Name)
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($repo -replace '\\', '/')
        $enc = New-Object Text.UTF8Encoding($false)

        & svn mkdir --parents -m 'r1: layout' "$uri/SRC/OLD/proj/trunk" --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }

        $co = [System.IO.Path]::Combine($Sandbox, "co-ren-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        & svn checkout "$uri/SRC/OLD/proj/trunk" $co --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'a.txt'), "a`n", $enc)
        & svn add ([System.IO.Path]::Combine($co, 'a.txt')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'r2: first import' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }

        & svn move -m 'r3: rename the root folder' "$uri/SRC/OLD" "$uri/SRC/NEW" --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }

        $co2 = [System.IO.Path]::Combine($Sandbox, "co-ren2-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        & svn checkout "$uri/SRC/NEW/proj/trunk" $co2 --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co2, 'b.txt'), "b`n", $enc)
        & svn add ([System.IO.Path]::Combine($co2, 'b.txt')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co2
        try { & svn commit -m 'r4: after the rename' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }

        return "$uri/SRC/NEW/proj/trunk"
    }

    # Build an svn repo where the ancestor is renamed AWAY and then BACK inside one import window:
    #   r1 mkdir /SRC/A/proj/trunk, r2 import, r3 move A->B, r4 commit under B, r5 move B->A,
    #   r6 commit. The endpoints (r2 and HEAD) BOTH sit at /SRC/A/proj/trunk, so a rename check that
    #   only compares the two ends sees nothing -- while r4 genuinely lives at /SRC/B/proj/trunk and
    #   cannot be reached by a plain `svn update -r`.
    function New-SvnRepoAncestorRenameRoundtrip {
        param([string]$Sandbox, [string]$Name = 'svnrepo-roundtrip', [string]$ConfigDir)
        $repo = [System.IO.Path]::Combine($Sandbox, $Name)
        & svnadmin create $repo
        if ($LASTEXITCODE -ne 0) { return $null }
        $uri = 'file:///' + ($repo -replace '\\', '/')
        $enc = New-Object Text.UTF8Encoding($false)

        & svn mkdir --parents -m 'r1: layout' "$uri/SRC/A/proj/trunk" --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $co = [System.IO.Path]::Combine($Sandbox, "co-rt-$([Guid]::NewGuid().ToString('N').Substring(0,6))")
        & svn checkout "$uri/SRC/A/proj/trunk" $co --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }

        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'a.txt'), "a`n", $enc)
        & svn add ([System.IO.Path]::Combine($co, 'a.txt')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'r2: first import' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }

        & svn move -m 'r3: A -> B' "$uri/SRC/A" "$uri/SRC/B" --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        Push-Location $co
        try { & svn switch --ignore-ancestry "$uri/SRC/B/proj/trunk" --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'b.txt'), "b`n", $enc)
        & svn add ([System.IO.Path]::Combine($co, 'b.txt')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'r4: while named B' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }

        & svn move -m 'r5: B -> A' "$uri/SRC/B" "$uri/SRC/A" --config-dir $ConfigDir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        Push-Location $co
        try { & svn switch --ignore-ancestry "$uri/SRC/A/proj/trunk" --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($co, 'c.txt'), "c`n", $enc)
        & svn add ([System.IO.Path]::Combine($co, 'c.txt')) --config-dir $ConfigDir 2>$null | Out-Null
        Push-Location $co
        try { & svn commit -m 'r6: renamed back to A' --config-dir $ConfigDir 2>$null | Out-Null } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { return $null }

        return "$uri/SRC/A/proj/trunk"
    }

    # Count trailer-bearing replay commits on remote-svn/main (numeric svn-revision trailers).
    function Get-BridgeTrailerCount {
        param([string]$Root)
        $raw = Run-Git-Capture -Cwd $Root -GitArgs @('for-each-ref', '--format=%(refname:lstrip=3)', 'refs/tp/svn/*')
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

    Context 'Scenario R (issue #32): an ANCESTOR of the SVN path was renamed after the first revision' {
        It 'imports the history instead of dying on E160013, and keeps it per-revision' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-rename'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SvnRepoAncestorRenamed -Sandbox $sb -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the renamed-ancestor svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)

                # The reported symptom: an E160013 naming the path BEFORE the rename -- a path the
                # user never entered, which is why it reads as "I typed the URL wrong".
                $res.Stdout + $res.Stderr | Should -Not -Match 'E160013'
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'SVN bridge connected\.'

                # The rename is REPORTED, not silently worked around: the user should learn that the
                # path moved, because it explains the history they are about to see.
                $res.Stdout | Should -Match 'TP_TOKEN:SVN_PATH_RENAMED'

                $bridge = Get-BridgePath -Root $root
                # Per-revision history survives. The documented workaround for this bug was to squash
                # the whole import into one commit; the point of the fix is not having to.
                (Get-BridgeTrailerCount -Root $root) | Should -BeGreaterThan 1
                # Content from BOTH sides of the rename landed.
                [System.IO.File]::Exists([System.IO.Path]::Combine($bridge, 'a.txt')) | Should -BeTrue
                [System.IO.File]::Exists([System.IO.Path]::Combine($bridge, 'b.txt')) | Should -BeTrue
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty

                # And the working copy ends up on the CURRENT path, so later pulls keep working.
                $wcUrl = (& svn info --show-item url $bridge --config-dir $cfg 2>$null | Out-String).Trim()
                $wcUrl | Should -Match '/SRC/NEW/proj/trunk$'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario R2: the ancestor was renamed AWAY and BACK inside one import window' {
        It 'still reaches the revisions that lived under the interim name' -Skip:(-not $SvnAvailable) {
            # Raised in PR review: comparing only "URL at the first pending revision" against "URL
            # at HEAD" reports no rename for an A->B->A round trip, yet the revisions in between
            # live at B and a plain `svn update -r` cannot reach them. The recovery path (resolve
            # that revision's own URL, then switch) is what makes this work.
            $sb = New-Sandbox -Tag 'igsb-rt'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SvnRepoAncestorRenameRoundtrip -Sandbox $sb -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the round-trip rename svn repo'; return }

                # -Granularity per-revision is REQUIRED here, not incidental: this fixture has 6
                # revisions, over the prompt threshold, so without it the script correctly stops at
                # GRANULARITY_REQUIRED having built nothing -- and every content assertion below
                # would then fail for the wrong reason. It also exercises the #33 fix (an explicit
                # granularity is honoured rather than silently dropped).
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri, '-Granularity', 'per-revision')

                $combined = $res.Stdout + $res.Stderr
                $combined | Should -Not -Match 'GRANULARITY_REQUIRED'  # explicit choice must win
                $res.ExitCode | Should -Be 0

                # An E160005 in the output is EXPECTED here, not a failure: the recovery is
                # deliberately "try the plain update, pay for a URL lookup only once it fails", so
                # svn reports the unreachable path first and the switch follows. What must hold is
                # that the replay RECOVERED -- this note plus the content checks below.
                $combined | Should -Match 'following the rename to'

                $bridge = Get-BridgePath -Root $root
                # All three phases must land: before the rename, while renamed, after renaming back.
                # The middle one is the whole point of this case.
                [System.IO.File]::Exists([System.IO.Path]::Combine($bridge, 'a.txt')) | Should -BeTrue
                [System.IO.File]::Exists([System.IO.Path]::Combine($bridge, 'b.txt')) | Should -BeTrue
                [System.IO.File]::Exists([System.IO.Path]::Combine($bridge, 'c.txt')) | Should -BeTrue
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'Scenario 1b: case (a) + a landing path that EXISTS BUT IS EMPTY, in a repo with history' {
        It 'connects instead of dying on an unborn bridge branch' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-1b'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SvnRepoWithEmptyTrunk -Sandbox $sb -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0
                $res.Stdout | Should -Match 'SVN bridge connected\.'
                # The failure this locks down reported a conflict with an EMPTY conflict list.
                $res.Stdout | Should -Not -Match 'MERGE_CONFLICT'
                $res.Stdout | Should -Not -Match 'MERGE_FAILED'

                (Get-BridgeBranchCount -Root $root) | Should -Be 1
                $bridge = Get-BridgePath -Root $root
                # The bridge branch must be a real commit, not an unborn ref: step 13 merges it.
                (Run-Git-Capture -Cwd $bridge -GitArgs @('rev-parse', '--verify', 'HEAD')) | Should -Not -BeNullOrEmpty
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
                (Run-Git-Capture -Cwd $root -GitArgs @('ls-files')) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
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

                # main is empty and STAYS empty. Since U4 the bridge no longer invents a
                # .gitignore, so an empty SVN URL contributes nothing at all -- the project's own
                # .gitignore is tp-setup's job, after this script returns.
                $mainFiles = Run-Git-Capture -Cwd $root -GitArgs @('ls-files')
                $mainFiles | Should -BeNullOrEmpty
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

                # The bridge mirrors SVN exactly. This seed's /trunk carries no .gitignore, so
                # neither does the bridge -- before U4 the bootstrap invented one containing
                # '.svn/', which is what made a first-time takeover conflict with any project that
                # had a .gitignore of its own. Keeping '.svn/' out of git is info/exclude's job now,
                # which the next assertion checks.
                $gi = [System.IO.Path]::Combine($bridge, '.gitignore')
                [System.IO.File]::Exists($gi) | Should -BeFalse -Because 'the bridge must not invent a .gitignore SVN does not have'

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

    # Regression for a real incident: the script resolves its target from the AMBIENT cwd, so an
    # invocation made inside a linked worktree bootstrapped a bridge into a DIFFERENT checkout (the
    # repo's main worktree) and merged SVN content into ITS current branch. No svn needed -- the
    # guard fires before any svn call.
    Context 'Scenario 7b: wrong-repo guard 1 -- refuse to bootstrap from a LINKED worktree' {
        It 'exits non-zero and leaves the OTHER checkout untouched' {
            $sb = New-Sandbox -Tag 'igsb-7b'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseBRepo -Root $root -Files @{ 'seed.txt' = "seed`n" }
                $peer = [System.IO.Path]::Combine($sb, 'peer-worktree')
                $rc = Run-Git -Cwd $root -GitArgs @('worktree', 'add', '-b', 'peer-branch', $peer)
                if ($rc -ne 0) { Set-ItResult -Skipped -Because 'could not create a linked worktree'; return }

                $svnUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'svnrepo') -replace '\\', '/')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $peer -ScriptArgs @('-SvnUrl', $svnUri)
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'linked worktree'

                # the OTHER checkout must be untouched.
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
                [System.IO.Directory]::Exists((Get-BridgePath -Root $root)) | Should -BeFalse
                (Run-Git-Capture -Cwd $root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    # A repo that already has a git remote already has a git server, which is not what this plugin
    # bridges; overwhelmingly it means the cwd was wrong. Token + zero changes, overridable by flag.
    Context 'Scenario 7c: wrong-repo guard 2 -- existing git remote gates on confirmation' {
        It 'emits the token, changes nothing, and -AllowExistingRemote takes the gate down' {
            $sb = New-Sandbox -Tag 'igsb-7c'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseBRepo -Root $root -Files @{ 'seed.txt' = "seed`n" }
                $null = Run-Git -Cwd $root -GitArgs @('remote', 'add', 'origin', 'https://example.invalid/some/repo.git')

                $svnUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'svnrepo') -replace '\\', '/')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $svnUri)
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'TP_TOKEN:EXISTING_GIT_REMOTE'
                $res.Combined | Should -Match 'remotes=origin'

                # the gate changed nothing.
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
                [System.IO.Directory]::Exists((Get-BridgePath -Root $root)) | Should -BeFalse
                (Run-Git-Capture -Cwd $root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty

                # -AllowExistingRemote takes the gate down. The run still fails later on the
                # unreachable URL; assert only that the gate itself no longer fires.
                $bogusUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'no-such-repo') -replace '\\', '/')
                $res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $bogusUri, '-AllowExistingRemote')
                $res2.Combined | Should -Not -Match 'TP_TOKEN:EXISTING_GIT_REMOTE'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    # A folder that is not a repo but holds sibling projects that are. `git rev-parse` only searches
    # UPWARD, so guards 1 and 2 see "no git here" and fall straight through to `git init` -- which
    # would wrap every sibling project into one repository. Nothing later undoes that.
    Context 'Scenario 7d: wrong-repo guard 3 -- refuse to git init over sibling repos' {
        It 'emits the token, creates no repository, and -AllowNestedRepos takes the gate down' {
            $sb = New-Sandbox -Tag 'igsb-7d'
            try {
                $workspace = [System.IO.Path]::Combine($sb, 'proj-root')
                $null = New-Item -ItemType Directory -Path $workspace -Force
                # two independent projects side by side; the workspace folder itself has no git
                foreach ($name in @('proj-1', 'proj-2')) {
                    $child = [System.IO.Path]::Combine($workspace, $name)
                    New-CaseBRepo -Root $child -Files @{ 'seed.txt' = "seed`n" }
                }

                $svnUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'svnrepo') -replace '\\', '/')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $workspace -ScriptArgs @('-SvnUrl', $svnUri)
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'TP_TOKEN:NESTED_GIT_REPOS'
                $res.Combined | Should -Match 'proj-1'
                $res.Combined | Should -Match 'proj-2'

                # the load-bearing assertion: no repository was created over the workspace folder.
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($workspace, '.git')) | Should -BeFalse
                # and the sibling projects are untouched.
                foreach ($name in @('proj-1', 'proj-2')) {
                    $child = [System.IO.Path]::Combine($workspace, $name)
                    (Run-Git-Capture -Cwd $child -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
                }

                # -AllowNestedRepos takes the gate down (a real project may hold a vendored sub-repo).
                # The run still fails later on the unreachable URL; assert only that the gate is gone.
                $bogusUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'no-such-repo') -replace '\\', '/')
                $res2 = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $workspace -ScriptArgs @('-SvnUrl', $bogusUri, '-AllowNestedRepos')
                $res2.Combined | Should -Not -Match 'TP_TOKEN:NESTED_GIT_REPOS'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    # Same guard, but the workspace is NAMED via -RepoRoot instead of being the cwd. Without this
    # the guard would scan the (clean) cwd, find nothing, fall through, and git init the workspace
    # it was pointed at -- i.e. the exact outcome guard 3 exists to prevent, now reachable through
    # the very argument added to make targeting explicit.
    Context 'Scenario 7e: guard 3 scans the -RepoRoot target, not the working directory' {
        It 'refuses over the NAMED workspace while the cwd is a clean unrelated directory' {
            $sb = New-Sandbox -Tag 'igsb-7e'
            try {
                $workspace = [System.IO.Path]::Combine($sb, 'proj-root')
                $null = New-Item -ItemType Directory -Path $workspace -Force
                foreach ($name in @('proj-1', 'proj-2')) {
                    New-CaseBRepo -Root ([System.IO.Path]::Combine($workspace, $name)) -Files @{ 'seed.txt' = "seed`n" }
                }
                # cwd for the run: a sibling directory with no git anywhere in it.
                $elsewhere = [System.IO.Path]::Combine($sb, 'elsewhere')
                $null = New-Item -ItemType Directory -Path $elsewhere -Force

                $svnUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'svnrepo') -replace '\\', '/')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $elsewhere `
                    -ScriptArgs @('-SvnUrl', $svnUri, '-RepoRoot', $workspace)

                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'TP_TOKEN:NESTED_GIT_REPOS'
                $res.Combined | Should -Match 'proj-1'
                $res.Combined | Should -Match 'proj-2'

                # the load-bearing pair: nothing was created at EITHER location.
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($workspace, '.git')) | Should -BeFalse
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($elsewhere, '.git')) | Should -BeFalse
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'a -RepoRoot naming a real project proceeds past the guard' {
            # Complement: the guard must not fire just because -RepoRoot was used. Pointing it at a
            # genuine single project gets past guard 3; the run then fails on the unreachable URL.
            $sb = New-Sandbox -Tag 'igsb-7e2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj-1')
                New-CaseBRepo -Root $root -Files @{ 'seed.txt' = "seed`n" }
                $elsewhere = [System.IO.Path]::Combine($sb, 'elsewhere')
                $null = New-Item -ItemType Directory -Path $elsewhere -Force

                $bogusUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'no-such-repo') -replace '\\', '/')
                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $elsewhere `
                    -ScriptArgs @('-SvnUrl', $bogusUri, '-RepoRoot', $root)

                $res.Combined | Should -Not -Match 'TP_TOKEN:NESTED_GIT_REPOS'
                # and the cwd was never turned into a repository on the way past.
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($elsewhere, '.git')) | Should -BeFalse
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'a -RepoRoot that does not exist is refused before anything is created' {
            $sb = New-Sandbox -Tag 'igsb-7e3'
            try {
                $elsewhere = [System.IO.Path]::Combine($sb, 'elsewhere')
                $null = New-Item -ItemType Directory -Path $elsewhere -Force
                $absent = [System.IO.Path]::Combine($sb, 'no-such-dir')
                $svnUri = 'file:///' + ([System.IO.Path]::Combine($sb, 'svnrepo') -replace '\\', '/')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $elsewhere `
                    -ScriptArgs @('-SvnUrl', $svnUri, '-RepoRoot', $absent)

                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'Repo root not found'
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($elsewhere, '.git')) | Should -BeFalse
                [System.IO.Directory]::Exists($absent) | Should -BeFalse
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

    # -- Scenario 3b (U4): a project that ALREADY has a .gitignore must not conflict --------------
    # Real-machine symptom (2026-07-31): proj-1 had no .gitignore and connected cleanly; proj-2 had
    # ONE line (`*.log`) and conflicted every time. Cause: the bootstrap wrote '.svn/' into the
    # bridge's .gitignore and committed it, so both unrelated histories "added" that file with
    # different content -- and git conflicts on add/add unless the sides are byte-identical
    # (verified: a strict superset conflicts too). Practically every real project has a .gitignore,
    # so first-time takeover conflicted essentially always, on a file the tool itself dirtied.
    Context 'Scenario 3b (U4): taking over a project that already has a .gitignore' {
        It 'merges without a manufactured conflict and keeps the project rule' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-3b'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseBRepo -Root $root -Files @{ '.gitignore' = "*.log`n"; 'app-git.txt' = "app`n" }

                # An SVN side with content but NO .gitignore of its own -- proj-2's exact shape, and
                # the reason the old code conflicted: with SVN contributing none, the ONLY .gitignore
                # on the bridge side was the '.svn/' line the bootstrap wrote itself.
                $uri = New-SvnRepo -Sandbox $sb
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build empty svn repo'; return }
                $seed = [System.IO.Path]::Combine($sb, 'seed-nogi')
                $null = New-Item -ItemType Directory -Path $seed -Force
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($seed, 'app-svn.txt'), "svn-side`n")
                $cfg = [System.IO.Path]::Combine($sb, '.svnconfig')
                $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
                try {
                    & svn import $seed $uri -m 'import (no gitignore)' --config-dir $cfg 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because 'svn import failed'; return }
                } finally { $ErrorActionPreference = $prev }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0 -Because "a project with a .gitignore must connect cleanly: $($res.Combined)"
                $res.Combined | Should -Not -Match 'TP_TOKEN:MERGE_CONFLICT'

                # The project's rule survives untouched -- the fix must not rewrite the user's file.
                $gi = @([System.IO.File]::ReadAllLines([System.IO.Path]::Combine($root, '.gitignore')))
                @($gi | Where-Object { $_.Trim() -eq '*.log' }).Count | Should -BeGreaterThan 0
                (Run-Git-Capture -Cwd $root -GitArgs @('ls-files')) | Should -Match 'app-git\.txt'
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    # -- Scenario 3c (U5): "cannot reach" and "path does not exist" are told apart ----------------
    # Both used to collapse into "Could not read SVN revision from '<url>'. Is the URL reachable?"
    # with svn's own stderr thrown away -- so a perfectly reachable repository with a typo'd or
    # not-yet-created path produced a message about reachability, which is simply false. They need
    # opposite responses: unreachable is an environment problem, a missing path is normal and
    # offerable to create (nothing in this plugin ever ran `svn mkdir`).
    Context 'Scenario 3c (U5): SVN preflight classification' {
        It 'classifies an unreachable repository, keeps the svn message, creates nothing' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-3c1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseARepo -Root $root
                $missing = 'file:///' + (([System.IO.Path]::Combine($sb, 'no-such-repo')) -replace '\\', '/')

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $missing)
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'TP_TOKEN:SVN_UNREACHABLE'
                $res.Combined | Should -Not -Match 'TP_TOKEN:SVN_PATH_MISSING'
                # The svn client's own words must survive -- they name the actual cause.
                $res.Combined | Should -Match 'svn: '
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
                (Test-Path -LiteralPath (Get-BridgePath -Root $root)) | Should -BeFalse
            } finally { Remove-Sandbox -Dir $sb }
        }

        It 'classifies a reachable repository with a missing path' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-3c2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                New-CaseARepo -Root $root
                $uri = New-SvnRepo -Sandbox $sb
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build empty svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', "$uri/proj-3/trunk")
                $res.ExitCode | Should -Not -Be 0
                $res.Combined | Should -Match 'TP_TOKEN:SVN_PATH_MISSING'
                $res.Combined | Should -Not -Match 'TP_TOKEN:SVN_UNREACHABLE'
                $res.Combined | Should -Match 'reachable'
                (Get-BridgeBranchCount -Root $root) | Should -Be 0
                (Test-Path -LiteralPath (Get-BridgePath -Root $root)) | Should -BeFalse
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    # -- Scenario 3d (U5): New-SvnPath creates the landing path, only when asked ------------------
    Context 'Scenario 3d (U5): New-SvnPath' {
        It 'dry-runs for free, creates trunk/branches/tags, refuses the rest' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-3d'
            try {
                $mk = [System.IO.Path]::Combine($script:PluginRoot, 'scripts', 'New-SvnPath.ps1')
                $uri = New-SvnRepo -Sandbox $sb
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build empty svn repo'; return }
                $cfg = [System.IO.Path]::Combine($sb, '.svnconfig')

                # -DryRun touches nothing: the point of "we ask before writing" is that asking is free.
                $dry = Invoke-PsScript -ScriptPath $mk -Cwd $sb -ScriptArgs @('-SvnUrl', "$uri/proj-3/trunk", '-StandardLayout', '-DryRun')
                $dry.ExitCode | Should -Be 0
                $dry.Stdout | Should -Match 'proj-3/branches'
                (Test-SvnPathExists -Url "$uri/proj-3" -ConfigDir $cfg) | Should -BeFalse

                $mkRes = Invoke-PsScript -ScriptPath $mk -Cwd $sb -ScriptArgs @('-SvnUrl', "$uri/proj-3/trunk", '-StandardLayout')
                $mkRes.ExitCode | Should -Be 0 -Because $mkRes.Combined
                # branches/ is not decoration: creating a branch is an `svn copy` WITHOUT --parents,
                # so an absent branches/ makes the first branch push fail outright.
                foreach ($leaf in @('trunk', 'branches', 'tags')) {
                    (Test-SvnPathExists -Url "$uri/proj-3/$leaf" -ConfigDir $cfg) | Should -BeTrue -Because "proj-3/$leaf should exist"
                }

                # Creating something that already exists is an error, not a silent no-op.
                $again = Invoke-PsScript -ScriptPath $mk -Cwd $sb -ScriptArgs @('-SvnUrl', "$uri/proj-3/trunk")
                $again.ExitCode | Should -Not -Be 0
                $again.Combined | Should -Match 'already exists'

                # -StandardLayout only has an unambiguous meaning under /trunk.
                $bad = Invoke-PsScript -ScriptPath $mk -Cwd $sb -ScriptArgs @('-SvnUrl', "$uri/proj-4", '-StandardLayout')
                $bad.ExitCode | Should -Not -Be 0
                (Test-SvnPathExists -Url "$uri/proj-4" -ConfigDir $cfg) | Should -BeFalse
            } finally { Remove-Sandbox -Dir $sb }
        }
    }

    Context 'Regression: a LATER revision adding .gitignore must not conflict/deadlock the import' {
        # Real-world failure: the bootstrap wrote the bridge .gitignore while the WC was at r1, so
        # replaying forward to the revision that ADDS .gitignore raised "An unversioned file was found
        # in the working copy" and svn blocked on its interactive conflict prompt (looked frozen).
        It 'imports per-revision over a later-added .gitignore, keeps svn content, leaves the bridge clean' -Skip:(-not $SvnAvailable) {
            $sb = New-Sandbox -Tag 'igsb-gi'
            try {
                $root = [System.IO.Path]::Combine($sb, 'test-turbo-plugin')
                $cfg  = [System.IO.Path]::Combine($sb, '.svnconfig')
                New-CaseARepo -Root $root
                $uri = New-SvnRepoGitignoreAddedLater -Sandbox $sb -ConfigDir $cfg
                if ($null -eq $uri) { Set-ItResult -Skipped -Because 'could not build the svn repo'; return }

                $res = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -Cwd $root -ScriptArgs @('-SvnUrl', $uri)
                $res.ExitCode | Should -Be 0 -Because $res.Combined
                $res.Combined | Should -Not -Match 'Tree conflict'
                $res.Combined | Should -Not -Match 'remains in conflict'
                (Get-BridgeTrailerCount -Root $root) | Should -Be 3

                $bridge = Get-BridgePath -Root $root
                $gi = @([System.IO.File]::ReadAllLines([System.IO.Path]::Combine($bridge, '.gitignore')))
                # End state matches the squash path: the bridge carries SVN's .gitignore and only
                # that -- nothing this tool added (the U4 conflict cause).
                @($gi | Where-Object { $_.Trim() -eq '.svn/' }).Count | Should -Be 0
                @($gi | Where-Object { $_.Trim() -eq '*.log' }).Count | Should -BeGreaterThan 0
                (Run-Git-Capture -Cwd $bridge -GitArgs @('ls-files')) | Should -Not -Match '(^|\n)\.svn'
                # A dirty bridge breaks the next push, so the .gitignore edit must be committed.
                (Run-Git-Capture -Cwd $bridge -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
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
