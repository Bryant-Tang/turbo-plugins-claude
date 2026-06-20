# Common.test.ps1 (Pester 5)
#
# Unit tests for the SVN concern + Core helpers in scripts/lib/Common.ps1.
#
# Migrated from the self-rolled Assert-* harness to Pester 5 (KTD-7 re-key):
#   - U6 removed the schema_version validator (Test-TurboPluginConfigSchema / once-guard /
#     call site). The old "schema_version warning" block + its three =1/=2/=3 assertions
#     are gone — validator no longer exists, residual keys are ignored by the TOML reader.
#   - The old config-merge carrier borrowed [svn] force_bash (removed in U5). It is re-keyed
#     onto [iis] enabled (config.toml false, config.local.toml true overrides) to keep the
#     "key-level shallow merge, local wins" coverage. Residual schema_version = 2 fixture
#     lines are replaced by a generic top-level `note` key to keep the empty-section /
#     top-level-key parser coverage.

BeforeAll {
    # <plugin>/tests/unit/scripts/lib/<this>.ps1 -> <plugin> is ..,..,..,..
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $commonPs1  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Common.ps1')
    if (-not (Test-Path -LiteralPath $commonPs1 -PathType Leaf)) {
        throw "Common.ps1 not found at: $commonPs1"
    }
    # Dot-source the production script (the subject under test).
    . $commonPs1

    function New-IsolatedRepoRoot {
        param([string]$Tag = 'common')
        # Each scenario gets its own sandbox dir so previous state never bleeds in.
        # Expand any 8.3 short-name segments in $env:TEMP (e.g. MELWU~1) — Remove-Item
        # -LiteralPath on PS 5.1 + a short-named parent dir trips an "object at path does
        # not exist" error.
        $tempDir = $env:TEMP
        try {
            $tempDir = (Get-Item -LiteralPath $tempDir).FullName
        } catch {
            # leave $tempDir as-is if Get-Item fails
        }
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = Join-Path $tempDir "turbo-plugin-$Tag-test-$stamp"
        $null = New-Item -ItemType Directory -Path $dir -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $dir '.turbo-plugin') -Force
        return $dir
    }

    function Remove-IsolatedRepoRoot {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        # Use the raw .NET API to sidestep PS 5.1's LiteralPath short-name parsing bug.
        try {
            if ([System.IO.Directory]::Exists($Dir)) {
                [System.IO.Directory]::Delete($Dir, $true)
            }
        } catch {
            # best-effort cleanup; test doesn't fail if a sandbox lingers
        }
    }

    function Write-Toml {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Content
        )
        Write-Utf8NoBom -Path $Path -Content $Content
    }

    function Invoke-AssertTrusted {
        # Returns @{ Threw = bool; Result = string; Message = string }
        param([string]$Wc, [string]$Candidate)
        $threw = $false; $result = ''; $msg = ''
        try {
            $result = Assert-TrustedSvnUrl -TrustedWorkingCopy $Wc -CandidateUrl $Candidate
        } catch {
            $threw = $true
            $msg = $_.Exception.Message
        }
        return @{ Threw = $threw; Result = $result; Message = $msg }
    }

    # git wrapper: PS 5.1 + EAP=Stop (set by Common.ps1) throws on harmless git stderr; soften.
    # NOTE: ValueFromRemainingArguments — a [Parameter()] attribute makes this an ADVANCED
    # function, which disables the automatic $args; remaining tokens must be bound explicitly.
    function Invoke-GitSilent {
        param(
            [Parameter(Mandatory = $true, Position = 0)][string]$RepoDir,
            [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs
        )
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & git -C $RepoDir @GitArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $old }
    }

    # Builds a repo with a 'svnbase' marker at the base commit, feat/fix on main, refactor on a
    # side branch, then a --no-ff merge of side into main — so range svnbase..main holds 3
    # non-merge subjects + 1 merge commit. Returns the repo dir.
    function New-PushBodyRepo {
        param([string]$Tag = 'pushbody')
        $dir = New-IsolatedRepoRoot $Tag
        Invoke-GitSilent $dir init -q -b main
        Invoke-GitSilent $dir config user.email 'test@turbo-plugin'
        Invoke-GitSilent $dir config user.name 'turbo-plugin-test'
        Invoke-GitSilent $dir commit -q --allow-empty -m 'base'
        Invoke-GitSilent $dir branch svnbase
        Invoke-GitSilent $dir commit -q --allow-empty -m 'feat: add A'
        Invoke-GitSilent $dir commit -q --allow-empty -m 'fix: fix B'
        Invoke-GitSilent $dir checkout -q -b side
        Invoke-GitSilent $dir commit -q --allow-empty -m 'refactor: tidy C'
        Invoke-GitSilent $dir checkout -q main
        Invoke-GitSilent $dir merge -q --no-ff -m 'Merge branch side into main' side
        return $dir
    }

}

# =============================================================================
# Resolve-ConfigValue + Read-TurboPluginConfig merge behavior (U1)
# =============================================================================
#
# Verifies the CLI -> config.toml -> config.local.toml -> Default lookup chain and the
# key-level shallow merge where config.local.toml wins. Carrier re-keyed (KTD-7) from the
# removed [svn] force_bash onto [iis] enabled.

Describe 'Resolve-ConfigValue merge behavior' {

    Context 'happy path - separate sections in each file' {
        It 'resolves both files and lets a generic top-level key parse' {
            $repo = New-IsolatedRepoRoot 'merge'
            try {
                $cfgToml      = Join-Path $repo '.turbo-plugin\config.toml'
                $cfgLocalToml = Join-Path $repo '.turbo-plugin\config.local.toml'

                Write-Toml -Path $cfgToml -Content @"
note = "x"
[iis]
enabled = false
"@
                Write-Toml -Path $cfgLocalToml -Content @"
[tools]
msbuild_path = "C:/MSBuild.exe"
"@

                $iisEnabled = Resolve-ConfigValue -RepoRoot $repo -Section 'iis'   -Key 'enabled'      -CliValue $null -Default $true
                $msbuild    = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
                $note       = Resolve-ConfigValue -RepoRoot $repo -Section ''      -Key 'note'         -CliValue $null -Default $null

                $iisEnabled | Should -BeFalse
                $msbuild | Should -Be 'C:/MSBuild.exe'
                $note | Should -Be 'x'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'U6 marker scaffolding - reader tolerates # marker comment lines + unknown section' {
        It 'skips "# >>> turbo-plugin:* >>>" markers and parses bracketed sections (incl. unknown) normally' {
            $repo = New-IsolatedRepoRoot 'marker'
            try {
                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
# turbo-plugin config.toml
# >>> turbo-plugin:git-svn >>>
[svn]
url = "https://svn.example/repo"
# <<< turbo-plugin:git-svn <<<
# >>> turbo-plugin:dotnet >>>
[iis]
enabled = true
# <<< turbo-plugin:dotnet <<<
[future-unknown-concern]
key = "v"
"@
                $svnUrl  = Resolve-ConfigValue -RepoRoot $repo -Section 'svn' -Key 'url'     -CliValue $null -Default $null
                $iis     = Resolve-ConfigValue -RepoRoot $repo -Section 'iis' -Key 'enabled' -CliValue $null -Default $null
                $unknown = Resolve-ConfigValue -RepoRoot $repo -Section 'future-unknown-concern' -Key 'key' -CliValue $null -Default $null

                # Markers (# lines) are skipped; bracketed sections parse; an unknown/foreign section
                # is tolerated (reader is section-agnostic) and does not throw.
                $svnUrl | Should -Be 'https://svn.example/repo'
                $iis | Should -BeTrue
                $unknown | Should -Be 'v'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'override - same section.key in both files, config.local.toml wins' {
        It 'returns the local override value for [iis] enabled' {
            $repo = New-IsolatedRepoRoot 'merge'
            try {
                $cfgToml      = Join-Path $repo '.turbo-plugin\config.toml'
                $cfgLocalToml = Join-Path $repo '.turbo-plugin\config.local.toml'

                Write-Toml -Path $cfgToml -Content @"
[iis]
enabled = false
"@
                Write-Toml -Path $cfgLocalToml -Content @"
[iis]
enabled = true
"@

                $iisEnabled = Resolve-ConfigValue -RepoRoot $repo -Section 'iis' -Key 'enabled' -CliValue $null -Default $null
                $iisEnabled | Should -BeTrue
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'missing local - only config.toml exists' {
        It 'falls back to config.toml without throwing' {
            $repo = New-IsolatedRepoRoot 'merge'
            try {
                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
note = "y"
[tools]
msbuild_path = "only-in-config-toml"
"@
                $cfgLocalToml = Join-Path $repo '.turbo-plugin\config.local.toml'
                Test-Path -LiteralPath $cfgLocalToml | Should -BeFalse

                $msbuild = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
                $msbuild | Should -Be 'only-in-config-toml'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'both files missing' {
        It 'returns Default when provided and null otherwise' {
            $repo = New-IsolatedRepoRoot 'merge'
            try {
                $val1 = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default 'fallback-default'
                $val1 | Should -Be 'fallback-default'

                $val2 = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
                $val2 | Should -BeNullOrEmpty
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'CLI value beats both files (regression guard)' {
        It 'returns the CLI value over config and local' {
            $repo = New-IsolatedRepoRoot 'merge'
            try {
                $cfgToml      = Join-Path $repo '.turbo-plugin\config.toml'
                $cfgLocalToml = Join-Path $repo '.turbo-plugin\config.local.toml'
                Write-Toml -Path $cfgToml -Content @"
[tools]
msbuild_path = "from-config"
"@
                Write-Toml -Path $cfgLocalToml -Content @"
[tools]
msbuild_path = "from-local"
"@
                $val = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue 'from-cli' -Default $null
                $val | Should -Be 'from-cli'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }
}

# =============================================================================
# Assert-TrustedSvnUrl (U1) - boundary-safe + case-normalized + traversal-reject
# =============================================================================
#
# Uses the seed SVN dump (fixtures/seed/svn-repo-r1-r20.dump) loaded into a throwaway
# repo, checked out as a trusted working copy. Self-SKIPs (via Set-ItResult) when svn is
# unavailable or the dump is missing or the fixture build fails.

Describe 'Assert-TrustedSvnUrl' {

    It 'enforces boundary-safe, case-normalized, traversal-rejecting trust against a seed WC' {
        $svnAvailable = $false
        try {
            $null = (& svn --version --quiet 2>$null)
            $svnAvailable = ($LASTEXITCODE -eq 0)
        } catch {
            $svnAvailable = $false
        }

        $dumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

        if (-not $svnAvailable) {
            Set-ItResult -Skipped -Because 'svn not on PATH'
            return
        }
        if (-not [System.IO.File]::Exists($dumpPath)) {
            Set-ItResult -Skipped -Because "seed dump missing at $dumpPath"
            return
        }

        $sandbox = New-IsolatedRepoRoot 'trusturl'
        try {
            $svnRepo    = [System.IO.Path]::Combine($sandbox, 'svnrepo')
            $wc         = [System.IO.Path]::Combine($sandbox, 'wc')
            $emptyNonWc = [System.IO.Path]::Combine($sandbox, 'empty-non-wc')
            $null = New-Item -ItemType Directory -Path $emptyNonWc -Force

            & svnadmin create $svnRepo
            $createOk = ($LASTEXITCODE -eq 0)

            $loadOk = $false
            if ($createOk) {
                $loadCmd = "svnadmin load `"$svnRepo`" < `"$dumpPath`""
                & cmd.exe /c $loadCmd > $null 2>$null
                $loadOk = ($LASTEXITCODE -eq 0)
            }

            if (-not $loadOk) {
                Set-ItResult -Skipped -Because 'svnadmin create/load failed (likely dump LF/CRLF mangle)'
                return
            }

            $repoUri = 'file:///' + ($svnRepo -replace '\\', '/')
            & svn checkout "$repoUri/trunk" $wc > $null 2>$null
            $coOk = ($LASTEXITCODE -eq 0)
            $reposRoot = (& svn info --show-item repos-root-url $wc 2>$null | Out-String).Trim()

            if (-not $coOk -or [string]::IsNullOrWhiteSpace($reposRoot)) {
                Set-ItResult -Skipped -Because 'svn checkout of trusted WC failed'
                return
            }

            # Case 1: same-repo trunk URL -> pass
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/trunk"
            $r.Threw | Should -BeFalse -Because $r.Message

            # Case 2: legitimate sibling branch -> pass (trust base is repos-root, not trunk url)
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/branches/test-1"
            $r.Threw | Should -BeFalse -Because $r.Message

            # Case 3: prefix-confusion root-evil/trunk -> reject (R10)
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot-evil/trunk"
            $r.Threw | Should -BeTrue -Because "unexpectedly accepted: $($r.Result)"

            # Case 4: uppercase scheme variant FILE:// -> normalized, still trusted (R11)
            $upperScheme = $reposRoot -replace '^file://', 'FILE://'
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$upperScheme/trunk"
            $r.Threw | Should -BeFalse -Because $r.Message

            # Case 5: candidate trailing-slash variant -> same result (trusted)
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/branches/test-1/"
            $r.Threw | Should -BeFalse -Because $r.Message

            # Case 6: out-of-bounds file:///C:/Windows/... -> reject
            $r = Invoke-AssertTrusted -Wc $wc -Candidate 'file:///C:/Windows/System32/'
            $r.Threw | Should -BeTrue -Because "unexpectedly accepted: $($r.Result)"

            # Case 7: different host/scheme http://attacker/... -> reject
            $r = Invoke-AssertTrusted -Wc $wc -Candidate 'http://attacker.example/repo'
            $r.Threw | Should -BeTrue -Because "unexpectedly accepted: $($r.Result)"

            # Case 8: path traversal in candidate -> reject
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/trunk/../../etc"
            $r.Threw | Should -BeTrue -Because "unexpectedly accepted: $($r.Result)"

            # Case 8b: percent-encoded traversal %2e%2e under base -> reject (decode-then-recheck)
            $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/trunk/%2e%2e/%2e%2e/etc"
            $r.Threw | Should -BeTrue -Because "unexpectedly accepted: $($r.Result)"

            # Case 9: fail-closed - empty non-WC reference dir -> throw
            $r = Invoke-AssertTrusted -Wc $emptyNonWc -Candidate "$reposRoot/trunk"
            $r.Threw | Should -BeTrue -Because "unexpectedly accepted: $($r.Result)"
            $r.Message | Should -Match '(fail closed|repos-root-url)'
        } finally {
            Remove-IsolatedRepoRoot -Dir $sandbox
        }
    }
}

# =============================================================================
# lib helper unit coverage (U7)
# =============================================================================

Describe 'Get-RelativePathSafe' {

    It 'child path resolves to sub then file.txt' {
        $rel = Get-RelativePathSafe -From 'C:\proj' -To 'C:\proj\sub\file.txt'
        $rel | Should -Be ('sub' + [System.IO.Path]::DirectorySeparatorChar + 'file.txt')
    }

    It 'sibling path resolves to up-one then b then x.cs' {
        $rel = Get-RelativePathSafe -From 'C:\proj\a' -To 'C:\proj\b\x.cs'
        $rel | Should -Be ('..' + [System.IO.Path]::DirectorySeparatorChar + 'b' + [System.IO.Path]::DirectorySeparatorChar + 'x.cs')
    }

    It 'nested up-then-down resolves to up-two then d then e.txt' {
        $rel = Get-RelativePathSafe -From 'C:\a\b\c' -To 'C:\a\d\e.txt'
        $rel | Should -Be ('..' + [System.IO.Path]::DirectorySeparatorChar + '..' + [System.IO.Path]::DirectorySeparatorChar + 'd' + [System.IO.Path]::DirectorySeparatorChar + 'e.txt')
    }

    It 'REGRESSION F-U2.9: From equals To returns empty string' {
        Get-RelativePathSafe -From 'C:\proj\sub' -To 'C:\proj\sub' | Should -Be ''
    }

    It 'REGRESSION F-U2.9: From equals To (trailing-slash variant) returns empty string' {
        Get-RelativePathSafe -From 'C:\proj\sub' -To 'C:\proj\sub\' | Should -Be ''
    }
}

Describe 'Get-NormalizedAbsolutePath' {

    It 'Git-Bash /c/... normalizes to c:\... (drive lowercased, backslashes)' {
        Get-NormalizedAbsolutePath -Path '/c/work/test/proj' | Should -Match '^c:\\work\\test\\proj$'
    }

    It 'uppercase drive C:\ is lowercased to c:\' {
        Get-NormalizedAbsolutePath -Path 'C:\Temp\Thing' | Should -Match '^c:\\'
    }

    It 'forward-slash absolute path normalizes to d:\data\sub' {
        Get-NormalizedAbsolutePath -Path 'D:/data/sub' | Should -Match '^d:\\data\\sub$'
    }

    It 'empty path throws (param binding)' {
        { Get-NormalizedAbsolutePath -Path '' } | Should -Throw
    }

    It 'whitespace path throws (function guard)' {
        { Get-NormalizedAbsolutePath -Path '   ' } | Should -Throw -ExpectedMessage '*empty path*'
    }
}

Describe 'Resolve-RemoteWorktree' {

    BeforeAll { $script:WtDir = 'C:\proj.worktrees' }

    It 'main resolves to the remote-svn-main triple' {
        $rw = Resolve-RemoteWorktree -BranchName 'main' -WorktreesDir $script:WtDir
        $rw.Name | Should -Be 'remote-svn-main'
        $rw.Branch | Should -Be 'remote-svn/main'
        $rw.Path | Should -Be (Join-Path $script:WtDir 'remote-svn-main')
    }

    It 'test-3 resolves to the remote-svn-test-3 triple' {
        $rw = Resolve-RemoteWorktree -BranchName 'test-3' -WorktreesDir $script:WtDir
        $rw.Name | Should -Be 'remote-svn-test-3'
        $rw.Branch | Should -Be 'remote-svn/test-3'
        $rw.Path | Should -Be (Join-Path $script:WtDir 'remote-svn-test-3')
    }

    It 'invalid branch name (contains dot-dot) throws' {
        { Resolve-RemoteWorktree -BranchName 'bad..name' -WorktreesDir $script:WtDir } | Should -Throw -ExpectedMessage "*Invalid branch name*"
    }
}

Describe 'Get-WorktreesDir' {

    It 'explicit MainWorktree returns the nested .turbo-plugin worktrees container' {
        $main = 'C:\proj\main'
        $expected = [System.IO.Path]::Combine($main, '.turbo-plugin', 'worktrees')
        $actual = Get-WorktreesDir -MainWorktree $main
        $actual | Should -Be $expected
        $actual.StartsWith($main, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $actual | Should -Match '\.turbo-plugin[\\/]worktrees$'
    }
}

Describe 'Write-Utf8NoBom' {

    It 'writes CJK content without a BOM and byte-identical to canonical UTF-8 (R6)' {
        $repo = New-IsolatedRepoRoot 'utf8nobom'
        try {
            $cjkContent = '組態載入完成 — 中文路徑支援已啟用'   # schema dict 5.5 (CJK + em-dash)
            $file = Join-Path $repo 'msg.txt'
            Write-Utf8NoBom -Path $file -Content $cjkContent

            $bytes = [System.IO.File]::ReadAllBytes($file)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $hasBom | Should -BeFalse

            $canonical = (New-Object System.Text.UTF8Encoding($false)).GetBytes($cjkContent)
            $bytes.Length | Should -Be $canonical.Length
            for ($i = 0; $i -lt $canonical.Length; $i++) {
                $bytes[$i] | Should -Be $canonical[$i]
            }
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}

# =============================================================================
# Get-SvnPushBody (U9) - locked SVN body = '- '-prefixed non-merge subjects
# =============================================================================

Describe 'Get-SvnPushBody' {

    It 'lists every non-merge subject (- prefixed, no hash) and excludes the merge commit' {
        $repo = New-PushBodyRepo 'pb-nomerge'
        try {
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            # Measure-Object — .Count on a raw collection is unreliable under Set-StrictMode Latest.
            $allLines = @($body -split "`n")
            ($allLines | Measure-Object).Count | Should -Be 3
            $bullets = @($allLines | Where-Object { $_ -match '^- ' })
            ($bullets | Measure-Object).Count | Should -Be 3
            $body | Should -Match '(?m)^- feat: add A$'
            $body | Should -Match '(?m)^- fix: fix B$'
            $body | Should -Match '(?m)^- refactor: tidy C$'
            $body | Should -Not -Match 'Merge branch'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'applies NO commit-type filtering — docs/chore subjects appear in the body (AE2)' {
        $repo = New-IsolatedRepoRoot 'pb-notype'
        try {
            Invoke-GitSilent $repo init -q -b main
            Invoke-GitSilent $repo config user.email 'test@turbo-plugin'
            Invoke-GitSilent $repo config user.name 'turbo-plugin-test'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'base'
            Invoke-GitSilent $repo branch svnbase
            Invoke-GitSilent $repo commit -q --allow-empty -m 'docs: update README'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'chore: bump version'
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            $body | Should -Match '(?m)^- docs: update README$'
            $body | Should -Match '(?m)^- chore: bump version$'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'is byte-identical across two runs on the same commit set (determinism)' {
        $repo = New-PushBodyRepo 'pb-determ'
        try {
            $b1 = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            $b2 = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            [System.String]::Equals($b1, $b2, [System.StringComparison]::Ordinal) | Should -BeTrue
            $enc = New-Object System.Text.UTF8Encoding($false)
            $h1 = [System.BitConverter]::ToString($enc.GetBytes($b1))
            $h2 = [System.BitConverter]::ToString($enc.GetBytes($b2))
            $h1 | Should -Be $h2
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'preserves special characters in a subject verbatim (leading dash, backtick, $)' {
        $repo = New-IsolatedRepoRoot 'pb-special'
        try {
            Invoke-GitSilent $repo init -q -b main
            Invoke-GitSilent $repo config user.email 'test@turbo-plugin'
            Invoke-GitSilent $repo config user.name 'turbo-plugin-test'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'base'
            Invoke-GitSilent $repo branch svnbase
            # No embedded double-quote here: PS 5.1's native-arg quoting mangles '"' when
            # invoking git.exe (a fixture limitation, not a helper bug). The bash sibling test
            # covers double-quote preservation; this asserts the helper never interpolates a
            # leading '- ', backtick, or '$' in the subject.
            $special = '- fix: weird `code` and $x end'
            Invoke-GitSilent $repo commit -q --allow-empty -m $special
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            $body | Should -Be ('- ' + $special)
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'returns empty when the range contains only merge commit(s)' {
        $repo = New-IsolatedRepoRoot 'pb-onlymerge'
        try {
            Invoke-GitSilent $repo init -q -b main
            Invoke-GitSilent $repo config user.email 'test@turbo-plugin'
            Invoke-GitSilent $repo config user.name 'turbo-plugin-test'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'base'
            Invoke-GitSilent $repo checkout -q -b feature
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: X'
            Invoke-GitSilent $repo checkout -q main
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: Y'
            $ySha = (& git -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
            Invoke-GitSilent $repo merge -q --no-ff -m 'Merge feature (main)' feature
            # startref = independent merge of the same two parents → contains X and Y but not main's merge
            Invoke-GitSilent $repo checkout -q -b startref $ySha
            Invoke-GitSilent $repo merge -q --no-ff -m 'Merge feature (startref)' feature
            $body = Get-SvnPushBody -RepoDir $repo -Range 'startref..main'
            [string]::IsNullOrEmpty($body) | Should -BeTrue
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}
