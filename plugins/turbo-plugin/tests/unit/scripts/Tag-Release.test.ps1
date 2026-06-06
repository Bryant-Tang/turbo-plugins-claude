# Tag-Release.test.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/Tag-Release.ps1.
#
# Scope (U9 plan):
#   - happy:           on a fixture repo with a remote-svn/test-1 branch, --branch test-1
#                      creates a tag test-1-release-<date>-001 pointing at remote-svn/test-1.
#                      (Covers AE1's tag part — tag points at remote-svn/<branch>.)
#   - serial increment: run twice same day → -001 then -002.
#   - ref naming:      tag points at remote-svn/test-<n>, NOT remote/test-<n>.
#   - arg validation:  missing -Branch → exit non-zero + stderr.
#
# Git-only (no SVN needed for the tag). Uses shared ScriptsCommon.ps1 helpers; no hardcoded paths.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Tag-Release.ps1')

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] Tag-Release.ps1 not found at $scriptUnderTest"
    exit 1
}

# Build a main repo + a remote-svn/test-N branch ref (tip = main + 1 extra commit).
# The tag only needs the branch ref to exist; no linked worktree / SVN required.
function New-RepoWithRemoteSvnTestBranch {
    param([string]$Root, [int]$N = 1)
    New-GitMainRepo -Root $Root
    $remoteBranch = "remote-svn/test-$N"
    $null = Run-Git -Cwd $Root -GitArgs @('checkout', '-b', $remoteBranch)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, "remote-svn-test-$N.txt"), "remote-svn/test-$N tip")
    $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
    $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', "feat: remote-svn/test-$N tip")
    $null = Run-Git -Cwd $Root -GitArgs @('checkout', 'main')
}

$today = (Get-Date -Format 'yyyy-MM-dd')

# ─── Case 1: happy — tag created, points at remote-svn/test-1 ─────────────────

Write-Output ''
Write-Output 'Case 1: happy — --branch test-1 → tag test-1-release-<date>-001 == remote-svn/test-1'
$sb1 = New-Sandbox -Tag 'tagrel-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    New-RepoWithRemoteSvnTestBranch -Root $root -N 1

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
    Assert-Equal -Name 'tag-release exit 0' -Expected 0 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"

    $expectedTag = "test-1-release-$today-001"
    Assert-Match -Name 'stdout reports created tag' -Pattern ([regex]::Escape("Created tag: $expectedTag")) -InputText $res.Stdout

    $tagList = Run-Git-Capture -Cwd $root -GitArgs @('tag', '-l', $expectedTag)
    Assert-Equal -Name 'tag exists' -Expected $expectedTag -Actual $tagList

    # Tag points at remote-svn/test-1 tip.
    $tagSha    = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', $expectedTag)
    $remoteSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/test-1')
    Assert-Equal -Name 'tag SHA == remote-svn/test-1 SHA' -Expected $remoteSha -Actual $tagSha
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: serial increment — run twice same day → -001 then -002 ───────────

Write-Output ''
Write-Output 'Case 2: serial increment — two runs same day → -001 then -002'
$sb2 = New-Sandbox -Tag 'tagrel-2'
try {
    $root = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    New-RepoWithRemoteSvnTestBranch -Root $root -N 1

    $r1 = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
    Assert-Equal -Name 'first run exit 0' -Expected 0 -Actual $r1.ExitCode -Message "stderr:`n$($r1.Stderr)"
    Assert-Match -Name 'first run -001' -Pattern ([regex]::Escape("test-1-release-$today-001")) -InputText $r1.Stdout

    $r2 = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
    Assert-Equal -Name 'second run exit 0' -Expected 0 -Actual $r2.ExitCode -Message "stderr:`n$($r2.Stderr)"
    Assert-Match -Name 'second run -002' -Pattern ([regex]::Escape("test-1-release-$today-002")) -InputText $r2.Stdout
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Case 3: ref naming — tag points at remote-svn/* (NOT remote/*) ───────────

Write-Output ''
Write-Output 'Case 3: ref naming — tag resolves to remote-svn/test-1, and remote/test-1 does not exist'
$sb3 = New-Sandbox -Tag 'tagrel-3'
try {
    $root = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    New-RepoWithRemoteSvnTestBranch -Root $root -N 1

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Branch', 'test-1')
    Assert-Equal -Name 'tag-release exit 0' -Expected 0 -Actual $res.ExitCode -Message "stderr:`n$($res.Stderr)"

    $tagName = "test-1-release-$today-001"
    # The old (wrong) ref remote/test-1 must NOT exist in this fixture; tag must NOT match it.
    $oldRefRc = Run-Git -Cwd $root -GitArgs @('rev-parse', '--verify', 'remote/test-1')
    Assert-True -Name 'remote/test-1 does NOT exist (old naming absent)' -Condition ($oldRefRc -ne 0)

    $tagSha    = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', $tagName)
    $remoteSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/test-1')
    Assert-Equal -Name 'tag points at remote-svn/test-1 (new naming)' -Expected $remoteSha -Actual $tagSha
} finally {
    Remove-Sandbox -Dir $sb3
}

# ─── Case 4: arg validation — missing -Branch → non-zero + stderr ────────────

Write-Output ''
Write-Output 'Case 4: missing -Branch → exit non-zero + stderr mentions branch'
$sb4 = New-Sandbox -Tag 'tagrel-4'
try {
    $root = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
    New-RepoWithRemoteSvnTestBranch -Root $root -N 1

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-True -Name 'missing -Branch exits non-zero' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions Branch' -Pattern '(?i)branch' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb4
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "tag-release: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
