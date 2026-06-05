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

# =============================================================================
# === assert-trusted-svn-url feature (U1) =====================================
# =============================================================================
#
# Verifies Assert-TrustedSvnUrl: boundary-safe + case-normalized + traversal-reject
# trust check anchored on the trusted working copy's repos-root-url (NOT trunk url).
#
# Uses the seed SVN dump (fixtures/seed/svn-repo-r1-r20.dump) loaded into a throwaway
# repo, checked out as a trusted working copy. The repo has trunk/ + branches/test-1/
# so we can prove a legitimate sibling branch passes (= repos-root, not trunk url).
# Fail-closed case uses an empty non-WC temp dir as the trusted reference.

Write-Output ''
Write-Output '═════════════════════════════════════════════════════════════════════'
Write-Output '═══ assert-trusted-svn-url feature (U1) ═══'
Write-Output '═════════════════════════════════════════════════════════════════════'

$svnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $svnAvailable = ($LASTEXITCODE -eq 0)
} catch {
    $svnAvailable = $false
}

$dumpPathU1 = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

function Invoke-AssertTrusted {
    # Returns @{ Threw = <bool>; Result = <string>; Message = <string> }
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

if (-not $svnAvailable) {
    Write-Output '  [SKIP] svn not on PATH — Assert-TrustedSvnUrl seed-backed cases skipped.'
} elseif (-not [System.IO.File]::Exists($dumpPathU1)) {
    Write-Output "  [SKIP] seed dump missing at $dumpPathU1 — run Build-SeedRepo.ps1."
} else {
    $sandboxU1 = New-IsolatedRepoRoot 'trusturl'
    $svnRepo = $null
    try {
        $svnRepo = [System.IO.Path]::Combine($sandboxU1, 'svnrepo')
        $wc      = [System.IO.Path]::Combine($sandboxU1, 'wc')
        $emptyNonWc = [System.IO.Path]::Combine($sandboxU1, 'empty-non-wc')
        $null = New-Item -ItemType Directory -Path $emptyNonWc -Force

        & svnadmin create $svnRepo
        $createOk = ($LASTEXITCODE -eq 0)

        # Load the seed dump via cmd /c stdin redirect (mirrors Reset-Fixture's F-2 symmetry).
        $loadOk = $false
        if ($createOk) {
            $loadCmd = "svnadmin load `"$svnRepo`" < `"$dumpPathU1`""
            & cmd.exe /c $loadCmd > $null 2>&1
            $loadOk = ($LASTEXITCODE -eq 0)
        }

        if (-not $loadOk) {
            Write-Output '  [SKIP] svnadmin create/load failed (likely dump LF→CRLF mangle); cannot build trust fixture.'
        } else {
            $repoUri = 'file:///' + ($svnRepo -replace '\\', '/')
            & svn checkout "$repoUri/trunk" $wc > $null 2>&1
            $coOk = ($LASTEXITCODE -eq 0)
            $reposRoot = (& svn info --show-item repos-root-url $wc 2>$null | Out-String).Trim()

            if (-not $coOk -or [string]::IsNullOrWhiteSpace($reposRoot)) {
                Write-Output '  [SKIP] svn checkout of trusted WC failed; cannot build trust fixture.'
            } else {
                Write-Output ''
                Write-Output "  (trusted repos-root-url = $reposRoot)"

                # Case 1: same-repo trunk URL → pass
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/trunk"
                Assert-True -Name 'same-repo trunk URL is trusted' -Condition (-not $r.Threw) -Detail $r.Message

                # Case 2: legitimate sibling branch (branches/test-1) → pass
                #         (proves trust base is repos-root, not trunk url)
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/branches/test-1"
                Assert-True -Name 'legit sibling branches/test-1 is trusted (repos-root, not trunk)' -Condition (-not $r.Threw) -Detail $r.Message

                # Case 3: prefix-confusion <root>-evil/trunk → reject
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot-evil/trunk"
                Assert-True -Name 'prefix-confusion <root>-evil/trunk is rejected (R10)' -Condition $r.Threw -Detail "unexpectedly accepted: $($r.Result)"

                # Case 4: uppercase scheme variant FILE:///... → normalized, still trusted
                $upperScheme = $reposRoot -replace '^file://', 'FILE://'
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$upperScheme/trunk"
                Assert-True -Name 'uppercase scheme FILE:// normalizes and is trusted (R11)' -Condition (-not $r.Threw) -Detail $r.Message

                # Case 5: candidate trailing-slash variant → same result as no trailing slash
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/branches/test-1/"
                Assert-True -Name 'trailing-slash candidate matches no-slash result (trusted)' -Condition (-not $r.Threw) -Detail $r.Message

                # Case 6: out-of-bounds file:///C:/Windows/... → reject
                $r = Invoke-AssertTrusted -Wc $wc -Candidate 'file:///C:/Windows/System32/'
                Assert-True -Name 'out-of-bounds file:///C:/Windows/... is rejected' -Condition $r.Threw -Detail "unexpectedly accepted: $($r.Result)"

                # Case 7: different host/scheme http://attacker/... → reject
                $r = Invoke-AssertTrusted -Wc $wc -Candidate 'http://attacker.example/repo'
                Assert-True -Name 'different scheme/host http://attacker/... is rejected' -Condition $r.Threw -Detail "unexpectedly accepted: $($r.Result)"

                # Case 8: path traversal in candidate → reject
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/trunk/../../etc"
                Assert-True -Name "candidate with '..' traversal is rejected" -Condition $r.Threw -Detail "unexpectedly accepted: $($r.Result)"

                # Case 8b: percent-encoded traversal %2e%2e under base → reject (decode-then-recheck)
                $r = Invoke-AssertTrusted -Wc $wc -Candidate "$reposRoot/trunk/%2e%2e/%2e%2e/etc"
                Assert-True -Name 'percent-encoded ..(%2e%2e) traversal is rejected after decode' -Condition $r.Threw -Detail "unexpectedly accepted: $($r.Result)"

                # Case 9: fail-closed — empty non-WC reference dir → throw (cannot be bypassed)
                $r = Invoke-AssertTrusted -Wc $emptyNonWc -Candidate "$reposRoot/trunk"
                Assert-True -Name 'fail-closed: non-WC trusted reference throws (not silently passes)' -Condition $r.Threw -Detail "unexpectedly accepted: $($r.Result)"
                if ($r.Threw) {
                    Assert-True -Name 'fail-closed message mentions fail closed / repos-root-url' -Condition ($r.Message -match '(fail closed|repos-root-url)') -Detail $r.Message
                }
            }
        }
    } finally {
        Remove-IsolatedRepoRoot -Dir $sandboxU1
    }
}

# =============================================================================
# === lib helper unit coverage (U7) ===========================================
# =============================================================================
#
# Direct unit tests for the previously-untested Common.ps1 helpers (R7) plus the
# Write-Utf8NoBom CJK no-BOM byte gate (R6). Every case calls the real dot-sourced
# function — no logic is reproduced in the test.
#
# Helpers covered:
#   Get-RelativePathSafe       (P0 regression: $From == $To -> '', per F-U2.9)
#   Get-ProjectIdentityHash    (determinism / case-normalization / cross-repo isolation)
#   Get-NormalizedAbsolutePath (Git-Bash /c/... + drive-letter lowercase + empty throw)
#   Resolve-RemoteWorktree     (main / test-<n> / unsupported throw)
#   Format-IisExpressSiteName  (ASCII + CJK csproj stem preserved)
#   Find-SingleCsproj          (single / zero throw / multiple throw)
#   schema_version warning     (=1/=2 silent, =3 stderr warning per actual code)
#   Write-Utf8NoBom            (CJK content -> no BOM + canonical UTF-8 bytes, R6)

# Two extra inline asserts mirroring AssertHelpers shape but wired to this file's
# own $script:Passed/$script:Failed counters (this test does NOT dot-source
# AssertHelpers.ps1 — it keeps its self-contained counter style).
function Assert-Match2 {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [string]$InputText
    )
    $text = if ($null -eq $InputText) { '' } else { [string]$InputText }
    if ($text -match $Pattern) {
        $script:Passed++
        Write-Output "  [PASS] $Name"
    } else {
        $script:Failed++
        $script:Failures += "${Name}: pattern '$Pattern' did not match '$text'"
        Write-Output "  [FAIL] $Name"
        Write-Output "         pattern: $Pattern"
        Write-Output "         input:   $text"
    }
}

function Assert-Throws2 {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$ExpectedMessagePattern = ''
    )
    $threw = $false; $msg = ''
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw = $true; $msg = $_.Exception.Message
    }
    if (-not $threw) {
        $script:Failed++
        $script:Failures += "${Name}: expected throw, none occurred"
        Write-Output "  [FAIL] $Name (expected throw, none occurred)"
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMessagePattern) -and ($msg -notmatch $ExpectedMessagePattern)) {
        $script:Failed++
        $script:Failures += "${Name}: threw but message '$msg' did not match '$ExpectedMessagePattern'"
        Write-Output "  [FAIL] $Name (message mismatch)"
        Write-Output "         pattern: $ExpectedMessagePattern"
        Write-Output "         message: $msg"
        return
    }
    $script:Passed++
    Write-Output "  [PASS] $Name"
}

function Assert-FileBytesEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ActualFilePath
    )
    if (-not [System.IO.File]::Exists($ActualFilePath)) {
        $script:Failed++
        $script:Failures += "${Name}: file does not exist: $ActualFilePath"
        Write-Output "  [FAIL] $Name (file missing: $ActualFilePath)"
        return
    }
    $actual = [System.IO.File]::ReadAllBytes($ActualFilePath)
    if ($actual.Length -ne $ExpectedBytes.Length) {
        $script:Failed++
        $script:Failures += "${Name}: byte length mismatch exp=$($ExpectedBytes.Length) act=$($actual.Length)"
        Write-Output "  [FAIL] $Name (length exp=$($ExpectedBytes.Length) act=$($actual.Length))"
        return
    }
    for ($i = 0; $i -lt $ExpectedBytes.Length; $i++) {
        if ($ExpectedBytes[$i] -ne $actual[$i]) {
            $script:Failed++
            $script:Failures += "${Name}: byte mismatch at offset $i exp=0x$('{0:X2}' -f $ExpectedBytes[$i]) act=0x$('{0:X2}' -f $actual[$i])"
            Write-Output "  [FAIL] $Name (offset $i exp=0x$('{0:X2}' -f $ExpectedBytes[$i]) act=0x$('{0:X2}' -f $actual[$i]))"
            return
        }
    }
    $script:Passed++
    Write-Output "  [PASS] $Name"
}

Write-Output ''
Write-Output '═════════════════════════════════════════════════════════════════════'
Write-Output '═══ lib helper unit coverage (U7) ═══'
Write-Output '═════════════════════════════════════════════════════════════════════'

# ─── Get-RelativePathSafe (P0 regression — F-U2.9) ─────────────────────────────

Write-Output ''
Write-Output '─── Get-RelativePathSafe ───'

# Three normal path inputs.
$relChild = Get-RelativePathSafe -From 'C:\proj' -To 'C:\proj\sub\file.txt'
Assert-Equal -Name 'child path -> sub\file.txt' -Expected ('sub' + [System.IO.Path]::DirectorySeparatorChar + 'file.txt') -Actual $relChild

$relSibling = Get-RelativePathSafe -From 'C:\proj\a' -To 'C:\proj\b\x.cs'
Assert-Equal -Name 'sibling path -> ..\b\x.cs' -Expected ('..' + [System.IO.Path]::DirectorySeparatorChar + 'b' + [System.IO.Path]::DirectorySeparatorChar + 'x.cs') -Actual $relSibling

$relNested = Get-RelativePathSafe -From 'C:\a\b\c' -To 'C:\a\d\e.txt'
Assert-Equal -Name 'nested up-then-down -> ..\..\d\e.txt' -Expected ('..' + [System.IO.Path]::DirectorySeparatorChar + '..' + [System.IO.Path]::DirectorySeparatorChar + 'd' + [System.IO.Path]::DirectorySeparatorChar + 'e.txt') -Actual $relNested

# REGRESSION (F-U2.9, commit 25fb77a): the original triggering input was
# `Get-RelativePathSafe -From X -To X` (same path). Before the fix MakeRelativeUri's
# result was ambiguous (could be '' or '../<basename>') depending on trailing-separator
# state; the fix defines the same-path contract as returning ''.
$regSame = Get-RelativePathSafe -From 'C:\proj\sub' -To 'C:\proj\sub'
Assert-Equal -Name 'REGRESSION F-U2.9: From==To returns empty string' -Expected '' -Actual $regSame

# Same regression, trailing-slash variant on one side — must still normalize to ''
# (the fix trims trailing separators on BOTH ends before the same-path check).
$regSameSlash = Get-RelativePathSafe -From 'C:\proj\sub' -To 'C:\proj\sub\'
Assert-Equal -Name 'REGRESSION F-U2.9: From==To (trailing-slash variant) returns empty string' -Expected '' -Actual $regSameSlash

# ─── Get-ProjectIdentityHash ───────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Get-ProjectIdentityHash ───'

function New-GitRepoFixture {
    param([string]$Tag = 'hash')
    $dir = New-IsolatedRepoRoot $Tag
    & git -C $dir init --quiet 2>$null | Out-Null
    return $dir
}

$ghGitOk = $true
try { $null = (& git --version 2>$null); $ghGitOk = ($LASTEXITCODE -eq 0) } catch { $ghGitOk = $false }

if (-not $ghGitOk) {
    Write-Output '  [SKIP] git not on PATH — Get-ProjectIdentityHash cases skipped.'
} else {
    $ghRepoA = New-GitRepoFixture 'hashA'
    $ghRepoB = New-GitRepoFixture 'hashB'
    try {
        # Determinism: same repo + same csproj relpath -> identical hash.
        $hA1 = Get-ProjectIdentityHash -RepoPath $ghRepoA -CsprojRelPath 'src/App.csproj'
        $hA2 = Get-ProjectIdentityHash -RepoPath $ghRepoA -CsprojRelPath 'src/App.csproj'
        Assert-Equal -Name 'determinism: same inputs -> same hash' -Expected $hA1 -Actual $hA2
        Assert-Match2 -Name 'hash is 8 lowercase hex chars' -Pattern '^[0-9a-f]{8}$' -InputText $hA1

        # Case-normalization: csproj relpath case + slash direction folded -> same hash.
        $hCaseLower = Get-ProjectIdentityHash -RepoPath $ghRepoA -CsprojRelPath 'src/app.csproj'
        $hCaseUpper = Get-ProjectIdentityHash -RepoPath $ghRepoA -CsprojRelPath 'SRC/APP.CSPROJ'
        Assert-Equal -Name 'case-normalization: lower/upper csproj relpath -> same hash' -Expected $hCaseLower -Actual $hCaseUpper

        # Backslash vs forward-slash relpath also folds to the same identity.
        $hBackslash = Get-ProjectIdentityHash -RepoPath $ghRepoA -CsprojRelPath 'src\App.csproj'
        Assert-Equal -Name 'slash-normalization: back/forward slash -> same hash' -Expected $hA1 -Actual $hBackslash

        # Cross-repo isolation: two DIFFERENT git repos, identical csproj relpath -> DIFFERENT hash
        # (proves the git-common-dir is folded into the identity, not just the relpath).
        $hB1 = Get-ProjectIdentityHash -RepoPath $ghRepoB -CsprojRelPath 'src/App.csproj'
        Assert-True -Name 'cross-repo isolation: distinct repos, same relpath -> distinct hash' -Condition ($hA1 -ne $hB1) -Detail "repoA=$hA1 repoB=$hB1"

        # Non-git path -> throw.
        $ghNonGit = New-IsolatedRepoRoot 'hashNonGit'
        try {
            Assert-Throws2 -Name 'non-git RepoPath throws' -ScriptBlock { Get-ProjectIdentityHash -RepoPath $ghNonGit -CsprojRelPath 'src/App.csproj' } -ExpectedMessagePattern 'Not a git repository'
        } finally {
            Remove-IsolatedRepoRoot -Dir $ghNonGit
        }
    } finally {
        Remove-IsolatedRepoRoot -Dir $ghRepoA
        Remove-IsolatedRepoRoot -Dir $ghRepoB
    }
}

# ─── Get-NormalizedAbsolutePath ────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Get-NormalizedAbsolutePath ───'

# Git-Bash style /c/Users/... -> C:\Users\... with lowercase drive letter.
$gnGitBash = Get-NormalizedAbsolutePath -Path '/c/Users/test/proj'
Assert-Match2 -Name 'Git-Bash /c/... -> c:\... (drive lowercased, backslashes)' -Pattern '^c:\\Users\\test\\proj$' -InputText $gnGitBash

# Uppercase drive letter input is lowercased.
$gnUpper = Get-NormalizedAbsolutePath -Path 'C:\Temp\Thing'
Assert-Match2 -Name 'uppercase drive C:\ lowercased to c:\' -Pattern '^c:\\' -InputText $gnUpper

# Mixed forward slashes get a full normalized absolute path back.
$gnFwd = Get-NormalizedAbsolutePath -Path 'D:/data/sub'
Assert-Match2 -Name 'forward-slash absolute path normalizes to d:\data\sub' -Pattern '^d:\\data\\sub$' -InputText $gnFwd

# Empty / whitespace input throws. ('' is rejected at Mandatory-param binding before
# the body runs; whitespace reaches the function's own 'empty path' guard.)
Assert-Throws2 -Name 'empty path throws (param binding)' -ScriptBlock { Get-NormalizedAbsolutePath -Path '' }
Assert-Throws2 -Name 'whitespace path throws (function guard)' -ScriptBlock { Get-NormalizedAbsolutePath -Path '   ' } -ExpectedMessagePattern 'empty path'

# ─── Resolve-RemoteWorktree ────────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Resolve-RemoteWorktree ───'

$wtDir = 'C:\proj.worktrees'

$rwMain = Resolve-RemoteWorktree -BranchName 'main' -WorktreesDir $wtDir
Assert-Equal -Name 'main -> Name remote-svn-main' -Expected 'remote-svn-main' -Actual $rwMain.Name
Assert-Equal -Name 'main -> Branch remote-svn/main' -Expected 'remote-svn/main' -Actual $rwMain.Branch
Assert-Equal -Name 'main -> Path <wt>\remote-svn-main' -Expected (Join-Path $wtDir 'remote-svn-main') -Actual $rwMain.Path

$rwTest = Resolve-RemoteWorktree -BranchName 'test-3' -WorktreesDir $wtDir
Assert-Equal -Name 'test-3 -> Name remote-svn-test-3' -Expected 'remote-svn-test-3' -Actual $rwTest.Name
Assert-Equal -Name 'test-3 -> Branch remote-svn/test-3' -Expected 'remote-svn/test-3' -Actual $rwTest.Branch
Assert-Equal -Name 'test-3 -> Path <wt>\remote-svn-test-3' -Expected (Join-Path $wtDir 'remote-svn-test-3') -Actual $rwTest.Path

Assert-Throws2 -Name 'unsupported branch (feature/x) throws' -ScriptBlock { Resolve-RemoteWorktree -BranchName 'feature/x' -WorktreesDir $wtDir } -ExpectedMessagePattern "Only 'main' and 'test-<n>'"

# ─── Get-WorktreesDir (U1) ─────────────────────────────────────────────────────
#
# happy: given an explicit -MainWorktree, returns <main>/.turbo-plugin/worktrees
# (the v1.0 nested container location, built via [System.IO.Path]::Combine).

Write-Output ''
Write-Output '─── Get-WorktreesDir ───'

$gwMain = 'C:\proj\main'
$gwExpected = [System.IO.Path]::Combine($gwMain, '.turbo-plugin', 'worktrees')
$gwActual = Get-WorktreesDir -MainWorktree $gwMain
Assert-Equal -Name 'explicit MainWorktree -> <main>\.turbo-plugin\worktrees' -Expected $gwExpected -Actual $gwActual

# The container is nested inside the main worktree (NOT a sibling "<proj>.worktrees").
Assert-True -Name 'result is nested under the main worktree' -Condition ($gwActual.StartsWith($gwMain, [System.StringComparison]::OrdinalIgnoreCase)) -Detail "got: $gwActual"
Assert-True -Name 'result ends with .turbo-plugin\worktrees' -Condition ($gwActual -match '\.turbo-plugin[\\/]worktrees$') -Detail "got: $gwActual"

# ─── Format-IisExpressSiteName ─────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Format-IisExpressSiteName ───'

# ASCII csproj stem.
$siteAscii = Format-IisExpressSiteName -CsprojPath 'C:\proj\src\HelloApp.csproj' -IdentityHash 'deadbeef'
Assert-Equal -Name 'ASCII csproj stem -> HelloApp-deadbeef' -Expected 'HelloApp-deadbeef' -Actual $siteAscii

# CJK csproj stem (dictionary 2.3 stem `報表範本`) — non-ASCII must be preserved verbatim.
$cjkStemName = '報表範本'
$siteCjk = Format-IisExpressSiteName -CsprojPath ("C:\proj\src\$cjkStemName.csproj") -IdentityHash 'cafe1234'
Assert-Equal -Name 'CJK csproj stem preserved (報表範本-cafe1234)' -Expected ("$cjkStemName-cafe1234") -Actual $siteCjk

# ─── Find-SingleCsproj ─────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─── Find-SingleCsproj ───'

# Single .csproj present (no config / no CLI) -> returns it.
$fcSingle = New-IsolatedRepoRoot 'csproj-single'
try {
    $onlyCsproj = Join-Path $fcSingle 'OnlyOne.csproj'
    Set-Content -LiteralPath $onlyCsproj -Value '<Project/>' -Encoding ASCII
    $found = Find-SingleCsproj -RepoRoot $fcSingle -CliProjectValue ''
    Assert-Equal -Name 'single .csproj is returned' -Expected ([System.IO.Path]::GetFullPath($onlyCsproj)) -Actual ([System.IO.Path]::GetFullPath($found))
} finally {
    Remove-IsolatedRepoRoot -Dir $fcSingle
}

# Zero .csproj -> throw.
$fcZero = New-IsolatedRepoRoot 'csproj-zero'
try {
    Assert-Throws2 -Name 'zero .csproj throws' -ScriptBlock { Find-SingleCsproj -RepoRoot $fcZero -CliProjectValue '' } -ExpectedMessagePattern 'No \.csproj found'
} finally {
    Remove-IsolatedRepoRoot -Dir $fcZero
}

# Multiple .csproj -> throw.
$fcMulti = New-IsolatedRepoRoot 'csproj-multi'
try {
    Set-Content -LiteralPath (Join-Path $fcMulti 'A.csproj') -Value '<Project/>' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $fcMulti 'B.csproj') -Value '<Project/>' -Encoding ASCII
    Assert-Throws2 -Name 'multiple .csproj throws' -ScriptBlock { Find-SingleCsproj -RepoRoot $fcMulti -CliProjectValue '' } -ExpectedMessagePattern 'Multiple \.csproj'
} finally {
    Remove-IsolatedRepoRoot -Dir $fcMulti
}

# ─── schema_version warning (Read-TurboPluginConfig / Test-TurboPluginConfigSchema) ─
#
# Actual code (Test-TurboPluginConfigSchema): versions 1 AND 2 are recognized
# (no warning); only an UNrecognized version (e.g. 3) emits a stderr warning, and
# only ONCE per process (guarded by $script:_TpSchemaWarned). The test resets that
# module-scope guard between cases so each is observed independently.

Write-Output ''
Write-Output '─── schema_version warning ───'

function Get-SchemaWarningStderr {
    param([Parameter(Mandatory = $true)][int]$Version)
    # Reset the once-per-process guard so this invocation can warn.
    Set-Variable -Name '_TpSchemaWarned' -Scope Script -Value $false
    $repo = New-IsolatedRepoRoot 'schema'
    $stderrFile = Join-Path $repo 'stderr.txt'
    try {
        Write-Utf8NoBom -Path (Join-Path $repo '.turbo-plugin\config.toml') -Content @"
schema_version = $Version
[tools]
msbuild_path = "C:/x.exe"
"@
        # Capture [Console]::Error output by redirecting the process stderr stream.
        $prevErr = [Console]::Error
        $sw = New-Object System.IO.StringWriter
        [Console]::SetError($sw)
        try {
            $null = Resolve-ConfigValue -RepoRoot $repo -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
        } finally {
            [Console]::SetError($prevErr)
        }
        return $sw.ToString()
    } finally {
        Remove-IsolatedRepoRoot -Dir $repo
    }
}

$stderrV1 = Get-SchemaWarningStderr -Version 1
Assert-True -Name 'schema_version=1 emits NO warning' -Condition ([string]::IsNullOrWhiteSpace($stderrV1)) -Detail "stderr: $stderrV1"

$stderrV2 = Get-SchemaWarningStderr -Version 2
Assert-True -Name 'schema_version=2 emits NO warning' -Condition ([string]::IsNullOrWhiteSpace($stderrV2)) -Detail "stderr: $stderrV2"

$stderrV3 = Get-SchemaWarningStderr -Version 3
Assert-Match2 -Name 'schema_version=3 (unrecognized) emits stderr warning' -Pattern 'schema_version=3 is not recognized' -InputText $stderrV3

# ─── Write-Utf8NoBom (R6 — CJK no-BOM byte gate) ───────────────────────────────
#
# The real encoding gate Submit-SvnCommit depends on when writing a CJK commit
# message to the UTF-8 temp file handed to `svn commit --file ... --encoding UTF-8`.
# CJK content (dictionary 5.5, includes an em-dash) must be written WITHOUT a BOM
# and byte-identical to canonical UTF-8.

Write-Output ''
Write-Output '─── Write-Utf8NoBom (R6) ───'

$wuRepo = New-IsolatedRepoRoot 'utf8nobom'
try {
    $cjkContent = '組態載入完成 — 中文路徑支援已啟用'   # schema dict 5.5 (CJK + em-dash)
    $wuFile = Join-Path $wuRepo 'msg.txt'
    Write-Utf8NoBom -Path $wuFile -Content $cjkContent

    $bytes = [System.IO.File]::ReadAllBytes($wuFile)
    # First 3 bytes must NOT be the UTF-8 BOM EF BB BF.
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True -Name 'Write-Utf8NoBom: file does NOT start with UTF-8 BOM (EF BB BF)' -Condition (-not $hasBom) -Detail ("first bytes: " + (($bytes | Select-Object -First 3 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))

    # Byte content equals canonical UTF-8 (no-BOM) encoding of the CJK string.
    $canonical = (New-Object System.Text.UTF8Encoding($false)).GetBytes($cjkContent)
    Assert-FileBytesEqual -Name 'Write-Utf8NoBom: bytes equal canonical UTF-8 (no BOM)' -ExpectedBytes $canonical -ActualFilePath $wuFile
} finally {
    Remove-IsolatedRepoRoot -Dir $wuRepo
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
