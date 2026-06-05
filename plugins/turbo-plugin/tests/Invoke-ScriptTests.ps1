# Invoke-ScriptTests.ps1
#
# turbo-plugin v1.0 script tests orchestrator entry (rewritten from Run-Phase1.ps1
# per plan U5 / KD-14).
#
# 五件事:
#   1. Pre-flight lint:
#        - tools/lint-ps-compat.ps1 對 plugins/turbo-plugin/scripts/
#      任一 violation → 整個 run abort,不進 infra gate (exit 2)。
#   2. Infra gate (with ordering — KD-14):
#        a) tests/lib/AssertHelpers.test.ps1 FIRST:
#             FAIL → full halt + exit 1 + 訊息 "infra gate failed: AssertHelpers"
#             (assertion 本身壞了,後續所有結果都不可信)
#        b) PASS 後跑 fixture meta-tests:
#             tests/fixtures/*/Reset-Fixture.test.ps1 + tests/fixtures/*/reset-fixture.test.sh
#             FAIL → skip fixture-dependent prod test (do NOT halt),log skip reason
#   3. Discovery (post-gate):
#        - PowerShell  cases:Get-ChildItem -Recurse <scriptDir>/**/*.test.ps1
#        - Bash        cases:Get-ChildItem -Recurse <scriptDir>/**/*.test.sh
#          (Brace expansion `*.test.{ps1,sh}` does NOT work with -Filter — must do
#           two separate -Filter calls per R12; Bash 端 find -name X -o -name Y.)
#   4. Path-based routing:
#        - tests/lib/*.test.ps1            -> infra (already run in step 2)
#        - tests/fixtures/*/*.test.{ps1,sh} -> infra (already run in step 2)
#        - tests/unit/**/*.test.{ps1,sh}   -> prod (run here)
#        - 其它路徑                          -> 報錯 "unrecognized test location"
#   5. Run prod tests + 收集 result + emit tracking row + summary via
#      Get-ScriptTestStatus.ps1。
#
# Exit code 規則 (KD-14):
#   0 = 全 PASS,或所有 non-PASS 都是 FAIL-known / SKIP / BLOCKED-BY (acknowledged)
#   1 = 至少 1 個 raw FAIL,或 infra gate AssertHelpers FAIL
#   2 = lint pre-flight FAIL
#
# 用法 (從 repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File plugins/turbo-plugin/tests/Invoke-ScriptTests.ps1
#
# 參數:
#   -RepoRoot           指定 repo 根 (預設 = 此 script 所在的上 3 層)
#   -SkipPreflight      跳過 lint pre-flight (除錯用,正式跑勿用)
#   -SkipInfraGate      跳過 infra gate (除錯用,正式跑勿用)
#   -SkipReset          跳過 per-case Reset-Fixture 呼叫 (本機 dev iterate 用)
#   -BashPath           Git Bash bash.exe 完整路徑 (預設嘗試標準位置)
#   -RunDir             per-release execution evidence 目錄 (預設 <scriptDir>/runs/v1.0.0)
#   -TargetDoc          tracking doc 路徑 (預設 <RunDir>/script-tests-results.md)

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$SkipPreflight,
    [switch]$SkipInfraGate,
    [switch]$SkipReset,
    [string]$BashPath,
    [string]$RunDir,
    [string]$TargetDoc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Locate paths ────────────────────────────────────────────────────────────

$scriptDir = $PSScriptRoot
# Invoke-ScriptTests.ps1 lives at: <repo>/plugins/turbo-plugin/tests/Invoke-ScriptTests.ps1
# Walk up 3 levels: tests -> turbo-plugin -> plugins -> <repo>
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..', '..', '..'))
}
$libDir            = [System.IO.Path]::Combine($scriptDir, 'lib')
$unitDir           = [System.IO.Path]::Combine($scriptDir, 'unit')
$fixturesDir       = [System.IO.Path]::Combine($scriptDir, 'fixtures')
$resetPs1          = [System.IO.Path]::Combine($fixturesDir, 'reset', 'Reset-Fixture.ps1')
$assertLib         = [System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1')
$assertMetaTest    = [System.IO.Path]::Combine($libDir, 'AssertHelpers.test.ps1')
$writeRowPs1       = [System.IO.Path]::Combine($libDir, 'Write-TrackingRow.ps1')
$statusPs1         = [System.IO.Path]::Combine($libDir, 'Get-ScriptTestStatus.ps1')
$lintPs1           = [System.IO.Path]::Combine($RepoRoot, 'tools', 'lint-ps-compat.ps1')
$lintSh            = [System.IO.Path]::Combine($RepoRoot, 'tools', 'lint-ps-compat.sh')
$scriptsDir        = [System.IO.Path]::Combine($RepoRoot, 'plugins', 'turbo-plugin', 'scripts')

# RunDir = per-release execution evidence dir (default: <scriptDir>/runs/v1.0.0)
if ([string]::IsNullOrWhiteSpace($RunDir)) {
    $RunDir = [System.IO.Path]::Combine($scriptDir, 'runs', 'v1.0.0')
}
if ([string]::IsNullOrWhiteSpace($TargetDoc)) {
    # F-003 jargon clean: default points at the new doc name (U7 will rename the file).
    $TargetDoc = [System.IO.Path]::Combine($RunDir, 'script-tests-results.md')
}

Write-Output "Invoke-ScriptTests: RepoRoot   = $RepoRoot"
Write-Output "Invoke-ScriptTests: unitDir    = $unitDir"
Write-Output "Invoke-ScriptTests: RunDir     = $RunDir"
Write-Output "Invoke-ScriptTests: TargetDoc  = $TargetDoc"
Write-Output ''

# Ensure the test sandbox base exists before any test runs (AssertHelpers.test.ps1 in the
# infra gate writes a tempfile there). All test artifacts live UNDER the repo-relative,
# gitignored tests/.sandbox/ so nothing pollutes outside the repo. Resolved LONG form via
# GetFullPath so 8.3 short-names never appear (tolerates a spaced parent path).
$sandboxBase = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '.sandbox', 'sandboxes'))
$null = New-Item -ItemType Directory -Path $sandboxBase -Force

# ─── Step 1: Pre-flight lint ─────────────────────────────────────────────────

if (-not $SkipPreflight) {
    Write-Output '─── Pre-flight lint ─────────────────────────────────────────────────'
    Write-Output "Target: $scriptsDir"

    if (-not [System.IO.File]::Exists($lintPs1)) {
        throw "Pre-flight: lint-ps-compat.ps1 not found at $lintPs1"
    }
    if (-not [System.IO.Directory]::Exists($scriptsDir)) {
        throw "Pre-flight: scripts dir not found at $scriptsDir"
    }

    # 1a. .ps1 lint
    Write-Output ''
    Write-Output '[1a] lint-ps-compat.ps1 ...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $lintPs1 -Path $scriptsDir
    $lintPs1Exit = $LASTEXITCODE
    if ($lintPs1Exit -ne 0) {
        Write-Output ''
        Write-Output "Pre-flight FAILED: lint-ps-compat.ps1 returned exit $lintPs1Exit"
        exit 2
    }
    Write-Output '[1a] OK'

    # 1b. .sh lint smoke (本質上 .sh wrapper 再 invoke .ps1)
    if (-not [System.IO.File]::Exists($lintSh)) {
        Write-Output "[1b] WARN: lint-ps-compat.sh not found at $lintSh — skipping bash entry validation"
    } else {
        Write-Output ''
        Write-Output '[1b] lint-ps-compat.sh ...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $lintPs1 -Path $scriptsDir | Out-Null
        $lintSh2Exit = $LASTEXITCODE
        if ($lintSh2Exit -ne 0) {
            Write-Output ''
            Write-Output "Pre-flight FAILED: lint-ps-compat (sh entry smoke) returned exit $lintSh2Exit"
            exit 2
        }
        Write-Output '[1b] OK'
    }
    Write-Output ''
    Write-Output 'Pre-flight: PASS'
    Write-Output ''
} else {
    Write-Output 'Pre-flight: SKIPPED (-SkipPreflight)'
    Write-Output ''
}

# ─── Step 2: Resolve BashPath (used by infra gate .sh meta-test + prod .sh) ──

if ([string]::IsNullOrWhiteSpace($BashPath)) {
    $candidates = @(
        'C:\Program Files\Git\bin\bash.exe'
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )
    foreach ($c in $candidates) {
        if ([System.IO.File]::Exists($c)) { $BashPath = $c; break }
    }
    if ([string]::IsNullOrWhiteSpace($BashPath)) {
        Write-Output "NOTE: BashPath not provided and no Git Bash bash.exe found at $(($candidates) -join ', '). .sh tests will SKIP."
        Write-Output ''
    } else {
        Write-Output "Resolved BashPath: $BashPath"
        Write-Output ''
    }
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

function ConvertTo-BashPath {
    param([string]$WinPath)
    $bp = [regex]::Replace($WinPath, '^([A-Za-z]):', { param($m) '/' + $m.Groups[1].Value.ToLower() })
    return ($bp -replace '\\', '/')
}

function ConvertTo-RepoRelativePath {
    # Emit a repo-relative, forward-slash Evidence path so the committed tracking doc never
    # carries a machine-local absolute path (AE6). Falls back to the leaf-name if the path is
    # somehow outside the repo (should not happen for discovered test files).
    param([string]$FullPath)
    $full = [System.IO.Path]::GetFullPath($FullPath)
    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($root.Length).TrimStart('\', '/')
        return ($rel -replace '\\', '/')
    }
    return [System.IO.Path]::GetFileName($full)
}

function Invoke-PsTestFile {
    param([string]$Path)
    # 跑 .test.ps1 child process,2>$null 抑 stderr 防 NativeCommandError 污染。
    $stdoutBuf = @()
    $caseExit  = 0
    try {
        $stdoutBuf = & powershell -NoProfile -ExecutionPolicy Bypass -File $Path 2>$null
        $caseExit  = $LASTEXITCODE
    } catch {
        $stdoutBuf = @($_.Exception.Message)
        $caseExit  = 99
    }
    return [PSCustomObject]@{
        ExitCode = $caseExit
        Stdout   = $stdoutBuf
    }
}

function Invoke-ShTestFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($script:BashPath)) {
        return [PSCustomObject]@{
            ExitCode = -1
            Stdout   = @('(no BashPath — SKIP)')
            Skipped  = $true
        }
    }
    $bashPath = ConvertTo-BashPath -WinPath $Path
    $bashCmd  = "'$bashPath'"
    $stdoutBuf = @()
    $caseExit  = 0
    try {
        $stdoutBuf = & $script:BashPath -c "$bashCmd"
        $caseExit  = $LASTEXITCODE
    } catch {
        $stdoutBuf = @($_.Exception.Message)
        $caseExit  = 99
    }
    return [PSCustomObject]@{
        ExitCode = $caseExit
        Stdout   = $stdoutBuf
        Skipped  = $false
    }
}

# ─── Step 3: Infra gate (AssertHelpers FIRST, then fixture meta-tests) ──────

$fixtureGateOk = $true   # If fixture meta-tests fail, skip fixture-dependent prod tests
$skippedFixtureReason = ''

if (-not $SkipInfraGate) {
    Write-Output '─── Infra gate ──────────────────────────────────────────────────────'

    # 3a. AssertHelpers.test.ps1 FIRST — full halt if FAIL
    if (-not [System.IO.File]::Exists($assertMetaTest)) {
        Write-Output "Infra gate ABORT: AssertHelpers meta-test not found: $assertMetaTest"
        exit 1
    }
    Write-Output ''
    Write-Output "[3a] AssertHelpers.test.ps1 ..."
    $assertResult = Invoke-PsTestFile -Path $assertMetaTest
    foreach ($l in $assertResult.Stdout) { Write-Output "    $l" }
    if ($assertResult.ExitCode -ne 0) {
        Write-Output ''
        Write-Output "infra gate failed: AssertHelpers (exit $($assertResult.ExitCode))"
        Write-Output 'Full halt — assertion library cannot be trusted; downstream results would be meaningless.'
        exit 1
    }
    Write-Output '[3a] AssertHelpers OK'

    # 3b. Fixture meta-tests — FAIL only causes fixture-dependent skip, not halt
    Write-Output ''
    Write-Output '[3b] fixture meta-tests ...'
    $fixturePsMeta = @(Get-ChildItem -Path $fixturesDir -Recurse -Filter '*.test.ps1' -ErrorAction SilentlyContinue)
    $fixtureShMeta = @(Get-ChildItem -Path $fixturesDir -Recurse -Filter '*.test.sh'  -ErrorAction SilentlyContinue)
    Write-Output "    fixture .test.ps1: $($fixturePsMeta.Count)"
    Write-Output "    fixture .test.sh:  $($fixtureShMeta.Count)"

    foreach ($f in $fixturePsMeta) {
        Write-Output ''
        Write-Output "    [fixture-ps] $($f.Name)"
        $r = Invoke-PsTestFile -Path $f.FullName
        foreach ($l in $r.Stdout) { Write-Output "        $l" }
        if ($r.ExitCode -ne 0) {
            $fixtureGateOk = $false
            $skippedFixtureReason = "fixture meta-test $($f.Name) FAILED (exit $($r.ExitCode))"
            Write-Output "    [fixture-ps] FAIL: $($f.Name) — fixture-dependent prod tests will SKIP"
        } else {
            Write-Output "    [fixture-ps] PASS: $($f.Name)"
        }
    }

    foreach ($f in $fixtureShMeta) {
        Write-Output ''
        Write-Output "    [fixture-sh] $($f.Name)"
        $r = Invoke-ShTestFile -Path $f.FullName
        foreach ($l in $r.Stdout) { Write-Output "        $l" }
        if ($r.PSObject.Properties['Skipped'] -and $r.Skipped) {
            Write-Output "    [fixture-sh] SKIPPED (no BashPath)"
            continue
        }
        if ($r.ExitCode -ne 0) {
            $fixtureGateOk = $false
            $skippedFixtureReason = "fixture meta-test $($f.Name) FAILED (exit $($r.ExitCode))"
            Write-Output "    [fixture-sh] FAIL: $($f.Name) — fixture-dependent prod tests will SKIP"
        } else {
            Write-Output "    [fixture-sh] PASS: $($f.Name)"
        }
    }

    Write-Output ''
    if ($fixtureGateOk) {
        Write-Output 'Infra gate: PASS'
    } else {
        Write-Output "Infra gate: PARTIAL — $skippedFixtureReason"
    }
    Write-Output ''
} else {
    Write-Output 'Infra gate: SKIPPED (-SkipInfraGate)'
    Write-Output ''
}

# ─── Step 4: Discovery (recursive *.test.ps1 + *.test.sh, brace-aware) ───────

Write-Output '─── Discovery ───────────────────────────────────────────────────────'
$allPsTests = @()
$allShTests = @()
if ([System.IO.Directory]::Exists($scriptDir)) {
    # R12: brace expansion `*.test.{ps1,sh}` does NOT work with -Filter; use two calls.
    $allPsTests = @(Get-ChildItem -Path $scriptDir -Recurse -Filter '*.test.ps1' -ErrorAction SilentlyContinue)
    $allShTests = @(Get-ChildItem -Path $scriptDir -Recurse -Filter '*.test.sh'  -ErrorAction SilentlyContinue)
}

# ─── Step 5: Path-based routing ──────────────────────────────────────────────

$prodPsTests  = @()
$prodShTests  = @()
$infraPsTests = @()
$infraShTests = @()
$unrecognized = @()

function Test-IsInfraPath {
    param([string]$FullPath, [string]$BaseDir)
    # Normalise separators for comparison
    $p = $FullPath -replace '/', '\'
    $b = $BaseDir  -replace '/', '\'
    $libPrefix      = ([System.IO.Path]::Combine($b, 'lib'))      + '\'
    $fixturesPrefix = ([System.IO.Path]::Combine($b, 'fixtures')) + '\'
    return $p.StartsWith($libPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or `
           $p.StartsWith($fixturesPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsProdPath {
    param([string]$FullPath, [string]$BaseDir)
    $p = $FullPath -replace '/', '\'
    $b = $BaseDir  -replace '/', '\'
    $unitPrefix = ([System.IO.Path]::Combine($b, 'unit')) + '\'
    return $p.StartsWith($unitPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

foreach ($t in $allPsTests) {
    if (Test-IsInfraPath -FullPath $t.FullName -BaseDir $scriptDir) {
        $infraPsTests += $t
    } elseif (Test-IsProdPath -FullPath $t.FullName -BaseDir $scriptDir) {
        $prodPsTests += $t
    } else {
        $unrecognized += $t.FullName
    }
}
foreach ($t in $allShTests) {
    if (Test-IsInfraPath -FullPath $t.FullName -BaseDir $scriptDir) {
        $infraShTests += $t
    } elseif (Test-IsProdPath -FullPath $t.FullName -BaseDir $scriptDir) {
        $prodShTests += $t
    } else {
        $unrecognized += $t.FullName
    }
}

Write-Output "  Total .test.ps1 discovered: $($allPsTests.Count)  (infra=$($infraPsTests.Count), prod=$($prodPsTests.Count))"
Write-Output "  Total .test.sh  discovered: $($allShTests.Count)  (infra=$($infraShTests.Count), prod=$($prodShTests.Count))"

if ($unrecognized.Count -gt 0) {
    Write-Output ''
    Write-Output 'ERROR: unrecognized test location(s) (must be under tests/lib/, tests/fixtures/, or tests/unit/):'
    foreach ($u in $unrecognized) { Write-Output "  - $u" }
    exit 1
}
Write-Output ''

if ($prodPsTests.Count -eq 0 -and $prodShTests.Count -eq 0) {
    Write-Output '─── Summary ─────────────────────────────────────────────────────────'
    Write-Output 'No prod test cases discovered (tests/unit/ empty or no *.test.{ps1,sh}).'
    Write-Output 'Lint pre-flight passed and infra gate completed. Exiting 0.'
    exit 0
}

# ─── Step 6: Run prod tests ──────────────────────────────────────────────────

$caseSummary = @{
    PsTotal   = $prodPsTests.Count
    PsPassed  = 0
    PsFailed  = 0
    PsSkipped = 0
    ShTotal   = $prodShTests.Count
    ShPassed  = 0
    ShFailed  = 0
    ShSkipped = 0
}

# Test which need a fresh fixture — anything under unit/ depends on Reset-Fixture
# being trustworthy. If fixture meta-test failed, we SKIP these prod tests with reason.
$fixtureDependent = $true   # treat all prod tests as fixture-dependent in v1.0

function Get-SectionName {
    param(
        [string]$Name,
        [string]$Directory = ''
    )
    # Strip .test.{ps1,sh} suffix; for .test.sh, try to map kebab to PascalCase
    # canonical via sibling .test.ps1 so .ps1 + .sh tests emit to same section.
    $n = $Name
    if ($n.EndsWith('.test.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $n.Substring(0, $n.Length - 9)
    }
    if ($n.EndsWith('.test.sh', [System.StringComparison]::OrdinalIgnoreCase)) {
        $kebab = $n.Substring(0, $n.Length - 8)
        # Find sibling .test.ps1 in same directory whose basename matches kebab
        # case-insensitively after PascalCase-to-kebab normalization.
        if ($Directory -and (Test-Path -LiteralPath $Directory -PathType Container)) {
            $candidates = @(Get-ChildItem -LiteralPath $Directory -Filter '*.test.ps1' -ErrorAction SilentlyContinue)
            foreach ($c in $candidates) {
                $psBase = $c.Name.Substring(0, $c.Name.Length - 9)
                # Normalize: strip all hyphens, lowercase. Handles both conventions:
                # - 'Build-SvnCommit' / 'build-svn-commit' both → 'buildsvncommit'
                # - 'Invoke-PostToolUseEnterWorktree' / 'invoke-posttooluse-enterworktree'
                #   both → 'invokeposttooluseenterworktree'
                $pseudoKebab = ($psBase -replace '-', '').ToLowerInvariant()
                $kebabNormalized = ($kebab -replace '-', '').ToLowerInvariant()
                if ($pseudoKebab -eq $kebabNormalized) {
                    return $psBase
                }
            }
        }
        return $kebab
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($n)
}

function Test-TargetDocAvailable {
    return [System.IO.File]::Exists($TargetDoc)
}

function Invoke-ProdPsCase {
    param([System.IO.FileInfo]$CaseFile)
    Write-Output ''
    Write-Output "─── PS prod case: $($CaseFile.Name) ─────────────────────────────────"

    if ($fixtureDependent -and -not $fixtureGateOk) {
        Write-Output "  SKIP — $skippedFixtureReason"
        $caseSummary.PsSkipped++
        if (Test-TargetDocAvailable) {
            & $writeRowPs1 `
                -CaseId   ('P1-' + $CaseFile.BaseName) `
                -Section  (Get-SectionName $CaseFile.Name -Directory $CaseFile.DirectoryName) `
                -Fixture  'skipped-fixture-gate' `
                -Expected 'fixture meta-test PASS' `
                -Actual   $skippedFixtureReason `
                -Result   'SKIP' `
                -Evidence (ConvertTo-RepoRelativePath $CaseFile.FullName) `
                -TargetDoc $TargetDoc | Out-Null
        }
        return
    }

    if (-not $SkipReset) {
        Write-Output '  Resetting fixture...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $resetPs1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Output "  Reset-Fixture FAILED with exit $LASTEXITCODE — emitting FAIL row"
            $caseSummary.PsFailed++
            if (Test-TargetDocAvailable) {
                & $writeRowPs1 `
                    -CaseId   ('P1-' + $CaseFile.BaseName) `
                    -Section  (Get-SectionName $CaseFile.Name -Directory $CaseFile.DirectoryName) `
                    -Fixture  'reset-failed' `
                    -Expected 'fixture reset to base' `
                    -Actual   "Reset-Fixture exit $LASTEXITCODE" `
                    -Result   'FAIL' `
                    -Evidence "Reset-Fixture.ps1 exit $LASTEXITCODE" `
                    -TargetDoc $TargetDoc | Out-Null
            }
            return
        }
    }

    $r = Invoke-PsTestFile -Path $CaseFile.FullName
    foreach ($l in $r.Stdout) { Write-Output "    $l" }
    $result = if ($r.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    if ($r.ExitCode -eq 0) { $caseSummary.PsPassed++ } else { $caseSummary.PsFailed++ }

    if (Test-TargetDocAvailable) {
        & $writeRowPs1 `
            -CaseId   ('P1-' + $CaseFile.BaseName) `
            -Section  (Get-SectionName $CaseFile.Name -Directory $CaseFile.DirectoryName) `
            -Fixture  'fresh-base' `
            -Expected 'all Assert-* PASS' `
            -Actual   "exit $($r.ExitCode)" `
            -Result   $result `
            -Evidence (ConvertTo-RepoRelativePath $CaseFile.FullName) `
            -TargetDoc $TargetDoc | Out-Null
    }
}

function Invoke-ProdShCase {
    param([System.IO.FileInfo]$CaseFile)
    Write-Output ''
    Write-Output "─── SH prod case: $($CaseFile.Name) ─────────────────────────────────"

    if ($fixtureDependent -and -not $fixtureGateOk) {
        Write-Output "  SKIP — $skippedFixtureReason"
        $caseSummary.ShSkipped++
        if (Test-TargetDocAvailable) {
            & $writeRowPs1 `
                -CaseId   ('P1-' + $CaseFile.BaseName) `
                -Section  (Get-SectionName $CaseFile.Name -Directory $CaseFile.DirectoryName) `
                -Fixture  'skipped-fixture-gate' `
                -Expected 'fixture meta-test PASS' `
                -Actual   $skippedFixtureReason `
                -Result   'SKIP' `
                -Evidence (ConvertTo-RepoRelativePath $CaseFile.FullName) `
                -TargetDoc $TargetDoc | Out-Null
        }
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:BashPath)) {
        Write-Output '  SKIP — no BashPath resolved'
        $caseSummary.ShSkipped++
        return
    }

    if (-not $SkipReset) {
        Write-Output '  Resetting fixture...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $resetPs1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Output "  Reset-Fixture FAILED with exit $LASTEXITCODE — emitting FAIL row"
            $caseSummary.ShFailed++
            if (Test-TargetDocAvailable) {
                & $writeRowPs1 `
                    -CaseId   ('P1-' + $CaseFile.BaseName) `
                    -Section  (Get-SectionName $CaseFile.Name -Directory $CaseFile.DirectoryName) `
                    -Fixture  'reset-failed' `
                    -Expected 'fixture reset to base' `
                    -Actual   "Reset-Fixture exit $LASTEXITCODE" `
                    -Result   'FAIL' `
                    -Evidence "Reset-Fixture.ps1 exit $LASTEXITCODE" `
                    -TargetDoc $TargetDoc | Out-Null
            }
            return
        }
    }

    $r = Invoke-ShTestFile -Path $CaseFile.FullName
    foreach ($l in $r.Stdout) { Write-Output "    $l" }

    # parse last OK / FAIL marker
    $lastLine = ''
    if ($r.Stdout.Count -gt 0) {
        for ($i = $r.Stdout.Count - 1; $i -ge 0; $i--) {
            $cand = [string]$r.Stdout[$i]
            if (-not [string]::IsNullOrWhiteSpace($cand)) { $lastLine = $cand; break }
        }
    }
    $resultFromBody = if ($lastLine -match '^OK(\b|:|$)') { 'PASS' }
                      elseif ($lastLine -match '^FAIL(\b|:|$)') { 'FAIL' }
                      else { '' }

    if ([string]::IsNullOrEmpty($resultFromBody)) {
        $result = if ($r.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    } else {
        $result = $resultFromBody
    }
    if ($result -eq 'PASS') { $caseSummary.ShPassed++ } else { $caseSummary.ShFailed++ }

    if (Test-TargetDocAvailable) {
        & $writeRowPs1 `
            -CaseId   ('P1-' + $CaseFile.BaseName) `
            -Section  (Get-SectionName $CaseFile.Name -Directory $CaseFile.DirectoryName) `
            -Fixture  'fresh-base' `
            -Expected 'script exit 0 + last line OK' `
            -Actual   "exit $($r.ExitCode); last: $lastLine" `
            -Result   $result `
            -Evidence (ConvertTo-RepoRelativePath $CaseFile.FullName) `
            -TargetDoc $TargetDoc | Out-Null
    }
}

foreach ($c in $prodPsTests) { Invoke-ProdPsCase -CaseFile $c }
foreach ($c in $prodShTests) { Invoke-ProdShCase -CaseFile $c }

# ─── Step 7: Summary via Get-ScriptTestStatus ───────────────────────────────

Write-Output ''
Write-Output '─── Summary ─────────────────────────────────────────────────────────'
Write-Output "  PS:    $($caseSummary.PsPassed) PASS / $($caseSummary.PsFailed) FAIL / $($caseSummary.PsSkipped) SKIP  (of $($caseSummary.PsTotal))"
Write-Output "  Bash:  $($caseSummary.ShPassed) PASS / $($caseSummary.ShFailed) FAIL / $($caseSummary.ShSkipped) SKIP  (of $($caseSummary.ShTotal))"
Write-Output ''

if (Test-TargetDocAvailable) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $statusPs1 -TargetDoc $TargetDoc
    $statusExit = $LASTEXITCODE
    exit $statusExit
} else {
    Write-Output "NOTE: TargetDoc not present yet ($TargetDoc) — skipping status doc parse."
    Write-Output "      (U7 creates the renamed tracking doc; current run was based on in-memory counters only.)"
    if ($caseSummary.PsFailed -gt 0 -or $caseSummary.ShFailed -gt 0) { exit 1 } else { exit 0 }
}
