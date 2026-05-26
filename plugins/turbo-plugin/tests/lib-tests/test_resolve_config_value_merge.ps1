# Unit test for Resolve-ConfigValue + Read-TurboPluginConfig merge behavior (U1).
#
# Verifies the 4 plan-defined scenarios:
#   1. Happy:        config.toml has [svn] force_bash, config.local.toml has [tools] msbuild_path
#                    -> both keys resolve correctly
#   2. Override:     config.toml [tools] msbuild_path = "A", config.local.toml same key = "B"
#                    -> returns "B" (local wins)
#   3. Missing local: config.local.toml does not exist
#                    -> falls back to config.toml without throwing
#   4. Both missing: neither file exists
#                    -> returns Default when provided, $null otherwise
#
# Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <path-to-this-test.ps1>
# Exit code 0 = all pass, 1 = any failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Locate common.ps1 relative to this test file:
#   <plugin>/tests/lib-tests/<this>.ps1  -> <plugin>/scripts/lib/common.ps1
$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$commonPs1  = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'common.ps1')
if (-not (Test-Path -LiteralPath $commonPs1 -PathType Leaf)) {
    Write-Error "common.ps1 not found at: $commonPs1"
    exit 1
}
. $commonPs1

# ─── Helpers ───────────────────────────────────────────────────────────────────

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function New-IsolatedRepoRoot {
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
    $dir = Join-Path $tempDir "turbo-plugin-test-$stamp"
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

function Write-Toml {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    Write-Utf8NoBom -Path $Path -Content $Content
}

# ─── Scenario 1: Happy path (different sections in each file) ──────────────────

Write-Output ''
Write-Output 'Scenario 1: Happy path (config.toml has [svn], config.local.toml has [tools])'
$repo1 = New-IsolatedRepoRoot
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
$repo2 = New-IsolatedRepoRoot
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
$repo3 = New-IsolatedRepoRoot
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
$repo4 = New-IsolatedRepoRoot
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
$repo5 = New-IsolatedRepoRoot
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

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output "─────────────────────────────────────────────────────────────────────"
Write-Output "test_resolve_config_value_merge: passed=$script:Passed failed=$script:Failed"
if ($script:Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
