# Common.test.ps1
#
# Unit tests for plugins/turbo-plugin/scripts/lib/Common.ps1 (+ IisHelpers.ps1 helpers
# Find-MSBuild / Find-IisExpressPath which dot-source Common.ps1).
#
# Merged from (U6):
#   - test_resolve_config_value_merge.ps1  -> # === resolve-config-value-merge feature ===
#   - test_find_tools_strict_cut.ps1       -> # === find-tools-strict-cut feature ===
# Both feature blocks preserved in full; each writes its own header + summary into stdout
# so a reader can still see which feature passed/failed.
#
# Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <path-to-this-test.ps1>
# Exit code 0 = all pass, 1 = any failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Locate Common.ps1 + IisHelpers.ps1 relative to this test file:
#   <plugin>/tests/unit/scripts/lib/<this>.ps1  -> <plugin>/scripts/lib/Common.ps1
#                                                -> <plugin>/scripts/lib/IisHelpers.ps1
$pluginRoot  = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
$commonPs1   = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Common.ps1')
$iisHelpers  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1')
if (-not (Test-Path -LiteralPath $commonPs1 -PathType Leaf)) {
    Write-Error "Common.ps1 not found at: $commonPs1"
    exit 1
}
if (-not (Test-Path -LiteralPath $iisHelpers -PathType Leaf)) {
    Write-Error "IisHelpers.ps1 not found at: $iisHelpers"
    exit 1
}
. $commonPs1
. $iisHelpers

# ─── Shared helpers (both features) ──────────────────────────────────────────

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function New-IsolatedRepoRoot {
    param([string]$Tag = 'common')
    # Each scenario gets its own sandbox dir so previous state never bleeds in.
    # Expand any 8.3 short-name segments in $env:TEMP (e.g. MELWU~1) — Remove-Item -LiteralPath
    # on PS 5.1 + a short-named parent dir trips an "object at path does not exist" error.
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

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Expected,
        $Actual
    )
    $expectedRepr = if ($null -eq $Expected) { '<null>' } else { "'$Expected' (type=$($Expected.GetType().Name))" }
    $actualRepr   = if ($null -eq $Actual)   { '<null>' } else { "'$Actual' (type=$($Actual.GetType().Name))" }
    if ($Expected -eq $Actual -and (($null -eq $Expected) -eq ($null -eq $Actual))) {
        $script:Passed++
        Write-Output "  [PASS] $Name"
    } else {
        $script:Failed++
        $script:Failures += "${Name}: expected $expectedRepr, got $actualRepr"
        Write-Output "  [FAIL] $Name"
        Write-Output "         expected: $expectedRepr"
        Write-Output "         actual:   $actualRepr"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:Passed++
        Write-Output "  [PASS] $Name"
    } else {
        $script:Failed++
        $msg = "${Name}: assertion failed"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $msg += " ($Detail)" }
        $script:Failures += $msg
        Write-Output "  [FAIL] $Name"
        if (-not [string]::IsNullOrWhiteSpace($Detail)) {
            Write-Output "         detail: $Detail"
        }
    }
}

function Write-Toml {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    Write-Utf8NoBom -Path $Path -Content $Content
}

# =============================================================================
# === resolve-config-value-merge feature ======================================
# =============================================================================
#
# Verifies Resolve-ConfigValue + Read-TurboPluginConfig merge behavior (U1).
#
# 5 scenarios:
#   1. Happy:        config.toml has [svn] force_bash, config.local.toml has [tools] msbuild_path
#                    -> both keys resolve correctly
#   2. Override:     config.toml [tools] msbuild_path = "A", config.local.toml same key = "B"
#                    -> returns "B" (local wins)
#   3. Missing local: config.local.toml does not exist
#                    -> falls back to config.toml without throwing
#   4. Both missing: neither file exists
#                    -> returns Default when provided, $null otherwise
#   5. CLI wins:     CLI value beats both files

Write-Output ''
Write-Output '═════════════════════════════════════════════════════════════════════'
Write-Output '═══ resolve-config-value-merge feature ═══'
Write-Output '═════════════════════════════════════════════════════════════════════'

# ─── Scenario 1: Happy path (different sections in each file) ──────────────────

Write-Output ''
Write-Output 'Scenario 1: Happy path (config.toml has [svn], config.local.toml has [tools])'
$repo1 = New-IsolatedRepoRoot 'merge'
try {
    $cfgToml      = Join-Path $repo1 '.turbo-plugin\config.toml'
    $cfgLocalToml = Join-Path $repo1 '.turbo-plugin\config.local.toml'

    Write-Toml -Path $cfgToml -Content @"
schema_version = 2
[svn]
force_bash = true
"@

    Write-Toml -Path $cfgLocalToml -Content @"
[tools]
msbuild_path = "C:/MSBuild.exe"
"@

    $forceBash = Resolve-ConfigValue -RepoRoot $repo1 -Section 'svn'   -Key 'force_bash'   -CliValue $null -Default $false
    $msbuild   = Resolve-ConfigValue -RepoRoot $repo1 -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null

    Assert-Equal -Name 'config.toml [svn] force_bash resolves to true' -Expected $true -Actual $forceBash
    Assert-Equal -Name 'config.local.toml [tools] msbuild_path resolves to C:/MSBuild.exe' -Expected 'C:/MSBuild.exe' -Actual $msbuild
} finally {
    Remove-IsolatedRepoRoot -Dir $repo1
}

# ─── Scenario 2: Override (same key in both files, local wins) ─────────────────

Write-Output ''
Write-Output 'Scenario 2: Override (same key in both files, config.local.toml wins)'
$repo2 = New-IsolatedRepoRoot 'merge'
try {
    $cfgToml      = Join-Path $repo2 '.turbo-plugin\config.toml'
    $cfgLocalToml = Join-Path $repo2 '.turbo-plugin\config.local.toml'

    Write-Toml -Path $cfgToml -Content @"
schema_version = 2
[tools]
msbuild_path = "A"
"@

    Write-Toml -Path $cfgLocalToml -Content @"
[tools]
msbuild_path = "B"
"@

    $msbuild = Resolve-ConfigValue -RepoRoot $repo2 -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
    Assert-Equal -Name 'local override beats config.toml (expect B)' -Expected 'B' -Actual $msbuild
} finally {
    Remove-IsolatedRepoRoot -Dir $repo2
}

# ─── Scenario 3: Missing local (only config.toml exists) ───────────────────────

Write-Output ''
Write-Output 'Scenario 3: Missing local (config.local.toml does not exist, fall back to config.toml)'
$repo3 = New-IsolatedRepoRoot 'merge'
try {
    $cfgToml = Join-Path $repo3 '.turbo-plugin\config.toml'
    Write-Toml -Path $cfgToml -Content @"
schema_version = 2
[tools]
msbuild_path = "only-in-config-toml"
"@

    # Sanity check: local file should not exist
    $cfgLocalToml = Join-Path $repo3 '.turbo-plugin\config.local.toml'
    if (Test-Path -LiteralPath $cfgLocalToml) {
        Write-Output '  [FAIL] precondition: config.local.toml unexpectedly exists'
        $script:Failed++
    }

    $threw = $false
    $msbuild = $null
    try {
        $msbuild = Resolve-ConfigValue -RepoRoot $repo3 -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
    } catch {
        $threw = $true
        Write-Output "  [FAIL] unexpected throw: $($_.Exception.Message)"
        $script:Failed++
    }

    if (-not $threw) {
        Assert-Equal -Name 'returns config.toml value when local missing' -Expected 'only-in-config-toml' -Actual $msbuild
    }
} finally {
    Remove-IsolatedRepoRoot -Dir $repo3
}

# ─── Scenario 4: Both missing (returns Default or $null) ───────────────────────

Write-Output ''
Write-Output 'Scenario 4: Both files missing (returns Default if provided, else $null)'
$repo4 = New-IsolatedRepoRoot 'merge'
try {
    # .turbo-plugin/ dir exists but both .toml files are absent.
    $val1 = Resolve-ConfigValue -RepoRoot $repo4 -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default 'fallback-default'
    Assert-Equal -Name 'returns Default when both files missing' -Expected 'fallback-default' -Actual $val1

    $val2 = Resolve-ConfigValue -RepoRoot $repo4 -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
    Assert-Equal -Name 'returns $null when both files missing and no Default' -Expected $null -Actual $val2
} finally {
    Remove-IsolatedRepoRoot -Dir $repo4
}

# ─── Extra: CLI value still wins over both ────────────────────────────────────

Write-Output ''
Write-Output 'Scenario 5 (regression guard): CLI value beats both files'
$repo5 = New-IsolatedRepoRoot 'merge'
try {
    $cfgToml      = Join-Path $repo5 '.turbo-plugin\config.toml'
    $cfgLocalToml = Join-Path $repo5 '.turbo-plugin\config.local.toml'
    Write-Toml -Path $cfgToml -Content @"
[tools]
msbuild_path = "from-config"
"@
    Write-Toml -Path $cfgLocalToml -Content @"
[tools]
msbuild_path = "from-local"
"@

    $val = Resolve-ConfigValue -RepoRoot $repo5 -Section 'tools' -Key 'msbuild_path' -CliValue 'from-cli' -Default $null
    Assert-Equal -Name 'CLI value wins over both files' -Expected 'from-cli' -Actual $val
} finally {
    Remove-IsolatedRepoRoot -Dir $repo5
}

# =============================================================================
# === find-tools-strict-cut feature ===========================================
# =============================================================================
#
# Verifies Find-MSBuild / Find-IisExpressPath strict cut to config.local.toml (U2).
#
# 4 scenarios per helper:
#   1. Happy:        config.local.toml [tools] msbuild_path = <path-to-existing-file>
#                    -> helper returns that path
#   2. Auto-probe:   [tools] section absent; mock probe candidate exists
#                    -> helper returns the probed path
#   3. Throw:        [tools] absent + no probe candidate exists
#                    -> helper throws with "/tp-setup" guidance in message
#   4. Env ignored:  $env:TURBO_PLUGIN_MSBUILD_PATH set to fake path
#                    -> helper does NOT read it (returns config / probe / throw per Step 1-3)
#
# Same coverage applied to Find-IisExpressPath via [tools] iis_express_path and
# $env:TURBO_PLUGIN_IIS_EXPRESS_PATH.

# Snapshot/restore the two env vars to ensure tests don't leak state out.
$origMsbuildEnv = $env:TURBO_PLUGIN_MSBUILD_PATH
$origIisEnv     = $env:TURBO_PLUGIN_IIS_EXPRESS_PATH

Write-Output ''
Write-Output '═════════════════════════════════════════════════════════════════════'
Write-Output '═══ find-tools-strict-cut feature ═══'
Write-Output '═════════════════════════════════════════════════════════════════════'

# ─── Find-MSBuild ─────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Find-MSBuild ───'

# Scenario 1: Happy — config.local.toml [tools] msbuild_path points to existing file
Write-Output ''
Write-Output 'Find-MSBuild Scenario 1: Happy path (config.local.toml [tools] msbuild_path -> existing file)'
$repoM1 = New-IsolatedRepoRoot 'tools'
try {
    # Create a fake MSBuild.exe stand-in (any file that exists)
    $fakeMsbuild = Join-Path $repoM1 'fake-msbuild.exe'
    Set-Content -LiteralPath $fakeMsbuild -Value '' -Encoding ASCII

    # Forward-slash path in TOML (config typically does this)
    $tomlPath = ($fakeMsbuild -replace '\\', '/')
    Write-Toml -Path (Join-Path $repoM1 '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "$tomlPath"
"@

    $result = Find-MSBuild -RepoRoot $repoM1
    Assert-True -Name 'returns the configured path' -Condition ([System.IO.Path]::GetFullPath($result) -eq [System.IO.Path]::GetFullPath($fakeMsbuild)) -Detail "got: $result; expected file at: $fakeMsbuild"
} finally {
    Remove-IsolatedRepoRoot -Dir $repoM1
}

# Scenario 2: Auto-probe — covered by Scenario 3 inverse on machines with VS installed.
# On a CI machine without VS, Scenario 3 verifies the throw path. On a dev machine WITH
# VS, the same call would return the VS path. We assert the relevant invariant in
# Scenario 3 below (no env fallback).

# Scenario 3a: Throw — [tools] absent + (assumed) no VS install in this sandbox.
# This test relies on the user's machine state: if VS is installed, we verify the result
# is a real existing file. If not, we verify a friendly throw.
Write-Output ''
Write-Output 'Find-MSBuild Scenario 2/3: Auto-probe OR throw (no [tools] configured)'
$repoM3 = New-IsolatedRepoRoot 'tools'
try {
    # No config.local.toml at all; clear env to ensure no contamination
    $env:TURBO_PLUGIN_MSBUILD_PATH = $null

    $result = $null
    $threw = $false
    $errMsg = ''
    try {
        $result = Find-MSBuild -RepoRoot $repoM3
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }

    if ($threw) {
        # Throw path — verify message contains /tp-setup guidance
        Assert-True -Name 'throw message contains /tp-setup guidance' -Condition ($errMsg -match '/tp-setup') -Detail "got message: $errMsg"
        Assert-True -Name 'throw message mentions config.local.toml or [tools]' -Condition ($errMsg -match '(config\.local\.toml|\[tools\])') -Detail "got message: $errMsg"
    } else {
        # Auto-probe path — verify it returned an existing file (one of the VS install paths)
        Assert-True -Name 'auto-probe returned an existing file' -Condition (Test-Path -LiteralPath $result -PathType Leaf) -Detail "got: $result"
    }
} finally {
    Remove-IsolatedRepoRoot -Dir $repoM3
}

# Scenario 4: Env ignored — fake env path, [tools] absent.
# Expected behavior: helper ignores env entirely. Outcome depends on machine state:
#   - If VS exists: returns a real VS path (NOT the fake env value)
#   - If VS missing: throws (with /tp-setup hint, NOT a TURBO_PLUGIN_MSBUILD_PATH hint)
Write-Output ''
Write-Output 'Find-MSBuild Scenario 4: Env var is IGNORED ($env:TURBO_PLUGIN_MSBUILD_PATH set to fake)'
$repoM4 = New-IsolatedRepoRoot 'tools'
try {
    $fakeEnvPath = Join-Path $repoM4 'this-path-must-not-be-read.exe'
    $env:TURBO_PLUGIN_MSBUILD_PATH = $fakeEnvPath

    $result = $null
    $threw = $false
    $errMsg = ''
    try {
        $result = Find-MSBuild -RepoRoot $repoM4
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }

    if ($threw) {
        # Throw should NOT mention TURBO_PLUGIN_MSBUILD_PATH
        Assert-True -Name 'throw message does NOT mention TURBO_PLUGIN_MSBUILD_PATH env var' -Condition (-not ($errMsg -match 'TURBO_PLUGIN_MSBUILD_PATH')) -Detail "got message: $errMsg"
        Assert-True -Name 'throw message mentions /tp-setup' -Condition ($errMsg -match '/tp-setup') -Detail "got message: $errMsg"
    } else {
        # Auto-probe path — verify it returned an existing file and NOT the fake env value
        Assert-True -Name 'returned an existing file (not the fake env path)' -Condition (Test-Path -LiteralPath $result -PathType Leaf) -Detail "got: $result"
        Assert-True -Name 'returned path is NOT the fake env value' -Condition ($result -ne $fakeEnvPath) -Detail "got: $result; fake env was: $fakeEnvPath"
    }
} finally {
    $env:TURBO_PLUGIN_MSBUILD_PATH = $origMsbuildEnv
    Remove-IsolatedRepoRoot -Dir $repoM4
}

# Scenario 5: Configured path points to a missing file -> friendly throw mentioning the path
Write-Output ''
Write-Output 'Find-MSBuild Scenario 5: Configured path points to non-existent file (friendly throw)'
$repoM5 = New-IsolatedRepoRoot 'tools'
try {
    Write-Toml -Path (Join-Path $repoM5 '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "C:/this/path/does/not/exist/MSBuild.exe"
"@

    $threw = $false
    $errMsg = ''
    try {
        $null = Find-MSBuild -RepoRoot $repoM5
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }
    Assert-True -Name 'throws when configured path is missing' -Condition $threw -Detail "errMsg: $errMsg"
    if ($threw) {
        Assert-True -Name 'throw message references config.local.toml' -Condition ($errMsg -match 'config\.local\.toml') -Detail "got: $errMsg"
    }
} finally {
    Remove-IsolatedRepoRoot -Dir $repoM5
}

# ─── Find-IisExpressPath ───────────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Find-IisExpressPath ───'

# Scenario 1: Happy
Write-Output ''
Write-Output 'Find-IisExpressPath Scenario 1: Happy path (config.local.toml [tools] iis_express_path -> existing file)'
$repoI1 = New-IsolatedRepoRoot 'tools'
try {
    $fakeIis = Join-Path $repoI1 'fake-iisexpress.exe'
    Set-Content -LiteralPath $fakeIis -Value '' -Encoding ASCII

    $tomlPath = ($fakeIis -replace '\\', '/')
    Write-Toml -Path (Join-Path $repoI1 '.turbo-plugin\config.local.toml') -Content @"
[tools]
iis_express_path = "$tomlPath"
"@

    $result = Find-IisExpressPath -RepoRoot $repoI1
    Assert-True -Name 'returns the configured path' -Condition ([System.IO.Path]::GetFullPath($result) -eq [System.IO.Path]::GetFullPath($fakeIis)) -Detail "got: $result"
} finally {
    Remove-IsolatedRepoRoot -Dir $repoI1
}

# Scenario 2/3: Auto-probe OR throw (machine-state dependent)
Write-Output ''
Write-Output 'Find-IisExpressPath Scenario 2/3: Auto-probe OR throw (no [tools] configured)'
$repoI3 = New-IsolatedRepoRoot 'tools'
try {
    $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $null

    $result = $null
    $threw = $false
    $errMsg = ''
    try {
        $result = Find-IisExpressPath -RepoRoot $repoI3
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }

    if ($threw) {
        Assert-True -Name 'throw message contains /tp-setup guidance' -Condition ($errMsg -match '/tp-setup') -Detail "got message: $errMsg"
        Assert-True -Name 'throw message mentions config.local.toml or [tools]' -Condition ($errMsg -match '(config\.local\.toml|\[tools\])') -Detail "got message: $errMsg"
    } else {
        Assert-True -Name 'auto-probe returned an existing file' -Condition (Test-Path -LiteralPath $result -PathType Leaf) -Detail "got: $result"
    }
} finally {
    Remove-IsolatedRepoRoot -Dir $repoI3
}

# Scenario 4: Env ignored
Write-Output ''
Write-Output 'Find-IisExpressPath Scenario 4: Env var is IGNORED ($env:TURBO_PLUGIN_IIS_EXPRESS_PATH set to fake)'
$repoI4 = New-IsolatedRepoRoot 'tools'
try {
    $fakeEnvPath = Join-Path $repoI4 'this-path-must-not-be-read.exe'
    $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $fakeEnvPath

    $result = $null
    $threw = $false
    $errMsg = ''
    try {
        $result = Find-IisExpressPath -RepoRoot $repoI4
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }

    if ($threw) {
        Assert-True -Name 'throw message does NOT mention TURBO_PLUGIN_IIS_EXPRESS_PATH env var' -Condition (-not ($errMsg -match 'TURBO_PLUGIN_IIS_EXPRESS_PATH')) -Detail "got message: $errMsg"
        Assert-True -Name 'throw message mentions /tp-setup' -Condition ($errMsg -match '/tp-setup') -Detail "got message: $errMsg"
    } else {
        Assert-True -Name 'returned an existing file (not the fake env path)' -Condition (Test-Path -LiteralPath $result -PathType Leaf) -Detail "got: $result"
        Assert-True -Name 'returned path is NOT the fake env value' -Condition ($result -ne $fakeEnvPath) -Detail "got: $result; fake env was: $fakeEnvPath"
    }
} finally {
    $env:TURBO_PLUGIN_IIS_EXPRESS_PATH = $origIisEnv
    Remove-IsolatedRepoRoot -Dir $repoI4
}

# Scenario 5: Configured path missing
Write-Output ''
Write-Output 'Find-IisExpressPath Scenario 5: Configured path points to non-existent file (friendly throw)'
$repoI5 = New-IsolatedRepoRoot 'tools'
try {
    Write-Toml -Path (Join-Path $repoI5 '.turbo-plugin\config.local.toml') -Content @"
[tools]
iis_express_path = "C:/this/path/does/not/exist/iisexpress.exe"
"@

    $threw = $false
    $errMsg = ''
    try {
        $null = Find-IisExpressPath -RepoRoot $repoI5
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }
    Assert-True -Name 'throws when configured path is missing' -Condition $threw -Detail "errMsg: $errMsg"
    if ($threw) {
        Assert-True -Name 'throw message references config.local.toml' -Condition ($errMsg -match 'config\.local\.toml') -Detail "got: $errMsg"
    }
} finally {
    Remove-IsolatedRepoRoot -Dir $repoI5
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output "─────────────────────────────────────────────────────────────────────"
Write-Output "Common.test: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
