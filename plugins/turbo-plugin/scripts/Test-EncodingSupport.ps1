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
# IMPORTANT (v0.5.2): a False result here does NOT mean turbo-plugin's SVN operations break.
# The push/pull scripts handle non-ASCII filenames in BOTH shells regardless of this flag —
# the PowerShell scripts scope [Console]::OutputEncoding to the system ANSI codepage around svn
# calls (so capture + argv stay byte-consistent with the on-disk filename), and the Git Bash
# (.sh) scripts parse `svn status --xml` (always UTF-8). This flag is therefore a CROSS-PLATFORM
# PORTABILITY signal — whether non-ASCII filenames land in SVN as portable UTF-8 vs system DBCS —
# NOT a local "will it work" gate. (Token name kept for contract stability; see WARNING below.)

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
    Write-Output 'NOTE: PowerShell 5.1 + non-UTF-8 system ANSI codepage detected.'
    Write-Output '  This does NOT break local SVN operations. turbo-plugin push/pull scripts (v0.5.2+)'
    Write-Output '  handle non-ASCII filenames in THIS environment on BOTH shells: the PowerShell'
    Write-Output '  scripts wrap svn calls in the system ANSI codepage (OutputEncoding), and the Git'
    Write-Output '  Bash (.sh) scripts parse `svn status --xml`. Both add/commit/checkout non-ASCII'
    Write-Output '  filenames correctly here -- you do NOT need to switch shells.'
    Write-Output ''
    Write-Output '  The only remaining concern is CROSS-PLATFORM interop: in this environment SVN'
    Write-Output '  stores non-ASCII filenames as system DBCS bytes (Big5 / GB2312 / Shift-JIS), not'
    Write-Output '  UTF-8. If your SVN repo has Mac/Linux (UTF-8) contributors, they may see garbled'
    Write-Output '  filenames. For portable UTF-8 filenames across operating systems, either:'
    Write-Output '    - install PowerShell 7+   (winget install Microsoft.PowerShell --silent), or'
    Write-Output '    - enable the Win10 UTF-8 codepage (intl.cpl -> Administrative -> Beta UTF-8 + reboot).'
    Write-Output '  If your whole team uses the same Chinese/CJK Windows, or you avoid non-ASCII'
    Write-Output '  filenames, no action is needed.'
}
