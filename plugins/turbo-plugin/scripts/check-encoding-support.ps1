Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Detect whether the current PowerShell + Windows codepage supports lossless UTF-8 argv
# passing to native exes (svn / git / msbuild). On zh-TW / zh-CN / ja-JP Windows running
# PowerShell 5.1, [System.Text.Encoding]::Default returns CP950 / CP936 / CP932 (DBCS),
# and UTF-8 strings passed as argv get mangled via CreateProcessA → svn can't find files
# with Chinese filenames. PowerShell 7+ uses CreateProcessW so this is a non-issue.

# Output structured tokens for SKILL parsing:
#   PS_VERSION=<major.minor>
#   ANSI_CODEPAGE=<CP_ACP webname e.g. "windows-1252" or "utf-8">
#   OEM_CODEPAGE=<CP_OEM webname>
#   ARGV_SAFE_FOR_UNICODE=<True|False>
#   RECOMMENDATION=<UPGRADE_PS7|ENABLE_WIN10_UTF8|OK>

$psVersion = $PSVersionTable.PSVersion
$psMajor = $psVersion.Major
$psMinor = $psVersion.Minor

# CP_ACP is what Win32 ANSI APIs use; PS 5.1 native exe argv passes through this codepage.
$ansiEnc = [System.Text.Encoding]::Default
$ansiName = $ansiEnc.WebName  # e.g. "utf-8" or "windows-950"
$ansiCp = $ansiEnc.CodePage   # e.g. 65001 or 950

# OEM codepage (less critical, just informational)
$oemCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
$oemEnc = $null
try { $oemEnc = [System.Text.Encoding]::GetEncoding($oemCp); $oemName = $oemEnc.WebName } catch { $oemName = "cp$oemCp" }

# Decision matrix:
#   PS 7+ → always safe (uses CreateProcessW for argv)
#   PS 5.1 + CP_ACP = UTF-8 (65001, Win10 "Beta: Use Unicode UTF-8 for worldwide language support") → safe
#   PS 5.1 + CP_ACP != UTF-8 → UNSAFE for non-ASCII argv to native exes
$argvSafe = $false
$recommendation = 'OK'

if ($psMajor -ge 7) {
    $argvSafe = $true
    $recommendation = 'OK'
} elseif ($ansiCp -eq 65001) {
    # Win10 UTF-8 codepage enabled
    $argvSafe = $true
    $recommendation = 'OK'
} else {
    $argvSafe = $false
    # Prefer PS 7+ recommendation (easier to install, doesn't require reboot)
    # but mention both
    $recommendation = 'UPGRADE_PS7_OR_ENABLE_WIN10_UTF8'
}

Write-Output "PS_VERSION=$psMajor.$psMinor"
Write-Output "ANSI_CODEPAGE=$ansiName ($ansiCp)"
Write-Output "OEM_CODEPAGE=$oemName ($oemCp)"
Write-Output "ARGV_SAFE_FOR_UNICODE=$argvSafe"
Write-Output "RECOMMENDATION=$recommendation"

if (-not $argvSafe) {
    Write-Output ''
    Write-Output 'WARNING: PowerShell 5.1 + non-UTF-8 ANSI codepage detected.'
    Write-Output '  SVN operations on filenames containing non-ASCII characters (中文 / 日本語 / etc.) will fail.'
    Write-Output '  Root cause: Win32 CreateProcessA converts UTF-8 strings to ANSI (CP_ACP)'
    Write-Output '  before passing to svn.exe; CP950/CP932/CP1252 cannot encode the full Unicode range losslessly.'
    Write-Output ''
    Write-Output 'IMPORTANT: Git Bash (.sh) does NOT bypass this limitation. MSYS2 bash invokes native Windows'
    Write-Output '  exes (svn.exe) through the same Win32 ANSI codepage conversion. In Git Bash svn add appears'
    Write-Output '  to succeed (exit 0) but silently writes mojibake filenames into permanent SVN history —'
    Write-Output '  worse than PowerShell visible failure. ONLY PS 7+ or Win10 UTF-8 codepage truly fix this.'
    Write-Output ''
    Write-Output 'Mitigation options:'
    Write-Output '  (a) Install PowerShell 7+ via: winget install Microsoft.PowerShell --silent'
    Write-Output '      Then re-launch Claude Code from PowerShell 7 (uses CreateProcessW for argv).'
    Write-Output '  (b) Enable Win10 UTF-8 codepage (system-wide, REQUIRES REBOOT):'
    Write-Output '      Run intl.cpl -> Administrative tab -> Change system locale -> check'
    Write-Output '      "Beta: Use Unicode UTF-8 for worldwide language support" -> Reboot.'
    Write-Output '  (c) Accept limitation: avoid non-ASCII filenames in SVN operations (use ASCII names only).'
}
