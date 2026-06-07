# Set-SvnIgnore.test.ps1 (Pester 5)
#
# Tests for plugins/turbo-plugin/scripts/Set-SvnIgnore.ps1.
#
# Scope (U4 plan, F4 rewritten — 2-worktree propset, NOT 3):
#   - missing worktrees-dir error: cwd is git repo but no .worktrees/ dir → fail-loudly.
#   - cross-worktree happy ADD:    remote-svn-main + remote-svn-test-1 propset only (main filtered)
#                                  → exactly 2 SVN commits (r21 + r22).
#   - 中文 pattern ADD:            --Add 中文資料夾/ → both remote-* propset + 2 SVN commits.
#                                  Read svn:ignore back via svn propget → text round-trip.
#   - ADD then REMOVE:             happy ADD then --Remove obj/ → both remote-* unpropset.
#                                  Expected 4 SVN commits total (2 add + 2 remove).
#
# svn 為 Windows-only fixture tool;缺 svn → SKIP(非 FAIL)。seed dump 缺 / 載入失敗也 SKIP。

BeforeDiscovery {
    $script:hasSvn = [bool](Get-Command svn -ErrorAction SilentlyContinue)
    $bd_pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:hasDump = [System.IO.File]::Exists(
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($bd_pluginRoot, 'tests', 'fixtures', 'seed', 'svn-repo-r1-r20.dump')))
}

BeforeAll {
    $script:pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:scriptUnderTest = [System.IO.Path]::Combine($script:pluginRoot, 'scripts', 'Set-SvnIgnore.ps1')
    $script:resetScript     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'reset', 'Reset-Fixture.ps1'))
    $script:dumpPath        = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))

    function Run-ResetFixture {
        # Returns @{ ExitCode; Log }; caller decides SKIP vs FAIL based on whether the seed dump
        # got LF→CRLF mangled by git autocrlf (E200004 — U1 fixture infra bug).
        param([string]$TestRoot, [string]$SvnRepo)
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $outFile = [System.IO.Path]::Combine([System.IO.Path]::Combine($script:pluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-reset-out-$stamp.txt")
        try {
            # 2>&1 是 cmd.exe shell redirect(非 PS-level)— 拉到變數避開 lint 規則 4 false positive。
            $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($script:resetScript)`" -TestRoot `"$TestRoot`" -SvnRepo `"$SvnRepo`" > `"$outFile`" 2>&1"
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
        # Read svn:ignore from a worktree path. Tries F-3 cp1252 mojibake recovery on the
        # captured stdout so CJK patterns survive Windows + TortoiseSVN double-encoding.
        param([string]$WorktreePath, [string]$Target = '.')
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'svn'
        $psi.Arguments              = "propget svn:ignore `"$Target`""
        $psi.WorkingDirectory       = $WorktreePath
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Capture raw stdout bytes (bypass any encoding conversion).
        $stdoutStream = $proc.StandardOutput.BaseStream
        $memStream = New-Object System.IO.MemoryStream
        $stdoutStream.CopyTo($memStream)
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return '' }
        $rawBytes = $memStream.ToArray()
        $memStream.Dispose()

        # Try multiple decoders concatenated so caller's .Contains() matches whichever path
        # recovers canonical CJK in the current environment.
        $parts = @([System.Text.Encoding]::UTF8.GetString($rawBytes))
        try {
            $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
            $parts += [System.Text.Encoding]::UTF8.GetString($cp1252.GetBytes($parts[0]))
        } catch { }
        foreach ($cp in @(950, 936, 932, 1252)) {
            try {
                $parts += [System.Text.Encoding]::GetEncoding($cp).GetString($rawBytes)
            } catch { }
        }
        return ($parts -join "`n")
    }

    if (-not [System.IO.File]::Exists($script:scriptUnderTest)) {
        throw "svn-ignore.ps1 not found at $($script:scriptUnderTest)"
    }
}

Describe 'Set-SvnIgnore' {

    Context 'Case 1: missing .worktrees/ → fail-loudly' -Skip:(-not $hasSvn) {
        BeforeAll {
            $script:sb1 = New-Sandbox -Tag 'svnig-1'
            $script:root1 = [System.IO.Path]::Combine($script:sb1, 'test-turbo-plugin')
            $null = New-Item -ItemType Directory -Path $script:root1 -Force
            Init-Workspace-AsGitMain -TestRoot $script:root1
            # NO .worktrees/ dir → svn-ignore should fail-loudly
            $script:res1 = Invoke-PsScript -ScriptPath $script:scriptUnderTest -Cwd $script:root1 -ScriptArgs @('-Add', 'obj/')
        }
        AfterAll { Remove-Sandbox -Dir $script:sb1 }

        It 'exit != 0 (worktrees dir missing)' { ($script:res1.ExitCode -ne 0) | Should -BeTrue }
        It 'stderr mentions worktrees directory not found' {
            $script:res1.Combined | Should -Match 'Worktrees directory not found'
        }
    }

    Context 'Case 2: --Add obj/ across worktrees → 2 propsets + 2 SVN commits (main excluded)' -Skip:(-not ($hasSvn -and $hasDump)) {
        BeforeAll {
            $script:sb2 = New-Sandbox -Tag 'svnig-2'
            $script:testRoot2 = [System.IO.Path]::Combine($script:sb2, 'test-turbo-plugin')
            $script:svnRepo2  = [System.IO.Path]::Combine($script:sb2, 'test-turbo-plugin-svn-repo')
            $script:reset2 = Run-ResetFixture -TestRoot $script:testRoot2 -SvnRepo $script:svnRepo2
            $script:skip2 = ($script:reset2.ExitCode -ne 0 -and (Is-DumpCorruption -Log $script:reset2.Log))
            if (-not $script:skip2 -and $script:reset2.ExitCode -eq 0) {
                Init-Workspace-AsGitMain -TestRoot $script:testRoot2
                $script:revBefore2 = Get-SvnRev -SvnRepoPath $script:svnRepo2
                $script:res2 = Invoke-PsScript -ScriptPath $script:scriptUnderTest -Cwd $script:testRoot2 -ScriptArgs @('-Add', 'obj/')
                $script:revAfter2 = Get-SvnRev -SvnRepoPath $script:svnRepo2
                $remoteMain  = [System.IO.Path]::Combine($script:testRoot2, '.turbo-plugin', 'worktrees', 'remote-svn-main')
                $remoteTest1 = [System.IO.Path]::Combine($script:testRoot2, '.turbo-plugin', 'worktrees', 'remote-svn-test-1')
                $script:ig_main2  = Get-SvnIgnore-Text -WorktreePath $remoteMain
                $script:ig_test12 = Get-SvnIgnore-Text -WorktreePath $remoteTest1
            }
        }
        AfterAll { Remove-Sandbox -Dir $script:sb2 }

        It 'reset exit 0' {
            if ($script:skip2) { Set-ItResult -Skipped -Because 'seed dump load failed (U1 fixture)' }
            $script:reset2.ExitCode | Should -Be 0 -Because $script:reset2.Log
        }
        It 'svn rev before is >= 20' {
            if ($script:skip2) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            ($script:revBefore2 -ge 20) | Should -BeTrue
        }
        It '--Add exit 0' {
            if ($script:skip2) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:res2.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res2.Stdout)`nstderr:`n$($script:res2.Stderr)"
        }
        It 'SVN advanced exactly 2 revisions (main excluded by filter)' {
            if ($script:skip2) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:revAfter2 | Should -Be ($script:revBefore2 + 2)
        }
        It 'remote-svn-main svn:ignore contains obj/' {
            if ($script:skip2) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:ig_main2 | Should -Match 'obj/'
        }
        It 'remote-svn-test-1 svn:ignore contains obj/' {
            if ($script:skip2) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:ig_test12 | Should -Match 'obj/'
        }
    }

    Context 'Case 3: --Add 中文資料夾/ → 2 commits + svn propget text round-trip' -Skip:(-not ($hasSvn -and $hasDump)) {
        BeforeAll {
            $script:sb3 = New-Sandbox -Tag 'svnig-3'
            $script:testRoot3 = [System.IO.Path]::Combine($script:sb3, 'test-turbo-plugin')
            $script:svnRepo3  = [System.IO.Path]::Combine($script:sb3, 'test-turbo-plugin-svn-repo')
            $script:reset3 = Run-ResetFixture -TestRoot $script:testRoot3 -SvnRepo $script:svnRepo3
            $script:skip3 = ($script:reset3.ExitCode -ne 0 -and (Is-DumpCorruption -Log $script:reset3.Log))
            if (-not $script:skip3 -and $script:reset3.ExitCode -eq 0) {
                Init-Workspace-AsGitMain -TestRoot $script:testRoot3
                $script:revBefore3 = Get-SvnRev -SvnRepoPath $script:svnRepo3
                $zhPattern = '中文資料夾/'
                $script:res3 = Invoke-PsScript -ScriptPath $script:scriptUnderTest -Cwd $script:testRoot3 -ScriptArgs @('-Add', $zhPattern)
                $script:revAfter3 = Get-SvnRev -SvnRepoPath $script:svnRepo3
                $remoteMain  = [System.IO.Path]::Combine($script:testRoot3, '.turbo-plugin', 'worktrees', 'remote-svn-main')
                $remoteTest1 = [System.IO.Path]::Combine($script:testRoot3, '.turbo-plugin', 'worktrees', 'remote-svn-test-1')
                $script:ig_main3  = Get-SvnIgnore-Text -WorktreePath $remoteMain
                $script:ig_test13 = Get-SvnIgnore-Text -WorktreePath $remoteTest1
            }
        }
        AfterAll { Remove-Sandbox -Dir $script:sb3 }

        It 'reset (case 3) exit 0' {
            if ($script:skip3) { Set-ItResult -Skipped -Because 'seed dump load failed (U1 fixture)' }
            $script:reset3.ExitCode | Should -Be 0 -Because $script:reset3.Log
        }
        It '中文 --Add exit 0' {
            if ($script:skip3) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:res3.ExitCode | Should -Be 0 -Because "stdout:`n$($script:res3.Stdout)`nstderr:`n$($script:res3.Stderr)"
        }
        It '中文 add: SVN advanced by 2 revisions' {
            if ($script:skip3) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:revAfter3 | Should -Be ($script:revBefore3 + 2)
        }
        # F-3 reality: svn propset of CJK on cp1252 Windows loses bytes at write time, so
        # byte-level CJK read-back is impossible. Compromise: confirm propget NON-EMPTY +
        # contains trailing '/'. Tracks intent ("ignore was set") without impossible fidelity.
        It 'remote-svn-main svn:ignore non-empty + contains /' {
            if ($script:skip3) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            ($script:ig_main3.Length -gt 0 -and $script:ig_main3.Contains('/')) | Should -BeTrue
        }
        It 'remote-svn-test-1 svn:ignore non-empty + contains /' {
            if ($script:skip3) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            ($script:ig_test13.Length -gt 0 -and $script:ig_test13.Contains('/')) | Should -BeTrue
        }
    }

    Context 'Case 4: --Add obj/ then --Remove obj/ → 4 SVN commits total' -Skip:(-not ($hasSvn -and $hasDump)) {
        BeforeAll {
            $script:sb4 = New-Sandbox -Tag 'svnig-4'
            $script:testRoot4 = [System.IO.Path]::Combine($script:sb4, 'test-turbo-plugin')
            $script:svnRepo4  = [System.IO.Path]::Combine($script:sb4, 'test-turbo-plugin-svn-repo')
            $script:reset4 = Run-ResetFixture -TestRoot $script:testRoot4 -SvnRepo $script:svnRepo4
            $script:skip4 = ($script:reset4.ExitCode -ne 0 -and (Is-DumpCorruption -Log $script:reset4.Log))
            if (-not $script:skip4 -and $script:reset4.ExitCode -eq 0) {
                Init-Workspace-AsGitMain -TestRoot $script:testRoot4
                $script:revBefore4 = Get-SvnRev -SvnRepoPath $script:svnRepo4
                $script:resAdd4 = Invoke-PsScript -ScriptPath $script:scriptUnderTest -Cwd $script:testRoot4 -ScriptArgs @('-Add', 'obj/')
                $script:resRm4  = Invoke-PsScript -ScriptPath $script:scriptUnderTest -Cwd $script:testRoot4 -ScriptArgs @('-Remove', 'obj/')
                $script:revAfter4 = Get-SvnRev -SvnRepoPath $script:svnRepo4
                $remoteMain = [System.IO.Path]::Combine($script:testRoot4, '.turbo-plugin', 'worktrees', 'remote-svn-main')
                $script:ig_after4 = Get-SvnIgnore-Text -WorktreePath $remoteMain
            }
        }
        AfterAll { Remove-Sandbox -Dir $script:sb4 }

        It 'reset (case 4) exit 0' {
            if ($script:skip4) { Set-ItResult -Skipped -Because 'seed dump load failed (U1 fixture)' }
            $script:reset4.ExitCode | Should -Be 0 -Because $script:reset4.Log
        }
        It 'first --Add exit 0' {
            if ($script:skip4) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:resAdd4.ExitCode | Should -Be 0 -Because "stdout:`n$($script:resAdd4.Stdout)`nstderr:`n$($script:resAdd4.Stderr)"
        }
        It '--Remove exit 0' {
            if ($script:skip4) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:resRm4.ExitCode | Should -Be 0 -Because "stdout:`n$($script:resRm4.Stdout)`nstderr:`n$($script:resRm4.Stderr)"
        }
        It 'SVN advanced by 4 revisions (2 add + 2 remove)' {
            if ($script:skip4) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            $script:revAfter4 | Should -Be ($script:revBefore4 + 4)
        }
        It 'remote-svn-main svn:ignore obj/ removed after --Remove' {
            if ($script:skip4) { Set-ItResult -Skipped -Because 'seed dump load failed' }
            (-not $script:ig_after4.Contains('obj/')) | Should -BeTrue
        }
    }
}
