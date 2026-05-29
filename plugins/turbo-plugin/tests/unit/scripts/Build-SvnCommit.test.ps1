# push-to-svn-prepare.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/push-to-svn-prepare.ps1
# Behavior: 從 main worktree (cwd) 與 remote-<branch> worktree 對比;準備 push 的 git→svn
#   bridge (merge git branch into remote-* worktree)。Read-mostly,但會跑 svn-side commands。
#
# 本測試只測 read-only / error 分支:
#   1. Missing -Branch: 不傳 -Branch → exit 非 0,訊息提及「Missing required argument」
#   2. Branch not found: -Branch test-99 (沒有 remote-test-99 worktree) → 訊息提及不存在
#   3. SKILL entry path consistency: 同一 case(missing arg)再呼叫 → 行為一致

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'AssertHelpers.ps1')
. $LibPath
Reset-Counters


# ─── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ───
# wrap each git call so stderr noise doesn't trigger NativeCommandError termination.
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

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'push-to-svn-prepare.ps1')

# The fixture has been reset by Run-Phase1 (Reset-Fixture.ps1) prior to invocation.
$testRoot = 'C:\Turbo\test-turbo-plugin'

# Need a git repo for Get-MainWorktree to work — fixture base has no .git, so init one.
function Ensure-FixtureGit {
    if (-not [System.IO.Directory]::Exists($testRoot)) { return $false }
    if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($testRoot, '.git'))) {
        Push-Location -LiteralPath $testRoot
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
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptUnderTest) + $ExtraArgs
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

if (-not (Ensure-FixtureGit)) {
    Write-Output "  [FAIL] setup: fixture $testRoot not found (Reset-Fixture should have created it)"
    exit 1
}

try {
    # Case 1: missing -Branch
    $r1 = Invoke-Script -WorkDir $testRoot
    Assert-True -Name 'case1: missing -Branch exit ≠ 0' -Condition ($r1.Exit -ne 0)
    Assert-Match -Name 'case1: 訊息提及 Missing required argument' `
                 -Pattern 'Missing required argument' -InputText ($r1.Stdout + "`n" + $r1.Stderr)

    # Case 2: SKILL entry — re-invoke 結果一致
    $r2 = Invoke-Script -WorkDir $testRoot
    Assert-True -Name 'case2: SKILL-entry exit ≠ 0' -Condition ($r2.Exit -ne 0)

    # Case 3: branch test-99 (worktree absent)
    $r3 = Invoke-Script -WorkDir $testRoot -ExtraArgs @('-Branch', 'test-99')
    Assert-True -Name 'case3: branch test-99 unknown exit ≠ 0' -Condition ($r3.Exit -ne 0)
    Assert-Match -Name 'case3: 訊息提及 remote / not found / worktree' `
                 -Pattern '(not found|Unknown branch|worktree|remote-test-99)' -InputText ($r3.Stdout + "`n" + $r3.Stderr)
}
catch {
    Write-Output "  [FAIL] unhandled: $($_.Exception.Message)"
    $script:Failed++
}

Write-Output ''
Write-Output "push-to-svn-prepare.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
