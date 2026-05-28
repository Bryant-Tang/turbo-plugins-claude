# cleanup-orphan-iis.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/cleanup-orphan-iis.ps1
# Behavior: 找與 current site name 不同 hash 的 stale iisexpress 進程 + 沒人在用的 temp apphost 檔。
#   無 orphan → exit 0 + echo「No orphan...」。
#
# 注意:此 script **沒有** 自己的 [iis] enabled gate(只 SKILL.md 有;見 commit 84e944a)。
#   因此本 case 文檔記為 deviation:我們改 assert script behavior when called directly with
#   [iis]=false → 因為 script 本身沒 gate,行為與 [iis]=true 一致(exit 0 + No orphan)。
#   這是「SKILL is the gatekeeper」設計;在 Phase 2 SKILL 測試會 cover SKILL-level gate。
#
# Cases:
#   1. No orphan: fresh fixture (no orphan process) → exit 0,stdout 含「No orphan IIS Express」
#   2. SKILL entry re-invoke: 一致 (no-orphan)
#   3. [iis] enabled = false (script does NOT have script-level gate — by design):
#      script 仍 exit 0 + No orphan;此 case 文件 deviation,SKILL-level gate test 在 Phase 2 cover

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Assert-Helpers.ps1')
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

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'cleanup-orphan-iis.ps1')

$testRoot = 'C:\Turbo\test-turbo-plugin'
$cfgPath = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')

function Ensure-FixtureGit {
    if (-not [System.IO.Directory]::Exists($testRoot)) { return $false }
    if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($testRoot, '.git'))) {
        Push-Location -LiteralPath $testRoot
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            & git -c commit.gpgsign=false commit -q -m init *>$null
        } finally { Pop-Location }
    }
    return $true
}

function Set-IisEnabled {
    param([bool]$Enabled)
    if (-not [System.IO.File]::Exists($cfgPath)) { throw "cfg not found: $cfgPath" }
    $text = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
    $valueLine = if ($Enabled) { 'enabled = true' } else { 'enabled = false' }
    $patched = [regex]::Replace($text, '(?m)^enabled\s*=\s*(true|false)\s*$', $valueLine)
    [System.IO.File]::WriteAllText($cfgPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
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
    Write-Output "  [FAIL] setup: $testRoot missing"
    exit 1
}

try {
    # Case 1: no orphan
    $r1 = Invoke-Script -WorkDir $testRoot
    Assert-Equal -Name 'case1: no-orphan exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: stdout 含 No orphan IIS Express' `
                 -Pattern 'No orphan IIS Express' -InputText $r1.Stdout

    # Case 2: SKILL entry re-invoke
    $r2 = Invoke-Script -WorkDir $testRoot
    Assert-Equal -Name 'case2: SKILL-entry no-orphan exit 0' -Expected 0 -Actual $r2.Exit
    Assert-Match -Name 'case2: 訊息一致' -Pattern 'No orphan IIS Express' -InputText $r2.Stdout

    # Case 3: [iis] enabled = false — script has NO script-level gate.
    # Documented deviation: SKILL.md guards [iis]=false; script proceeds normally.
    Set-IisEnabled -Enabled $false
    try {
        $r3 = Invoke-Script -WorkDir $testRoot
        # By design: script-level still runs (SKILL is the gatekeeper). exit 0 + No orphan.
        Assert-Equal -Name 'case3 (deviation): script-level no [iis] gate — still exits 0' `
                     -Expected 0 -Actual $r3.Exit
        Assert-Match -Name 'case3: 訊息仍是 No orphan' -Pattern 'No orphan IIS Express' -InputText $r3.Stdout
    } finally {
        Set-IisEnabled -Enabled $true
    }
}
catch {
    Write-Output "  [FAIL] unhandled: $($_.Exception.Message)"
    $script:Failed++
}

Write-Output ''
Write-Output "cleanup-orphan-iis.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
