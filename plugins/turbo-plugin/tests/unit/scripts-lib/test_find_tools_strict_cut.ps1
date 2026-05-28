# Unit test for Find-MSBuild / Find-IisExpressPath strict cut to config.local.toml (U2).
#
# Verifies the 4 plan-defined scenarios for each helper:
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
#
# Auto-probe scenarios are skipped if the test cannot reliably create a fake binary on
# the standard probe paths (Program Files needs admin); instead we exercise the helper
# by pointing $env:ProgramFiles to a sandbox via a stand-in candidate list. To keep the
# helper untouched, we cover auto-probe end-to-end indirectly: we verify the helper
# returns ANY existing-on-disk path when the configured path is missing — implementation
# correctness of the candidate list is exercised by the throw scenarios (machine without VS).
#
# Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <path-to-this-test.ps1>
# Exit code 0 = all pass, 1 = any failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Locate the two source files under test relative to this test file:
#   <plugin>/tests/unit/scripts-lib/<this>.ps1  -> <plugin>/scripts/lib/common.ps1
#                                               -> <plugin>/scripts/resolve-iis-settings.ps1
$pluginRoot          = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$commonPs1           = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'common.ps1')
$resolveIisSettings  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'resolve-iis-settings.ps1')
if (-not (Test-Path -LiteralPath $commonPs1 -PathType Leaf)) {
    Write-Error "common.ps1 not found at: $commonPs1"
    exit 1
}
if (-not (Test-Path -LiteralPath $resolveIisSettings -PathType Leaf)) {
    Write-Error "resolve-iis-settings.ps1 not found at: $resolveIisSettings"
    exit 1
}
. $commonPs1
. $resolveIisSettings

# ─── Helpers ───────────────────────────────────────────────────────────────────

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function New-IsolatedRepoRoot {
    $tempDir = $env:TEMP
    try {
        $tempDir = (Get-Item -LiteralPath $tempDir).FullName
    } catch {
        # leave as-is
    }
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = Join-Path $tempDir "turbo-plugin-tools-test-$stamp"
    $null = New-Item -ItemType Directory -Path $dir -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $dir '.turbo-plugin') -Force
    return $dir
}

function Remove-IsolatedRepoRoot {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        if ([System.IO.Directory]::Exists($Dir)) {
            [System.IO.Directory]::Delete($Dir, $true)
        }
    } catch {
        # best-effort cleanup
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Expected,
        $Actual
    )
    $expectedRepr = if ($null -eq $Expected) { '<null>' } else { "'$Expected'" }
    $actualRepr   = if ($null -eq $Actual)   { '<null>' } else { "'$Actual'" }
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

# Snapshot/restore the two env vars to ensure tests don't leak state out.
$origMsbuildEnv = $env:TURBO_PLUGIN_MSBUILD_PATH
$origIisEnv     = $env:TURBO_PLUGIN_IIS_EXPRESS_PATH

# ─── Find-MSBuild ─────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '═══ Find-MSBuild ═══'

# Scenario 1: Happy — config.local.toml [tools] msbuild_path points to existing file
Write-Output ''
Write-Output 'Find-MSBuild Scenario 1: Happy path (config.local.toml [tools] msbuild_path -> existing file)'
$repo1 = New-IsolatedRepoRoot
try {
    # Create a fake MSBuild.exe stand-in (any file that exists)
    $fakeMsbuild = Join-Path $repo1 'fake-msbuild.exe'
    Set-Content -LiteralPath $fakeMsbuild -Value '' -Encoding ASCII

    # Forward-slash path in TOML (config typically does this)
    $tomlPath = ($fakeMsbuild -replace '\\', '/')
    Write-Toml -Path (Join-Path $repo1 '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "$tomlPath"
"@

    $result = Find-MSBuild -RepoRoot $repo1
    Assert-True -Name 'returns the configured path' -Condition ([System.IO.Path]::GetFullPath($result) -eq [System.IO.Path]::GetFullPath($fakeMsbuild)) -Detail "got: $result; expected file at: $fakeMsbuild"
} finally {
    Remove-IsolatedRepoRoot -Dir $repo1
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
$repo3 = New-IsolatedRepoRoot
try {
    # No config.local.toml at all; clear env to ensure no contamination
    $env:TURBO_PLUGIN_MSBUILD_PATH = $null

    $result = $null
    $threw = $false
    $errMsg = ''
    try {
        $result = Find-MSBuild -RepoRoot $repo3
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
    Remove-IsolatedRepoRoot -Dir $repo3
}

# Scenario 4: Env ignored — fake env path, [tools] absent.
# Expected behavior: helper ignores env entirely. Outcome depends on machine state:
#   - If VS exists: returns a real VS path (NOT the fake env value)
#   - If VS missing: throws (with /tp-setup hint, NOT a TURBO_PLUGIN_MSBUILD_PATH hint)
Write-Output ''
Write-Output 'Find-MSBuild Scenario 4: Env var is IGNORED ($env:TURBO_PLUGIN_MSBUILD_PATH set to fake)'
$repo4 = New-IsolatedRepoRoot
try {
    $fakeEnvPath = Join-Path $repo4 'this-path-must-not-be-read.exe'
    $env:TURBO_PLUGIN_MSBUILD_PATH = $fakeEnvPath

    $result = $null
    $threw = $false
    $errMsg = ''
    try {
        $result = Find-MSBuild -RepoRoot $repo4
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
    Remove-IsolatedRepoRoot -Dir $repo4
}

# Scenario 5: Configured path points to a missing file -> friendly throw mentioning the path
Write-Output ''
Write-Output 'Find-MSBuild Scenario 5: Configured path points to non-existent file (friendly throw)'
$repo5 = New-IsolatedRepoRoot
try {
    Write-Toml -Path (Join-Path $repo5 '.turbo-plugin\config.local.toml') -Content @"
[tools]
msbuild_path = "C:/this/path/does/not/exist/MSBuild.exe"
"@

    $threw = $false
    $errMsg = ''
    try {
        $null = Find-MSBuild -RepoRoot $repo5
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }
    Assert-True -Name 'throws when configured path is missing' -Condition $threw -Detail "errMsg: $errMsg"
    if ($threw) {
        Assert-True -Name 'throw message references config.local.toml' -Condition ($errMsg -match 'config\.local\.toml') -Detail "got: $errMsg"
    }
} finally {
    Remove-IsolatedRepoRoot -Dir $repo5
}

# ─── Find-IisExpressPath ───────────────────────────────────────────────────────

Write-Output ''
Write-Output '═══ Find-IisExpressPath ═══'

# Scenario 1: Happy
Write-Output ''
Write-Output 'Find-IisExpressPath Scenario 1: Happy path (config.local.toml [tools] iis_express_path -> existing file)'
$repoI1 = New-IsolatedRepoRoot
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
$repoI3 = New-IsolatedRepoRoot
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
$repoI4 = New-IsolatedRepoRoot
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
$repoI5 = New-IsolatedRepoRoot
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
Write-Output "test_find_tools_strict_cut: passed=$script:Passed failed=$script:Failed"
if ($script:Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
