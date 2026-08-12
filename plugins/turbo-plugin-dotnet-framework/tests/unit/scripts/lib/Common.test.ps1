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

Describe 'Format-FrontendStatusLine' {

    It 'states 未設定 when no pack will run (the line that was missing in issue #30)' {
        Format-FrontendStatusLine -FrontendDir '' | Should -Match '未設定'
    }

    It 'names the directory when a pack ran' {
        Format-FrontendStatusLine -FrontendDir 'src/web/frontend' | Should -Be 'Frontend: 已執行 (src/web/frontend)'
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

            $packed = Format-BuildResultLines -ResolvedTarget 'Web.csproj' -FrontendDir 'src/web/frontend'
            ($packed -join "`n") | Should -Match 'Frontend: 已執行 \(src/web/frontend\)'
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
