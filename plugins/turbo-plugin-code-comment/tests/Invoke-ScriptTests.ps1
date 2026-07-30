# Invoke-ScriptTests.ps1
#
# turbo-plugin script-tests orchestrator (Pester 5).
#
# Pipeline:
#   1. Lint pre-flight (tools/lint-ps-compat.ps1 over scripts/). Skipped by -SkipPreflight.
#      Failure => exit 1.
#   2. Framework gate (ALWAYS, even with -SkipPreflight): Import-Module Pester
#      -MinimumVersion 5.0. Pester 5 absent (or only the WinPS-builtin 3.4 resolvable)
#      => exit 1. This is the R20 "framework missing is a FAIL, not a SKIP" gate; it must
#      run regardless of -SkipPreflight (R3-3) so a Pester-less runner can never go green.
#   3. Resolve BashPath for .sh (Windows Git Bash only; non-Windows does NOT resolve, so
#      the .sh suite SKIPs here and is owned by the bash orchestrator — avoids double-run, R3-4).
#   4. Discover *.test.ps1 + *.test.sh under tests/unit and tests/fixtures.
#   5. Run each *.test.ps1 via Invoke-Pester (one file per Invoke-Pester call for isolation),
#      resetting the shared fixture before each (best-effort; -SkipReset to skip).
#   6. Run each *.test.sh via bash (shUnit2), exit-code based, when BashPath resolves.
#   7. Summary + exit. 0 = all PASS (SKIP counts as green); 1 = any FAIL / framework gate fail.
#
# Exit codes (0/1 contract, U16): 0 = success (incl. legal SKIP); 1 = any failure (lint,
# test FAIL, or framework-missing gate). No exit 2.
#
# Params:
#   -RepoRoot        repo root (default = 3 levels up from this script)
#   -SkipPreflight   skip ONLY the lint pre-flight (framework + fixture handling still run)
#   -SkipReset       skip the per-file Reset-Fixture call (local dev iterate)
#   -BashPath        explicit Git Bash bash.exe path (Windows; default tries standard locations)

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$SkipPreflight,
    [switch]$SkipReset,
    [string]$BashPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# PS executable for child processes: Windows PowerShell 5.1 (Desktop) ships `powershell`;
# PowerShell 7+ (Core, e.g. the ubuntu CI runner) ships `pwsh`. Spawn children with the
# SAME edition the orchestrator is running under so the .ps1 suite works on both.
$psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

# ─── Paths ───────────────────────────────────────────────────────────────────
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..', '..', '..'))
}
$unitDir     = [System.IO.Path]::Combine($scriptDir, 'unit')
$fixturesDir = [System.IO.Path]::Combine($scriptDir, 'fixtures')
$resetPs1    = [System.IO.Path]::Combine($fixturesDir, 'reset', 'Reset-Fixture.ps1')
$lintPs1     = [System.IO.Path]::Combine($RepoRoot, 'tools', 'lint-ps-compat.ps1')
# scriptsDir is THIS plugin's own scripts/ (sibling of tests/), not a hardcoded plugin
# name — so a copied/renamed orchestrator auto-targets its own plugin (U2-U5).
$scriptsDir  = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..', 'scripts'))
# But LINT the whole plugin, not just scripts/. The PS 5.1 taboos it checks (BOM on non-ASCII,
# 3-arg Join-Path, 2>&1 on a native exe, unwrapped pipeline .Count) apply to test code exactly as
# much as to production code — a test that dies on a NativeCommandError is just as broken. Keeping
# tests/ out of range meant nothing could even enumerate the violations there, and a hand-driven
# fix off a review list left most of them in place. The lint itself skips tests/.sandbox/.
$lintTargetDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..'))

Write-Output "Invoke-ScriptTests: RepoRoot = $RepoRoot"
Write-Output "Invoke-ScriptTests: unitDir  = $unitDir"
Write-Output ''

# Ensure the gitignored sandbox base exists before any test runs.
$sandboxBase = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '.sandbox', 'sandboxes'))
$null = New-Item -ItemType Directory -Path $sandboxBase -Force

# ─── No-scripts plugin detection (U5) ────────────────────────────────────────
# A pure-skill plugin (e.g. code-comment) has no scripts/ dir and no *.test.ps1. It
# must still go green: skip the lint pre-flight (nothing to lint) and skip the Pester
# framework gate (no Pester run to gate, so a Pester-less runner must not be forced red).
# Retained for reference/reporting only. The lint no longer keys on it: a pure-skill plugin still
# ships this orchestrator as a .ps1, so there IS something to lint even with no scripts/ dir.
$hasScriptsDir = [System.IO.Directory]::Exists($scriptsDir)
$hasPs1Tests = $false
foreach ($base in @($unitDir, $fixturesDir)) {
    if ([System.IO.Directory]::Exists($base) -and
        @(Get-ChildItem -Path $base -Recurse -Filter '*.test.ps1' -ErrorAction SilentlyContinue).Count -gt 0) {
        $hasPs1Tests = $true; break
    }
}

# ─── Step 1: Lint pre-flight (skippable; also skipped when there is no scripts/) ──
if ($SkipPreflight) {
    Write-Output 'Pre-flight lint: SKIPPED (-SkipPreflight)'
    Write-Output ''
} else {
    Write-Output '─── Pre-flight lint ─────────────────────────────────────────────────'
    if (-not [System.IO.File]::Exists($lintPs1)) {
        throw "Pre-flight: lint-ps-compat.ps1 not found at $lintPs1"
    }
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $lintPs1 -Path $lintTargetDir
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Pre-flight FAILED: lint-ps-compat.ps1 returned exit $LASTEXITCODE"
        exit 1
    }
    Write-Output 'Pre-flight: PASS'
    Write-Output ''
}

# ─── Step 2: Framework gate (ALWAYS when .ps1 tests exist — not gated by ──────
# -SkipPreflight, R3-3). Skipped only when there are zero *.test.ps1 (pure-skill plugin).
if ($hasPs1Tests) {
    Write-Output '─── Framework gate (Pester >= 5.0) ──────────────────────────────────'
    try {
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $pesterVer = (Get-Module Pester | Select-Object -First 1).Version
        Write-Output "Pester $pesterVer present."
        Write-Output ''
    } catch {
        Write-Output 'Framework gate FAILED: Pester 5.0+ is not available.'
        Write-Output '  Windows PowerShell 5.1 ships Pester 3.4; install side-by-side with:'
        Write-Output '    Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck'
        Write-Output "  (Import-Module Pester -MinimumVersion 5.0 error: $($_.Exception.Message))"
        exit 1
    }
} else {
    Write-Output 'Framework gate (Pester): SKIPPED (no *.test.ps1 — pure-skill plugin)'
    Write-Output ''
}

# ─── Step 3: Resolve BashPath (Windows only; non-Windows does NOT resolve) ────
$isWindows = ($env:OS -eq 'Windows_NT') -or ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
if ([string]::IsNullOrWhiteSpace($BashPath)) {
    if ($isWindows) {
        foreach ($c in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
            if ([System.IO.File]::Exists($c)) { $BashPath = $c; break }
        }
        if ([string]::IsNullOrWhiteSpace($BashPath)) {
            Write-Output 'NOTE: no Git Bash bash.exe found; .sh tests will SKIP (run them via the bash orchestrator).'
        } else {
            Write-Output "Resolved BashPath: $BashPath"
        }
    } else {
        # R3-4: on non-Windows do NOT resolve bash (no PATH fallback) so the .sh suite is
        # owned solely by invoke-script-tests.sh and never double-runs here.
        Write-Output 'Non-Windows host: BashPath not resolved by design; .sh tests SKIP here (owned by invoke-script-tests.sh).'
    }
    Write-Output ''
}

# ─── Step 4: Discover test files ─────────────────────────────────────────────
$psTests = @()
$shTests = @()
foreach ($base in @($unitDir, $fixturesDir)) {
    if ([System.IO.Directory]::Exists($base)) {
        $psTests += @(Get-ChildItem -Path $base -Recurse -Filter '*.test.ps1' -ErrorAction SilentlyContinue)
        $shTests += @(Get-ChildItem -Path $base -Recurse -Filter '*.test.sh'  -ErrorAction SilentlyContinue)
    }
}
Write-Output "Discovered $($psTests.Count) *.test.ps1 and $($shTests.Count) *.test.sh"
Write-Output ''

# ─── Step 5: Run *.test.ps1 via Pester (one file per Invoke-Pester for isolation) ─
$psPassed = 0; $psFailed = 0; $psSkipped = 0
$failedFiles = @()

foreach ($t in $psTests) {
    Write-Output "─── PS: $($t.Name) ──────────────────────────────────────"
    if (-not $SkipReset -and [System.IO.File]::Exists($resetPs1)) {
        # Best-effort fixture reset. A failure here (e.g. svn absent on a non-Windows
        # runner) is logged, not fatal — fixture-dependent It blocks self-SKIP on the
        # missing tool, and tests that build their own sandbox are unaffected.
        try {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $resetPs1 2>$null | Out-Null
        } catch { }
    }
    # Run each file in its OWN powershell child process. Pester state (functions/vars
    # defined in BeforeAll) leaks across multiple Invoke-Pester calls in one process, so
    # in-process per-file looping produces false failures — a fresh process per file is
    # the reliable isolation boundary. The child emits a "TPCOUNT p f s" line and exits
    # with its FailedCount.
    $childCmd = "Import-Module Pester -MinimumVersion 5.0; " +
                "`$c = New-PesterConfiguration; " +
                "`$c.Run.Path = '$($t.FullName)'; " +
                "`$c.Run.PassThru = `$true; `$c.Run.Exit = `$false; " +
                "`$c.Output.Verbosity = 'Detailed'; " +
                "`$r = Invoke-Pester -Configuration `$c; " +
                "Write-Output ('TPCOUNT ' + `$r.PassedCount + ' ' + `$r.FailedCount + ' ' + `$r.SkippedCount); " +
                "exit ([int]`$r.FailedCount)"
    $childOut = & $psExe -NoProfile -ExecutionPolicy Bypass -Command $childCmd
    foreach ($l in $childOut) { Write-Output $l }
    $countLine = @($childOut | Where-Object { $_ -match '^TPCOUNT ' }) | Select-Object -Last 1
    if ($countLine -and ($countLine -match '^TPCOUNT (\d+) (\d+) (\d+)$')) {
        $psPassed  += [int]$Matches[1]
        $psFailed  += [int]$Matches[2]
        $psSkipped += [int]$Matches[3]
        if ([int]$Matches[2] -gt 0) { $failedFiles += $t.Name }
    } else {
        # No parseable count — treat as a failure (child crashed before reporting).
        $psFailed++
        $failedFiles += $t.Name
        Write-Output "  (no TPCOUNT emitted — treating as FAIL)"
    }
    Write-Output ''
}

# ─── Step 6: Run *.test.sh via bash (shUnit2), exit-code based ────────────────
$shPassed = 0; $shFailed = 0; $shSkipped = 0
foreach ($t in $shTests) {
    Write-Output "─── SH: $($t.Name) ──────────────────────────────────────"
    if ([string]::IsNullOrWhiteSpace($BashPath)) {
        Write-Output '  SKIP (no BashPath on this host)'
        $shSkipped++
        Write-Output ''
        continue
    }
    if (-not $SkipReset -and [System.IO.File]::Exists($resetPs1)) {
        try { & $psExe -NoProfile -ExecutionPolicy Bypass -File $resetPs1 2>$null | Out-Null } catch { }
    }
    $bashFile = ([regex]::Replace($t.FullName, '^([A-Za-z]):', { param($m) '/' + $m.Groups[1].Value.ToLower() })) -replace '\\', '/'
    & $BashPath -c "'$bashFile'"
    $code = $LASTEXITCODE
    if ($code -eq 0) { $shPassed++ } else { $shFailed++; $failedFiles += $t.Name }
    Write-Output ''
}

# ─── Step 7: Summary + exit (0/1) ────────────────────────────────────────────
Write-Output '─── Summary ─────────────────────────────────────────────────────────'
Write-Output "  Pester (.ps1): $psPassed passed / $psFailed failed / $psSkipped skipped  (across $($psTests.Count) files)"
Write-Output "  Bash   (.sh):  $shPassed passed / $shFailed failed / $shSkipped skipped  (across $($shTests.Count) files)"
if ($failedFiles.Count -gt 0) {
    Write-Output ''
    Write-Output 'Failed files:'
    foreach ($f in $failedFiles) { Write-Output "  - $f" }
    exit 1
}
Write-Output ''
Write-Output 'All tests passed (SKIP counts as green).'
exit 0
