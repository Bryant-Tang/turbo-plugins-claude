# Common.test.ps1 (Pester 5)
#
# Unit tests for plugins/turbo-plugin/scripts/lib/Common.ps1 (+ IisHelpers.ps1 helpers
# Find-MSBuild / Find-IisExpressPath which dot-source Common.ps1).
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
    $iisHelpers = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1')
    if (-not (Test-Path -LiteralPath $commonPs1 -PathType Leaf)) {
        throw "Common.ps1 not found at: $commonPs1"
    }
    if (-not (Test-Path -LiteralPath $iisHelpers -PathType Leaf)) {
        throw "IisHelpers.ps1 not found at: $iisHelpers"
    }
    # Dot-source the production scripts (the subjects under test).
    . $commonPs1
    . $iisHelpers

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

    function New-GitRepoFixture {
        param([string]$Tag = 'hash')
        $dir = New-IsolatedRepoRoot $Tag
        & git -C $dir init --quiet 2>$null | Out-Null
        return $dir
    }

    # Snapshot the two env vars up-front so per-test mutations can be restored.
    $script:OrigMsbuildEnv = $env:TURBO_PLUGIN_MSBUILD_PATH
    $script:OrigIisEnv     = $env:TURBO_PLUGIN_IIS_EXPRESS_PATH
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
# Find-MSBuild / Find-IisExpressPath strict cut to config.local.toml (U2)
# =============================================================================

Describe 'Find-MSBuild' {

    Context 'happy path - config.local.toml points to an existing file' {
        It 'returns the configured path' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $fakeMsbuild = Join-Path $repo 'fake-msbuild.exe'
                Set-Content -LiteralPath $fakeMsbuild -Value '' -Encoding ASCII

                $tomlPath = ($fakeMsbuild -replace '\\', '/')
                Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "$tomlPath"
"@
                $result = Find-MSBuild -RepoRoot $repo
                [System.IO.Path]::GetFullPath($result) | Should -Be ([System.IO.Path]::GetFullPath($fakeMsbuild))
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'auto-probe OR throw - no [tools] configured (machine-state dependent)' {
        It 'either throws with /tp-setup guidance or auto-probes an existing file' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $env:TURBO_PLUGIN_MSBUILD_PATH = $null
                $result = $null; $threw = $false; $errMsg = ''
                try {
                    $result = Find-MSBuild -RepoRoot $repo
                } catch {
                    $threw = $true; $errMsg = $_.Exception.Message
                }
                if ($threw) {
                    $errMsg | Should -Match '/tp-setup'
                    $errMsg | Should -Match '(config\.local\.toml|\[tools\])'
                } else {
                    Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
                }
            } finally {
                $env:TURBO_PLUGIN_MSBUILD_PATH = $script:OrigMsbuildEnv
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'env var is ignored - fake env path, no [tools]' {
        It 'never reads the env var (throws without env hint, or probes a real file)' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $fakeEnvPath = Join-Path $repo 'this-path-must-not-be-read.exe'
                $env:TURBO_PLUGIN_MSBUILD_PATH = $fakeEnvPath
                $result = $null; $threw = $false; $errMsg = ''
                try {
                    $result = Find-MSBuild -RepoRoot $repo
                } catch {
                    $threw = $true; $errMsg = $_.Exception.Message
                }
                if ($threw) {
                    $errMsg | Should -Not -Match 'TURBO_PLUGIN_MSBUILD_PATH'
                    $errMsg | Should -Match '/tp-setup'
                } else {
                    Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
                    $result | Should -Not -Be $fakeEnvPath
                }
            } finally {
                $env:TURBO_PLUGIN_MSBUILD_PATH = $script:OrigMsbuildEnv
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'configured path points to a missing file' {
        It 'throws a friendly error referencing config.local.toml' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "C:/this/path/does/not/exist/MSBuild.exe"
"@
                { Find-MSBuild -RepoRoot $repo } | Should -Throw -ExpectedMessage '*config.local.toml*'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }
}

Describe 'Find-IisExpressPath' {

    Context 'happy path - config.local.toml points to an existing file' {
        It 'returns the configured path' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $fakeIis = Join-Path $repo 'fake-iisexpress.exe'
                Set-Content -LiteralPath $fakeIis -Value '' -Encoding ASCII

                $tomlPath = ($fakeIis -replace '\\', '/')
                Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.local.toml') -Content @"
[tools]
iis_express_path = "$tomlPath"
"@
                $result = Find-IisExpressPath -RepoRoot $repo
                [System.IO.Path]::GetFullPath($result) | Should -Be ([System.IO.Path]::GetFullPath($fakeIis))
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'auto-probe OR throw - no [tools] configured (machine-state dependent)' {
        It 'either throws with /tp-setup guidance or auto-probes an existing file' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $null
                $result = $null; $threw = $false; $errMsg = ''
                try {
                    $result = Find-IisExpressPath -RepoRoot $repo
                } catch {
                    $threw = $true; $errMsg = $_.Exception.Message
                }
                if ($threw) {
                    $errMsg | Should -Match '/tp-setup'
                    $errMsg | Should -Match '(config\.local\.toml|\[tools\])'
                } else {
                    Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
                }
            } finally {
                $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $script:OrigIisEnv
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'env var is ignored - fake env path, no [tools]' {
        It 'never reads the env var (throws without env hint, or probes a real file)' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $fakeEnvPath = Join-Path $repo 'this-path-must-not-be-read.exe'
                $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $fakeEnvPath
                $result = $null; $threw = $false; $errMsg = ''
                try {
                    $result = Find-IisExpressPath -RepoRoot $repo
                } catch {
                    $threw = $true; $errMsg = $_.Exception.Message
                }
                if ($threw) {
                    $errMsg | Should -Not -Match 'TURBO_PLUGIN_IIS_EXPRESS_PATH'
                    $errMsg | Should -Match '/tp-setup'
                } else {
                    Test-Path -LiteralPath $result -PathType Leaf | Should -BeTrue
                    $result | Should -Not -Be $fakeEnvPath
                }
            } finally {
                $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $script:OrigIisEnv
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    Context 'configured path points to a missing file' {
        It 'throws a friendly error referencing config.local.toml' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.local.toml') -Content @"
[tools]
iis_express_path = "C:/this/path/does/not/exist/iisexpress.exe"
"@
                { Find-IisExpressPath -RepoRoot $repo } | Should -Throw -ExpectedMessage '*config.local.toml*'
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
                & cmd.exe /c $loadCmd > $null 2>&1
                $loadOk = ($LASTEXITCODE -eq 0)
            }

            if (-not $loadOk) {
                Set-ItResult -Skipped -Because 'svnadmin create/load failed (likely dump LF/CRLF mangle)'
                return
            }

            $repoUri = 'file:///' + ($svnRepo -replace '\\', '/')
            & svn checkout "$repoUri/trunk" $wc > $null 2>&1
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

Describe 'Get-ProjectIdentityHash' {

    BeforeAll {
        $script:GhGitOk = $true
        try { $null = (& git --version 2>$null); $script:GhGitOk = ($LASTEXITCODE -eq 0) } catch { $script:GhGitOk = $false }
    }

    It 'is deterministic and case/slash normalized, isolates across repos, throws off-git' {
        if (-not $script:GhGitOk) {
            Set-ItResult -Skipped -Because 'git not on PATH'
            return
        }
        $repoA = New-GitRepoFixture 'hashA'
        $repoB = New-GitRepoFixture 'hashB'
        try {
            # Determinism: same repo + same csproj relpath -> identical hash.
            $hA1 = Get-ProjectIdentityHash -RepoPath $repoA -CsprojRelPath 'src/App.csproj'
            $hA2 = Get-ProjectIdentityHash -RepoPath $repoA -CsprojRelPath 'src/App.csproj'
            $hA2 | Should -Be $hA1
            $hA1 | Should -Match '^[0-9a-f]{8}$'

            # Case-normalization: csproj relpath case folded -> same hash.
            $hCaseLower = Get-ProjectIdentityHash -RepoPath $repoA -CsprojRelPath 'src/app.csproj'
            $hCaseUpper = Get-ProjectIdentityHash -RepoPath $repoA -CsprojRelPath 'SRC/APP.CSPROJ'
            $hCaseUpper | Should -Be $hCaseLower

            # Backslash vs forward-slash relpath also folds to the same identity.
            $hBackslash = Get-ProjectIdentityHash -RepoPath $repoA -CsprojRelPath 'src\App.csproj'
            $hBackslash | Should -Be $hA1

            # Cross-repo isolation: different repos, identical relpath -> different hash.
            $hB1 = Get-ProjectIdentityHash -RepoPath $repoB -CsprojRelPath 'src/App.csproj'
            $hB1 | Should -Not -Be $hA1

            # Non-git path -> throw.
            $nonGit = New-IsolatedRepoRoot 'hashNonGit'
            try {
                { Get-ProjectIdentityHash -RepoPath $nonGit -CsprojRelPath 'src/App.csproj' } | Should -Throw -ExpectedMessage '*Not a git repository*'
            } finally {
                Remove-IsolatedRepoRoot -Dir $nonGit
            }
        } finally {
            Remove-IsolatedRepoRoot -Dir $repoA
            Remove-IsolatedRepoRoot -Dir $repoB
        }
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

Describe 'Format-IisExpressSiteName' {

    It 'ASCII csproj stem produces HelloApp-deadbeef' {
        Format-IisExpressSiteName -CsprojPath 'C:\proj\src\HelloApp.csproj' -IdentityHash 'deadbeef' | Should -Be 'HelloApp-deadbeef'
    }

    It 'CJK csproj stem is preserved verbatim' {
        $cjkStemName = '報表範本'
        $site = Format-IisExpressSiteName -CsprojPath ("C:\proj\src\$cjkStemName.csproj") -IdentityHash 'cafe1234'
        $site | Should -Be ("$cjkStemName-cafe1234")
    }
}

Describe 'Find-SingleCsproj' {

    It 'returns the single .csproj when exactly one is present' {
        $repo = New-IsolatedRepoRoot 'csproj-single'
        try {
            $onlyCsproj = Join-Path $repo 'OnlyOne.csproj'
            Set-Content -LiteralPath $onlyCsproj -Value '<Project/>' -Encoding ASCII
            $found = Find-SingleCsproj -RepoRoot $repo -CliProjectValue ''
            [System.IO.Path]::GetFullPath($found) | Should -Be ([System.IO.Path]::GetFullPath($onlyCsproj))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'throws when zero .csproj are present' {
        $repo = New-IsolatedRepoRoot 'csproj-zero'
        try {
            { Find-SingleCsproj -RepoRoot $repo -CliProjectValue '' } | Should -Throw -ExpectedMessage '*No .csproj found*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'throws when multiple .csproj are present' {
        $repo = New-IsolatedRepoRoot 'csproj-multi'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'A.csproj') -Value '<Project/>' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $repo 'B.csproj') -Value '<Project/>' -Encoding ASCII
            { Find-SingleCsproj -RepoRoot $repo -CliProjectValue '' } | Should -Throw -ExpectedMessage '*Multiple .csproj*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
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
