# push-to-svn-commit.Tests.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/Submit-SvnCommit.ps1.
#
# Scope (U4 plan):
#   - missing -Branch → required-arg error
#   - missing -Message → required-arg error
#   - unsupported branch name → "Unsupported branch"
#   - no prepared merge (no MERGE_HEAD) → "No pending merge ..." (中文 commit msg input — verify the
#     script handles 中文 -Message arg without parser/encoding crash before hitting the
#     precondition fail)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Submit-SvnCommit.ps1')

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] push-to-svn-commit.ps1 not found at $scriptUnderTest"
    exit 1
}

# ─── Case 1: missing -Branch ─────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 1: missing -Branch → required-arg error'
$sb1 = New-Sandbox -Tag 'ptsc-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-True -Name 'exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions -Branch required' -Pattern '-Branch' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: missing -Message ───────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 2: -Branch supplied but missing -Message → required-arg error'
$sb2 = New-Sandbox -Tag 'ptsc-2'
try {
    $root = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main')
    Assert-True -Name 'exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions -Message required' -Pattern '-Message' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Case 3: unsupported branch name ─────────────────────────────────────────

Write-Output ''
Write-Output 'Case 3: -Branch develop (unsupported) → "Unsupported branch"'
$sb3 = New-Sandbox -Tag 'ptsc-3'
try {
    $root = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'develop', '-Message', 'irrelevant')
    Assert-True -Name 'exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions Unsupported branch' -Pattern 'Unsupported branch' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb3
}

# ─── Case 4: no MERGE_HEAD → fails with "No pending merge" (中文 -Message in arg) ─

Write-Output ''
Write-Output 'Case 4: -Branch main with remote-svn-main but no MERGE_HEAD → "No pending merge" (中文 -Message)'
$sb4 = New-Sandbox -Tag 'ptsc-4'
try {
    $root = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir -CreateRemoteMain
    $zhMsg = '修正中文 bug — push-commit precondition case'
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'main', '-Message', $zhMsg)
    Assert-True -Name 'exit != 0 (no MERGE_HEAD)' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions No pending merge' -Pattern 'No pending merge' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb4
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "push-to-svn-commit: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
