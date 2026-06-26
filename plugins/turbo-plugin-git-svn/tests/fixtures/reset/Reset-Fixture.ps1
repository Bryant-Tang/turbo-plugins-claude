# Reset-Fixture.ps1
#
# Per-case fixture reset entry for turbo-plugin Phase 1 tests.
#
# 做三件事:
#   1. robocopy /MIR  plugins/turbo-plugin-git-svn/tests/fixtures/base  ->  $TestRoot
#      (default = repo-relative, gitignored tests/.sandbox/test-turbo-plugin)
#      (F-4 fix: robocopy exit 0-7 都是 success;只 ≥ 8 才 throw,且每次跑完 reset $LASTEXITCODE = 0)
#   2. svnadmin create $SvnRepo; svnadmin load < seed.dump  (via cmd /c redirect, F-2 一致)
#   3. svn checkout trunk -> <TestRoot>\.turbo-plugin\worktrees\remote-svn-main
#      svn checkout branches/test-1 -> <TestRoot>\.turbo-plugin\worktrees\remote-svn-test-1
#      (nested layout: container lives INSIDE the main worktree at
#       <TestRoot>\.turbo-plugin\worktrees\。所有 turbo-plugin script — resolve-iis-settings /
#       svn-log / pull-from-svn 等 — 都讀這個 nested 路徑。)
#
# Idempotent:任意先前狀態 (clean / dirty / 中間態) 都還原到 base。
# Delete 前清 ReadOnly attr(SVN repo 的 'format' file 與 worktree 的 '.svn/' 內檔都是
# ReadOnly,[System.IO.Directory]::Delete 不會自動清,需 walk 子樹手動清)。
#
# 為 PS 5.1 + 中文 Windows 寫;以 UTF-8 BOM 存檔。

[CmdletBinding()]
param(
    [string]$TestRoot,
    [string]$SvnRepo,
    [string]$BaseDir,
    [string]$DumpPath,
    [switch]$SkipSvn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Helper: delete dir tree with ReadOnly attr clear ─────────────────────────
#
# SVN repo db/format / db/revs/* 等 file 是 ReadOnly,worktree .svn/wc.db 也含
# ReadOnly file。[System.IO.Directory]::Delete($dir, $true) 對 ReadOnly file 會
# throw 'Access denied'。先 walk 子樹清 ReadOnly bit 再 Delete。
function Remove-DirTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) { return }
    foreach ($f in [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) {
        $fa = [System.IO.File]::GetAttributes($f)
        if ($fa -band [System.IO.FileAttributes]::ReadOnly) {
            [System.IO.File]::SetAttributes($f, $fa -band (-bnot [System.IO.FileAttributes]::ReadOnly))
        }
    }
    [System.IO.Directory]::Delete($Path, $true)
}

# ─── Paths ────────────────────────────────────────────────────────────────────

$scriptDir = $PSScriptRoot
# Reset-Fixture.ps1 lives at: <repo>/plugins/turbo-plugin-git-svn/tests/fixtures/reset/Reset-Fixture.ps1
# base/   ->  ../base
# seed/   ->  ../seed
# tests/  ->  ../..
$fixturesDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..'))
$testsDir    = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..', '..'))

# Default work root = repo-relative, gitignored tests/.sandbox/. Resolved LONG form via
# GetFullPath so 8.3 short-names never appear and a spaced parent path is tolerated. The svn
# CLIENT calls below get --config-dir <sandbox>/.svnconfig so %APPDATA%\Subversion is untouched.
$sandboxDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($testsDir, '.sandbox'))
if ([string]::IsNullOrWhiteSpace($TestRoot)) {
    $TestRoot = [System.IO.Path]::Combine($sandboxDir, 'test-turbo-plugin')
}
if ([string]::IsNullOrWhiteSpace($SvnRepo)) {
    $SvnRepo = [System.IO.Path]::Combine($sandboxDir, 'svn-repo')
}
$svnConfigDir = [System.IO.Path]::Combine($sandboxDir, '.svnconfig')

if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    $BaseDir = [System.IO.Path]::Combine($fixturesDir, 'base')
}
if ([string]::IsNullOrWhiteSpace($DumpPath)) {
    $DumpPath = [System.IO.Path]::Combine($fixturesDir, 'seed', 'svn-repo-r1-r20.dump')
}

# ─── Sanity checks ────────────────────────────────────────────────────────────

if (-not [System.IO.Directory]::Exists($BaseDir)) {
    throw "Base fixture dir does not exist: $BaseDir"
}
if (-not $SkipSvn -and -not (Test-Path -LiteralPath $DumpPath -PathType Leaf)) {
    throw @"
SVN seed dump does not exist: $DumpPath
Run plugins/turbo-plugin-git-svn/tests/fixtures/seed/build-seed-repo.ps1 first (or pass -SkipSvn to reset only the workspace mirror).
"@
}

# ─── Step 1: robocopy /MIR (F-4 fix) ──────────────────────────────────────────
#
# robocopy exit code semantics (NOT ordinary unix exit):
#   0   = no files copied (already in sync)
#   1   = files copied successfully
#   2   = extra files / dirs detected (informational)
#   4   = mismatched files / dirs detected (informational)
#   1-7 = various combinations of the above; ALL SUCCESS
#   ≥ 8 = at least one failure
# Treat 0-7 as success; only throw on ≥ 8. Then reset $LASTEXITCODE = 0 so
# downstream `if ($LASTEXITCODE -ne 0)` checks don't false-positive (repo-wide
# $ErrorActionPreference = 'Stop' would otherwise make a stale $LASTEXITCODE=1
# silently kill the next native invocation).

if (-not [System.IO.Directory]::Exists($TestRoot)) {
    $null = New-Item -ItemType Directory -Path $TestRoot -Force
}

Write-Output "Step 1: robocopy /MIR  $BaseDir  ->  $TestRoot"
# /MIR  = mirror (purge + copy)
# /NFL  = no file list (less noise)
# /NDL  = no dir list
# /NJH  = no job header
# /NJS  = no job summary
# /NP   = no progress
# /R:1  /W:1  = retry once with 1-sec wait (default 1M retries × 30 sec = forever)
# We keep some output for orchestrator log; drop /NFL if debugging.
& robocopy.exe $BaseDir $TestRoot /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    throw "robocopy /MIR failed with exit code $rc (≥ 8 = real failure)."
}
# F-4 fix: explicitly reset so downstream checks don't see stale 1-7.
$global:LASTEXITCODE = 0
Write-Output "  robocopy OK (exit=$rc treated as success)"

# ─── Step 2: SVN repo reset via svnadmin load ─────────────────────────────────

if (-not $SkipSvn) {
    Write-Output "Step 2: rebuild SVN repo at $SvnRepo from $DumpPath"

    try {
        Remove-DirTree -Path $SvnRepo
    } catch {
        throw "Failed to delete previous SVN repo at $SvnRepo : $($_.Exception.Message)"
    }

    # Ensure parent dir exists
    $svnParent = [System.IO.Path]::GetDirectoryName($SvnRepo)
    if (-not [System.IO.Directory]::Exists($svnParent)) {
        $null = New-Item -ItemType Directory -Path $svnParent -Force
    }

    & svnadmin create $SvnRepo
    if ($LASTEXITCODE -ne 0) {
        throw "svnadmin create $SvnRepo failed with exit code $LASTEXITCODE"
    }

    # Use cmd /c stdin redirect to feed dump to svnadmin load — matches the F-2
    # symmetry of build-seed-repo.ps1's dump step.
    $loadCmd = "svnadmin.exe load `"$SvnRepo`" < `"$DumpPath`""
    & cmd.exe /c $loadCmd | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "cmd /c svnadmin load failed with exit code $LASTEXITCODE"
    }
    Write-Output "  svnadmin load OK"

    # ─── Step 3: svn checkout remote-svn-main / remote-svn-test-1 ─────────────
    #
    # nested layout (matches Get-WorktreesDir):
    #   <TestRoot>                              main project
    #   <TestRoot>/.turbo-plugin/worktrees/     worktrees container (inside main)
    #     ├── remote-svn-main/
    #     └── remote-svn-test-1/
    # turbo-plugin scripts(resolve-iis-settings / svn-log / pull-from-svn etc.)
    # 都讀 `<TestRoot>/.turbo-plugin/worktrees/` 這個 nested 路徑。

    $worktreesDir   = [System.IO.Path]::Combine($TestRoot, '.turbo-plugin', 'worktrees')
    $remoteMainDir  = [System.IO.Path]::Combine($worktreesDir, 'remote-svn-main')
    $remoteTest1Dir = [System.IO.Path]::Combine($worktreesDir, 'remote-svn-test-1')

    # 整個 sibling worktrees container 砍掉重建(per-case clean slate)。
    # ReadOnly attr clear 由 Remove-DirTree helper 處理(`.svn/` 內含 ReadOnly file)。
    try {
        Remove-DirTree -Path $worktreesDir
    } catch {
        throw "Failed to delete previous worktrees container $worktreesDir : $($_.Exception.Message)"
    }
    $null = New-Item -ItemType Directory -Path $worktreesDir -Force

    $repoUri = 'file:///' + ($SvnRepo -replace '\\', '/')

    # svn CLIENT calls get --config-dir <sandbox>/.svnconfig so %APPDATA%\Subversion is not
    # touched (svnadmin create/load above read no global state and accept no --config-dir).
    Write-Output "Step 3a: svn checkout trunk -> $remoteMainDir"
    & svn checkout --config-dir $svnConfigDir "$repoUri/trunk" $remoteMainDir | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "svn checkout trunk failed with exit code $LASTEXITCODE"
    }

    Write-Output "Step 3b: svn checkout branches/test-1 -> $remoteTest1Dir"
    & svn checkout --config-dir $svnConfigDir "$repoUri/branches/test-1" $remoteTest1Dir | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "svn checkout branches/test-1 failed with exit code $LASTEXITCODE"
    }
}

Write-Output ""
Write-Output "✔ Fixture reset complete."
Write-Output "  Workspace: $TestRoot"
if (-not $SkipSvn) {
    Write-Output "  SVN repo:  $SvnRepo (loaded from $DumpPath)"
    Write-Output "  Remote-*:  ${TestRoot}\.turbo-plugin\worktrees\{remote-svn-main, remote-svn-test-1}"
} else {
    Write-Output "  (SVN reset skipped)"
}

exit 0
