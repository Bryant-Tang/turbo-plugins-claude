# pack-content.Tests.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/Compress-Content.ps1.
#
# Scope (U4 plan):
#   - no [frontend] section in config.toml → skip + exit 0
#   - [frontend].dir points to missing directory → throw
#   - trust hash NOT approved → TRUST_REQUIRED token emitted + exit non-zero
#   - happy + 中文 source body byte-preserve (R18 source body axis):  package.json + .cs with
#     中文 string literal + approved trust hash + build_command = Copy-Item Sample.cs bin/ →
#     verify bin/Sample.cs bytes equal source bytes (UTF-8 canonical filesystem byte preservation).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Compress-Content.ps1')
$baseDir         = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'base'))
$resetScript     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'reset', 'Reset-Fixture.ps1'))

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] pack-content.ps1 not found at $scriptUnderTest"
    exit 1
}

function Mirror-Base-To {
    # Run Reset-Fixture with -SkipSvn to mirror base/ into TestRoot.
    param([string]$TestRoot)
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 10)
    $outFile = [System.IO.Path]::Combine([System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-reset-out-$stamp.txt")
    try {
        # `2>&1` 在 cmd.exe shell context 內,**不是** PS-level — cmd.exe 做 shell
        # 重導向,PS 看到的是 single stream,不會 trigger NativeCommandError。把字串
        # 拉到變數讓 lint-ps-compat 規則 4 不誤判。
        # -SvnRepo is required by Reset-Fixture's signature but unused under -SkipSvn; pass a
        # sandbox-relative throwaway path so no machine-local literal leaks into the tree.
        $unusedSvn = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'unused-svn')
        $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$resetScript`" -TestRoot `"$TestRoot`" -SvnRepo `"$unusedSvn`" -SkipSvn > `"$outFile`" 2>&1"
        & cmd.exe /c $cmdStr
        return $LASTEXITCODE
    } finally {
        if ([System.IO.File]::Exists($outFile)) { try { [System.IO.File]::Delete($outFile) } catch {} }
    }
}

function Compute-TrustHash {
    param([string]$InstallCmd, [string]$BuildCmd)
    $trustInput = "$InstallCmd|$BuildCmd"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($trustInput))
    } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-Utf8NoBom-Local {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Append-Utf8 {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $Content, $enc)
}

# ─── Case 1: no [frontend] section → skip ────────────────────────────────────

Write-Output ''
Write-Output 'Case 1: no [frontend] section → "not configured" + exit 0'
$sb1 = New-Sandbox -Tag 'pc-1'
try {
    $testRoot = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    $rc = Mirror-Base-To -TestRoot $testRoot
    Assert-Equal -Name 'mirror exit 0' -Expected 0 -Actual $rc
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-Equal -Name 'no-frontend exit code 0' -Expected 0 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"
    Assert-Match -Name 'no-frontend stdout contains "not configured"' `
                 -Pattern 'not configured' -InputText $res.Stdout
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: [frontend].dir → missing dir ────────────────────────────────────

Write-Output ''
Write-Output 'Case 2: [frontend].dir → missing dir → "does not exist" + exit non-zero'
$sb2 = New-Sandbox -Tag 'pc-2'
try {
    $testRoot = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    $null = Mirror-Base-To -TestRoot $testRoot
    $cfg = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
    Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./no-such-frontend-dir`"`n"
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-True -Name 'missing-dir exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'missing-dir stderr contains "does not exist"' `
                 -Pattern 'does not exist' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Case 3: trust hash NOT approved → TRUST_REQUIRED ────────────────────────

Write-Output ''
Write-Output 'Case 3: [frontend] configured + package.json present, no trust file → TRUST_REQUIRED'
$sb3 = New-Sandbox -Tag 'pc-3'
try {
    $testRoot = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    $null = Mirror-Base-To -TestRoot $testRoot
    $frontendDir = [System.IO.Path]::Combine($testRoot, 'frontend')
    $null = New-Item -ItemType Directory -Path $frontendDir -Force
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')
    $cfg = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
    Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"cmd /c echo install`"`nbuild_command = `"cmd /c echo build`"`n"
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-True -Name 'trust-required exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stdout contains TRUST_REQUIRED token' `
                 -Pattern 'TRUST_REQUIRED' -InputText $res.Stdout
} finally {
    Remove-Sandbox -Dir $sb3
}

# ─── Case 4: 中文 source body byte-preserve (R18 source body axis) ──────────

Write-Output ''
Write-Output 'Case 4: 中文 source body byte-preserve through pack (R18; dict #5.3)'
$sb4 = New-Sandbox -Tag 'pc-4'
try {
    $testRoot = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
    $null = Mirror-Base-To -TestRoot $testRoot

    # Frontend dir + package.json
    $frontendDir = [System.IO.Path]::Combine($testRoot, 'frontend')
    $null = New-Item -ItemType Directory -Path $frontendDir -Force
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')

    # 中文 source file with string literal #5.3
    $zh53     = '"中文錯誤訊息:檔案不存在"'
    $srcBody  = "namespace HelloApp {`r`n    public class Sample {`r`n        // 中文註解:確認 byte preserve`r`n        public string Get() { return $zh53; }`r`n    }`r`n}`r`n"
    $srcFile = [System.IO.Path]::Combine($frontendDir, 'Sample.cs')
    Write-Utf8NoBom-Local -Path $srcFile -Content $srcBody
    $srcBytes = [System.IO.File]::ReadAllBytes($srcFile)

    # bin/ dir for build output target
    $binDir = [System.IO.Path]::Combine($frontendDir, 'bin')
    $null = New-Item -ItemType Directory -Path $binDir -Force
    $dstFile = [System.IO.Path]::Combine($binDir, 'Sample.cs')

    # Pre-approve trust by writing pack-content-trust.local.toml with matching hash.
    $installCmd = 'cmd /c echo install-ok'
    # build_command:in PowerShell, Copy-Item preserves bytes verbatim. We use a token-split-safe form.
    $buildCmd   = "powershell -NoProfile -Command Copy-Item Sample.cs bin\Sample.cs -Force"
    $cfg = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')
    Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"$installCmd`"`nbuild_command = `"$buildCmd`"`n"

    $hash = Compute-TrustHash -InstallCmd $installCmd -BuildCmd $buildCmd
    $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
    Write-Utf8NoBom-Local -Path $trustFile -Content "approved_hash = `"$hash`"`n"

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-Equal -Name 'happy-path exit 0' -Expected 0 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"
    Assert-True -Name 'bin/Sample.cs created by build_command' -Condition ([System.IO.File]::Exists($dstFile))
    if ([System.IO.File]::Exists($dstFile)) {
        Assert-FileBytes -Name 'bin/Sample.cs byte-equal to source (中文 byte-preserve)' `
                         -ExpectedBytes $srcBytes -ActualFilePath $dstFile
    }
} finally {
    Remove-Sandbox -Dir $sb4
}

# ─── Trust-gate side-effect cases (U4 / R4) ──────────────────────────────────
#
# The real security property of pack-content is: install/build commands must clear the
# trust-hash gate BEFORE they execute. The 002 U8.3 shell-metachar canary is a no-op
# (tokenized `& $tokens[0] @tokenArgs` never goes through a shell), so we instead prove
# the gate itself. To distinguish "blocked" from "ran" we point install_command at a
# command that leaves an observable trace (creates a sentinel file) and assert presence
# / absence of the sentinel.
#
# Helper: build a [frontend] config whose install_command touches $SentinelPath via a
# token-split-safe `cmd /c type nul > <abs-path>` invocation. The production gate splits the
# command on whitespace (`$installCmd -split '\s+'`) and never reparses quotes, so the sentinel
# path MUST be space-free for the redirect target to survive tokenization — see
# New-SpaceFreeSentinel (the repo/sandbox path itself may contain spaces under AE8).

# AE8: the sandbox may live under a spaced parent path, but the gate tokenizes install_command
# on whitespace, so the sentinel redirect target must be space-free. Mint it under the system
# drive root (always space-free + writable) instead of inside the spaced sandbox.
function New-SpaceFreeSentinel {
    param([string]$Leaf = 'sentinel')
    $sysDrive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($sysDrive)) { $sysDrive = 'C:' }
    $dir = $sysDrive + '\tp-sentinel-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $null = New-Item -ItemType Directory -Path $dir -Force
    return [System.IO.Path]::Combine($dir, "$Leaf.txt")
}

function New-FrontendWithSentinel {
    param([string]$TestRoot, [string]$SentinelPath)
    $frontendDir = [System.IO.Path]::Combine($TestRoot, 'frontend')
    $null = New-Item -ItemType Directory -Path $frontendDir -Force
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($frontendDir, 'package.json'), '{"name":"x"}')
    # `cmd /c type nul > <path>` creates an empty sentinel file. Path MUST be space-free (gate
    # tokenizes on whitespace — see New-SpaceFreeSentinel).
    $installCmd = "cmd /c type nul > $SentinelPath"
    $buildCmd   = ''
    $cfg = [System.IO.Path]::Combine($TestRoot, '.turbo-plugin', 'config.toml')
    Append-Utf8 -Path $cfg -Content "`n[frontend]`ndir = `"./frontend`"`ninstall_command = `"$installCmd`"`nbuild_command = `"$buildCmd`"`n"
    return [PSCustomObject]@{ InstallCmd = $installCmd; BuildCmd = $buildCmd }
}

# ─── Case 5: unapproved command (no trust file) → blocked, sentinel NOT created ──

Write-Output ''
Write-Output 'Case 5: unapproved install_command → blocked before execution (sentinel absent)'
$sb5 = New-Sandbox -Tag 'pc-5'
try {
    $testRoot = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin')
    $null = Mirror-Base-To -TestRoot $testRoot
    $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-unapproved'
    $null = New-FrontendWithSentinel -TestRoot $testRoot -SentinelPath $sentinel
    # No pack-content-trust.local.toml written → gate must reject.
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-True -Name 'unapproved exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'unapproved emits TRUST_REQUIRED' -Pattern 'TRUST_REQUIRED' -InputText $res.Stdout
    Assert-True -Name 'unapproved: sentinel NOT created (command did not run)' `
                -Condition (-not [System.IO.File]::Exists($sentinel)) `
                -Message "sentinel unexpectedly present at $sentinel"
} finally {
    Remove-Sandbox -Dir $sb5
    if ($sentinel) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($sentinel)) }
}

# ─── Case 6: trust hash stale (config changed since approval) → blocked ──────

Write-Output ''
Write-Output 'Case 6: trust file present but hash does not match config → blocked (sentinel absent)'
$sb6 = New-Sandbox -Tag 'pc-6'
try {
    $testRoot = [System.IO.Path]::Combine($sb6, 'test-turbo-plugin')
    $null = Mirror-Base-To -TestRoot $testRoot
    $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-stale'
    $null = New-FrontendWithSentinel -TestRoot $testRoot -SentinelPath $sentinel
    # Write a trust file whose approved_hash is for *different* (old) commands —
    # simulates "config edited after approval". Hash must therefore mismatch.
    $staleHash = Compute-TrustHash -InstallCmd 'cmd /c echo old-install' -BuildCmd 'cmd /c echo old-build'
    $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
    Write-Utf8NoBom-Local -Path $trustFile -Content "approved_hash = `"$staleHash`"`n"
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-True -Name 'stale-hash exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stale-hash emits TRUST_REQUIRED' -Pattern 'TRUST_REQUIRED' -InputText $res.Stdout
    Assert-True -Name 'stale-hash: sentinel NOT created (command did not run)' `
                -Condition (-not [System.IO.File]::Exists($sentinel)) `
                -Message "sentinel unexpectedly present at $sentinel"
} finally {
    Remove-Sandbox -Dir $sb6
    if ($sentinel) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($sentinel)) }
}

# ─── Case 7: approved command (control) → runs, sentinel IS created ──────────

Write-Output ''
Write-Output 'Case 7: approved hash matches config → command runs (sentinel present, control group)'
$sb7 = New-Sandbox -Tag 'pc-7'
try {
    $testRoot = [System.IO.Path]::Combine($sb7, 'test-turbo-plugin')
    $null = Mirror-Base-To -TestRoot $testRoot
    $sentinel = New-SpaceFreeSentinel -Leaf 'sentinel-approved'
    $cmds = New-FrontendWithSentinel -TestRoot $testRoot -SentinelPath $sentinel
    # Write a trust file whose approved_hash matches the *actual* configured commands.
    $hash = Compute-TrustHash -InstallCmd $cmds.InstallCmd -BuildCmd $cmds.BuildCmd
    $trustFile = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
    Write-Utf8NoBom-Local -Path $trustFile -Content "approved_hash = `"$hash`"`n"
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $testRoot -ScriptArgs @()
    Assert-Equal -Name 'approved exit 0' -Expected 0 -Actual $res.ExitCode `
        -Message "stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"
    Assert-True -Name 'approved: sentinel created (command ran — gate did not over-block)' `
                -Condition ([System.IO.File]::Exists($sentinel)) `
                -Message "sentinel missing at $sentinel; stdout:`n$($res.Stdout)`nstderr:`n$($res.Stderr)"
} finally {
    Remove-Sandbox -Dir $sb7
    if ($sentinel) { Remove-Sandbox -Dir ([System.IO.Path]::GetDirectoryName($sentinel)) }
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "pack-content: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
