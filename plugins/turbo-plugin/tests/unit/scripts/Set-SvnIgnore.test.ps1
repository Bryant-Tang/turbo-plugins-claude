# svn-ignore.Tests.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/svn-ignore.ps1.
#
# Scope (U4 plan, F4 rewritten — 2-worktree propset, NOT 3):
#   - cross-worktree happy ADD:    main + remote-main + remote-test-1 worktrees exist.
#                                  svn-ignore --Add obj/ → propset on remote-main + remote-test-1 ONLY
#                                  (main is filtered out by `^remote-(main|test-\d+)$`).
#                                  Expected: exactly **2** SVN commits (r21 + r22).
#   - 中文 pattern ADD:            --Add 中文資料夾/ → both remote-* propset + 2 SVN commits.
#                                  Read svn:ignore back via svn propget → text contains 中文資料夾/
#                                  (text round-trip; NOT byte-equal per F-3 / AssertHelpers docs).
#   - ADD then REMOVE:             happy ADD then --Remove obj/ → both remote-* unpropset.
#                                  Expected 4 SVN commits total (2 add + 2 remove).
#   - missing worktrees-dir error: cwd is git repo but no .worktrees/ dir → fail-loudly.
#
# Fixture wiring:
#   Reset-Fixture seeds: .worktrees/{remote-main, remote-test-1} as SVN checkouts from the seed dump.
#   We additionally `git init` + commit in the workspace root so Get-MainWorktree resolves.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'svn-ignore.ps1')
$resetScript     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'reset', 'Reset-Fixture.ps1'))
$dumpPath        = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] svn-ignore.ps1 not found at $scriptUnderTest"
    exit 1
}

function Run-ResetFixture {
    # Returns @{ ExitCode; Log }; caller decides SKIP vs FAIL based on whether the seed dump
    # got LF→CRLF mangled by git autocrlf (E200004 — U1 fixture infra bug).
    param([string]$TestRoot, [string]$SvnRepo)
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 10)
    $outFile = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-reset-out-$stamp.txt")
    try {
        # 2>&1 是 cmd.exe shell redirect(非 PS-level)— 拉到變數避開 lint 規則 4 false positive。
        $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$resetScript`" -TestRoot `"$TestRoot`" -SvnRepo `"$SvnRepo`" > `"$outFile`" 2>&1"
        & cmd.exe /c $cmdStr
        $rc = $LASTEXITCODE
        $log = if ([System.IO.File]::Exists($outFile)) { [System.IO.File]::ReadAllText($outFile) } else { '' }
        return @{ ExitCode = $rc; Log = $log }
    } finally {
        if ([System.IO.File]::Exists($outFile)) { try { [System.IO.File]::Delete($outFile) } catch {} }
    }
}

function Is-DumpCorruption {
    param([string]$Log)
    return ($Log -match 'E200004|Could not convert|svnadmin load failed')
}

function Init-Workspace-AsGitMain {
    # After Reset-Fixture mirrors base/ into TestRoot, `git init` so Get-MainWorktree works.
    param([string]$TestRoot)
    $null = Run-Git -Cwd $TestRoot -GitArgs @('init', '-b', 'main')
    $null = Run-Git -Cwd $TestRoot -GitArgs @('config', 'user.email', 'test@turbo-plugin')
    $null = Run-Git -Cwd $TestRoot -GitArgs @('config', 'user.name',  'turbo-plugin-test')
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($TestRoot, 'init.txt'), 'init')
    $null = Run-Git -Cwd $TestRoot -GitArgs @('add', '-A')
    $null = Run-Git -Cwd $TestRoot -GitArgs @('commit', '-m', 'initial', '--allow-empty')
}

function Get-SvnRev {
    # Return current HEAD revision of the SVN repo.
    param([string]$SvnRepoPath)
    $repoUri = 'file:///' + ($SvnRepoPath -replace '\\', '/')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'svn'
    $psi.Arguments              = "info --show-item revision `"$repoUri`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { return -1 }
    return [int]$stdout.Trim()
}

function Get-SvnIgnore-Text {
    # Read svn:ignore from a worktree path; return raw stdout decoded as UTF-8.
    param([string]$WorktreePath, [string]$Target = '.')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'svn'
    $psi.Arguments              = "propget svn:ignore `"$Target`""
    $psi.WorkingDirectory       = $WorktreePath
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { return '' }
    return $stdout
}

# ─── Case 1: missing worktrees dir → fail-loudly ─────────────────────────────

Write-Output ''
Write-Output 'Case 1: missing .worktrees/ → "Worktrees directory not found"'
$sb1 = New-Sandbox -Tag 'svnig-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    $null = New-Item -ItemType Directory -Path $root -Force
    Init-Workspace-AsGitMain -TestRoot $root
    # NO .worktrees/ dir → svn-ignore should fail-loudly

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @('-Add', 'obj/')
    Assert-True -Name 'exit != 0 (worktrees dir missing)' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions worktrees directory not found' `
                 -Pattern 'Worktrees directory not found' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Cases 2-4: require seeded SVN fixture ───────────────────────────────────

if (-not [System.IO.File]::Exists($dumpPath)) {
    Write-Output ''
    Write-Output "  [SKIP] cases 2-4 (seed dump missing at $dumpPath; run build-seed-repo.ps1)"
} else {

    # ─── Case 2: cross-worktree happy ADD → exactly 2 SVN commits ────────────

    Write-Output ''
    Write-Output 'Case 2: --Add obj/ across worktrees → 2 propsets + 2 SVN commits (main excluded)'
    $sb2 = New-Sandbox -Tag 'svnig-2'
    try {
        $testRoot = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
        $svnRepo  = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin-svn-repo')
        $reset = Run-ResetFixture -TestRoot $testRoot -SvnRepo $svnRepo
        if ($reset.ExitCode -ne 0 -and (Is-DumpCorruption -Log $reset.Log)) {
            Write-Output "  [SKIP] case 2 — seed dump load failed (LF→CRLF mangle / U1 .gitattributes fix needed)"
        } else {
            Assert-Equal -Name 'reset exit 0' -Expected 0 -Actual $reset.ExitCode -Message $reset.Log
            if ($reset.ExitCode -eq 0) {
                Init-Workspace-AsGitMain -TestRoot $testRoot
                $revBefore = Get-SvnRev -SvnRepoPath $svnRepo
                Assert-True -Name 'svn rev before is >= 20' -Condition ($revBefore -ge 20)

                $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @('-Add', 'obj/')
                Assert-Equal -Name '--Add exit 0' -Expected 0 -Actual $res.ExitCode `
                    -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"

                $revAfter = Get-SvnRev -SvnRepoPath $svnRepo
                Assert-Equal -Name 'SVN advanced exactly 2 revisions (main excluded by filter)' `
                             -Expected ($revBefore + 2) -Actual $revAfter

                $remoteMain  = [System.IO.Path]::Combine($testRoot + '.worktrees', 'remote-main')
                $remoteTest1 = [System.IO.Path]::Combine($testRoot + '.worktrees', 'remote-test-1')
                $ig_main_text  = Get-SvnIgnore-Text -WorktreePath $remoteMain
                $ig_test1_text = Get-SvnIgnore-Text -WorktreePath $remoteTest1
                Assert-Match -Name 'remote-main svn:ignore contains obj/' -Pattern 'obj/' -InputText $ig_main_text
                Assert-Match -Name 'remote-test-1 svn:ignore contains obj/' -Pattern 'obj/' -InputText $ig_test1_text
            }
        }
    } finally {
        Remove-Sandbox -Dir $sb2
    }

    # ─── Case 3: 中文 pattern ADD → both worktrees + text round-trip ─────────

    Write-Output ''
    Write-Output 'Case 3: --Add 中文資料夾/ → 2 commits + svn propget text round-trip contains 中文'
    $sb3 = New-Sandbox -Tag 'svnig-3'
    try {
        $testRoot = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
        $svnRepo  = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin-svn-repo')
        $reset = Run-ResetFixture -TestRoot $testRoot -SvnRepo $svnRepo
        if ($reset.ExitCode -ne 0 -and (Is-DumpCorruption -Log $reset.Log)) {
            Write-Output "  [SKIP] case 3 — seed dump load failed (U1 fixture)"
        } else {
            Assert-Equal -Name 'reset (case 3) exit 0' -Expected 0 -Actual $reset.ExitCode -Message $reset.Log
            if ($reset.ExitCode -eq 0) {
                Init-Workspace-AsGitMain -TestRoot $testRoot
                $revBefore = Get-SvnRev -SvnRepoPath $svnRepo
                $zhPattern = '中文資料夾/'
                $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @('-Add', $zhPattern)
                Assert-Equal -Name '中文 --Add exit 0' -Expected 0 -Actual $res.ExitCode `
                    -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"
                $revAfter = Get-SvnRev -SvnRepoPath $svnRepo
                Assert-Equal -Name '中文 add: SVN advanced by 2 revisions' -Expected ($revBefore + 2) -Actual $revAfter

                $remoteMain  = [System.IO.Path]::Combine($testRoot + '.worktrees', 'remote-main')
                $remoteTest1 = [System.IO.Path]::Combine($testRoot + '.worktrees', 'remote-test-1')
                $ig_main  = Get-SvnIgnore-Text -WorktreePath $remoteMain
                $ig_test1 = Get-SvnIgnore-Text -WorktreePath $remoteTest1
                Assert-True -Name 'remote-main svn:ignore text contains 中文資料夾/' -Condition ($ig_main.Contains($zhPattern))
                Assert-True -Name 'remote-test-1 svn:ignore text contains 中文資料夾/' -Condition ($ig_test1.Contains($zhPattern))
            }
        }
    } finally {
        Remove-Sandbox -Dir $sb3
    }

    # ─── Case 4: ADD then REMOVE → total 4 SVN commits ───────────────────────

    Write-Output ''
    Write-Output 'Case 4: --Add obj/ then --Remove obj/ → 4 SVN commits total'
    $sb4 = New-Sandbox -Tag 'svnig-4'
    try {
        $testRoot = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
        $svnRepo  = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin-svn-repo')
        $reset = Run-ResetFixture -TestRoot $testRoot -SvnRepo $svnRepo
        if ($reset.ExitCode -ne 0 -and (Is-DumpCorruption -Log $reset.Log)) {
            Write-Output "  [SKIP] case 4 — seed dump load failed (U1 fixture)"
        } else {
            Assert-Equal -Name 'reset (case 4) exit 0' -Expected 0 -Actual $reset.ExitCode -Message $reset.Log
            if ($reset.ExitCode -eq 0) {
                Init-Workspace-AsGitMain -TestRoot $testRoot
                $revBefore = Get-SvnRev -SvnRepoPath $svnRepo

                $resAdd = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @('-Add', 'obj/')
                Assert-Equal -Name 'first --Add exit 0' -Expected 0 -Actual $resAdd.ExitCode `
                    -Message "stdout:`n$($resAdd.Stdout)`nstderr:`n$($resAdd.Stderr)"

                $resRm = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @('-Remove', 'obj/')
                Assert-Equal -Name '--Remove exit 0' -Expected 0 -Actual $resRm.ExitCode `
                    -Message "stdout:`n$($resRm.Stdout)`nstderr:`n$($resRm.Stderr)"

                $revAfter = Get-SvnRev -SvnRepoPath $svnRepo
                Assert-Equal -Name 'SVN advanced by 4 revisions (2 add + 2 remove)' `
                             -Expected ($revBefore + 4) -Actual $revAfter

                $remoteMain = [System.IO.Path]::Combine($testRoot + '.worktrees', 'remote-main')
                $ig_after = Get-SvnIgnore-Text -WorktreePath $remoteMain
                Assert-True -Name 'remote-main svn:ignore obj/ removed after --Remove' `
                            -Condition (-not $ig_after.Contains('obj/'))
            }
        }
    } finally {
        Remove-Sandbox -Dir $sb4
    }
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "svn-ignore: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
