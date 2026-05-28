# test_reset_fixture.ps1
#
# Hand-rolled assertion tests for Reset-Fixture.ps1 (style matches
# plugins/turbo-plugin/tests/unit/scripts-lib/test_resolve_config_value_merge.ps1).
#
# 不用 Pester。直接 Describe-less script with Assert-Equal / Assert-True / counters.
#
# 共 5 個 scenario (對齊 U1 Test scenarios):
#   1. Happy reset:          fresh base → reset → diff = empty
#   2. Dirty reset:          extras/garbage.txt → reset → garbage.txt 消失
#   3. 中文路徑 reset:       測試/含中文/subdir + 中文檔案.txt → reset 後完全還原
#   4. 中文 commit msg seed: r5 svn:log byte-level == 字典 #3 第 1 條
#   5. Idempotency:          連跑 2 次 reset → 第 2 次後 diff = empty
#
# Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <path-to-this-test.ps1>
# Exit code 0 = all pass, 1 = any failure.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Locate sibling scripts ───────────────────────────────────────────────────
#
# <repo>/plugins/turbo-plugin/tests/fixtures/reset/test_reset_fixture.ps1
#   -> ../base                                       (base fixture dir)
#   -> ./Reset-Fixture.ps1                           (system under test)
#   -> ../seed/svn-repo-r1-r20.dump                  (seed dump produced by build-seed-repo.ps1)

$resetScript = [System.IO.Path]::Combine($PSScriptRoot, 'Reset-Fixture.ps1')
$baseDir     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'base'))
$dumpPath    = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'seed', 'svn-repo-r1-r20.dump'))

if (-not (Test-Path -LiteralPath $resetScript -PathType Leaf)) {
    Write-Error "Reset-Fixture.ps1 not found at: $resetScript"
    exit 1
}
if (-not [System.IO.Directory]::Exists($baseDir)) {
    Write-Error "base fixture dir not found at: $baseDir"
    exit 1
}

$dumpExists = Test-Path -LiteralPath $dumpPath -PathType Leaf
if (-not $dumpExists) {
    Write-Output "NOTE: seed dump not found at $dumpPath."
    Write-Output "      Scenarios using -SkipSvn will run; SVN-touching scenarios (4) will be SKIPped."
    Write-Output "      Run plugins/turbo-plugin/tests/fixtures/seed/build-seed-repo.ps1 first for full coverage."
    Write-Output ""
}

# ─── Helpers (mirrors test_resolve_config_value_merge.ps1 style) ──────────────

$script:Passed   = 0
$script:Failed   = 0
$script:Skipped  = 0
$script:Failures = @()

function New-IsolatedFixtureRoot {
    # Each scenario gets its own sandbox dir (matches isolated repo root pattern).
    $tempDir = $env:TEMP
    try {
        $tempDir = (Get-Item -LiteralPath $tempDir).FullName
    } catch {
        # leave as-is
    }
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $sandbox = [System.IO.Path]::Combine($tempDir, "turbo-plugin-reset-test-$stamp")
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    return $sandbox
}

function Remove-IsolatedFixtureRoot {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        if ([System.IO.Directory]::Exists($Dir)) {
            # Use raw .NET API to sidestep PS 5.1 LiteralPath short-name bug.
            [System.IO.Directory]::Delete($Dir, $true)
        }
    } catch {
        # best-effort
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
        $msg = if ($Detail) { "${Name}: $Detail" } else { $Name }
        $script:Failures += $msg
        Write-Output "  [FAIL] $Name"
        if ($Detail) { Write-Output "         $Detail" }
    }
}

function Mark-Skip {
    param([string]$Name, [string]$Reason)
    $script:Skipped++
    Write-Output "  [SKIP] ${Name}: $Reason"
}

# Compare 2 directory trees:return $true if exact contents match (incl files / dirs / file bytes).
# Excludes nothing — caller passes only the parts they want compared.
function Test-DirsEqual {
    param(
        [Parameter(Mandatory = $true)][string]$A,
        [Parameter(Mandatory = $true)][string]$B
    )
    if (-not [System.IO.Directory]::Exists($A) -or -not [System.IO.Directory]::Exists($B)) {
        return $false
    }
    $filesA = @(Get-ChildItem -LiteralPath $A -Recurse -File -Force | ForEach-Object {
        $rel = Get-RelativePath -From $A -To $_.FullName
        [PSCustomObject]@{ Rel = $rel; Path = $_.FullName; Length = $_.Length }
    })
    $filesB = @(Get-ChildItem -LiteralPath $B -Recurse -File -Force | ForEach-Object {
        $rel = Get-RelativePath -From $B -To $_.FullName
        [PSCustomObject]@{ Rel = $rel; Path = $_.FullName; Length = $_.Length }
    })
    if ($filesA.Count -ne $filesB.Count) { return $false }

    $mapB = @{}
    foreach ($f in $filesB) { $mapB[$f.Rel.ToLower()] = $f }

    foreach ($fa in $filesA) {
        $key = $fa.Rel.ToLower()
        if (-not $mapB.ContainsKey($key)) { return $false }
        $fb = $mapB[$key]
        if ($fa.Length -ne $fb.Length) { return $false }
        $bytesA = [System.IO.File]::ReadAllBytes($fa.Path)
        $bytesB = [System.IO.File]::ReadAllBytes($fb.Path)
        if ($bytesA.Length -ne $bytesB.Length) { return $false }
        for ($i = 0; $i -lt $bytesA.Length; $i++) {
            if ($bytesA[$i] -ne $bytesB[$i]) { return $false }
        }
    }
    return $true
}

# Relative path helper that works under PS 5.1 (no [System.IO.Path]::GetRelativePath).
function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    $fromTrim = $From.TrimEnd('\','/')
    $toTrim   = $To
    if ($toTrim.StartsWith($fromTrim, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $toTrim.Substring($fromTrim.Length).TrimStart('\','/')
        return $rel
    }
    # Fallback via Uri MakeRelativeUri (rare case)
    $fromUri = New-Object System.Uri(($fromTrim + [System.IO.Path]::DirectorySeparatorChar))
    $toUri   = New-Object System.Uri($To)
    return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()) -replace '/', '\'
}

function Invoke-Reset {
    param(
        [string]$TestRoot,
        [string]$SvnRepo,
        [switch]$SkipSvn
    )
    $extra = @()
    if ($SkipSvn) { $extra += '-SkipSvn' }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $resetScript `
        -TestRoot $TestRoot -SvnRepo $SvnRepo @extra
    return $LASTEXITCODE
}

# ─── Scenario 1: Happy reset (fresh base → diff = empty) ──────────────────────

Write-Output ''
Write-Output 'Scenario 1: Happy reset (fresh base → diff = empty)'
$sb1 = New-IsolatedFixtureRoot
try {
    $testRoot = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    $svnRepo  = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin-svn-repo')

    $rc = Invoke-Reset -TestRoot $testRoot -SvnRepo $svnRepo -SkipSvn
    Assert-Equal -Name 'reset exit code 0' -Expected 0 -Actual $rc
    Assert-True -Name 'testRoot mirrors base contents' -Condition (Test-DirsEqual -A $baseDir -B $testRoot)
    Assert-True -Name 'HelloApp.csproj exists in test root' -Condition (Test-Path -LiteralPath ([System.IO.Path]::Combine($testRoot, 'HelloApp.csproj')) -PathType Leaf)
    Assert-True -Name '.turbo-plugin/config.toml exists in test root' -Condition (Test-Path -LiteralPath ([System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')) -PathType Leaf)
} finally {
    Remove-IsolatedFixtureRoot -Dir $sb1
}

# ─── Scenario 2: Dirty reset (garbage.txt + extras dir vanishes) ──────────────

Write-Output ''
Write-Output 'Scenario 2: Dirty reset (extras/garbage.txt → vanishes)'
$sb2 = New-IsolatedFixtureRoot
try {
    $testRoot = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    $svnRepo  = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin-svn-repo')

    # Pre-populate with dirty content.
    $extrasDir   = [System.IO.Path]::Combine($testRoot, 'extras')
    $garbageFile = [System.IO.Path]::Combine($extrasDir, 'garbage.txt')
    $null = New-Item -ItemType Directory -Path $extrasDir -Force
    [System.IO.File]::WriteAllText($garbageFile, 'this should disappear after reset')

    $rc = Invoke-Reset -TestRoot $testRoot -SvnRepo $svnRepo -SkipSvn
    Assert-Equal -Name 'reset exit code 0' -Expected 0 -Actual $rc
    Assert-True -Name 'extras/garbage.txt removed' -Condition (-not (Test-Path -LiteralPath $garbageFile))
    Assert-True -Name 'extras dir removed' -Condition (-not (Test-Path -LiteralPath $extrasDir))
    Assert-True -Name 'testRoot still matches base after dirty reset' -Condition (Test-DirsEqual -A $baseDir -B $testRoot)
} finally {
    Remove-IsolatedFixtureRoot -Dir $sb2
}

# ─── Scenario 3: 中文路徑 reset ────────────────────────────────────────────────

Write-Output ''
Write-Output 'Scenario 3: 中文路徑 reset (測試/含中文/subdir + 中文檔案.txt → vanishes)'
$sb3 = New-IsolatedFixtureRoot
try {
    $testRoot = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    $svnRepo  = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin-svn-repo')

    $cjkDir  = [System.IO.Path]::Combine($testRoot, '測試', '含中文', 'subdir')
    $cjkFile = [System.IO.Path]::Combine($cjkDir, '中文檔案.txt')
    $null = New-Item -ItemType Directory -Path $cjkDir -Force
    # Write with UTF-8 BOM for visibility (content's encoding is irrelevant to the test).
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($cjkFile, '中文 fixture body — should disappear', $utf8WithBom)

    $rc = Invoke-Reset -TestRoot $testRoot -SvnRepo $svnRepo -SkipSvn
    Assert-Equal -Name 'reset exit code 0' -Expected 0 -Actual $rc
    Assert-True -Name '中文檔案.txt removed' -Condition (-not (Test-Path -LiteralPath $cjkFile))
    Assert-True -Name '中文 dir 測試/含中文 removed' -Condition (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($testRoot, '測試'))))
    Assert-True -Name 'testRoot still matches base after 中文 reset' -Condition (Test-DirsEqual -A $baseDir -B $testRoot)
} finally {
    Remove-IsolatedFixtureRoot -Dir $sb3
}

# ─── Scenario 4: SVN seed 中文 commit msg (only if dump exists) ────────────────

Write-Output ''
Write-Output 'Scenario 4: SVN seed 中文 commit msg r5 byte-level == 字典 #3 第 1 條'
if (-not $dumpExists) {
    Mark-Skip -Name 'scenario 4' -Reason 'dump not yet built — run build-seed-repo.ps1 first'
} else {
    $sb4 = New-IsolatedFixtureRoot
    try {
        $testRoot = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
        $svnRepo  = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin-svn-repo')

        $rc = Invoke-Reset -TestRoot $testRoot -SvnRepo $svnRepo
        Assert-Equal -Name 'reset exit code 0 (with SVN)' -Expected 0 -Actual $rc
        Assert-True -Name 'SVN repo dir exists' -Condition ([System.IO.Directory]::Exists($svnRepo))
        Assert-True -Name 'remote-main worktree checked out' -Condition (Test-Path -LiteralPath ([System.IO.Path]::Combine($testRoot, '.worktrees', 'remote-main', '.svn')))
        Assert-True -Name 'remote-test-1 worktree checked out' -Condition (Test-Path -LiteralPath ([System.IO.Path]::Combine($testRoot, '.worktrees', 'remote-test-1', '.svn')))

        # Read r5 svn:log via svnlook (raw bytes, no console transcoding)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = 'svnlook'
        $psi.Arguments = "propget --revprop -r 5 `"$svnRepo`" svn:log"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $rawMem = New-Object System.IO.MemoryStream
        $proc.StandardOutput.BaseStream.CopyTo($rawMem)
        $proc.WaitForExit()
        $rawAll = $rawMem.ToArray()
        # Trim trailing 0x0A added by svnlook.
        $rawBytes = $rawAll
        if ($rawAll.Length -gt 0 -and $rawAll[$rawAll.Length - 1] -eq 0x0A) {
            $rawBytes = $rawAll[0..($rawAll.Length - 2)]
        }

        # Expected message = dict #3 entry #1 (kept in sync with build-seed-repo.ps1 / phase1-scripts-schema.md)
        $expectedMsg = '修正中文 commit 訊息亂碼'
        $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($expectedMsg)

        $byteMatch = ($rawBytes.Length -eq $expectedBytes.Length)
        if ($byteMatch) {
            for ($i = 0; $i -lt $expectedBytes.Length; $i++) {
                if ($rawBytes[$i] -ne $expectedBytes[$i]) { $byteMatch = $false; break }
            }
        }
        $detail = ''
        if (-not $byteMatch) {
            $detail = "expected $($expectedBytes.Length) bytes ($([System.Text.Encoding]::UTF8.GetString($expectedBytes))), got $($rawBytes.Length) bytes ($([System.Text.Encoding]::UTF8.GetString($rawBytes)))"
        }
        Assert-True -Name 'r5 svn:log bytes match 字典 #3 第 1 條' -Condition $byteMatch -Detail $detail
    } finally {
        Remove-IsolatedFixtureRoot -Dir $sb4
    }
}

# ─── Scenario 5: Idempotency (跑 2 次 reset, 第 2 次 diff = empty) ─────────────

Write-Output ''
Write-Output 'Scenario 5: Idempotency (2 consecutive resets → diff = empty)'
$sb5 = New-IsolatedFixtureRoot
try {
    $testRoot = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin')
    $svnRepo  = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin-svn-repo')

    $rc1 = Invoke-Reset -TestRoot $testRoot -SvnRepo $svnRepo -SkipSvn
    Assert-Equal -Name 'first reset exit code 0' -Expected 0 -Actual $rc1
    Assert-True -Name 'first reset matches base' -Condition (Test-DirsEqual -A $baseDir -B $testRoot)

    $rc2 = Invoke-Reset -TestRoot $testRoot -SvnRepo $svnRepo -SkipSvn
    Assert-Equal -Name 'second reset exit code 0' -Expected 0 -Actual $rc2
    Assert-True -Name 'second reset still matches base (idempotent)' -Condition (Test-DirsEqual -A $baseDir -B $testRoot)
} finally {
    Remove-IsolatedFixtureRoot -Dir $sb5
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
Write-Output "test_reset_fixture: passed=$script:Passed failed=$script:Failed skipped=$script:Skipped"
if ($script:Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
