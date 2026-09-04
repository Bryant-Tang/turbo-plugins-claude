# Initialize-SvnEolStyle.test.ps1 (Pester 5)
#
# Script under test: plugins/turbo-plugin-git-svn/scripts/Initialize-SvnEolStyle.ps1
#
# The fixture is a REAL bridge -- one directory that is both a git worktree and an SVN working
# copy -- because that pairing is the whole subject. A fixture where the two are separate would
# exercise none of the interesting behaviour: the classifier reads git, the property writing goes
# through svn, and the failures live in the seam.
#
# Mirrors initialize-svn-eol-style.test.sh case for case.

# --- Discovery-time svn gate (evaluated BEFORE BeforeAll) -----------------------
# It has to live here, not in BeforeAll: Pester resolves -Skip: during DISCOVERY, where a flag set
# in BeforeAll is still $null -- the file would then skip silently while reporting green.
$SvnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $SvnAvailable = ($LASTEXITCODE -eq 0)
} catch {
    $SvnAvailable = $false
}

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Initialize-SvnEolStyle.ps1')

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    function Invoke-GitQuiet {
        param([Parameter(Mandatory = $true, Position = 0)][string]$RepoDir,
              [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & git -C $RepoDir @GitArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $old }
    }

    function Invoke-SvnQuiet {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$SvnArgs)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & svn --non-interactive @SvnArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $old }
    }

    function Get-SvnEolProp {
        param([string]$File)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $v = (& svn --non-interactive propget svn:eol-style $File 2>$null | Out-String) } catch { $v = '' } finally { $ErrorActionPreference = $old }
        return "$v".Trim()
    }

    # Build root + a bridge that is genuinely both things. Returns @{ Root; Bridge; SvnRepo }.
    #
    # Order matters and mirrors the production bootstrap: `git worktree add --no-checkout` first so
    # the directory is a git worktree, then `svn checkout --force` to overlay SVN's content and
    # metadata, then a git commit that takes SVN's bytes as the git content.
    function New-BridgeFixture {
        param([string]$Tag = 'eolinit')
        $sandbox = New-Sandbox $Tag
        $root = [System.IO.Path]::Combine($sandbox, 'repo')
        $svnrepo = [System.IO.Path]::Combine($sandbox, 'svnrepo')
        $bridge = [System.IO.Path]::Combine($root, '.turbo-plugin', 'worktrees', 'remote-svn-main')

        & svnadmin create $svnrepo 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'svnadmin create failed' }
        $uri = 'file:///' + ($svnrepo -replace '\\', '/')

        $seed = [System.IO.Path]::Combine($sandbox, 'seed')
        Invoke-SvnQuiet checkout -q $uri $seed
        $trunk = [System.IO.Path]::Combine($seed, 'trunk')
        $null = New-Item -ItemType Directory -Path $trunk -Force

        # Byte-exact writes: Set-Content would impose its own newline handling and the mixed and
        # CRLF fixtures would stop being what they claim to be.
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($trunk, 'plain.txt'), "alpha`nbeta`n", $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($trunk, 'mixed.txt'), "one`r`ntwo`n", $enc)
        [System.IO.File]::WriteAllBytes([System.IO.Path]::Combine($trunk, 'blob.bin'), [byte[]](120, 0, 121, 0))
        # Stored as CRLF with no property -- the shape issue #164 left behind. The migration is
        # supposed to normalise this in the repository, which is the whole point of running it.
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($trunk, 'wascrlf.txt'), "red`r`ngreen`r`n", $enc)

        Invoke-SvnQuiet add -q $trunk
        Invoke-SvnQuiet commit -q -m 'seed' $seed

        $null = New-Item -ItemType Directory -Path $root -Force
        Invoke-GitQuiet $root init -q -b main
        Invoke-GitQuiet $root config user.email 'test@turbo-plugin'
        Invoke-GitQuiet $root config user.name 'turbo-plugin-test'
        Invoke-GitQuiet $root config core.autocrlf false
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'init.txt'), "init`n", $enc)
        Invoke-GitQuiet $root add -A
        Invoke-GitQuiet $root -c commit.gpgsign=false commit -q -m 'initial'

        $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($root, '.turbo-plugin', 'worktrees')) -Force
        Invoke-GitQuiet $root worktree add -q --no-checkout $bridge -b 'remote-svn/main'
        Invoke-SvnQuiet checkout -q --force "$uri/trunk" $bridge
        Invoke-SvnQuiet propset -q 'svn:ignore' '.git' $bridge

        # Keep .svn out of git, as the production bootstrap does. It goes in the COMMON git dir's
        # info/exclude because git does not read a linked worktree's own. Without it the bridge is
        # permanently git-dirty -- svn rewrites .svn/wc.db constantly -- and every guard that asks
        # "is this worktree clean?" fires on metadata that was never meant to be tracked.
        $infoDir = [System.IO.Path]::Combine($root, '.git', 'info')
        $null = New-Item -ItemType Directory -Path $infoDir -Force
        Add-Content -LiteralPath ([System.IO.Path]::Combine($infoDir, 'exclude')) -Value '.svn/' -Encoding ASCII

        Invoke-GitQuiet $bridge add -A
        Invoke-GitQuiet $bridge -c commit.gpgsign=false commit -q -m 'svn content'
        Invoke-SvnQuiet commit -q -m 'svn:ignore' $bridge

        # Fixture guard: without a real worktree the classifier reads a different repository and
        # every assertion below would measure the wrong tree while still reporting green.
        if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($bridge, '.git')))) {
            throw "fixture: bridge worktree was not created at $bridge"
        }
        return @{ Sandbox = $sandbox; Root = $root; Bridge = $bridge; SvnRepo = $svnrepo }
    }
}

Describe 'Initialize-SvnEolStyle' {

    It 'exists' {
        Test-Path -LiteralPath $script:ScriptUnderTest | Should -BeTrue
    }

    It 'previews without changing anything, and names the mixed-ending file' {
        if (-not $SvnAvailable) {
            Set-ItResult -Skipped -Because 'svn is not on PATH'
            return
        }
        $fx = New-BridgeFixture 'eolprev'
        try {
            $r = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -ScriptArgs @('-RepoRoot', $fx.Root, '-Preview')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -Match 'Preview only'
            # The mixed file must be NAMED, not just counted: it is excluded permanently and
            # nothing afterwards says why.
            $r.Stdout | Should -Match 'mixed\.txt'

            (Get-SvnEolProp ([System.IO.Path]::Combine($fx.Bridge, 'plain.txt'))) | Should -BeNullOrEmpty
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $st = @(& svn --non-interactive status $fx.Bridge 2>$null | Where-Object { $_ -and ($_ -notmatch '^\?') }) } finally { $ErrorActionPreference = $old }
            $st.Count | Should -Be 0
        } finally {
            Remove-Sandbox -Dir $fx.Sandbox
        }
    }

    It 'marks text files, skips binary and mixed, commits, and SVN then stores LF' {
        if (-not $SvnAvailable) {
            Set-ItResult -Skipped -Because 'svn is not on PATH'
            return
        }
        $fx = New-BridgeFixture 'eolapply'
        try {
            $r = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -ScriptArgs @('-RepoRoot', $fx.Root)
            $r.ExitCode | Should -Be 0

            (Get-SvnEolProp ([System.IO.Path]::Combine($fx.Bridge, 'plain.txt'))) | Should -Be 'native'
            # A binary carrying svn:eol-style comes back corrupted; a mixed-ending file makes
            # `svn commit` fail atomically. Neither may be touched.
            (Get-SvnEolProp ([System.IO.Path]::Combine($fx.Bridge, 'mixed.txt'))) | Should -BeNullOrEmpty
            (Get-SvnEolProp ([System.IO.Path]::Combine($fx.Bridge, 'blob.bin'))) | Should -BeNullOrEmpty

            # The payoff: a file the repository was storing as CRLF is now stored as LF. Read back
            # through svnlook rather than a working copy -- a working copy applies the very
            # translation under test, so it would report LF either way.
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $bytes = (& svnlook cat $fx.SvnRepo 'trunk/wascrlf.txt' 2>$null | Out-String) } finally { $ErrorActionPreference = $old }
            ([regex]::Matches($bytes, "`r")).Count | Should -Be 0
        } finally {
            Remove-Sandbox -Dir $fx.Sandbox
        }
    }

    It 'refuses a bridge with pending SVN changes' {
        if (-not $SvnAvailable) {
            Set-ItResult -Skipped -Because 'svn is not on PATH'
            return
        }
        $fx = New-BridgeFixture 'eoldirty'
        try {
            # A pending SVN change must stop the run: the property commit would otherwise sweep it
            # up, and the pull path skips property-only revisions -- so it would reach SVN and
            # never come back into git.
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($fx.Bridge, 'plain.txt'), "alpha`nbeta`ngamma`n", $enc)

            $r = Invoke-PsScript -ScriptPath $script:ScriptUnderTest -ScriptArgs @('-RepoRoot', $fx.Root)
            $r.ExitCode | Should -Not -Be 0
        } finally {
            Remove-Sandbox -Dir $fx.Sandbox
        }
    }
}
