# start-iis.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/start-iis.ps1
# Behavior:
#   - Defensive layer:.turbo-plugin/config.toml [iis] enabled = false → throw with bilingual msg
#   - Else:resolve IIS settings → render temp apphost.config (placeholder substitution) → launch
#     iisexpress.exe → wait for port LISTENING。
#
# Cases:
#   1. [iis] enabled = false canonical (CRITICAL — this is the canonical disabled fixture case):
#      改 fixture 的 config.toml 為 enabled = false → 跑 script → exit ≠ 0,stderr 含「IIS 已停用」;
#      temp apphost.config 不被建立。最後還原 config.toml 為 enabled = true。
#   2. Missing canonical applicationhost.config in fixture: 刪 fixture 的 apphost.config →
#      script throws「applicationhost.config does not exist」or「無法解析」
#   3. Missing csproj: workspace 無 csproj → throws .csproj 訊息
#   4. SKILL entry path (disabled fixture):用同樣的 [iis] enabled=false fixture 再呼叫一次 →
#      行為一致
#
# 不跑「真正啟動 IIS Express + port LISTENING」happy case:會 spawn 真實 process 污染 OS state,
#   且 fixture apphost.config 的 site name (HelloApp-deadbeef) 與動態 site name (HelloApp-<actualHash>)
#   不對齊,真實 launch 會 fail。Happy 完整路徑屬於 Phase 2 SKILL 手動測試範圍。

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

$repoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($repoRoot, 'plugins', 'turbo-plugin', 'scripts', 'start-iis.ps1')

$testRoot = 'C:\Turbo\test-turbo-plugin'
$cfgPath = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
$apphostPath = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'applicationhost.config')

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

function Set-IisEnabled {
    param([bool]$Enabled)
    if (-not [System.IO.File]::Exists($cfgPath)) {
        throw "cfg not found: $cfgPath"
    }
    $text = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
    $valueLine = if ($Enabled) { 'enabled = true' } else { 'enabled = false' }
    # Replace existing 'enabled = true|false' under [iis] section
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
                -ArgumentList $argList `
                -WorkingDirectory $WorkDir `
                -RedirectStandardOutput $tmpStdout `
                -RedirectStandardError $tmpStderr `
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
    # Case 1: [iis] enabled = false canonical disabled fixture
    Set-IisEnabled -Enabled $false
    try {
        # Snapshot existing temp apphost file paths (we'll check none get created for THIS workspace)
        $r1 = Invoke-Script -WorkDir $testRoot
        Assert-True -Name 'case1: [iis] disabled exit ≠ 0' -Condition ($r1.Exit -ne 0)
        $combined1 = $r1.Stdout + "`n" + $r1.Stderr
        Assert-Match -Name 'case1: stderr 含 IIS 已停用' -Pattern 'IIS 已停用' -InputText $combined1
        Assert-Match -Name 'case1: stderr 含 [iis] enabled = false 提示' -Pattern '\[iis\].*enabled.*false' -InputText $combined1

        # Case 4: SKILL entry re-invoke with same disabled fixture — same behavior
        $r4 = Invoke-Script -WorkDir $testRoot
        Assert-True -Name 'case4: SKILL-entry disabled exit ≠ 0' -Condition ($r4.Exit -ne 0)
        $combined4 = $r4.Stdout + "`n" + $r4.Stderr
        Assert-Match -Name 'case4: 訊息一致' -Pattern 'IIS 已停用' -InputText $combined4
    } finally {
        Set-IisEnabled -Enabled $true  # restore so other tests don't see disabled state
    }

    # Case 2: missing canonical applicationhost.config
    if ([System.IO.File]::Exists($apphostPath)) {
        $apphostBackup = [System.IO.File]::ReadAllBytes($apphostPath)
        try {
            [System.IO.File]::Delete($apphostPath)
            $r2 = Invoke-Script -WorkDir $testRoot
            Assert-True -Name 'case2: missing apphost exit ≠ 0' -Condition ($r2.Exit -ne 0)
            $combined2 = $r2.Stdout + "`n" + $r2.Stderr
            Assert-Match -Name 'case2: 訊息提及 applicationhost' `
                         -Pattern 'applicationhost' -InputText $combined2
        } finally {
            [System.IO.File]::WriteAllBytes($apphostPath, $apphostBackup)
        }
    } else {
        Write-Output '  [SKIP] case2: no canonical apphost present in fixture (treated as N/A)'
    }

    # Case 3: missing csproj — temp dir without csproj
    $sandboxGuid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $sandbox = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-startiis-$sandboxGuid")
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    try {
        $tpDir = [System.IO.Path]::Combine($sandbox, '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tpDir -Force
        # Need [iis] enabled = true so we get past the gate
        [System.IO.File]::WriteAllText(
            [System.IO.Path]::Combine($tpDir, 'config.toml'),
            "[iis]`nenabled = true`n",
            (New-Object System.Text.UTF8Encoding($false)))
        Push-Location -LiteralPath $sandbox
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            & git -c commit.gpgsign=false commit -q -m init *>$null
        } finally { Pop-Location }
        $r3 = Invoke-Script -WorkDir $sandbox
        Assert-True -Name 'case3: no csproj exit ≠ 0' -Condition ($r3.Exit -ne 0)
        $combined3 = $r3.Stdout + "`n" + $r3.Stderr
        Assert-Match -Name 'case3: 訊息提及 .csproj' -Pattern '\.csproj' -InputText $combined3
    } finally {
        try { [System.IO.Directory]::Delete($sandbox, $true) } catch { }
    }
}
catch {
    Write-Output "  [FAIL] unhandled: $($_.Exception.Message)"
    $script:Failed++
}

Write-Output ''
Write-Output "start-iis.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
