# Run-Phase1.ps1
#
# turbo-plugin v1.0 PR-readiness Phase 1 自動測試的 orchestrator 入口。
#
# 三件事:
#   1. Pre-flight lint (R30):
#        - tools/lint-ps-compat.ps1 對 plugins/turbo-plugin/scripts/ (36 個 script)
#        - tools/lint-ps-compat.sh  對同一目錄 (走 PowerShell 內部再 invoke ps1)
#      任一 violation → 整個 Phase 1 abort,不進 discovery。
#   2. Discovery:
#        - PowerShell  cases:Get-ChildItem -Recurse tests/v1.0/phase1/*.Tests.ps1
#        - Bash        cases:Get-ChildItem -Recurse tests/v1.0/phase1/*.sh.test.sh
#      (U2 階段 phase1/ 目錄是空的,U3 / U4 才會 populate。)
#   3. Per-case loop:
#        for each .Tests.ps1
#            -> 呼叫 tests/v1.0/fixtures/reset/Reset-Fixture.ps1 重設 fixture
#            -> dot-source Assert-Helpers.ps1 → Reset-Counters → 跑 .Tests.ps1
#            -> 收集 $script:Passed / $script:Failed → emit tracking row
#        for each .sh.test.sh
#            -> Reset-Fixture (PS 版本仍是 ground truth — Reset-Fixture.ps1)
#            -> 透過 Git Bash 的 bash.exe -c 跑 .sh.test.sh,捕捉 exit code + stdout
#            -> parse 最後 `OK|FAIL: <msg>` 行
#            -> emit tracking row
#
# 最後:呼叫 Get-Phase1Status.ps1 印 summary 並決定 exit code。
#
# 用法 (從 repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/v1.0/Run-Phase1.ps1
#
# 參數:
#   -RepoRoot           指定 repo 根 (預設 = 此 script 所在的上 2 層)
#   -SkipPreflight      跳過 lint pre-flight (除錯用,正式跑勿用)
#   -SkipReset          跳過 per-case Reset-Fixture 呼叫 (本機 dev iterate 用)
#   -BashPath           Git Bash bash.exe 完整路徑 (預設嘗試標準位置)
#   -TargetDoc          tracking doc 路徑 (預設 docs/test-plans/v1.0/phase1-scripts.md)

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$SkipPreflight,
    [switch]$SkipReset,
    [string]$BashPath,
    [string]$TargetDoc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Locate paths ────────────────────────────────────────────────────────────

$scriptDir = $PSScriptRoot
# Run-Phase1.ps1 lives at: <repo>/tests/v1.0/Run-Phase1.ps1
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..', '..'))
}
$libDir       = [System.IO.Path]::Combine($scriptDir, 'lib')
$phase1Dir    = [System.IO.Path]::Combine($scriptDir, 'phase1')
$fixturesDir  = [System.IO.Path]::Combine($scriptDir, 'fixtures')
$resetPs1     = [System.IO.Path]::Combine($fixturesDir, 'reset', 'Reset-Fixture.ps1')
$assertLib    = [System.IO.Path]::Combine($libDir, 'Assert-Helpers.ps1')
$emitRowPs1   = [System.IO.Path]::Combine($libDir, 'Emit-TrackingRow.ps1')
$statusPs1    = [System.IO.Path]::Combine($libDir, 'Get-Phase1Status.ps1')
$lintPs1      = [System.IO.Path]::Combine($RepoRoot, 'tools', 'lint-ps-compat.ps1')
$lintSh       = [System.IO.Path]::Combine($RepoRoot, 'tools', 'lint-ps-compat.sh')
$scriptsDir   = [System.IO.Path]::Combine($RepoRoot, 'plugins', 'turbo-plugin', 'scripts')

if ([string]::IsNullOrWhiteSpace($TargetDoc)) {
    $TargetDoc = [System.IO.Path]::Combine($RepoRoot, 'docs', 'test-plans', 'v1.0', 'phase1-scripts.md')
}

Write-Output "Run-Phase1: RepoRoot = $RepoRoot"
Write-Output "Run-Phase1: phase1Dir = $phase1Dir"
Write-Output "Run-Phase1: TargetDoc = $TargetDoc"
Write-Output ''

# ─── Step 1: Pre-flight lint (R30) ───────────────────────────────────────────

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

    # 1b. .sh lint (本質上 .sh wrapper 再 invoke .ps1，重複跑會多花 ~1 sec
    #     但能驗證 bash 入口存在 + 可執行)
    if (-not [System.IO.File]::Exists($lintSh)) {
        Write-Output "[1b] WARN: lint-ps-compat.sh not found at $lintSh — skipping bash entry validation"
    } else {
        Write-Output ''
        Write-Output '[1b] lint-ps-compat.sh ...'
        # 在 Windows 上 .sh 走 Git Bash;但 lint-ps-compat.sh 本體只是 exec
        # powershell -File lint-ps-compat.ps1，本質沒在跑 bash logic。為了避免
        # bash 路徑解析問題且重複 lint 沒有額外信號,直接 invoke .ps1 第二次當
        # smoke (一致性 check)。
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

# ─── Step 2: Discovery ───────────────────────────────────────────────────────

Write-Output '─── Discovery ───────────────────────────────────────────────────────'
$psCases   = @()
$bashCases = @()
if ([System.IO.Directory]::Exists($phase1Dir)) {
    $psCases   = @(Get-ChildItem -Path $phase1Dir -Recurse -Filter '*.Tests.ps1'  -ErrorAction SilentlyContinue)
    $bashCases = @(Get-ChildItem -Path $phase1Dir -Recurse -Filter '*.sh.test.sh' -ErrorAction SilentlyContinue)
} else {
    Write-Output "  (phase1 dir does not exist yet: $phase1Dir)"
}

Write-Output "  PS .Tests.ps1 cases:   $($psCases.Count)"
Write-Output "  Bash .sh.test.sh:      $($bashCases.Count)"
Write-Output ''

if ($psCases.Count -eq 0 -and $bashCases.Count -eq 0) {
    Write-Output '─── Summary ─────────────────────────────────────────────────────────'
    Write-Output 'No Phase 1 test cases discovered (phase1/ empty — U2-only state).'
    Write-Output 'Pre-flight passed. Exiting 0.'
    exit 0
}

# ─── Step 3: Resolve BashPath (for .sh.test.sh cases) ───────────────────────

if ($bashCases.Count -gt 0 -and [string]::IsNullOrWhiteSpace($BashPath)) {
    $candidates = @(
        'C:\Program Files\Git\bin\bash.exe'
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )
    foreach ($c in $candidates) {
        if ([System.IO.File]::Exists($c)) { $BashPath = $c; break }
    }
    if ([string]::IsNullOrWhiteSpace($BashPath)) {
        throw "BashPath not provided and no Git Bash bash.exe found at $(($candidates) -join ', '). Pass -BashPath."
    }
    Write-Output "Resolved BashPath: $BashPath"
    Write-Output ''
}

# ─── Step 4: Run cases ───────────────────────────────────────────────────────

$caseSummary = @{
    PsTotal    = $psCases.Count
    PsPassed   = 0
    PsFailed   = 0
    ShTotal    = $bashCases.Count
    ShPassed   = 0
    ShFailed   = 0
}

function Invoke-PsCase {
    param([System.IO.FileInfo]$CaseFile)
    Write-Output ''
    Write-Output "─── PS case: $($CaseFile.Name) ─────────────────────────────────────"
    if (-not $SkipReset) {
        Write-Output "  Resetting fixture..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File $resetPs1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Output "  Reset-Fixture FAILED with exit $LASTEXITCODE — emitting FAIL row"
            & $emitRowPs1 `
                -CaseId   ('P1-' + $CaseFile.BaseName) `
                -Section  $CaseFile.BaseName.Replace('.Tests', '') `
                -Fixture  'reset-failed' `
                -Expected 'fixture reset to base' `
                -Actual   "Reset-Fixture exit $LASTEXITCODE" `
                -Result   'FAIL' `
                -Evidence "Reset-Fixture.ps1 exit $LASTEXITCODE" `
                -TargetDoc $TargetDoc | Out-Null
            $caseSummary.PsFailed++
            return
        }
    }
    # 跑 .Tests.ps1;期望 它自己 dot-source Assert-Helpers.ps1 + 用 Assert-* helper。
    # 失敗計入 by exit code (約定:Tests.ps1 自己 exit 0/1 + 印 [PASS]/[FAIL])。
    # 不用 `2>&1` (lint rule 4 — PS 5.1 NativeCommandError 會污染 $LASTEXITCODE under
    # EAP=Stop);把 stderr 抑制掉,只 capture stdout。Tests.ps1 自己印 [PASS]/[FAIL]
    # 進 stdout 已足夠 trace。
    $caseExit = 0
    $stdoutBuf = @()
    try {
        $stdoutBuf = & powershell -NoProfile -ExecutionPolicy Bypass -File $CaseFile.FullName 2>$null
        $caseExit = $LASTEXITCODE
    } catch {
        $stdoutBuf = @($_.Exception.Message)
        $caseExit = 99
    }
    foreach ($l in $stdoutBuf) { Write-Output "    $l" }

    $result = if ($caseExit -eq 0) { 'PASS' } else { 'FAIL' }
    if ($caseExit -eq 0) { $caseSummary.PsPassed++ } else { $caseSummary.PsFailed++ }

    $section = $CaseFile.BaseName.Replace('.Tests', '')
    & $emitRowPs1 `
        -CaseId   ('P1-' + $CaseFile.BaseName) `
        -Section  $section `
        -Fixture  'fresh-base' `
        -Expected 'all Assert-* PASS' `
        -Actual   "exit $caseExit" `
        -Result   $result `
        -Evidence "$($CaseFile.FullName)" `
        -TargetDoc $TargetDoc | Out-Null
}

function Invoke-ShCase {
    param([System.IO.FileInfo]$CaseFile)
    Write-Output ''
    Write-Output "─── SH case: $($CaseFile.Name) ─────────────────────────────────────"
    if (-not $SkipReset) {
        Write-Output "  Resetting fixture..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File $resetPs1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Output "  Reset-Fixture FAILED with exit $LASTEXITCODE — emitting FAIL row"
            & $emitRowPs1 `
                -CaseId   ('P1-' + $CaseFile.BaseName) `
                -Section  $CaseFile.BaseName.Replace('.sh.test', '') `
                -Fixture  'reset-failed' `
                -Expected 'fixture reset to base' `
                -Actual   "Reset-Fixture exit $LASTEXITCODE" `
                -Result   'FAIL' `
                -Evidence "Reset-Fixture.ps1 exit $LASTEXITCODE" `
                -TargetDoc $TargetDoc | Out-Null
            $caseSummary.ShFailed++
            return
        }
    }

    # 把 Windows 路徑轉成 bash 路徑 (C:\... -> /c/...)
    $winPath  = $CaseFile.FullName
    $bashPath = $winPath -replace '^([A-Za-z]):', { '/' + $args[0].Groups[1].Value.ToLower() }
    $bashPath = $bashPath -replace '\\', '/'

    # 用 bash.exe -c "<script>" 跑;對含空白或特殊字元的路徑要 single-quote。
    $bashCmd  = "'$bashPath'"
    $caseExit = 0
    $stdoutBuf = @()
    try {
        $stdoutBuf = & $BashPath -c "$bashCmd"
        $caseExit = $LASTEXITCODE
    } catch {
        $stdoutBuf = @($_.Exception.Message)
        $caseExit = 99
    }
    foreach ($l in $stdoutBuf) { Write-Output "    $l" }

    # 找最後一行 OK / FAIL marker
    $lastLine = ''
    if ($stdoutBuf.Count -gt 0) {
        for ($i = $stdoutBuf.Count - 1; $i -ge 0; $i--) {
            $cand = [string]$stdoutBuf[$i]
            if (-not [string]::IsNullOrWhiteSpace($cand)) { $lastLine = $cand; break }
        }
    }
    $resultFromBody = if ($lastLine -match '^OK(\b|:|$)') { 'PASS' }
                      elseif ($lastLine -match '^FAIL(\b|:|$)') { 'FAIL' }
                      else { '' }

    if ([string]::IsNullOrEmpty($resultFromBody)) {
        $result = if ($caseExit -eq 0) { 'PASS' } else { 'FAIL' }
    } else {
        $result = $resultFromBody
    }
    if ($result -eq 'PASS') { $caseSummary.ShPassed++ } else { $caseSummary.ShFailed++ }

    $section = $CaseFile.BaseName.Replace('.sh.test', '')
    & $emitRowPs1 `
        -CaseId   ('P1-' + $CaseFile.BaseName) `
        -Section  $section `
        -Fixture  'fresh-base' `
        -Expected 'script exit 0 + last line OK' `
        -Actual   "exit $caseExit; last: $lastLine" `
        -Result   $result `
        -Evidence "$($CaseFile.FullName)" `
        -TargetDoc $TargetDoc | Out-Null
}

foreach ($c in $psCases)   { Invoke-PsCase -CaseFile $c }
foreach ($c in $bashCases) { Invoke-ShCase -CaseFile $c }

# ─── Step 5: Summary via Get-Phase1Status ───────────────────────────────────

Write-Output ''
Write-Output '─── Summary ─────────────────────────────────────────────────────────'
Write-Output "  PS:    $($caseSummary.PsPassed) PASS / $($caseSummary.PsFailed) FAIL  (of $($caseSummary.PsTotal))"
Write-Output "  Bash:  $($caseSummary.ShPassed) PASS / $($caseSummary.ShFailed) FAIL  (of $($caseSummary.ShTotal))"
Write-Output ''

& powershell -NoProfile -ExecutionPolicy Bypass -File $statusPs1 -TargetDoc $TargetDoc
$statusExit = $LASTEXITCODE
exit $statusExit
