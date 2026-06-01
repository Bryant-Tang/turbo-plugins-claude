# stop-iis.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/Stop-Iis.ps1
# Behavior: 跑 [iis] enabled gate;若 enabled,從 CIM 找 iisexpress.exe 並用 /site:<name> match 殺。
#   無 instance → echo 提示 + exit 0;temp apphost 也順便清掉。
#
# Cases:
#   1. No IIS running: fresh fixture (沒有 iisexpress) → exit 0 + stdout 含「No IIS Express
#      process found for site」
#   2. [iis] enabled = false consistency: 改 config.toml 為 disabled → exit ≠ 0,stderr 含「IIS 已停用」
#   3. SKILL entry: 再呼叫 no-running case → 行為一致

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
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Stop-Iis.ps1')

$testRoot = 'C:\Turbo\test-turbo-plugin\test-turbo-plugin'
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
    # Case 1: no IIS running (fresh fixture, [iis]=true default)
    $r1 = Invoke-Script -WorkDir $testRoot
    Assert-Equal -Name 'case1: no-IIS exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: stdout 含 No IIS Express process found' `
                 -Pattern 'No IIS Express process found' -InputText $r1.Stdout

    # Case 2: [iis] disabled consistency
    Set-IisEnabled -Enabled $false
    try {
        $r2 = Invoke-Script -WorkDir $testRoot
        Assert-True -Name 'case2: [iis]=false exit ≠ 0' -Condition ($r2.Exit -ne 0)
        $combined2 = $r2.Stdout + "`n" + $r2.Stderr
        Assert-Match -Name 'case2: stderr 含 IIS 已停用' -Pattern 'IIS 已停用' -InputText $combined2
    } finally {
        Set-IisEnabled -Enabled $true
    }

    # Case 3: SKILL entry re-invoke (no-running) → 一致
    $r3 = Invoke-Script -WorkDir $testRoot
    Assert-Equal -Name 'case3: SKILL-entry no-IIS exit 0' -Expected 0 -Actual $r3.Exit
    Assert-Match -Name 'case3: 訊息一致' -Pattern 'No IIS Express process found' -InputText $r3.Stdout
}
catch {
    Write-Output "  [FAIL] unhandled: $($_.Exception.Message)"
    $script:Failed++
}

Write-Output ''
Write-Output "stop-iis.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
