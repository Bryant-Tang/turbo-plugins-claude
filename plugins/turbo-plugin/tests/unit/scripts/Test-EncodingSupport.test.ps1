# check-encoding-support.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/check-encoding-support.ps1
# Behavior: Emit PS_VERSION / ANSI_CODEPAGE / OEM_CODEPAGE / ARGV_SAFE_FOR_UNICODE / RECOMMENDATION;
#   非 UTF-8 ANSI → 額外印 WARNING + 3-選一 (a) (b) (c) 建議。
#
# Cases:
#   1. Tokens present: stdout 含全部 5 個 token (PS_VERSION/ANSI_CODEPAGE/OEM_CODEPAGE/ARGV_SAFE_FOR_UNICODE/RECOMMENDATION)
#   2. SKILL entry: 再呼叫一次 → 結果 deterministic (PS 5.1 + 同機 codepage 是固定的)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'AssertHelpers.ps1')
. $LibPath
Reset-Counters

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'check-encoding-support.ps1')

function Invoke-Script {
    $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $stdout = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptUnderTest 2>$null
        $exit = $LASTEXITCODE
    } catch {
        $stdout = @($_.Exception.Message); $exit = 99
    } finally {
        $ErrorActionPreference = $savedEap
    }
    return @{ Stdout = ($stdout -join "`n"); Exit = $exit }
}

try {
    # Case 1: tokens present
    $r1 = Invoke-Script
    Assert-Equal -Name 'case1: exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: PS_VERSION token' -Pattern 'PS_VERSION=\d+\.\d+' -InputText $r1.Stdout
    Assert-Match -Name 'case1: ANSI_CODEPAGE token' -Pattern 'ANSI_CODEPAGE=' -InputText $r1.Stdout
    Assert-Match -Name 'case1: OEM_CODEPAGE token' -Pattern 'OEM_CODEPAGE=' -InputText $r1.Stdout
    Assert-Match -Name 'case1: ARGV_SAFE_FOR_UNICODE token' -Pattern 'ARGV_SAFE_FOR_UNICODE=(True|False)' -InputText $r1.Stdout
    Assert-Match -Name 'case1: RECOMMENDATION token' -Pattern 'RECOMMENDATION=(OK|UPGRADE_PS7_OR_ENABLE_WIN10_UTF8)' -InputText $r1.Stdout

    # Case 2: SKILL entry — re-invoke,結果 deterministic
    $r2 = Invoke-Script
    Assert-Equal -Name 'case2: SKILL-entry exit 0' -Expected 0 -Actual $r2.Exit
    # Compare PS_VERSION + ANSI_CODEPAGE lines
    $r1Lines = $r1.Stdout -split "`r?`n"
    $r2Lines = $r2.Stdout -split "`r?`n"
    $r1Tokens = ($r1Lines | Where-Object { $_ -match '^(PS_VERSION|ANSI_CODEPAGE|OEM_CODEPAGE|ARGV_SAFE_FOR_UNICODE|RECOMMENDATION)=' }) -join "`n"
    $r2Tokens = ($r2Lines | Where-Object { $_ -match '^(PS_VERSION|ANSI_CODEPAGE|OEM_CODEPAGE|ARGV_SAFE_FOR_UNICODE|RECOMMENDATION)=' }) -join "`n"
    Assert-Equal -Name 'case2: tokens deterministic across runs' -Expected $r1Tokens -Actual $r2Tokens
}
catch {
    Write-Output "  [FAIL] unhandled exception: $($_.Exception.Message)"
    $script:Failed++
}

Write-Output ''
Write-Output "check-encoding-support.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
