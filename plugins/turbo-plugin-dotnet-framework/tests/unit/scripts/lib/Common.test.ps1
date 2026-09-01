# Common.test.ps1 (Pester 5)
#
# Unit tests for plugins/turbo-plugin-dotnet-framework/scripts/lib/Common.ps1 (+ IisHelpers.ps1 helpers
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
        It 'either throws pointing at config.local.toml or auto-probes an existing file' {
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
                    $errMsg | Should -Match 'MSBuild'
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

    # "Build Tools for Visual Studio" is a standalone installer with no IDE -- what a CI agent or a
    # trimmed developer machine actually has. Leaving it out of the probe list is what made this
    # plugin quietly require a full Visual Studio install despite being built to avoid one.
    #
    # The probe reads $env:ProgramFiles / ${env:ProgramFiles(x86)} at call time, so both are pointed
    # at a sandbox: that exercises the real lookup instead of asserting on source text, and it also
    # hides whatever Visual Studio the machine running the tests happens to have. Both variables are
    # process-local and restored in finally -- nothing outside this process is touched.
    Context 'probes a Build Tools install (no Visual Studio IDE present)' {
        BeforeAll {
            $script:origPF = $env:ProgramFiles
            $script:origPF86 = ${env:ProgramFiles(x86)}

            # Defined in BeforeAll, not at Context scope: Pester 5 evaluates Context bodies during
            # discovery, so a function declared there is gone by the time the tests actually run.
            function New-FakeMsbuild {
                param([string]$Root, [string]$Year, [string]$Edition, [string]$ToolsVersion)
                $dir = [System.IO.Path]::Combine($Root, 'Microsoft Visual Studio', $Year, $Edition, 'MSBuild', $ToolsVersion, 'Bin')
                $null = New-Item -ItemType Directory -Path $dir -Force
                $exe = [System.IO.Path]::Combine($dir, 'MSBuild.exe')
                [System.IO.File]::WriteAllText($exe, '')
                return $exe
            }
        }
        AfterAll {
            $env:ProgramFiles = $script:origPF
            ${env:ProgramFiles(x86)} = $script:origPF86
        }

        It 'finds MSBuild under 2022 BuildTools in Program Files (x86)' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $pf = Join-Path $repo 'PF'; $pf86 = Join-Path $repo 'PF86'
                $null = New-Item -ItemType Directory -Path $pf -Force
                $null = New-Item -ItemType Directory -Path $pf86 -Force
                $expected = New-FakeMsbuild -Root $pf86 -Year '2022' -Edition 'BuildTools' -ToolsVersion 'Current'
                $env:ProgramFiles = $pf
                ${env:ProgramFiles(x86)} = $pf86
                Find-MSBuild -RepoRoot $repo | Should -Be $expected
            } finally {
                $env:ProgramFiles = $script:origPF
                ${env:ProgramFiles(x86)} = $script:origPF86
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'finds MSBuild under 2019 / 2017 BuildTools too' {
            foreach ($case in @(
                @{ Year = '2019'; Tools = 'Current' },
                @{ Year = '2017'; Tools = '15.0' }
            )) {
                $repo = New-IsolatedRepoRoot 'tools'
                try {
                    $pf = Join-Path $repo 'PF'; $pf86 = Join-Path $repo 'PF86'
                    $null = New-Item -ItemType Directory -Path $pf -Force
                    $null = New-Item -ItemType Directory -Path $pf86 -Force
                    $expected = New-FakeMsbuild -Root $pf86 -Year $case.Year -Edition 'BuildTools' -ToolsVersion $case.Tools
                    $env:ProgramFiles = $pf
                    ${env:ProgramFiles(x86)} = $pf86
                    Find-MSBuild -RepoRoot $repo | Should -Be $expected -Because "BuildTools $($case.Year) 應該要被探測到"
                } finally {
                    $env:ProgramFiles = $script:origPF
                    ${env:ProgramFiles(x86)} = $script:origPF86
                    Remove-IsolatedRepoRoot -Dir $repo
                }
            }
        }

        It 'prefers a real IDE edition over BuildTools of the same year' {
            # BuildTools is the most limited edition; when a machine has both, the IDE install wins.
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $pf = Join-Path $repo 'PF'; $pf86 = Join-Path $repo 'PF86'
                $null = New-Item -ItemType Directory -Path $pf -Force
                $null = New-Item -ItemType Directory -Path $pf86 -Force
                $community = New-FakeMsbuild -Root $pf -Year '2022' -Edition 'Community' -ToolsVersion 'Current'
                $null = New-FakeMsbuild -Root $pf -Year '2022' -Edition 'BuildTools' -ToolsVersion 'Current'
                $env:ProgramFiles = $pf
                ${env:ProgramFiles(x86)} = $pf86
                Find-MSBuild -RepoRoot $repo | Should -Be $community
            } finally {
                $env:ProgramFiles = $script:origPF
                ${env:ProgramFiles(x86)} = $script:origPF86
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'with nothing installed, the error names Build Tools as the fix' {
            $repo = New-IsolatedRepoRoot 'tools'
            try {
                $pf = Join-Path $repo 'PF'; $pf86 = Join-Path $repo 'PF86'
                $null = New-Item -ItemType Directory -Path $pf -Force
                $null = New-Item -ItemType Directory -Path $pf86 -Force
                $env:ProgramFiles = $pf
                ${env:ProgramFiles(x86)} = $pf86
                $errMsg = ''
                try { $null = Find-MSBuild -RepoRoot $repo } catch { $errMsg = $_.Exception.Message }
                $errMsg | Should -Match 'Build Tools'
                $errMsg | Should -Match 'config\.local\.toml'
            } finally {
                $env:ProgramFiles = $script:origPF
                ${env:ProgramFiles(x86)} = $script:origPF86
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
                    $errMsg | Should -Match 'config\.local\.toml'
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

    # issue #50. Both Program Files roots are pointed at a sandbox holding a fake iisexpress.exe in
    # each, so the ORDER is asserted against a known install layout rather than against whatever the
    # test machine happens to have. Both variables are process-local and restored in finally.
    # NOTE: no angle brackets in Describe/Context/It NAMES anywhere in this block. Pester 5 treats
    # `<word>` in a test name as a -ForEach template placeholder and tries to expand $word, which
    # under StrictMode throws "variable cannot be retrieved" and fails the whole Context in
    # BeforeAll -- with an empty ErrorRecord, so the individual Its report no reason at all.
    Context 'issue #50 - probe order follows the csproj Use64BitIISExpress property' {
        BeforeAll {
            $script:origPF64 = $env:ProgramFiles
            $script:origPF86x = ${env:ProgramFiles(x86)}

            # Declared in BeforeAll, not at Context scope: Pester 5 evaluates Context bodies during
            # discovery, so a function declared there is gone by the time the tests run.
            function New-FakeIisTree {
                param([string]$Repo, [switch]$Only86)
                $pf   = Join-Path $Repo 'PF'
                $pf86 = Join-Path $Repo 'PF86'
                foreach ($root in @($pf, $pf86)) {
                    $null = New-Item -ItemType Directory -Path (Join-Path $root 'IIS Express') -Force
                }
                $exe86 = [System.IO.Path]::Combine($pf86, 'IIS Express', 'iisexpress.exe')
                $exe64 = [System.IO.Path]::Combine($pf,   'IIS Express', 'iisexpress.exe')
                [System.IO.File]::WriteAllText($exe86, '')
                if (-not $Only86) { [System.IO.File]::WriteAllText($exe64, '') }
                $env:ProgramFiles = $pf
                ${env:ProgramFiles(x86)} = $pf86
                return [pscustomobject]@{ Exe64 = $exe64; Exe86 = $exe86 }
            }

            function New-CsprojWith {
                param([string]$Repo, [string]$Inner)
                $p = Join-Path $Repo 'App.csproj'
                [System.IO.File]::WriteAllText($p,
                    "<Project><PropertyGroup>$Inner</PropertyGroup></Project>",
                    (New-Object System.Text.UTF8Encoding($false)))
                return $p
            }
        }
        AfterAll {
            $env:ProgramFiles = $script:origPF64
            ${env:ProgramFiles(x86)} = $script:origPF86x
        }

        It 'returns the 64-bit binary when the csproj asks for it' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $t = New-FakeIisTree -Repo $repo
                $csproj = New-CsprojWith -Repo $repo -Inner '<Use64BitIISExpress>true</Use64BitIISExpress>'
                Find-IisExpressPath -RepoRoot $repo -ProjectFile $csproj | Should -Be $t.Exe64
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'keeps the historical x86-first order when the property is absent' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $t = New-FakeIisTree -Repo $repo
                $csproj = New-CsprojWith -Repo $repo -Inner '<OutputType>Library</OutputType>'
                Find-IisExpressPath -RepoRoot $repo -ProjectFile $csproj | Should -Be $t.Exe86
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        # The shipped test fixture carries the self-closing form, and VS writes it that way for
        # projects that never opted in -- it must NOT be read as "true".
        It 'treats a self-closing Use64BitIISExpress element as 32-bit' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $t = New-FakeIisTree -Repo $repo
                $csproj = New-CsprojWith -Repo $repo -Inner '<Use64BitIISExpress />'
                Find-IisExpressPath -RepoRoot $repo -ProjectFile $csproj | Should -Be $t.Exe86
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'treats an explicit false as 32-bit' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $t = New-FakeIisTree -Repo $repo
                $csproj = New-CsprojWith -Repo $repo -Inner '<Use64BitIISExpress>false</Use64BitIISExpress>'
                Find-IisExpressPath -RepoRoot $repo -ProjectFile $csproj | Should -Be $t.Exe86
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'omitting -ProjectFile keeps x86 first (back-compat for existing callers)' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $t = New-FakeIisTree -Repo $repo
                Find-IisExpressPath -RepoRoot $repo | Should -Be $t.Exe86
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        # Falling back is correct -- returning nothing would be worse -- but doing it silently
        # recreates exactly the BadImageFormatException this ordering exists to prevent.
        It 'warns (does not silently downgrade) when 64-bit is wanted but only 32-bit is installed' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $t = New-FakeIisTree -Repo $repo -Only86
                $csproj = New-CsprojWith -Repo $repo -Inner '<Use64BitIISExpress>true</Use64BitIISExpress>'
                $warnings = @()
                $result = Find-IisExpressPath -RepoRoot $repo -ProjectFile $csproj -WarningVariable warnings -WarningAction SilentlyContinue
                $result | Should -Be $t.Exe86
                @($warnings).Count | Should -BeGreaterThan 0
                ($warnings -join "`n") | Should -Match 'Use64BitIISExpress'
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }

        It 'does not warn when the 64-bit binary is actually there' {
            $repo = New-IsolatedRepoRoot 'iisbit'
            try {
                $null = New-FakeIisTree -Repo $repo
                $csproj = New-CsprojWith -Repo $repo -Inner '<Use64BitIISExpress>true</Use64BitIISExpress>'
                $warnings = @()
                $null = Find-IisExpressPath -RepoRoot $repo -ProjectFile $csproj -WarningVariable warnings -WarningAction SilentlyContinue
                @($warnings).Count | Should -Be 0
            } finally {
                $env:ProgramFiles = $script:origPF64
                ${env:ProgramFiles(x86)} = $script:origPF86x
                Remove-IsolatedRepoRoot -Dir $repo
            }
        }
    }

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
        It 'either throws pointing at config.local.toml or auto-probes an existing file' {
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
                    $errMsg | Should -Match 'IIS Express'
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
                    $errMsg | Should -Match 'config\.local\.toml'
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

    It 'is deterministic and case/slash normalized, isolates across repos, falls back off-git' {
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

            # Non-git path -> falls back to the folder's own path instead of throwing (issue #29):
            # a project that was never `git init`-ed must still get a stable site name, or it can
            # be built but never run.
            $nonGit = New-IsolatedRepoRoot 'hashNonGit'
            $nonGit2 = New-IsolatedRepoRoot 'hashNonGit2'
            try {
                $hNon1 = Get-ProjectIdentityHash -RepoPath $nonGit -CsprojRelPath 'src/App.csproj'
                $hNon1 | Should -Match '^[0-9a-f]{8}$'

                # Stable across calls -- this is what stop / orphan-cleanup rely on to match the
                # running site back to the project.
                $hNon2 = Get-ProjectIdentityHash -RepoPath $nonGit -CsprojRelPath 'src/App.csproj'
                $hNon2 | Should -Be $hNon1

                # Still isolates two different non-git folders sharing a relpath.
                $hOther = Get-ProjectIdentityHash -RepoPath $nonGit2 -CsprojRelPath 'src/App.csproj'
                $hOther | Should -Not -Be $hNon1

                # And a non-git folder must not collide with a real repo's identity.
                $hNon1 | Should -Not -Be $hA1
            } finally {
                Remove-IsolatedRepoRoot -Dir $nonGit
                Remove-IsolatedRepoRoot -Dir $nonGit2
            }
        } finally {
            Remove-IsolatedRepoRoot -Dir $repoA
            Remove-IsolatedRepoRoot -Dir $repoB
        }
    }

    It 'REGRESSION issue #29: inside git the identity is byte-identical to the pre-fallback formula' {
        if (-not $script:GhGitOk) {
            Set-ItResult -Skipped -Because 'git not on PATH'
            return
        }
        # The off-git fallback added for issue #29 must not disturb the IN-git hash by even one
        # character: existing IIS site names, the site entries committed in applicationhost.config,
        # and the name Stop-Iis / Remove-OrphanIis look up all derive from it. Recomputing the
        # original formula here (sha256 of git-common-dir + '#' + lowercased relpath, first 8 hex)
        # pins the algorithm rather than a literal digest, which a path-free fixture cannot have.
        $repo = New-GitRepoFixture 'hashInvariant'
        try {
            $commonDir = (& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
            $commonDir | Should -Not -BeNullOrEmpty
            $commonDir = Get-NormalizedAbsolutePath -Path $commonDir

            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("$commonDir#src/app.csproj")
                $digest = $sha.ComputeHash($bytes)
            } finally {
                $sha.Dispose()
            }
            $expected = ((($digest | ForEach-Object { $_.ToString('x2') }) -join '')).Substring(0, 8)

            Get-ProjectIdentityHash -RepoPath $repo -CsprojRelPath 'src/App.csproj' | Should -Be $expected
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}

Describe 'Resolve-FrontendPackDir' {

    It 'returns empty when [frontend] is absent (so the template says 未設定, issue #30)' {
        $root = New-IsolatedRepoRoot 'feNone'
        try {
            Resolve-FrontendPackDir -RepoRoot $root | Should -Be ''
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'returns the configured dir when [frontend] dir is set' {
        $root = New-IsolatedRepoRoot 'feDir'
        try {
            $tp = Join-Path $root '.turbo-plugin'
            New-Item -ItemType Directory -Path $tp -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tp 'config.toml') -Value @(
                '[frontend]'
                'dir = "src/web/frontend"'
            ) -Encoding UTF8
            Resolve-FrontendPackDir -RepoRoot $root | Should -Be 'src/web/frontend'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'enabled = false wins over a configured dir (explicit opt-out, mirrors [iis] enabled)' {
        $root = New-IsolatedRepoRoot 'feOff'
        try {
            $tp = Join-Path $root '.turbo-plugin'
            New-Item -ItemType Directory -Path $tp -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tp 'config.toml') -Value @(
                '[frontend]'
                'dir = "src/web/frontend"'
                'enabled = false'
            ) -Encoding UTF8
            # Reporting and behaviour both read this function, so an opt-out must not leave the
            # result template claiming a pack that Compress-Content is going to skip.
            Resolve-FrontendPackDir -RepoRoot $root | Should -Be ''
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }
}

Describe 'Resolve-SolutionDir (mono-repo SolutionDir, issue #132)' {

    # BeforeAll, not the Describe body: under Pester 5 a function defined directly in a Describe
    # block is not in scope inside its It blocks.
    BeforeAll {
        # The .sln files have to EXIST -- the walk looks for them on disk, so a fixture that only
        # names them would make every case fall through to the repo root and pass for the wrong
        # reason. The .csproj need not exist: nothing on this path opens it.
        function New-SolutionDirFixture {
            param([string]$Tag, [string[]]$SolutionDirs)
            $root = New-IsolatedRepoRoot $Tag
            foreach ($rel in $SolutionDirs) {
                $dir = if ($rel -eq '.') { $root } else { [System.IO.Path]::Combine($root, ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)) }
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $dir 'App.sln') -Value '' -Encoding UTF8
            }
            return $root
        }
        function Join-Rel {
            param([string]$Root, [string]$Rel)
            return [System.IO.Path]::Combine($Root, ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        }
    }

    # The regression itself. Before the fix this answered with the repo root, so NuGet restored to
    # <root>/packages while the csproj's <HintPath>..\packages\ pointed at <root>/proj-1/packages.
    It 'a csproj under a sub-project solution anchors on that sub-project, not the repo root' {
        $root = New-SolutionDirFixture 'sdMono' @('proj-1', 'proj-2')
        try {
            $csproj = Join-Rel $root 'proj-1/src/Web/Web.csproj'
            $got = Resolve-SolutionDir -RepoRoot $root -TargetPath $csproj
            $got | Should -Be ((Join-Rel $root 'proj-1') + '\')
            $got | Should -Not -Be ($root.TrimEnd('\') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }

    It 'each sub-project gets its own answer' {
        $root = New-SolutionDirFixture 'sdMonoBoth' @('proj-1', 'proj-2')
        try {
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'proj-2/Web/Web.csproj')) |
                Should -Be ((Join-Rel $root 'proj-2') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }

    # Both solutions are on the walk, so this fails if the walk ever runs outermost-first or keeps
    # going after its first hit. The repo-root solution is created FIRST so a fixture-order accident
    # cannot be what makes the expected answer come out.
    It 'the NEAREST solution wins when the repo root also has one' {
        $root = New-SolutionDirFixture 'sdNearest' @('.', 'proj-1')
        try {
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'proj-1/src/Web/Web.csproj')) |
                Should -Be ((Join-Rel $root 'proj-1') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }

    It 'a csproj sitting beside its solution answers with that directory' {
        $root = New-SolutionDirFixture 'sdBeside' @('proj-1')
        try {
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'proj-1/Web.csproj')) |
                Should -Be ((Join-Rel $root 'proj-1') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }

    # The historical answer, kept: a single-project repo with no .sln at all must not change.
    It 'falls back to the repo root when there is no solution anywhere on the walk' {
        $root = New-IsolatedRepoRoot 'sdNoSln'
        try {
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'src/Web/Web.csproj')) |
                Should -Be ($root.TrimEnd('\') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }

    It 'a .sln target answers with its own directory' {
        $root = New-SolutionDirFixture 'sdSlnTarget' @('proj-1')
        try {
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'proj-1/App.sln') -IsSolution) |
                Should -Be ((Join-Rel $root 'proj-1') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }

    # A solution ABOVE the repo root is not this repo's business, and following one would make the
    # answer depend on where the repo happens to be checked out.
    It 'never walks above the repo root' {
        $outer = New-IsolatedRepoRoot 'sdOuter'
        try {
            Set-Content -LiteralPath (Join-Path $outer 'App.sln') -Value '' -Encoding UTF8
            $root = Join-Path $outer 'repo'
            New-Item -ItemType Directory -Path (Join-Rel $root 'src/Web') -Force | Out-Null
            $got = Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'src/Web/Web.csproj')
            $got | Should -Be ($root.TrimEnd('\') + '\')
            $got | Should -Not -Be ($outer.TrimEnd('\') + '\')
        } finally { Remove-IsolatedRepoRoot -Dir $outer }
    }

    # $(SolutionDir) is documented as ending in a separator, and MSBuild property concatenation
    # relies on it; dropping it produces paths like <root>proj-1packages.
    It 'always ends with a path separator' {
        $root = New-SolutionDirFixture 'sdTrailing' @('proj-1')
        try {
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'proj-1/Web.csproj')).EndsWith('\') |
                Should -BeTrue
            (Resolve-SolutionDir -RepoRoot $root -TargetPath (Join-Rel $root 'nope/Web.csproj')).EndsWith('\') |
                Should -BeTrue
        } finally { Remove-IsolatedRepoRoot -Dir $root }
    }
}

Describe 'Resolve-FrontendGroup (multi-project [frontend], issue #125)' {

    # BeforeAll, not the Describe body: under Pester 5 a function defined directly in a Describe
    # block is not in scope inside its It blocks.
    BeforeAll {
        # Writes a config.toml and returns a repo root INSIDE the sandbox, so the containment
        # check has something real to measure against. The project file itself need not exist:
        # nothing in this resolution path opens it, and creating one would only invite
        # Resolve-Path to succeed for the wrong reason.
        function New-FrontendFixture {
            param([string]$Tag, [string[]]$ConfigLines)
            $root = New-IsolatedRepoRoot $Tag
            $tp = Join-Path $root '.turbo-plugin'
            New-Item -ItemType Directory -Path $tp -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tp 'config.toml') -Value $ConfigLines -Encoding UTF8
            return $root
        }
    }

    It 'a keyed group applies to its own project and to nothing else' {
        $root = New-FrontendFixture 'feKeyed' @(
            '[frontend."src/proj-1/Proj1.Web"]'
            'dir = "src/proj-1/Proj1.Web/frontend"'
            '[frontend."src/proj-2/Proj2.Web"]'
            'enabled = false'
        )
        try {
            $p1 = [System.IO.Path]::Combine($root, 'src', 'proj-1', 'Proj1.Web', 'Proj1.Web.csproj')
            $g1 = Resolve-FrontendGroup -RepoRoot $root -TargetProject $p1
            $g1.Status | Should -Be 'ready'
            $g1.Dir | Should -Be 'src/proj-1/Proj1.Web/frontend'
            $g1.Key | Should -Be 'src/proj-1/Proj1.Web'

            $p2 = [System.IO.Path]::Combine($root, 'src', 'proj-2', 'Proj2.Web', 'Proj2.Web.csproj')
            $g2 = Resolve-FrontendGroup -RepoRoot $root -TargetProject $p2
            $g2.Status | Should -Be 'disabled'
            $g2.Dir | Should -Be ''
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    # The bug this whole change exists for: a project with no group of its own must get NOTHING,
    # and must be reported differently from "this repo does no frontend work". Falling back to
    # another group is what packed one project's frontend during another project's build.
    It 'a project with no group of its own is unmatched, not silently packed by another group' {
        $root = New-FrontendFixture 'feUnmatched' @(
            '[frontend."src/proj-1/Proj1.Web"]'
            'dir = "src/proj-1/Proj1.Web/frontend"'
        )
        try {
            $p5 = [System.IO.Path]::Combine($root, 'src', 'proj-5', 'Proj5.Web', 'Proj5.Web.csproj')
            $g = Resolve-FrontendGroup -RepoRoot $root -TargetProject $p5
            $g.Status | Should -Be 'unmatched'
            $g.Dir | Should -Be ''
            Format-FrontendStatusLine -Group $g | Should -Match '沒有一組對應這個專案'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'a bare [frontend] alongside keyed groups is no longer a catch-all' {
        $root = New-FrontendFixture 'feNoFallback' @(
            '[frontend]'
            'dir = "src/web/frontend"'
            '[frontend."src/proj-1/Proj1.Web"]'
            'dir = "src/proj-1/Proj1.Web/frontend"'
        )
        try {
            $p9 = [System.IO.Path]::Combine($root, 'src', 'proj-9', 'Proj9.Web', 'Proj9.Web.csproj')
            (Resolve-FrontendGroup -RepoRoot $root -TargetProject $p9).Status | Should -Be 'unmatched'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'a group key may name the project directory OR the .csproj itself' {
        $root = New-FrontendFixture 'feKeyForms' @(
            '[frontend."src/proj-1/Proj1.Web/Proj1.Web.csproj"]'
            'dir = "src/proj-1/Proj1.Web/frontend"'
        )
        try {
            $p1 = [System.IO.Path]::Combine($root, 'src', 'proj-1', 'Proj1.Web', 'Proj1.Web.csproj')
            (Resolve-FrontendGroup -RepoRoot $root -TargetProject $p1).Status | Should -Be 'ready'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'two groups naming the same project is an error, not a silent pick' {
        $root = New-FrontendFixture 'feAmbiguous' @(
            '[frontend."src/proj-1/Proj1.Web"]'
            'dir = "a"'
            '[frontend."src/proj-1/Proj1.Web/Proj1.Web.csproj"]'
            'dir = "b"'
        )
        try {
            $p1 = [System.IO.Path]::Combine($root, 'src', 'proj-1', 'Proj1.Web', 'Proj1.Web.csproj')
            { Resolve-FrontendGroup -RepoRoot $root -TargetProject $p1 } | Should -Throw -ExpectedMessage '*Ambiguous*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    # The un-keyed form still runs -- changing that would break single-project repos, which is not
    # this change's business -- but it must stop being SILENT about packing somebody else's
    # frontend. That silence is the entire complaint in issue #125.
    It 'a bare [frontend] pointing outside the target project still runs but says so' {
        $root = New-FrontendFixture 'feForeign' @(
            '[frontend]'
            'dir = "src/proj-2/Proj2.Web/frontend"'
        )
        try {
            $p1 = [System.IO.Path]::Combine($root, 'src', 'proj-1', 'Proj1.Web', 'Proj1.Web.csproj')
            $g = Resolve-FrontendGroup -RepoRoot $root -TargetProject $p1
            $g.Status | Should -Be 'foreign'
            $g.Dir | Should -Be 'src/proj-2/Proj2.Web/frontend'
            Format-FrontendStatusLine -Group $g | Should -Match '警告'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'a bare [frontend] inside the target project is plain ready, no warning' {
        $root = New-FrontendFixture 'feOwn' @(
            '[frontend]'
            'dir = "src/web/frontend"'
        )
        try {
            $p = [System.IO.Path]::Combine($root, 'src', 'web', 'Web.csproj')
            $g = Resolve-FrontendGroup -RepoRoot $root -TargetProject $p
            $g.Status | Should -Be 'ready'
            Format-FrontendStatusLine -Group $g | Should -Be 'Frontend: 已執行 (src/web/frontend)'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    # Every caller passes -TargetProject today, so this is what a FUTURE caller gets if it
    # forgets. Documented behaviour deserves a test, or the comment is the only thing holding it.
    It 'with no target in view and keyed groups present, nothing runs' {
        $root = New-FrontendFixture 'feNoTargetKeyed' @(
            '[frontend."src/proj-1/Proj1.Web"]'
            'dir = "src/proj-1/Proj1.Web/frontend"'
        )
        try {
            (Resolve-FrontendGroup -RepoRoot $root).Status | Should -Be 'unmatched'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    It 'with no target in view and no keyed groups, the bare group still applies' {
        $root = New-FrontendFixture 'feNoTargetBare' @(
            '[frontend]'
            'dir = "src/web/frontend"'
        )
        try {
            $g = Resolve-FrontendGroup -RepoRoot $root
            $g.Status | Should -Be 'ready'
            $g.Dir | Should -Be 'src/web/frontend'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }

    # A .sln spans projects and normally sits at the repo root, so the containment check has to
    # neutralise itself there instead of warning on every solution build.
    It 'a solution at the repo root does not trip the containment warning' {
        $root = New-FrontendFixture 'feSln' @(
            '[frontend]'
            'dir = "src/web/frontend"'
        )
        try {
            $sln = [System.IO.Path]::Combine($root, 'All.sln')
            (Resolve-FrontendGroup -RepoRoot $root -TargetProject $sln).Status | Should -Be 'ready'
        } finally {
            Remove-IsolatedRepoRoot -Dir $root
        }
    }
}

Describe 'Per-project config groups for [build] / [publish] (issue #133)' {

    BeforeAll {
        function New-GroupFixture {
            param([string]$Tag, [string[]]$ConfigLines)
            $root = New-IsolatedRepoRoot $Tag
            $tp = Join-Path $root '.turbo-plugin'
            New-Item -ItemType Directory -Path $tp -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $tp 'config.toml') -Value $ConfigLines -Encoding UTF8
            return $root
        }
        function New-GroupProject {
            param([string]$Root, [string]$Rel)
            $abs = [System.IO.Path]::Combine($Root, ($Rel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($abs)) -Force | Out-Null
            Set-Content -LiteralPath $abs -Value '<Project />' -Encoding UTF8
            return $abs
        }
    }

    Context 'Resolve-ConfigGroup' {
        It 'a section with no keyed groups reports none and reads the bare section' {
            $root = New-GroupFixture 'grpNone' @('[build]', 'platform = "x64"')
            try {
                $g = Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'App.csproj'))
                $g.Status | Should -Be 'none'
                $g.Section | Should -Be 'build'
                $g.Key | Should -Be ''
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        It 'a keyed group naming the project directory applies to that project' {
            $root = New-GroupFixture 'grpReady' @(
                '[build."proj-1/src/Web"]'
                'platform = "x64"'
                '[build."proj-2/src/Web"]'
                'platform = "AnyCPU"'
            )
            try {
                $g = Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'proj-1', 'src', 'Web', 'Web.csproj'))
                $g.Status | Should -Be 'ready'
                $g.Key | Should -Be 'proj-1/src/Web'
                $g.Parent | Should -Be 'build'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        # The Q1 decision, made explicit: a key names the project file or the ONE directory holding
        # it, never everything underneath. Matching by containment would need a "deepest group wins"
        # rule layered on top, which only surfaces once two groups already overlap.
        It 'a key does NOT own projects nested deeper beneath it' {
            $root = New-GroupFixture 'grpDepth' @('[build."proj-1"]', 'platform = "x64"')
            try {
                $deep = Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'proj-1', 'src', 'Web', 'Web.csproj'))
                $deep.Status | Should -Be 'unmatched'
                # ...while the project sitting directly in that directory still matches.
                $flat = Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'proj-1', 'App.csproj'))
                $flat.Status | Should -Be 'ready'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        It 'groups that name other projects leave this one unmatched' {
            $root = New-GroupFixture 'grpUnmatched' @('[build."proj-1"]', 'platform = "x64"')
            try {
                (Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'proj-9', 'App.csproj'))).Status |
                    Should -Be 'unmatched'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        It 'two groups naming the same project is an error, not a silent pick' {
            $root = New-GroupFixture 'grpAmbig' @(
                '[build."proj-1"]'
                'platform = "x64"'
                '[build."proj-1/App.csproj"]'
                'platform = "AnyCPU"'
            )
            try {
                { Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'proj-1', 'App.csproj')) } |
                    # Brackets are escaped: -ExpectedMessage is a -like pattern, where an unescaped
                    # [build] is the CHARACTER CLASS {b,u,i,l,d} and would not match the literal.
                    Should -Throw -ExpectedMessage '*Ambiguous `[build`] configuration*'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        It 'groups under one section do not leak into another' {
            $root = New-GroupFixture 'grpIsolation' @('[publish."proj-1"]', 'platform = "x64"')
            try {
                (Resolve-ConfigGroup -RepoRoot $root -Section 'build' -TargetProject ([System.IO.Path]::Combine($root, 'proj-1', 'App.csproj'))).Status |
                    Should -Be 'none'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }
    }

    Context 'Resolve-GroupedConfigValue - per-key layering (the Q2 decision)' {
        BeforeAll {
            $script:layerRoot = New-GroupFixture 'grpLayer' @(
                '[build]'
                'configuration = "Release"'
                'platform = "AnyCPU"'
                '[build."proj-1"]'
                'platform = "x64"'
                '[build."proj-2"]'
                'configuration = "Debug"'
            )
            $script:layerP1 = Resolve-ConfigGroup -RepoRoot $script:layerRoot -Section 'build' -TargetProject ([System.IO.Path]::Combine($script:layerRoot, 'proj-1', 'App.csproj'))
            $script:layerP2 = Resolve-ConfigGroup -RepoRoot $script:layerRoot -Section 'build' -TargetProject ([System.IO.Path]::Combine($script:layerRoot, 'proj-2', 'App.csproj'))
            $script:layerP9 = Resolve-ConfigGroup -RepoRoot $script:layerRoot -Section 'build' -TargetProject ([System.IO.Path]::Combine($script:layerRoot, 'proj-9', 'App.csproj'))
        }
        AfterAll { Remove-IsolatedRepoRoot -Dir $script:layerRoot }

        It "a key the group sets overrides the bare section's value" {
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP1 -Key 'platform') | Should -Be 'x64'
        }
        # The whole reason layering was chosen over whole-group replacement: a repo-wide setting is
        # written ONCE. Under replacement this returns nothing and the build silently loses Release.
        It 'a key the group omits is inherited from the bare section' {
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP1 -Key 'configuration') | Should -Be 'Release'
        }
        It 'each group overrides independently' {
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP2 -Key 'configuration') | Should -Be 'Debug'
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP2 -Key 'platform') | Should -Be 'AnyCPU'
        }
        It 'an explicit CLI value beats both layers' {
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP1 -Key 'platform' -CliValue 'ARM64') | Should -Be 'ARM64'
        }
        It 'an unmatched project still gets every shared value' {
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP9 -Key 'configuration') | Should -Be 'Release'
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP9 -Key 'platform') | Should -Be 'AnyCPU'
        }
        It 'falls through to the supplied default when neither layer has the key' {
            (Resolve-GroupedConfigValue -RepoRoot $script:layerRoot -Group $script:layerP1 -Key 'nothing_sets_this' -Default 'fallback') | Should -Be 'fallback'
        }
    }

    Context 'Resolve-ProjectTarget - no default target once groups exist (the Q3 decision)' {
        It 'refuses to pick a target and names the configured groups' {
            $root = New-GroupFixture 'grpNoDefault' @(
                '[publish."proj-1/src/Web"]'
                'default_pubxml = "a.pubxml"'
                '[publish."proj-2/src/Web"]'
                'default_pubxml = "b.pubxml"'
            )
            try {
                { Resolve-ProjectTarget -RepoRoot $root -Section 'publish' } |
                    Should -Throw -ExpectedMessage '*proj-1/src/Web*proj-2/src/Web*'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        # Rejected alternative: let a bare `project` remain the default. That turns "forgot to say
        # which project" into "silently acted on the main one" -- the same wrong answer, one step
        # later. The message says so rather than leaving the user to infer it.
        It 'a bare project key is not a default while groups exist, and the message says so' {
            $root = New-GroupFixture 'grpBareIgnored' @(
                '[publish]'
                'project = "proj-1/src/Web/Web.csproj"'
                '[publish."proj-2/src/Web"]'
                'default_pubxml = "b.pubxml"'
            )
            try {
                $null = New-GroupProject -Root $root -Rel 'proj-1/src/Web/Web.csproj'
                { Resolve-ProjectTarget -RepoRoot $root -Section 'publish' } |
                    Should -Throw -ExpectedMessage '*not used as a default*'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        It 'an explicitly named project is accepted as before' {
            $root = New-GroupFixture 'grpExplicit' @('[publish."proj-1/src/Web"]', 'default_pubxml = "a.pubxml"')
            try {
                $abs = New-GroupProject -Root $root -Rel 'proj-1/src/Web/Web.csproj'
                (Resolve-ProjectTarget -RepoRoot $root -Section 'publish' -CliProjectValue 'proj-1/src/Web/Web.csproj').Path |
                    Should -Be $abs
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        # Single-project repos are the majority and must be untouched by all of the above.
        It 'a repo with no groups still uses its bare project key' {
            $root = New-GroupFixture 'grpLegacy' @('[publish]', 'project = "src/Web/Web.csproj"')
            try {
                $abs = New-GroupProject -Root $root -Rel 'src/Web/Web.csproj'
                (Resolve-ProjectTarget -RepoRoot $root -Section 'publish').Path | Should -Be $abs
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }

        # run falls back to [build].project, so without the same check the arbitrary pick would come
        # back through that door.
        It 'the run -> build fallback is covered by the same rule' {
            $root = New-GroupFixture 'grpRunFallback' @(
                '[build]'
                'project = "proj-1/App.csproj"'
                '[build."proj-2"]'
                'platform = "x64"'
            )
            try {
                $null = New-GroupProject -Root $root -Rel 'proj-1/App.csproj'
                { Resolve-ProjectTarget -RepoRoot $root -Section 'run' } |
                    Should -Throw -ExpectedMessage '*`[build`] has per-project groups*'
            } finally { Remove-IsolatedRepoRoot -Dir $root }
        }
    }

    Context 'Format-ConfigGroupLine' {
        It 'says nothing at all when the repo has no groups' {
            (Format-ConfigGroupLine -Group ([PSCustomObject]@{ Section = 'build'; Parent = 'build'; Key = ''; Status = 'none' }) -Label '設定分組') |
                Should -BeNullOrEmpty
        }
        It 'names the group that supplied the settings' {
            (Format-ConfigGroupLine -Group ([PSCustomObject]@{ Section = 'build."proj-1"'; Parent = 'build'; Key = 'proj-1'; Status = 'ready' }) -Label '設定分組') |
                Should -Match 'proj-1'
        }
        # Groups exist but none matched: the build still succeeds on the shared values, so without
        # this line "my group did nothing" is invisible.
        It 'reports the unmatched case rather than staying silent' {
            (Format-ConfigGroupLine -Group ([PSCustomObject]@{ Section = 'build'; Parent = 'build'; Key = ''; Status = 'unmatched' }) -Label '設定分組') |
                Should -Match '無對應分組'
        }
    }
}

Describe 'Format-FrontendStatusLine' {

    It 'states 未設定 when no pack will run (the line that was missing in issue #30)' {
        Format-FrontendStatusLine -Group $null | Should -Match '未設定'
        Format-FrontendStatusLine -Group ([PSCustomObject]@{ Section = ''; Key = ''; Dir = ''; Status = 'unset'; TargetDir = '' }) |
            Should -Match '未設定'
    }

    It 'names the directory when a pack ran' {
        Format-FrontendStatusLine -Group ([PSCustomObject]@{ Section = 'frontend'; Key = ''; Dir = 'src/web/frontend'; Status = 'ready'; TargetDir = '' }) |
            Should -Be 'Frontend: 已執行 (src/web/frontend)'
    }

    It 'names the group a keyed pack came from, so the reader can tell which project it was for' {
        Format-FrontendStatusLine -Group ([PSCustomObject]@{ Section = 'frontend."src/proj-1/Proj1.Web"'; Key = 'src/proj-1/Proj1.Web'; Dir = 'src/proj-1/Proj1.Web/frontend'; Status = 'ready'; TargetDir = '' }) |
            Should -Be 'Frontend: 已執行 (src/proj-1/Proj1.Web/frontend,設定來自 [frontend."src/proj-1/Proj1.Web"])'
    }

    # 停用 and 未設定 are different facts: one is the user's decision, the other is an omission,
    # and Step 1.5 is supposed to act on the second only.
    It 'distinguishes a deliberate opt-out from an omission' {
        $disabled = Format-FrontendStatusLine -Group ([PSCustomObject]@{ Section = 'frontend'; Key = ''; Dir = ''; Status = 'disabled'; TargetDir = '' })
        $disabled | Should -Match '已停用'
        $disabled | Should -Not -Match '未設定'
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

Describe 'Resolve-ProjectTarget' {

    It 'returns an explicit -Project .csproj with type csproj' {
        $repo = New-IsolatedRepoRoot 'rpt-cli-csproj'
        try {
            $csproj = Join-Path $repo 'App.csproj'
            Set-Content -LiteralPath $csproj -Value '<Project/>' -Encoding ASCII
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue $csproj
            $t.Type | Should -Be 'csproj'
            [System.IO.Path]::GetFullPath($t.Path) | Should -Be ([System.IO.Path]::GetFullPath($csproj))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'returns an explicit -Project .sln with type sln for build (-AllowSolution)' {
        $repo = New-IsolatedRepoRoot 'rpt-cli-sln'
        try {
            $sln = Join-Path $repo 'App.sln'
            Set-Content -LiteralPath $sln -Value '' -Encoding ASCII
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue $sln -AllowSolution
            $t.Type | Should -Be 'sln'
            [System.IO.Path]::GetFullPath($t.Path) | Should -Be ([System.IO.Path]::GetFullPath($sln))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'rejects a .sln target when -AllowSolution is not set (run/publish)' {
        $repo = New-IsolatedRepoRoot 'rpt-sln-reject'
        try {
            $sln = Join-Path $repo 'App.sln'
            Set-Content -LiteralPath $sln -Value '' -Encoding ASCII
            { Resolve-ProjectTarget -RepoRoot $repo -Section 'run' -CliProjectValue $sln } |
                Should -Throw -ExpectedMessage '*.sln target is only valid for build*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'build resolves from [build].project when no CLI value' {
        $repo = New-IsolatedRepoRoot 'rpt-build-cfg'
        try {
            $csproj = Join-Path $repo 'Web.csproj'
            Set-Content -LiteralPath $csproj -Value '<Project/>' -Encoding ASCII
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[build]`r`nproject = `"Web.csproj`"`r`n"
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue ''
            [System.IO.Path]::GetFullPath($t.Path) | Should -Be ([System.IO.Path]::GetFullPath($csproj))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'run falls back to [build].project when [run].project is unset (back-compat)' {
        $repo = New-IsolatedRepoRoot 'rpt-run-fallback'
        try {
            $csproj = Join-Path $repo 'Web.csproj'
            Set-Content -LiteralPath $csproj -Value '<Project/>' -Encoding ASCII
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[build]`r`nproject = `"Web.csproj`"`r`n"
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'run' -CliProjectValue ''
            [System.IO.Path]::GetFullPath($t.Path) | Should -Be ([System.IO.Path]::GetFullPath($csproj))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'run prefers [run].project over [build].project' {
        $repo = New-IsolatedRepoRoot 'rpt-run-pref'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'Build.csproj') -Value '<Project/>' -Encoding ASCII
            $runCsproj = Join-Path $repo 'Run.csproj'
            Set-Content -LiteralPath $runCsproj -Value '<Project/>' -Encoding ASCII
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[build]`r`nproject = `"Build.csproj`"`r`n[run]`r`nproject = `"Run.csproj`"`r`n"
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'run' -CliProjectValue ''
            [System.IO.Path]::GetFullPath($t.Path) | Should -Be ([System.IO.Path]::GetFullPath($runCsproj))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'throws a clear error when no CLI and no config key (incl. fallback) resolves' {
        $repo = New-IsolatedRepoRoot 'rpt-none'
        try {
            { Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue '' } |
                Should -Throw -ExpectedMessage '*No build target resolved*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'does NOT auto-detect and does NOT throw "Multiple" when several .csproj exist unspecified' {
        $repo = New-IsolatedRepoRoot 'rpt-multi'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'A.csproj') -Value '<Project/>' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $repo 'B.csproj') -Value '<Project/>' -Encoding ASCII
            # No auto-detect: with no explicit target it errors generically, never "Multiple .csproj".
            { Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue '' } |
                Should -Throw -ExpectedMessage '*No build target resolved*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'AllowMissing returns $null instead of throwing when nothing resolves' {
        $repo = New-IsolatedRepoRoot 'rpt-allowmissing'
        try {
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'run' -CliProjectValue '' -AllowMissing
            $t | Should -BeNullOrEmpty
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'throws when the configured project file does not exist' {
        $repo = New-IsolatedRepoRoot 'rpt-missing-file'
        try {
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[build]`r`nproject = `"Nope.csproj`"`r`n"
            { Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue '' } |
                Should -Throw -ExpectedMessage '*does not exist*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'publish resolves from [publish].project' {
        $repo = New-IsolatedRepoRoot 'rpt-publish'
        try {
            $csproj = Join-Path $repo 'Pub.csproj'
            Set-Content -LiteralPath $csproj -Value '<Project/>' -Encoding ASCII
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[publish]`r`nproject = `"Pub.csproj`"`r`n"
            $t = Resolve-ProjectTarget -RepoRoot $repo -Section 'publish' -CliProjectValue ''
            [System.IO.Path]::GetFullPath($t.Path) | Should -Be ([System.IO.Path]::GetFullPath($csproj))
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'publish does NOT fall back to [build].project (per-op isolation; only run/stop fall back)' {
        $repo = New-IsolatedRepoRoot 'rpt-publish-noxfall'
        try {
            Set-Content -LiteralPath (Join-Path $repo 'Build.csproj') -Value '<Project/>' -Encoding ASCII
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[build]`r`nproject = `"Build.csproj`"`r`n"
            { Resolve-ProjectTarget -RepoRoot $repo -Section 'publish' -CliProjectValue '' } |
                Should -Throw -ExpectedMessage '*No publish target resolved*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }

    It 'seeded empty sections do not false-resolve; per-op keys read independently' {
        # Mirrors a real config: active-but-empty [build]/[publish] + a real [run].project.
        $repo = New-IsolatedRepoRoot 'rpt-seeded'
        try {
            $runCsproj = Join-Path $repo 'Run.csproj'
            Set-Content -LiteralPath $runCsproj -Value '<Project/>' -Encoding ASCII
            Write-Toml -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content "[build]`r`n[publish]`r`n[run]`r`nproject = `"Run.csproj`"`r`n"
            # run resolves from [run].project
            (Resolve-ProjectTarget -RepoRoot $repo -Section 'run' -CliProjectValue '').Path |
                Should -Be ([System.IO.Path]::GetFullPath($runCsproj))
            # empty [build] section does not false-resolve a target
            { Resolve-ProjectTarget -RepoRoot $repo -Section 'build' -CliProjectValue '' } |
                Should -Throw -ExpectedMessage '*No build target resolved*'
        } finally {
            Remove-IsolatedRepoRoot -Dir $repo
        }
    }
}

Describe 'Result-template family (KTD5)' {

    Context 'Format-BuildResultLines' {
        It 'includes the resolved target line' {
            $lines = Format-BuildResultLines -ResolvedTarget 'C:\proj\Web.csproj'
            ($lines -join "`n") | Should -Match 'Target: C:\\proj\\Web\.csproj'
        }
        It 'lists configuration/platform when specified' {
            $lines = Format-BuildResultLines -ResolvedTarget 'Web.csproj' -Configuration 'Release' -Platform 'x64'
            ($lines -join "`n") | Should -Match 'Configuration: Release'
            ($lines -join "`n") | Should -Match 'Platform: x64'
        }
        It 'marks configuration/platform as MSBuild-decided when unspecified' {
            $lines = Format-BuildResultLines -ResolvedTarget 'Web.csproj'
            $joined = $lines -join "`n"
            $joined | Should -Match 'Configuration:.*MSBuild'
            $joined | Should -Match 'Platform:.*MSBuild'
            # Must NOT fabricate a concrete value the executor did not pass.
            $joined | Should -Not -Match 'Configuration: Debug'
        }
        It 'flags a solution target' {
            $lines = Format-BuildResultLines -ResolvedTarget 'App.sln' -IsSolution
            ($lines -join "`n") | Should -Match 'App\.sln.*solution'
        }
        It 'REGRESSION issue #30: always carries a Frontend line, packed or not' {
            # The agent relays only these lines, so a frontend that was skipped is invisible to the
            # user unless the template itself says so.
            $none = Format-BuildResultLines -ResolvedTarget 'Web.csproj'
            ($none -join "`n") | Should -Match 'Frontend:.*未設定'

            $packed = Format-BuildResultLines -ResolvedTarget 'Web.csproj' -FrontendGroup ([PSCustomObject]@{
                Section = 'frontend'; Key = ''; Dir = 'src/web/frontend'; Status = 'ready'; TargetDir = '' })
            ($packed -join "`n") | Should -Match 'Frontend: 已執行 \(src/web/frontend\)'

            # issue #125: a template that says 已執行 while the pack ran in ANOTHER project's
            # directory is the exact failure that had to be made visible. The relayed lines are
            # the only thing the user sees, so the warning has to live here.
            $foreign = Format-BuildResultLines -ResolvedTarget 'src/proj-1/Proj1.Web/Proj1.Web.csproj' -FrontendGroup ([PSCustomObject]@{
                Section = 'frontend'; Key = ''; Dir = 'src/proj-2/Proj2.Web/frontend'; Status = 'foreign'; TargetDir = 'src/proj-1/Proj1.Web' })
            ($foreign -join "`n") | Should -Match '警告'
        }
    }

    Context 'Format-RunResultLines' {
        It 'includes target and web URL, no configuration line' {
            $lines = Format-RunResultLines -ResolvedTarget 'Web.csproj' -WebUrl 'http://localhost:5000/'
            $joined = $lines -join "`n"
            $joined | Should -Match 'Target: Web\.csproj'
            $joined | Should -Match 'http://localhost:5000/'
            $joined | Should -Not -Match 'Configuration'
        }
        It 'keeps the URL bare at end of line (clickable, no trailing punctuation)' {
            $lines = Format-RunResultLines -ResolvedTarget 'Web.csproj' -WebUrl 'http://localhost:5000/'
            $urlLine = $lines | Where-Object { $_ -match 'localhost:5000' }
            $urlLine | Should -Match 'http://localhost:5000/$'
        }
    }

    Context 'Format-StopResultLines' {
        It 'reports the stopped site name' {
            $lines = Format-StopResultLines -Site 'HelloApp-deadbeef'
            ($lines -join "`n") | Should -Match 'HelloApp-deadbeef'
        }
        It 'includes the target line when provided' {
            $lines = Format-StopResultLines -Site 'HelloApp-deadbeef' -ResolvedTarget 'Web.csproj'
            ($lines -join "`n") | Should -Match 'Target: Web\.csproj'
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

# =============================================================================
# Get-PublishOutputLines (U10) - raw path + file:/// URL, no trailing punctuation
# =============================================================================

Describe 'Get-PublishOutputLines' {

    It 'FileSystem absolute path: trims trailing backslash + builds a forward-slash file:/// URL' {
        $out = Get-PublishOutputLines -PublishUrlRaw 'C:\builds\out\' -Method 'FileSystem' -ProjectDir 'C:\proj'
        $out.IsFileSystem | Should -BeTrue
        $out.Resolved | Should -Be 'C:\builds\out'
        $out.DisplayPath | Should -Be 'file:///C:/builds/out'
        $out.DisplayPath | Should -Not -Match '\\'            # URL must not contain backslashes
    }

    It 'FileSystem relative path: resolves against the project directory' {
        $out = Get-PublishOutputLines -PublishUrlRaw 'bin\Publish' -Method 'FileSystem' -ProjectDir 'C:\proj\src'
        $out.Resolved | Should -Be 'C:\proj\src\bin\Publish'
        $out.DisplayPath | Should -Be 'file:///C:/proj/src/bin/Publish'
    }

    It 'defaults to FileSystem when -Method is omitted' {
        $out = Get-PublishOutputLines -PublishUrlRaw 'C:\out' -ProjectDir 'C:\proj'
        $out.IsFileSystem | Should -BeTrue
        $out.DisplayPath | Should -Be 'file:///C:/out'
    }

    It 'preserves spaces in the path on a single line, with no trailing punctuation' {
        $out = Get-PublishOutputLines -PublishUrlRaw 'C:\my builds\web out\' -Method 'FileSystem' -ProjectDir 'C:\proj'
        $out.Resolved | Should -Be 'C:\my builds\web out'
        $out.DisplayPath | Should -Be 'file:///C:/my builds/web out'
        # single line + no trailing punctuation / whitespace (R15: agent relays verbatim, clickable)
        $out.Resolved | Should -Not -Match "`n"
        $out.DisplayPath | Should -Not -Match "`n"
        $out.Resolved | Should -Not -Match '[.\s]$'
        $out.DisplayPath | Should -Not -Match '[.\s]$'
    }

    It 'non-FileSystem method passes the URL through unchanged for both lines' {
        $out = Get-PublishOutputLines -PublishUrlRaw 'https://ftp.example.com/site' -Method 'AzurePublish'
        $out.IsFileSystem | Should -BeFalse
        $out.Resolved | Should -Be 'https://ftp.example.com/site'
        $out.DisplayPath | Should -Be 'https://ftp.example.com/site'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-DotnetRepoRoot - omitted keeps the historical "act on cwd" behaviour; supplied names
# the project outright (multi-project workspace) and validates before anything is touched.
Describe 'Resolve-DotnetRepoRoot' {
    It 'returns the current directory when -RepoRoot is omitted (historical behaviour)' {
        $dir = New-IsolatedRepoRoot 'dnroot-cwd'
        try {
            Push-Location -LiteralPath $dir
            try {
                Resolve-DotnetRepoRoot | Should -Be (Get-Location).Path
            } finally { Pop-Location }
        } finally { Remove-IsolatedRepoRoot $dir }
    }
    It 'returns the empty-string case as the current directory too' {
        $dir = New-IsolatedRepoRoot 'dnroot-empty'
        try {
            Push-Location -LiteralPath $dir
            try {
                Resolve-DotnetRepoRoot -RepoRoot '' | Should -Be (Get-Location).Path
            } finally { Pop-Location }
        } finally { Remove-IsolatedRepoRoot $dir }
    }
    It 'returns the named directory, independent of where the process is standing' {
        $target = New-IsolatedRepoRoot 'dnroot-target'
        $other = New-IsolatedRepoRoot 'dnroot-other'
        try {
            Push-Location -LiteralPath $other
            try {
                $resolved = Resolve-DotnetRepoRoot -RepoRoot $target
                (Get-NormalizedAbsolutePath -Path $resolved) | Should -Be (Get-NormalizedAbsolutePath -Path $target)
            } finally { Pop-Location }
        } finally { Remove-IsolatedRepoRoot $target; Remove-IsolatedRepoRoot $other }
    }
    It 'throws naming the argument when the path is not a directory' {
        $dir = New-IsolatedRepoRoot 'dnroot-bad'
        try {
            { Resolve-DotnetRepoRoot -RepoRoot (Join-Path $dir 'nope') } | Should -Throw -ExpectedMessage '*Repo root not found*'
        } finally { Remove-IsolatedRepoRoot $dir }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-MsbuildProperty - publish reads <Configuration> out of the profile because with
# /p:PublishProfile the profile does NOT govern the build (real-machine, 2026-07-31).
Describe 'Get-MsbuildProperty' {
    BeforeAll {
        $script:pubxmlDir = New-IsolatedRepoRoot 'pubxmlprop'
        function New-Pubxml {
            param([string]$Name, [string]$Body)
            $p = Join-Path $script:pubxmlDir "$Name.pubxml"
            [System.IO.File]::WriteAllText($p, "<Project><PropertyGroup>$Body</PropertyGroup></Project>", (New-Object System.Text.UTF8Encoding($false)))
            return $p
        }
    }
    AfterAll { Remove-IsolatedRepoRoot $script:pubxmlDir }

    It 'reads the named property' {
        $p = New-Pubxml 'plain' '<Configuration>Release</Configuration><PublishUrl>bin\out\</PublishUrl>'
        Get-MsbuildProperty -Path $p -Name 'Configuration' | Should -Be 'Release'
    }
    It 'matches the element name case-insensitively (VS casing varies across pubxml versions)' {
        $p = New-Pubxml 'casing' '<configuration>Release</configuration>'
        Get-MsbuildProperty -Path $p -Name 'Configuration' | Should -Be 'Release'
    }
    It 'trims surrounding whitespace' {
        $p = New-Pubxml 'ws' "<Configuration>`n  Release`n</Configuration>"
        Get-MsbuildProperty -Path $p -Name 'Configuration' | Should -Be 'Release'
    }
    It 'returns empty string when the property is absent' {
        $p = New-Pubxml 'absent' '<PublishUrl>bin\out\</PublishUrl>'
        Get-MsbuildProperty -Path $p -Name 'Configuration' | Should -Be ''
    }
    It 'returns empty string when the file does not exist' {
        Get-MsbuildProperty -Path (Join-Path $script:pubxmlDir 'nope.pubxml') -Name 'Configuration' | Should -Be ''
    }
    It 'returns empty string on malformed XML instead of throwing' {
        $bad = Join-Path $script:pubxmlDir 'bad.pubxml'
        [System.IO.File]::WriteAllText($bad, '<Project><PropertyGroup><Configuration>Release', (New-Object System.Text.UTF8Encoding($false)))
        Get-MsbuildProperty -Path $bad -Name 'Configuration' | Should -Be ''
    }
    It 'last definition wins (matches MSBuild property semantics)' {
        $p = New-Pubxml 'dup' '<Configuration>Debug</Configuration><Configuration>Release</Configuration>'
        Get-MsbuildProperty -Path $p -Name 'Configuration' | Should -Be 'Release'
    }
}

# =============================================================================
# Test-NodeVersionSatisfied (issue #49)
# =============================================================================
#
# The reported bug: a requirement written as a range rejected EVERY Node version, because the old
# code took Split('.')[0] of ">=16.0.0" (yielding ">=16") and string-compared it to "18". The three
# versions named in the issue are pinned below so that exact scenario can never come back.
Describe 'Test-NodeVersionSatisfied' {

    Context 'bare value keeps its historical "major only" meaning' {
        It 'accepts any patch/minor within the same major' {
            Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '18' | Should -BeTrue
        }
        It 'rejects a different major' {
            Test-NodeVersionSatisfied -CurrentVersion 'v16.0.0' -Requirement '18' | Should -BeFalse
        }
        It 'ignores extra components in the requirement (18.20.8 still means "major 18")' {
            Test-NodeVersionSatisfied -CurrentVersion 'v18.4.0' -Requirement '18.20.8' | Should -BeTrue
        }
    }

    Context 'issue #49 - a >= range no longer rejects everything' {
        # These are the three versions the issue reported as blocked. v10 genuinely does not
        # satisfy >=16; the other two must now pass.
        It 'v18.20.8 satisfies >=16.0.0' {
            Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '>=16.0.0' | Should -BeTrue
        }
        It 'v24.14.0 satisfies >=16.0.0' {
            Test-NodeVersionSatisfied -CurrentVersion 'v24.14.0' -Requirement '>=16.0.0' | Should -BeTrue
        }
        It 'v10.15.3 does NOT satisfy >=16.0.0 (still a real rejection)' {
            Test-NodeVersionSatisfied -CurrentVersion 'v10.15.3' -Requirement '>=16.0.0' | Should -BeFalse
        }
    }

    Context 'comparisons are numeric, not lexical' {
        # The case that catches a string-compare regression: lexically "10" < "9", so a naive
        # implementation calls v18.10.0 older than 18.9 and rejects it.
        It 'v18.10.0 satisfies >=18.9' {
            Test-NodeVersionSatisfied -CurrentVersion 'v18.10.0' -Requirement '>=18.9' | Should -BeTrue
        }
        It '>= is inclusive at the boundary' {
            Test-NodeVersionSatisfied -CurrentVersion 'v16.0.0' -Requirement '>=16' | Should -BeTrue
        }
        It '> is exclusive at the boundary' {
            Test-NodeVersionSatisfied -CurrentVersion 'v16.0.0' -Requirement '>16' | Should -BeFalse
        }
        It 'supports an upper bound' {
            Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '<=20' | Should -BeTrue
            Test-NodeVersionSatisfied -CurrentVersion 'v20.1.0'  -Requirement '<20'  | Should -BeFalse
        }
        It 'tolerates a leading v and whitespace in the requirement' {
            Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '>= v16' | Should -BeTrue
        }
    }

    Context 'unsupported syntax fails loudly instead of silently rejecting' {
        # This is the half of the fix that matters most: the old behaviour for an unparseable
        # requirement was "reject every version and blame the Node install".
        It 'throws on npm caret ranges' {
            { Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '^18' } | Should -Throw '*not supported*'
        }
        It 'throws on npm tilde ranges' {
            { Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '~18' } | Should -Throw '*not supported*'
        }
        It 'throws on unions' {
            { Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '16 || 18' } | Should -Throw '*not supported*'
        }
        It 'the message names the offending value so the config line can be found' {
            { Test-NodeVersionSatisfied -CurrentVersion 'v18.20.8' -Requirement '^18' } | Should -Throw '*^18*'
        }
        It 'throws when the reported Node version is unparseable' {
            { Test-NodeVersionSatisfied -CurrentVersion 'not-a-version' -Requirement '18' } | Should -Throw '*not-a-version*'
        }
    }
}
