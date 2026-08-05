Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Render this detector's own output as UTF-8. Detection below reads
# [System.Text.Encoding]::Default (CP_ACP), which is independent of these Console
# settings, so forcing UTF-8 here does NOT skew the codepage detection.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Detect whether the current PowerShell + Windows codepage passes Unicode argv to native exes
# (svn / git / msbuild) WITHOUT an ANSI-codepage translation. On zh-TW / zh-CN / ja-JP Windows
# running PowerShell 5.1, [System.Text.Encoding]::Default returns CP950 / CP936 / CP932 (DBCS),
# and a raw UTF-8 string passed as argv goes through CreateProcessA. PowerShell 7+ uses
# CreateProcessW, and the Win10 "Beta UTF-8" codepage makes CP_ACP == UTF-8.
#
# IMPORTANT: a False result here does NOT mean turbo-plugin's SVN operations break, and it does
# NOT mean filenames are stored non-portably. Empirically (svn 1.14 + PS5.1 + cp950, verified by
# reading the FSFS revision bytes): filenames whose characters are REPRESENTABLE in the active
# ANSI codepage (e.g. Traditional Chinese in Big5) round-trip correctly and svn stores them as
# portable UTF-8 -- a UTF-8 (Mac/Linux) checkout sees them correctly. The push/pull scripts handle
# this in BOTH shells: the PowerShell scripts scope [Console]::OutputEncoding to the system ANSI
# codepage around svn (argv bytes match svn's locale, so svn converts ANSI->UTF-8 correctly), and
# the Git Bash (.sh) scripts parse `svn status --xml` (always UTF-8).
#
# What False ACTUALLY signals: on PS5.1 + a non-UTF-8 codepage, native-exe argv can only carry
# characters the active codepage can represent. A filename with characters OUTSIDE that codepage
# (e.g. Japanese kana / CJK-ext / emoji on a Traditional-Chinese cp950 host) cannot be passed to
# svn.exe via argv at all -- it is lost/mangled to '?'. That is a LOCAL limitation (it breaks on
# this host, not merely cross-platform); the PS7 / Win10-UTF8 fix is only needed when you must use
# filenames with characters beyond your system codepage. (Token name kept for contract stability.)

# Output structured tokens for SKILL parsing:
#   PS_VERSION=<major.minor>
#   ANSI_CODEPAGE=<CP_ACP webname e.g. "windows-1252" or "utf-8">
#   OEM_CODEPAGE=<CP_OEM webname>
#   ARGV_SAFE_FOR_UNICODE=<True|False>
#   RECOMMENDATION=<OK|UPGRADE_PS7_OR_ENABLE_WIN10_UTF8>

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
    Write-Output 'NOTE: PowerShell 5.1 + non-UTF-8 system ANSI codepage detected.'
    Write-Output '  This does NOT break local SVN operations, and it does NOT make filenames'
    Write-Output '  non-portable. turbo-plugin push/pull scripts wrap svn in the system ANSI codepage'
    Write-Output '  (PowerShell) / parse `svn status --xml` (Git Bash), so filenames whose characters'
    Write-Output '  are representable in your codepage (e.g. Traditional Chinese on cp950) are stored'
    Write-Output '  in SVN as portable UTF-8 -- a Mac/Linux (UTF-8) checkout sees them correctly.'
    Write-Output ''
    Write-Output '  The real limitation: on this host a native-exe argument can only carry characters'
    Write-Output '  your system codepage can represent. A filename containing characters OUTSIDE it'
    Write-Output '  (e.g. Japanese kana / emoji on a Traditional-Chinese system) cannot be passed to'
    Write-Output '  svn at all and is lost/mangled -- and that breaks locally, not just cross-platform.'
    Write-Output '  If you need filenames with characters beyond your system codepage, either:'
    Write-Output '    - install PowerShell 7+   (winget install Microsoft.PowerShell --silent), or'
    Write-Output '    - enable the Win10 UTF-8 codepage (intl.cpl -> Administrative -> Beta UTF-8 + reboot).'
    Write-Output '  If you only use ASCII + your-own-language filenames, no action is needed.'
}
