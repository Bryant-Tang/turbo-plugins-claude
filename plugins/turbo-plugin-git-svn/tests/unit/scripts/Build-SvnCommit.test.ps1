# Build-SvnCommit.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin/scripts/Build-SvnCommit.ps1
# Behavior: 從 main worktree (cwd) 與 remote-<branch> worktree 對比;準備 push 的 git→svn
#   bridge (merge git branch into remote-* worktree)。Read-mostly,但會跑 svn-side commands。
#
# 本測試只測 read-only / error 分支:
#   1. Missing -Branch: 不傳 -Branch → exit 非 0,訊息提及「Missing required argument」
#   2. Branch not found: -Branch test-99 (沒有 remote-svn-test-99 worktree) → 訊息提及不存在
#   3. SKILL entry path consistency: 同一 case(missing arg)再呼叫 → 行為一致

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-SvnCommit.ps1')

    # The fixture has been reset by Run-Phase1 (Reset-Fixture.ps1) prior to invocation.
    $script:TestRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'test-turbo-plugin')

    # ─── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ───
    function Invoke-GitSilent {
        $allArgs = $args
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git @allArgs 2>$null | Out-Null
        } catch {
            # tolerate;tests assert outcomes from script-under-test, not fixture-init noise
        } finally {
            $ErrorActionPreference = $oldEap
        }
    }

    # Need a git repo for Get-MainWorktree to work — fixture base has no .git, so init one.
    function Ensure-FixtureGit {
        param([string]$Root)
        if (-not [System.IO.Directory]::Exists($Root)) { return $false }
        if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($Root, '.git'))) {
            Push-Location -LiteralPath $Root
            try {
                Invoke-GitSilent init -q
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                Invoke-GitSilent add -A
                Invoke-GitSilent -c commit.gpgsign=false commit -q -m 'fixture init'
            } finally { Pop-Location }
        }
        return $true
    }

    function Invoke-Script {
        param([string]$WorkDir, [string[]]$ExtraArgs = @())
        $oldLoc = Get-Location
        try {
            Set-Location -LiteralPath $WorkDir
            $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
            $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
            try {
                # Quote -File (and any spaced ExtraArg) so a spaced repo/parent path (AE8) survives
                # Start-Process's naive space-join of -ArgumentList.
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) + @($ExtraArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
                $proc = Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList $argList -WorkingDirectory $WorkDir `
                    -RedirectStandardOutput $tmpStdout -RedirectStandardError $tmpStderr `
                    -NoNewWindow -PassThru -Wait
                $stdout = if (Test-Path -LiteralPath $tmpStdout -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStdout, [System.Text.Encoding]::UTF8) } else { '' }
                $stderr = if (Test-Path -LiteralPath $tmpStderr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStderr, [System.Text.Encoding]::UTF8) } else { '' }
                return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode }
            } finally {
                foreach ($t in @($tmpStdout, $tmpStderr)) {
                    if (Test-Path -LiteralPath $t -PathType Leaf) {
                        try { [System.IO.File]::Delete($t) } catch { }
                    }
                }
            }
        } finally { Set-Location -LiteralPath $oldLoc }
    }

    $script:FixtureReady = Ensure-FixtureGit -Root $script:TestRoot
}

Describe 'Build-SvnCommit' {

    It 'fixture git repo is present (Reset-Fixture should have created it)' {
        $script:FixtureReady | Should -BeTrue
    }

    Context 'Case 1: missing -Branch' {
        BeforeAll { $script:r1 = Invoke-Script -WorkDir $script:TestRoot }

        It 'exit != 0' { ($script:r1.Exit -ne 0) | Should -BeTrue }
        It '訊息提及 Missing required argument' {
            ($script:r1.Stdout + "`n" + $script:r1.Stderr) | Should -Match 'Missing required argument'
        }
    }

    Context 'Case 2: SKILL entry — re-invoke 結果一致' {
        BeforeAll { $script:r2 = Invoke-Script -WorkDir $script:TestRoot }

        It 'SKILL-entry exit != 0' { ($script:r2.Exit -ne 0) | Should -BeTrue }
    }

    Context 'Case 3: branch test-99 (worktree absent)' {
        BeforeAll { $script:r3 = Invoke-Script -WorkDir $script:TestRoot -ExtraArgs @('-Branch', 'test-99') }

        It 'branch test-99 unknown exit != 0' { ($script:r3.Exit -ne 0) | Should -BeTrue }
        It '訊息提及 remote / not found / worktree' {
            ($script:r3.Stdout + "`n" + $script:r3.Stderr) | Should -Match '(not found|Unknown branch|worktree|remote-svn-test-99)'
        }
    }
}
