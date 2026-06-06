# Merge-MainIntoAll.test.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/Merge-MainIntoAll.ps1.
#
# Scope (U10 plan — NEW semantics):
#   - happy:    main advanced + 2 target branches (test-x, feature-y) behind main →
#               after run, both contain main's tip; main & remote-svn/main are NOT targets.
#   - exclude:  remote-svn/* branches and main itself are skipped (never touched).
#   - conflict: a branch conflicting with main is reported CONFLICT (abort, clean — no
#               conflict markers committed); OTHER non-conflicting branches still merge;
#               original branch is restored at end.
#
# Git-only (no SVN). Uses shared ScriptsCommon.ps1 helpers; no hardcoded paths (AE6).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Merge-MainIntoAll.ps1')

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] Merge-MainIntoAll.ps1 not found at $scriptUnderTest"
    exit 1
}

# ─── Fixture builders ────────────────────────────────────────────────────────

# Commit a file on the currently-checked-out branch.
function Commit-File {
    param([string]$Root, [string]$Name, [string]$Content, [string]$Msg)
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, $Name), $Content)
    $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
    $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', $Msg)
}

# Build: main with an extra commit ahead; two target branches forked BEFORE that commit
# (so they are behind main); a remote-svn/main branch that must NOT be touched.
function New-MergeFixture {
    param([string]$Root)
    New-GitMainRepo -Root $Root
    # Branch the two targets off the current main tip (behind the upcoming main commit).
    $null = Run-Git -Cwd $Root -GitArgs @('branch', 'test-x')
    $null = Run-Git -Cwd $Root -GitArgs @('branch', 'feature-y')
    # remote-svn/main bridge branch — must be excluded.
    $null = Run-Git -Cwd $Root -GitArgs @('branch', 'remote-svn/main')
    # Advance main with a new commit the targets don't have.
    Commit-File -Root $Root -Name 'main-only.txt' -Content 'main tip' -Msg 'feat: main advances'
}

# ─── Case 1: happy — both targets get main tip; main & remote-svn/main untouched ──

Write-Output ''
Write-Output 'Case 1: happy — test-x + feature-y both contain main tip; main & remote-svn/main not targets'
$sb1 = New-Sandbox -Tag 'merge-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    New-MergeFixture -Root $root

    $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
    $remoteSvnBefore = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/main')

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-Equal -Name 'happy exit 0' -Expected 0 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"

    # Both target branches must now contain main's tip (main is an ancestor of each).
    $tx = Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'test-x')
    Assert-Equal -Name 'test-x contains main tip' -Expected 0 -Actual $tx
    $fy = Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'feature-y')
    Assert-Equal -Name 'feature-y contains main tip' -Expected 0 -Actual $fy

    # main itself unchanged; remote-svn/main untouched.
    $mainAfter = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')
    Assert-Equal -Name 'main tip unchanged' -Expected $mainSha -Actual $mainAfter
    $remoteSvnAfter = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'remote-svn/main')
    Assert-Equal -Name 'remote-svn/main untouched' -Expected $remoteSvnBefore -Actual $remoteSvnAfter

    Assert-Match -Name 'summary lists merged' -Pattern 'Merged cleanly:' -InputText $res.Stdout
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: exclude — main & remote-svn/* never appear as merge targets ──────

Write-Output ''
Write-Output 'Case 2: exclude — main and remote-svn/* are not merge targets (no "OK main" / "OK remote-svn/*")'
$sb2 = New-Sandbox -Tag 'merge-2'
try {
    $root = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    New-MergeFixture -Root $root
    # add a second remote-svn branch to be thorough
    $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote-svn/test-1')

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-Equal -Name 'exclude exit 0' -Expected 0 -Actual $res.ExitCode -Message "stderr:`n$($res.Stderr)"

    # The per-branch "OK <branch>" lines must never name main or any remote-svn/* branch.
    Assert-True -Name 'no OK main line' -Condition ($res.Stdout -notmatch '(?m)^OK main\b')
    Assert-True -Name 'no OK remote-svn/* line' -Condition ($res.Stdout -notmatch '(?m)^OK remote-svn/')
    # Targets that SHOULD appear.
    Assert-Match -Name 'test-x merged' -Pattern '(?m)^OK test-x\b' -InputText $res.Stdout
    Assert-Match -Name 'feature-y merged' -Pattern '(?m)^OK feature-y\b' -InputText $res.Stdout
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Case 3: conflict — conflicting branch reported + aborted; others still merge ─

Write-Output ''
Write-Output 'Case 3: conflict — conflicting branch reported CONFLICT (aborted clean); non-conflicting branch merges; original branch restored'
$sb3 = New-Sandbox -Tag 'merge-3'
try {
    $root = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    New-GitMainRepo -Root $root

    # Create a shared file on main, then a clean target + a conflicting target.
    Commit-File -Root $root -Name 'shared.txt' -Content 'base' -Msg 'feat: add shared'
    $null = Run-Git -Cwd $root -GitArgs @('branch', 'clean-branch')
    $null = Run-Git -Cwd $root -GitArgs @('branch', 'conflict-branch')

    # conflict-branch edits shared.txt one way.
    $null = Run-Git -Cwd $root -GitArgs @('checkout', 'conflict-branch')
    Commit-File -Root $root -Name 'shared.txt' -Content 'branch-version' -Msg 'feat: branch edits shared'

    # back to main, edit shared.txt a conflicting way + advance.
    $null = Run-Git -Cwd $root -GitArgs @('checkout', 'main')
    Commit-File -Root $root -Name 'shared.txt' -Content 'main-version' -Msg 'feat: main edits shared'
    $mainSha = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', 'main')

    # Start on a known branch so we can assert it gets restored.
    $null = Run-Git -Cwd $root -GitArgs @('checkout', 'clean-branch')
    $startBranch = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
    Assert-Equal -Name 'start on clean-branch' -Expected 'clean-branch' -Actual $startBranch

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-Equal -Name 'conflict run exit 1' -Expected 1 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"

    # conflict-branch reported CONFLICT and NOT merged (main not an ancestor).
    Assert-Match -Name 'conflict-branch reported CONFLICT' -Pattern '(?m)^CONFLICT conflict-branch\b' -InputText $res.Stdout
    $cb = Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'conflict-branch')
    Assert-True -Name 'conflict-branch NOT merged' -Condition ($cb -ne 0)

    # clean-branch still merged (main is an ancestor).
    $cln = Run-Git -Cwd $root -GitArgs @('merge-base', '--is-ancestor', $mainSha, 'clean-branch')
    Assert-Equal -Name 'clean-branch merged' -Expected 0 -Actual $cln

    # No leftover MERGE_HEAD / conflict state in main worktree (abort was clean).
    $statusOut = Run-Git-Capture -Cwd $root -GitArgs @('status', '--porcelain')
    Assert-Equal -Name 'worktree clean after run' -Expected '' -Actual $statusOut

    # Original branch restored.
    $endBranch = Run-Git-Capture -Cwd $root -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
    Assert-Equal -Name 'original branch restored' -Expected 'clean-branch' -Actual $endBranch
} finally {
    Remove-Sandbox -Dir $sb3
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "merge-main-into-all: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
