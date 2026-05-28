# pack-content.Tests.ps1
#
# Phase 1 hand-rolled tests for plugins/turbo-plugin/scripts/pack-content.ps1.
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
. ([System.IO.Path]::Combine($libDir, 'Assert-Helpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '_Common.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'pack-content.ps1')
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
    $outFile = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-reset-out-$stamp.txt")
    try {
        # `2>&1` 在 cmd.exe shell context 內,**不是** PS-level — cmd.exe 做 shell
        # 重導向,PS 看到的是 single stream,不會 trigger NativeCommandError。把字串
        # 拉到變數讓 lint-ps-compat 規則 4 不誤判。
        $cmdStr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$resetScript`" -TestRoot `"$TestRoot`" -SvnRepo `"C:\Turbo\turbo-plugin-pc-unused-svn`" -SkipSvn > `"$outFile`" 2>&1"
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
