# reset-remote-test.Tests.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/Reset-RemoteTest.ps1.
#
# Scope (U4 plan):
#   - happy:               test-N branch ahead of main → reset → test-N HEAD = main HEAD
#   - dirty branch refuse: main has uncommitted change → script refuses with "uncommitted changes"
#
# Setup uses shared `ScriptsCommon.ps1` helpers in tests/lib/.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Reset-RemoteTest.ps1')

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] reset-remote-test.ps1 not found at $scriptUnderTest"
    exit 1
}

function New-RepoWithTestBranchAhead {
    # main has 1 commit; test-N branch has main + 1 extra; remote-test-N linked worktree on remote/test-N.
    param([string]$Root, [int]$N = 1)
    New-GitMainRepo -Root $Root
    $tb = "test-$N"
    $null = Run-Git -Cwd $Root -GitArgs @('branch', $tb)
    $null = Run-Git -Cwd $Root -GitArgs @('checkout', $tb)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, "test-$N-only.txt"), "test-$N specific")
    $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
    $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', "feat: test-$N-only change")
    $null = Run-Git -Cwd $Root -GitArgs @('checkout', 'main')

    $wtDir = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($Root),
        "$([System.IO.Path]::GetFileName($Root)).worktrees")
    $null = New-Item -ItemType Directory -Path $wtDir -Force
    $remoteTestDir = [System.IO.Path]::Combine($wtDir, "remote-test-$N")
    $null = Run-Git -Cwd $Root -GitArgs @('branch', "remote/test-$N", 'main')
    $null = Run-Git -Cwd $Root -GitArgs @('worktree', 'add', $remoteTestDir, "remote/test-$N")
}

# ─── Case 1: happy ───────────────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 1: happy — test-1 ahead of main → reset → test-1 HEAD = main HEAD'
$sb1 = New-Sandbox -Tag 'rrt-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    New-RepoWithTestBranchAhead -Root $root -N 1
    $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
    $testSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'test-1')
    Assert-True -Name 'pre: test-1 SHA != main SHA' -Condition ($mainSha -ne $testSha)

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-N', '1')
    Assert-Equal -Name 'reset exit 0' -Expected 0 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"
    Assert-Match -Name 'stdout contains LOSE marker' -Pattern '(?m)^LOSE' -InputText $res.Stdout

    $mainSha2 = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
    $testSha2 = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'test-1')
    Assert-Equal -Name 'post: test-1 SHA == main SHA' -Expected $mainSha2 -Actual $testSha2
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: main dirty → refuse ─────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 2: main worktree has uncommitted change → refuse with error'
$sb2 = New-Sandbox -Tag 'rrt-2'
try {
    $root = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    New-RepoWithTestBranchAhead -Root $root -N 1
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'dirty.txt'), 'uncommitted')

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-N', '1')
    Assert-True -Name 'reset exit != 0 (refused)' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr contains "uncommitted"' `
                 -Pattern 'uncommitted' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "reset-remote-test: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
