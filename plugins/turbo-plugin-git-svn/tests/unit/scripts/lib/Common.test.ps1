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
        # Expand any 8.3 short-name segments in $env:TEMP (e.g. FIRSTL~1) — Remove-Item
        # -LiteralPath on PS 5.1 + a short-named parent dir trips an "object at path does
        # not exist" error.
        # GetTempPath(), not $env:TEMP: TEMP is a Windows-only variable and is unset under pwsh on
        # Linux, so Combine() would receive $null and yield a RELATIVE path -- the sandbox would be
        # created inside the repo. For this suite that is not just untidy: its own "is this folder
        # inside a git repo?" guard then correctly answers yes and skips every case, so the whole
        # file silently self-disabled on the ubuntu runner.
        $tempDir = [System.IO.Path]::GetTempPath()
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
    # It also brings in the COMMON PARAMETERS, and those win over ValueFromRemainingArguments:
    # any short git flag that is an unambiguous prefix of one (-D → -Debug, -v → -Verbose,
    # -p → -PipelineVariable) is bound by PowerShell and never reaches git. It disappears in
    # silence — `branch -q -D x` ran as `branch -q x`, which is a no-op that exits 0, so the
    # fixture built the wrong repo and the test still passed. Pass long options (--delete
    # --force) for anything in that set.
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
        # Spelled the way git itself writes a merge subject -- grouping reads the source branch off
        # this line, so a fixture with an ad-hoc message would not exercise the real path.
        Invoke-GitSilent $dir merge -q --no-ff -m "Merge branch 'side' into main" side
        return $dir
    }

    # Issue #67 fixture. X reached main through the merge of feat/a. feat/b was branched off X,
    # never merged into main, and feat/a was deleted afterwards -- an entirely ordinary sequence.
    # `git name-rev` answers "feat/b" here, and naming it would put a claim in the SVN log --
    # permanently -- that a branch which shipped nothing was the source.
    function New-Issue67Repo {
        param([string]$Tag = 'issue67')
        $dir = New-IsolatedRepoRoot $Tag
        Invoke-GitSilent $dir init -q -b main
        Invoke-GitSilent $dir config user.email 'test@turbo-plugin'
        Invoke-GitSilent $dir config user.name 'turbo-plugin-test'
        Invoke-GitSilent $dir commit -q --allow-empty -m 'base'
        Invoke-GitSilent $dir branch svnbase
        Invoke-GitSilent $dir checkout -q -b 'feat/a'
        Invoke-GitSilent $dir commit -q --allow-empty -m 'fix: the real fix'
        $x = (& git -C $dir rev-parse HEAD 2>$null | Out-String).Trim()
        Invoke-GitSilent $dir commit -q --allow-empty -m 'test: cover the fix'
        Invoke-GitSilent $dir checkout -q main
        Invoke-GitSilent $dir commit -q --allow-empty -m 'chore: main work'
        Invoke-GitSilent $dir merge -q --no-ff -m "Merge branch 'feat/a' into main" 'feat/a'
        Invoke-GitSilent $dir checkout -q -b 'feat/b' $x
        Invoke-GitSilent $dir commit -q --allow-empty -m 'wip: never merged anywhere'
        Invoke-GitSilent $dir checkout -q main
        # Long options: -D would be eaten by the common -Debug parameter (see Invoke-GitSilent).
        Invoke-GitSilent $dir branch --quiet --delete --force 'feat/a'
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

    # Only git-svn's suite carries this case. Core.ps1 is byte-identical across every plugin
    # (enforced by tools/verify-core-identical.sh in CI), so exercising one copy exercises them all
    # -- that invariant is precisely what buys us the right not to quadruplicate the test.
    Context 'issue #53 - config is read as UTF-8, not the system ANSI code page' {
        It 'round-trips a non-ASCII value, and keeps the section header that follows a non-ASCII comment' {
            $repo = New-IsolatedRepoRoot 'utf8cfg'
            try {
                # Built from code points on purpose: this test is about how a file gets DECODED, so
                # it must not itself depend on how its own source file is decoded. U+6E2C U+8A66.
                $cjk = [string]([char]0x6E2C) + [string]([char]0x8A66)

                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
# $cjk
[tools]
msbuild_path = "C:/MSBuild.exe"
note = "$cjk"
"@
                $note    = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'note'         -CliValue $null -Default $null
                $msbuild = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null

                # The two assertions below fail under DIFFERENT code pages, which is why both exist:
                #
                #   * value round-trip: any non-UTF-8 ANSI code page mis-decodes the bytes, so this
                #     one goes red on cp1252 (an English CI runner) as well as on cp950. It is the
                #     portable guard -- without it the whole case would pass on CI whether or not
                #     the fix is present, which is the failure mode this repo keeps getting bitten by.
                #   * section survival: a DOUBLE-byte code page (cp950 on zh-TW Windows) also
                #     swallows line breaks, merging `[tools]` into the comment above it so the whole
                #     section vanishes. That is the reported symptom, and it cannot reproduce on
                #     cp1252 -- on CI this assertion only proves the parse did not regress.
                $note | Should -Be $cjk
                $msbuild | Should -Be 'C:/MSBuild.exe'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    # Same silent-fallback symptom as #53/#60, different cause: both constructs below are legal
    # TOML that the reader dropped without a word. Found while verifying #60 -- the encoding fix
    # cleared the reported case, these two were still live.
    Context 'issue #60 - inline comments must not swallow a section or a value' {
        It 'keeps a section whose header carries a trailing comment' {
            $repo = New-IsolatedRepoRoot 'cfg-sec-comment'
            try {
                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
[tools] # machine-specific tool paths
msbuild_path = "C:/MSBuild.exe"
"@
                # Previously the header had to END at ']', so the line was treated as a plain key
                # line, no section was opened, and EVERY key under it vanished.
                Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                    Should -Be 'C:/MSBuild.exe'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'strips a comment after a quoted value but keeps a # inside the quotes' {
            $repo = New-IsolatedRepoRoot 'cfg-val-comment'
            try {
                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
[tools]
msbuild_path = "C:/MSBuild.exe" # pinned for this machine
note = "sharp # inside"
"@
                # The comment-stripping branch skipped quoted values and the unquoting branch
                # required the line to END at the quote, so the value kept BOTH its quotes and the
                # comment: '"C:/MSBuild.exe" # pinned for this machine'.
                Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                    Should -Be 'C:/MSBuild.exe'
                Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'note' -CliValue $null -Default $null |
                    Should -Be 'sharp # inside'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'preserves a backslash Windows path, with and without a trailing comment' {
            $repo = New-IsolatedRepoRoot 'cfg-backslash'
            try {
                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
[tools]
msbuild_path = "C:\Program Files\MSBuild\MSBuild.exe"
iis_express_path = "C:\Program Files\IIS Express\iisexpress.exe" # 64-bit
"@
                Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                    Should -Be 'C:\Program Files\MSBuild\MSBuild.exe'
                Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'iis_express_path' -CliValue $null -Default $null |
                    Should -Be 'C:\Program Files\IIS Express\iisexpress.exe'
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'still treats a QUOTED true/1 as a string, not a bool/int' {
            $repo = New-IsolatedRepoRoot 'cfg-quoted-scalar'
            try {
                $cfgToml = Join-Path $repo '.turbo-plugin\config.toml'
                Write-Toml -Path $cfgToml -Content @"
[iis]
enabled = true
label = "true"
port = 8080
tag = "1"
"@
                Resolve-ConfigValue -RepoRoot $repo -Section 'iis' -Key 'enabled' -CliValue $null -Default $null |
                    Should -BeOfType [bool]
                Resolve-ConfigValue -RepoRoot $repo -Section 'iis' -Key 'label' -CliValue $null -Default $null |
                    Should -BeOfType [string]
                Resolve-ConfigValue -RepoRoot $repo -Section 'iis' -Key 'port' -CliValue $null -Default $null |
                    Should -BeOfType [int]
                Resolve-ConfigValue -RepoRoot $repo -Section 'iis' -Key 'tag' -CliValue $null -Default $null |
                    Should -BeOfType [string]
            } finally {
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

    # config.local.toml describes THIS MACHINE, so it has no per-worktree meaning -- but being
    # gitignored is exactly what keeps it out of a newly created worktree, so every new worktree
    # started from defaults and the user re-entered settings already given.
    Context 'issue #61 - a linked worktree inherits the main worktree local config' {
        BeforeAll {
            $script:i61Main = New-IsolatedRepoRoot 'wt-inherit'
            Invoke-GitSilent $script:i61Main init -q -b main
            Invoke-GitSilent $script:i61Main config user.email 'test@turbo-plugin'
            Invoke-GitSilent $script:i61Main config user.name 'turbo-plugin-test'
            Write-Toml -Path (Join-Path $script:i61Main '.turbo-plugin\config.toml') -Content @"
[tools]
msbuild_path = "FROM-CONFIG-TOML"
"@
            Invoke-GitSilent $script:i61Main add -A
            Invoke-GitSilent $script:i61Main -c commit.gpgsign=false commit -q -m init
            Write-Toml -Path (Join-Path $script:i61Main '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "FROM-MAIN-LOCAL"
iis_express_path = "MAIN-IIS"
"@
            $script:i61Wt = Join-Path ([System.IO.Path]::GetDirectoryName($script:i61Main)) (
                [System.IO.Path]::GetFileName($script:i61Main) + '-linked')
            Invoke-GitSilent $script:i61Main worktree add -q -b feat $script:i61Wt
        }
        AfterAll {
            Invoke-GitSilent $script:i61Main worktree remove --force $script:i61Wt
            Remove-IsolatedRepoRoot -Dir $script:i61Main
            Remove-IsolatedRepoRoot -Dir $script:i61Wt
        }

        It 'reads the main worktree local value from a linked worktree that has no local file' {
            Resolve-ConfigValue -RepoRoot $script:i61Wt -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                Should -Be 'FROM-MAIN-LOCAL'
            Resolve-ConfigValue -RepoRoot $script:i61Wt -Section 'tools' -Key 'iis_express_path' -CliValue $null -Default $null |
                Should -Be 'MAIN-IIS'
        }

        It 'still lets the linked worktree own local file win, key by key' {
            Write-Toml -Path (Join-Path $script:i61Wt '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "FROM-WORKTREE-LOCAL"
"@
            # Deliberate per-worktree overrides keep working -- the inherited layer sits BELOW.
            Resolve-ConfigValue -RepoRoot $script:i61Wt -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                Should -Be 'FROM-WORKTREE-LOCAL'
            # ...and a key it does NOT set is still inherited rather than lost.
            Resolve-ConfigValue -RepoRoot $script:i61Wt -Section 'tools' -Key 'iis_express_path' -CliValue $null -Default $null |
                Should -Be 'MAIN-IIS'
        }

        It 'leaves the main worktree itself unchanged' {
            Resolve-ConfigValue -RepoRoot $script:i61Main -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                Should -Be 'FROM-MAIN-LOCAL'
        }

        # A plain directory is a legitimate caller (tests, a project not under git yet). Looking up
        # the main worktree must not turn that into a failure.
        It 'does not fail on a directory that is not a git repository' {
            $plain = New-IsolatedRepoRoot 'wt-plain'
            try {
                Write-Toml -Path (Join-Path $plain '.turbo-plugin\config.toml') -Content @"
[tools]
msbuild_path = "PLAIN"
"@
                Resolve-ConfigValue -RepoRoot $plain -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null |
                    Should -Be 'PLAIN'
            } finally {
                Remove-IsolatedRepoRoot -Dir $plain
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

# Guards an IRREVERSIBLE operation: Remove-SvnFile feeds the result to `svn delete` + `svn commit`
# against the shared repository. A path that escapes the bridge worktree has to stop before that,
# not be discovered in the history afterwards.
Describe 'Resolve-PathWithinWorktree' {
    BeforeAll {
        $script:PwRoot = [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(), "tp-pwr-$([Guid]::NewGuid().ToString('N').Substring(0, 8))")
        $null = New-Item -ItemType Directory -Path $script:PwRoot -Force
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:PwRoot) {
            Remove-Item -LiteralPath $script:PwRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'resolves an ordinary relative path under the root' {
        $r = Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath 'docs/a.txt'
        $r.StartsWith($script:PwRoot) | Should -BeTrue
        $r | Should -Match 'a\.txt$'
    }

    It 'refuses a leading .. segment' {
        { Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath '../outside.txt' } |
            Should -Throw -ExpectedMessage "*'..'*"
    }
    It 'refuses a .. buried deeper in the path' {
        { Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath 'docs/../../outside.txt' } |
            Should -Throw
    }
    It 'refuses a backslash-separated .. too (Windows callers write it that way)' {
        { Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath '..\outside.txt' } |
            Should -Throw
    }
    It 'refuses an absolute path' {
        { Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath 'C:\Windows\notepad.exe' } |
            Should -Throw -ExpectedMessage '*absolute*'
    }
    It 'refuses an empty path' {
        { Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath '  ' } | Should -Throw
    }

    # '..' inside a FILENAME is legal. Checking for the substring instead of the path segments would
    # reject real files like "notes..bak" -- a guard that breaks valid input is its own bug.
    It 'allows a filename that merely contains ..' {
        $r = Resolve-PathWithinWorktree -Root $script:PwRoot -RelativePath 'notes..bak'
        $r | Should -Match 'notes\.\.bak$'
    }
}

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

Describe 'Resolve-GitRoot' {

    It 'omitted repo root resolves to "." so git -C . stays a no-op' {
        Resolve-GitRoot -RepoRoot '' | Should -Be '.'
    }

    It 'whitespace-only repo root also resolves to "."' {
        Resolve-GitRoot -RepoRoot '   ' | Should -Be '.'
    }

    It 'a path that does not exist throws instead of reaching git' {
        $missing = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('tp-absent-' + [Guid]::NewGuid().ToString('N')))
        { Resolve-GitRoot -RepoRoot $missing } | Should -Throw -ExpectedMessage '*Repo root not found*'
    }

    It 'a file rather than a directory is rejected' {
        $repo = New-IsolatedRepoRoot 'gitrootfile'
        try {
            $file = Join-Path $repo 'not-a-dir.txt'
            [System.IO.File]::WriteAllText($file, 'x')
            { Resolve-GitRoot -RepoRoot $file } | Should -Throw -ExpectedMessage '*Repo root not found*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}

Describe 'Get-MainWorktree / Test-IsMainWorktree with an explicit -RepoRoot' {

    BeforeAll {
        # Declared in BeforeAll, not at Describe scope: a function defined directly under a
        # Describe/Context body is gone by the time Pester 5 runs the It blocks.
        function Invoke-GitQuiet {
            param([string]$Cwd, [string[]]$GitArgs)
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            try {
                & git -C $Cwd @GitArgs 2>$null | Out-Null
            } finally {
                $ErrorActionPreference = $prev
            }
        }

        function New-BareGitRepo {
            param([string]$Path)
            $null = New-Item -ItemType Directory -Path $Path -Force
            Invoke-GitQuiet -Cwd $Path -GitArgs @('init', '-b', 'main')
            Invoke-GitQuiet -Cwd $Path -GitArgs @('config', 'user.email', 'test@turbo-plugin')
            Invoke-GitQuiet -Cwd $Path -GitArgs @('config', 'user.name', 'turbo-plugin-test')
            Invoke-GitQuiet -Cwd $Path -GitArgs @('commit', '--allow-empty', '-m', 'init')
        }
    }

    It 'resolves the NAMED repo, not the one the process happens to be standing in' {
        $sandbox = New-IsolatedRepoRoot 'reporoot'
        $origin = (Get-Location).Path
        try {
            $alpha = Join-Path $sandbox 'alpha'
            $beta = Join-Path $sandbox 'beta'
            New-BareGitRepo -Path $alpha
            New-BareGitRepo -Path $beta

            Set-Location -LiteralPath $alpha
            $ambient = Get-MainWorktree
            $named = Get-MainWorktree -RepoRoot $beta

            $ambient | Should -Match 'alpha$'
            $named | Should -Match 'beta$'
            $named | Should -Not -Be $ambient
        } finally {
            Set-Location -LiteralPath $origin
            Remove-IsolatedRepoRoot -Dir $sandbox
        }
    }

    It 'Test-IsMainWorktree judges the named path, not the cwd' {
        # Guard 1 of the bridge bootstrap rides on this: standing in the main worktree while
        # naming a linked one must still report "linked".
        $sandbox = New-IsolatedRepoRoot 'reporootlw'
        $origin = (Get-Location).Path
        try {
            $main = Join-Path $sandbox 'main'
            $linked = Join-Path $sandbox 'linked'
            New-BareGitRepo -Path $main
            Invoke-GitQuiet -Cwd $main -GitArgs @('worktree', 'add', '-b', 'feat/lw', $linked)

            Set-Location -LiteralPath $main
            (Test-IsMainWorktree -RepoRoot $main) | Should -BeTrue
            (Test-IsMainWorktree -RepoRoot $linked) | Should -BeFalse
            # ...and the main worktree is what both resolve to.
            (Get-MainWorktree -RepoRoot $linked) | Should -Be (Get-MainWorktree -RepoRoot $main)
        } finally {
            Set-Location -LiteralPath $origin
            Remove-IsolatedRepoRoot -Dir $sandbox
        }
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

    It 'groups every non-merge subject by source branch and excludes the merge commit' {
        # Fixture = main's own feat/fix + a merged-in `side` branch -> two source branches, so the
        # body groups under 【main】 / 【side】 headers (current branch first). #4 review change.
        $repo = New-PushBodyRepo 'pb-nomerge'
        try {
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            # Measure-Object — .Count on a raw collection is unreliable under Set-StrictMode Latest.
            $allLines = @($body -split "`n")
            ($allLines | Measure-Object).Count | Should -Be 5   # 2 group headers + 3 bullets
            $bullets = @($allLines | Where-Object { $_ -match '^- ' })
            ($bullets | Measure-Object).Count | Should -Be 3
            $body | Should -Match '(?m)^【main】$'
            $body | Should -Match '(?m)^【side】$'
            $body | Should -Match '(?m)^- feat: add A$'
            $body | Should -Match '(?m)^- fix: fix B$'
            $body | Should -Match '(?m)^- refactor: tidy C$'
            $body | Should -Not -Match 'Merge branch'
            # current branch (main) group precedes the merged-in (side) group.
            ($body.IndexOf('【main】')) | Should -BeLessThan ($body.IndexOf('【side】'))
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

    It 'groups a feature push that merged main: own commits under 【feat/x】 before merged-in 【main】 (#4)' {
        $repo = New-IsolatedRepoRoot 'pb-group-merged'
        try {
            Invoke-GitSilent $repo init -q -b main
            Invoke-GitSilent $repo config user.email 'test@turbo-plugin'
            Invoke-GitSilent $repo config user.name 'turbo-plugin-test'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'base'
            Invoke-GitSilent $repo branch svnbase                       # bridge tip = feature start
            Invoke-GitSilent $repo checkout -q -b 'feat/x'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: feature one'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: feature two'
            Invoke-GitSilent $repo checkout -q main
            Invoke-GitSilent $repo commit -q --allow-empty -m 'chore: main one'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'chore: main two'
            Invoke-GitSilent $repo checkout -q 'feat/x'
            Invoke-GitSilent $repo merge -q --no-ff -m "Merge branch 'main' into feat/x" main
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..feat/x'
            $body | Should -Match '(?m)^【feat/x】$'
            $body | Should -Match '(?m)^【main】$'
            # current branch group precedes the merged-in main group
            ($body.IndexOf('【feat/x】')) | Should -BeLessThan ($body.IndexOf('【main】'))
            $body | Should -Match '(?m)^- feat: feature one$'
            $body | Should -Match '(?m)^- chore: main two$'
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

    # The fixture only proves anything while it still reproduces the misattribution. If a future
    # git changes name-rev's tie-breaking, this fails loudly rather than passing for the wrong
    # reason.
    It 'still reproduces the name-rev misattribution the fix is about (#67 fixture guard)' {
        $repo = New-Issue67Repo 'pb-i67-guard'
        try {
            $x = (& git -C $repo rev-list --no-merges --grep='fix: the real fix' 'svnbase..main' 2>$null | Out-String).Trim()
            $named = (& git -C $repo name-rev --name-only --refs='refs/heads/*' $x 2>$null | Out-String).Trim()
            $named | Should -Be 'feat/b~1'
            & git -C $repo merge-base --is-ancestor 'feat/b' main 2>$null | Out-Null
            $LASTEXITCODE | Should -Not -Be 0   # feat/b is genuinely not in main
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'attributes a merged-in commit via the merge that introduced it, not via name-rev (#67)' {
        $repo = New-Issue67Repo 'pb-i67'
        try {
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            # The never-merged branch must not appear at all -- not as a header, not anywhere.
            $body | Should -Not -Match 'feat/b'
            # The branch that WAS merged is named, even though it has since been deleted: the name
            # comes from the merge commit, which still records it.
            $body | Should -Match '(?m)^【feat/a】$'
            # Both of feat/a's commits belong to the same group; name-rev used to split them.
            $body | Should -Match "(?m)^【feat/a】`n- fix: the real fix`n- test: cover the fix$"
            $body | Should -Match "(?m)^【main】`n- chore: main work$"
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    # A merge subject that records no source branch -> no grouping at all. A wrong group is worse
    # than no group: the body is locked, so the agent cannot correct it in the SVN log afterwards.
    It 'falls back to a flat list when a merge subject records no source branch (#67)' {
        $repo = New-IsolatedRepoRoot 'pb-nosrc'
        try {
            Invoke-GitSilent $repo init -q -b main
            Invoke-GitSilent $repo config user.email 'test@turbo-plugin'
            Invoke-GitSilent $repo config user.name 'turbo-plugin-test'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'base'
            Invoke-GitSilent $repo branch svnbase
            Invoke-GitSilent $repo checkout -q -b side
            Invoke-GitSilent $repo commit -q --allow-empty -m 'refactor: tidy C'
            Invoke-GitSilent $repo checkout -q main
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: add A'
            Invoke-GitSilent $repo merge -q --no-ff -m 'hand-written message with no branch name' side
            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            $body | Should -Not -Match '【'
            $body | Should -Match '(?m)^- feat: add A$'
            $body | Should -Match '(?m)^- refactor: tidy C$'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
    # An octopus merge has more than one "other side", so no single source branch can be named for
    # the commits it brought in. Same rule as an unreadable subject: flatten rather than pick one.
    #
    # The subject here deliberately DOES parse (`Merge branch 'sideA' into main`). git's own
    # octopus subject is "Merge branches 'a' and 'b'", which Get-MergeSourceBranch already rejects
    # on wording alone -- using it would leave the parent-count guard untested while the case still
    # went green.
    It 'falls back to a flat list on an octopus merge (#67)' {
        $repo = New-IsolatedRepoRoot 'pb-octopus'
        try {
            Invoke-GitSilent $repo init -q -b main
            Invoke-GitSilent $repo config user.email 'test@turbo-plugin'
            Invoke-GitSilent $repo config user.name 'turbo-plugin-test'
            Invoke-GitSilent $repo commit -q --allow-empty -m 'base'
            Invoke-GitSilent $repo branch svnbase
            Invoke-GitSilent $repo checkout -q -b sideA
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: from A'
            Invoke-GitSilent $repo checkout -q main
            Invoke-GitSilent $repo checkout -q -b sideB
            Invoke-GitSilent $repo commit -q --allow-empty -m 'feat: from B'
            Invoke-GitSilent $repo checkout -q main
            Invoke-GitSilent $repo commit -q --allow-empty -m 'chore: on main'
            Invoke-GitSilent $repo merge -q --no-ff -m "Merge branch 'sideA' into main" sideA sideB
            # Guard the fixture: without three parents this would be testing an ordinary merge.
            $parents = @((& git -C $repo rev-list --parents -n 1 main 2>$null | Out-String).Trim() -split '\s+' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            ($parents | Measure-Object).Count | Should -Be 4

            $body = Get-SvnPushBody -RepoDir $repo -Range 'svnbase..main'
            $body | Should -Not -Match '【'
            # Nothing may be dropped on the way to the fallback.
            $body | Should -Match '(?m)^- feat: from A$'
            $body | Should -Match '(?m)^- feat: from B$'
            $body | Should -Match '(?m)^- chore: on main$'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}

Describe 'Get-MergeSourceBranch' {

    It 'reads the source branch off git''s own merge subjects' {
        Get-MergeSourceBranch -Subject "Merge branch 'feat/a' into main" | Should -Be 'feat/a'
        Get-MergeSourceBranch -Subject "Merge branch 'feat/a'" | Should -Be 'feat/a'
        Get-MergeSourceBranch -Subject "Merge remote-tracking branch 'origin/feat/a'" | Should -Be 'origin/feat/a'
        Get-MergeSourceBranch -Subject 'Merge pull request #12 from someone/feat/a' | Should -Be 'feat/a'
    }

    # The bridge ref is an implementation detail; a trunk replay must read as `main` to the user.
    It 'strips the bridge-ref prefix so a trunk replay reads as main' {
        Get-MergeSourceBranch -Subject "Merge branch 'remote-svn/main' into feat/x" | Should -Be 'main'
    }

    It 'returns nothing rather than guessing when the subject records no branch' {
        Get-MergeSourceBranch -Subject 'Merge two things together' | Should -Be ''
        Get-MergeSourceBranch -Subject 'feat: not a merge at all' | Should -Be ''
        Get-MergeSourceBranch -Subject "Merge branch 'has a space' into main" | Should -Be ''
        Get-MergeSourceBranch -Subject "Merge branch '' into main" | Should -Be ''
        # A crafted name must not be able to forge a group header inside the locked body.
        $forged = "Merge branch 'x" + [char]0x3011 + 'fake' + [char]0x3010 + "y' into main"
        Get-MergeSourceBranch -Subject $forged | Should -Be ''
    }
}

Describe 'Assert-SvnVersion (issue #26)' {

    BeforeAll {
        # NOT $IsWindows: that automatic variable is read-only under pwsh and undefined under
        # Windows PowerShell 5.1. Same expression the test orchestrator uses.
        $script:SvOnWindows = ($env:OS -eq 'Windows_NT') -or ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
    }

    It 'rejects a pre-1.9 client, naming --show-item and the upgrade path' {
        # Set-ItResult inside the It, never -Skip:, because -Skip: is evaluated during Pester's
        # DISCOVERY phase where a flag set in BeforeAll is still $null -- the file would then skip
        # silently while reporting green.
        if (-not $script:SvOnWindows) {
            Set-ItResult -Skipped -Because 'the fake svn stub is a .cmd (Windows only); the .sh suite covers bash'
            return
        }
        $root = New-IsolatedRepoRoot 'svnver18'
        try {
            $stub = Join-Path $root 'fakesvn.cmd'
            # 1.8.15 is not an arbitrary number: it is exactly what chocolatey's win32svn pins to,
            # which is how this reaches real users.
            Set-Content -LiteralPath $stub -Value '@echo 1.8.15' -Encoding ASCII
            { Assert-SvnVersion -SvnExe $stub } | Should -Throw -ExpectedMessage '*--show-item*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'accepts a 1.9+ client' {
        if (-not $script:SvOnWindows) {
            Set-ItResult -Skipped -Because 'the fake svn stub is a .cmd (Windows only); the .sh suite covers bash'
            return
        }
        $root = New-IsolatedRepoRoot 'svnver114'
        try {
            $stub = Join-Path $root 'fakesvn.cmd'
            Set-Content -LiteralPath $stub -Value '@echo 1.14.2' -Encoding ASCII
            { Assert-SvnVersion -SvnExe $stub } | Should -Not -Throw
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'accepts exactly 1.9 (boundary)' {
        if (-not $script:SvOnWindows) {
            Set-ItResult -Skipped -Because 'the fake svn stub is a .cmd (Windows only); the .sh suite covers bash'
            return
        }
        $root = New-IsolatedRepoRoot 'svnver19'
        try {
            $stub = Join-Path $root 'fakesvn.cmd'
            Set-Content -LiteralPath $stub -Value '@echo 1.9.0' -Encoding ASCII
            { Assert-SvnVersion -SvnExe $stub } | Should -Not -Throw
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'fails loudly when the version cannot be determined' {
        if (-not $script:SvOnWindows) {
            Set-ItResult -Skipped -Because 'the fake svn stub is a .cmd (Windows only); the .sh suite covers bash'
            return
        }
        $root = New-IsolatedRepoRoot 'svnverJunk'
        try {
            $stub = Join-Path $root 'fakesvn.cmd'
            Set-Content -LiteralPath $stub -Value '@echo not-a-version' -Encoding ASCII
            { Assert-SvnVersion -SvnExe $stub } | Should -Throw
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }
}

Describe 'ConvertTo-SvnTarget (issue #34)' {

    It 'escapes a filename containing @ so svn stops reading it as a peg revision' {
        # `banner@2x.jpg` is a legal SVN filename (retina naming), but as a TARGET argument svn
        # parsed "2x.jpg" as a revision and failed the whole commit with E200009.
        ConvertTo-SvnTarget -Path 'Content/img/banner@2x.jpg' | Should -Be 'Content/img/banner@2x.jpg@'
    }

    It 'appends the escape unconditionally (harmless on paths without @)' {
        # Applied to every path rather than only the ones containing '@': a detect-then-escape
        # branch is one more place for our parsing to disagree with svn's, and `foo.txt@` resolves
        # to `foo.txt` anyway.
        ConvertTo-SvnTarget -Path 'src/app.txt' | Should -Be 'src/app.txt@'
    }

    It 'leaves a path that already ends in @ resolvable (trailing escape still applies)' {
        ConvertTo-SvnTarget -Path 'weird@' | Should -Be 'weird@@'
    }
}

Describe 'Write-SvnTargetsFile (issue #35)' {

    It 'writes one path per line' {
        $f = [System.IO.Path]::GetTempFileName()
        try {
            Write-SvnTargetsFile -Path $f -Targets @('Content/one.txt@', 'Content/two.txt@')
            $lines = @([System.IO.File]::ReadAllLines($f) | Where-Object { $_ -match '\S' })
            $lines.Count | Should -Be 2
            $lines[0] | Should -Be 'Content/one.txt@'
            $lines[1] | Should -Be 'Content/two.txt@'
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    It 'handles a target list far beyond the command-line limit' {
        # The whole point of the targets file: 3000 paths as argv is what blew up.
        $f = [System.IO.Path]::GetTempFileName()
        try {
            $many = 1..3000 | ForEach-Object { "bulk/file$_.txt@" }
            Write-SvnTargetsFile -Path $f -Targets $many
            @([System.IO.File]::ReadAllLines($f) | Where-Object { $_ -match '\S' }).Count | Should -Be 3000
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    It 'never writes a BOM, whatever the host codepage is' {
        # Runs unconditionally, and that is the point: the ANSI test below has to skip when the
        # host's codepage is already 65001, which left the UTF-8-system-locale branch untested.
        # On such a host GetEncoding(65001) returns Encoding.UTF8, whose preamble IS a BOM, and
        # File.WriteAllText emits it -- svn would then read three stray bytes as part of the first
        # path. That configuration is not exotic: /tp-setup actively recommends it to users who
        # need filenames beyond their codepage.
        $f = [System.IO.Path]::GetTempFileName()
        try {
            Write-SvnTargetsFile -Path $f -Targets @('Content/one.txt@')
            $bytes = [System.IO.File]::ReadAllBytes($f)
            @($bytes).Count | Should -BeGreaterThan 3
            $startsWithBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $startsWithBom | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes in the ANSI codepage, not UTF-8, so svn reads the paths back correctly' {
        # svn reads a --targets file through CP_ACP on Windows. A UTF-8 file makes it look for a
        # mojibake path and fail "is not under version control" -- verified against a local repo.
        $onWindows = ($env:OS -eq 'Windows_NT') -or ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
        if (-not $onWindows) {
            Set-ItResult -Skipped -Because 'no CP_ACP off Windows; svn reads the locale encoding there'
            return
        }
        $acp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        if ($acp -le 0 -or $acp -eq 65001) {
            Set-ItResult -Skipped -Because "ANSI codepage is $acp (UTF-8 host); nothing to distinguish"
            return
        }
        # A CJK path is the case that actually differs between the two encodings.
        # Built from code points (U+4E2D U+6587) rather than literal characters so this
        # assertion does not itself depend on how the test file is encoded.
        $cjk = "Content/$([char]0x4E2D)$([char]0x6587).txt@"
        $ansiProbe = [System.Text.Encoding]::GetEncoding($acp)
        if ($ansiProbe.GetString($ansiProbe.GetBytes($cjk)) -ne $cjk) {
            # CP1252 and friends cannot represent CJK at all, so there is no "correct bytes" to
            # compare against -- the function refuses instead, which is its own case below.
            Set-ItResult -Skipped -Because "CP$acp cannot represent a CJK path; refusal is covered separately"
            return
        }
        $f = [System.IO.Path]::GetTempFileName()
        try {
            Write-SvnTargetsFile -Path $f -Targets @($cjk)

            $ansi = [System.Text.Encoding]::GetEncoding($acp)
            $expected = $ansi.GetBytes("$cjk`n")
            $actual = [System.IO.File]::ReadAllBytes($f)
            # Byte-for-byte: reading it back as UTF-8 would silently "work" and prove nothing.
            [System.Convert]::ToBase64String($actual) | Should -Be ([System.Convert]::ToBase64String($expected))
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a path its codepage cannot represent instead of writing question marks' {
        # GetEncoding's DEFAULT encoder fallback substitutes '?' for every unmappable character, so
        # a CJK filename on a CP1252 host was written as "??????.txt" and svn then reported
        # "E200009: Could not add all targets ... don't exist" -- naming neither the file nor the
        # cause, and pointing the reader at the push logic instead of at the codepage. The bash twin
        # has always failed loudly here (iconv returns non-zero); this is the same behaviour.
        # Observed on the CI Windows runner, whose ACP is 1252.
        $onWindows = ($env:OS -eq 'Windows_NT') -or ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
        if (-not $onWindows) {
            Set-ItResult -Skipped -Because 'no CP_ACP off Windows; svn reads the locale encoding there'
            return
        }
        $acp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        if ($acp -le 0 -or $acp -eq 65001) {
            Set-ItResult -Skipped -Because "ANSI codepage is $acp (UTF-8 host); every path is representable"
            return
        }
        # An emoji (U+1F600, as its surrogate pair), not a CJK name: CP950 CARRIES CJK, so a CJK
        # name would make this case skip on the very machines most likely to run it by hand and
        # only ever execute on the CI runner. No legacy ANSI codepage can represent an astral
        # character, so this exercises the refusal on every non-UTF-8 host.
        # Built from code points, like the case above it: an assertion about encoding must not
        # itself depend on how this test file happens to be encoded.
        $unrep = "Content/$([char]0xD83D)$([char]0xDE00).txt"
        $f = [System.IO.Path]::GetTempFileName()
        try {
            { Write-SvnTargetsFile -Path $f -Targets @($unrep) } |
                Should -Throw -ExpectedMessage '*cannot represent*'
            # ...and it must not have left a half-written file of question marks behind either.
            $bytes = [System.IO.File]::ReadAllBytes($f)
            $bytes.Length | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-UnversionedDirectoryFiles (issue #24)' {

    It 'lists every file under a new folder, recursively' {
        $repo = New-IsolatedRepoRoot 'unvExpand'
        try {
            Invoke-GitSilent $repo init -q -b main
            $newDir = Join-Path $repo 'NewFolder'
            $subDir = Join-Path $newDir 'sub'
            $null = New-Item -ItemType Directory -Path $subDir -Force
            Set-Content -LiteralPath (Join-Path $newDir 'a.txt') -Value 'a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $subDir 'b.txt') -Value 'b' -Encoding ASCII

            $lines = @(Get-UnversionedDirectoryFiles -RemotePath $repo -RelativeDir 'NewFolder')

            # svn status alone would have reported only the folder -- these two files are exactly
            # what used to be missing from the confirmation list while still being committed.
            $lines.Count | Should -Be 2
            ($lines -join "`n") | Should -Match 'A\|tracked\|NewFolder.a\.txt'
            ($lines -join "`n") | Should -Match 'A\|tracked\|NewFolder.sub.b\.txt'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'marks git-ignored children as ignored rather than dropping or mislabelling them' {
        $repo = New-IsolatedRepoRoot 'unvIgnored'
        try {
            Invoke-GitSilent $repo init -q -b main
            Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'NewFolder/skip/' -Encoding ASCII
            $newDir = Join-Path $repo 'NewFolder'
            $skipDir = Join-Path $newDir 'skip'
            $null = New-Item -ItemType Directory -Path $skipDir -Force
            Set-Content -LiteralPath (Join-Path $newDir 'keep.txt') -Value 'k' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $skipDir 'junk.txt') -Value 'j' -Encoding ASCII

            $joined = (@(Get-UnversionedDirectoryFiles -RemotePath $repo -RelativeDir 'NewFolder') -join "`n")

            $joined | Should -Match 'A\|tracked\|NewFolder.keep\.txt'
            $joined | Should -Match 'A\|ignored\|NewFolder.skip.junk\.txt'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'skips .git and .svn metadata' {
        $repo = New-IsolatedRepoRoot 'unvMeta'
        try {
            Invoke-GitSilent $repo init -q -b main
            $newDir = Join-Path $repo 'NewFolder'
            $svnMeta = Join-Path $newDir '.svn'
            $null = New-Item -ItemType Directory -Path $svnMeta -Force
            Set-Content -LiteralPath (Join-Path $newDir 'real.txt') -Value 'r' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $svnMeta 'entries') -Value 'x' -Encoding ASCII

            $lines = @(Get-UnversionedDirectoryFiles -RemotePath $repo -RelativeDir 'NewFolder')

            $lines.Count | Should -Be 1
            ($lines -join "`n") | Should -Match 'real\.txt'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'returns nothing for a path that is not a directory' {
        $repo = New-IsolatedRepoRoot 'unvNotDir'
        try {
            Invoke-GitSilent $repo init -q -b main
            Set-Content -LiteralPath (Join-Path $repo 'plain.txt') -Value 'p' -Encoding ASCII

            @(Get-UnversionedDirectoryFiles -RemotePath $repo -RelativeDir 'plain.txt').Count | Should -Be 0
            @(Get-UnversionedDirectoryFiles -RemotePath $repo -RelativeDir 'DoesNotExist').Count | Should -Be 0
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}
