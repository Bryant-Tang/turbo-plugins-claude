# create-remote-test.Tests.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/create-remote-test.ps1.
#
# Scope (U4 plan):
#   - missing arg:  -SvnUrl required → script throws.
#   - worktrees dir missing → script throws (early fail before any git mutation).
#   - rollback on svn copy/checkout failure (含中文 SvnUrl 段):
#       -SvnUrl points to a bogus URL → script attempts to create git branches + worktree, then
#       svn copy/info/checkout fails → rollback fires → no orphan branches / worktree remain.
#
# We deliberately DO NOT exercise a full real-SVN happy path here — that requires both an empty
# initialized SVN repo (so svn copy can succeed) AND a remote-main worktree pre-checkout from
# that repo. Reset-Fixture provides exactly that wiring for svn-ignore tests; reusing it for
# create-remote-test would duplicate svn-ignore happy-path coverage. The rollback case is the
# more rigorous one since it tests the trap+restore primitive that protects the user.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'create-remote-test.ps1')

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] create-remote-test.ps1 not found at $scriptUnderTest"
    exit 1
}

# ─── Case 1: missing -SvnUrl ─────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 1: missing -SvnUrl → required-arg error'
$sb1 = New-Sandbox -Tag 'crt-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-True -Name 'exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions SvnUrl required' -Pattern '-SvnUrl' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: worktrees dir does not exist ────────────────────────────────────

Write-Output ''
Write-Output 'Case 2: worktrees dir missing → "Run /tp-setup first" error'
$sb2 = New-Sandbox -Tag 'crt-2'
try {
    $root = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    New-GitMainRepo -Root $root  # NO -CreateWorktreesDir → .worktrees/ absent at parent

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                           -ScriptArgs @('-SvnUrl', 'file:///C:/Turbo/no-such-repo/branches/test-1')
    Assert-True -Name 'exit != 0 (worktrees dir missing)' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions Worktrees directory not found' `
                 -Pattern 'Worktrees directory not found' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Case 3: rollback on svn copy failure (含中文 SvnUrl segment) ────────────

Write-Output ''
Write-Output 'Case 3: bogus -SvnUrl with 中文 segment → rollback → no orphan git state'
$sb3 = New-Sandbox -Tag 'crt-3'
try {
    $root = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir
    # 中文 segment exercises path-encoding in rollback path
    $bogusUrl = 'file:///C:/Turbo/no-such-repo-中文路徑/branches/test-99'
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                           -ScriptArgs @('-N', '99', '-SvnUrl', $bogusUrl)
    Assert-True -Name 'exit != 0 (rollback fired)' -Condition ($res.ExitCode -ne 0)

    $remoteBranchListing = Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'remote/test-99')
    $testBranchListing   = Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'test-99')
    Assert-Equal -Name 'no orphan remote/test-99 branch' -Expected '' -Actual $remoteBranchListing
    Assert-Equal -Name 'no orphan test-99 branch' -Expected '' -Actual $testBranchListing

    $worktreesDir = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($root),
        "$([System.IO.Path]::GetFileName($root)).worktrees")
    $remoteWtPath = [System.IO.Path]::Combine($worktreesDir, 'remote-test-99')
    Assert-True -Name 'no orphan remote-test-99 worktree dir' `
                -Condition (-not [System.IO.Directory]::Exists($remoteWtPath))
} finally {
    Remove-Sandbox -Dir $sb3
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "create-remote-test: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
